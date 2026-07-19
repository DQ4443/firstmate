#!/usr/bin/env node

// Linear leg of the housekeeping intake daemon.
// Receives signed Linear webhooks, verifies them, dedups by delivery, persists
// the raw body, and hands each verified delivery to the worker. Every path
// derives from FM_HK_ROOT (default $HOME/fm-state/housekeeping) so the server,
// the worker, and the reconcile sweep all agree on one runtime tree.

import { createHmac, createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import {
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  rmdir,
  unlink,
} from "node:fs/promises";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));

// Runtime tree. FM_HK_ROOT is the single source of truth; the worker and the
// reconcile sweep default to the same path, and the server re-exports the
// resolved value into the worker's environment so a defaulted root can never
// drift between the two processes.
const hkRoot =
  process.env.FM_HK_ROOT || path.join(os.homedir(), "fm-state", "housekeeping");
const secretFile =
  process.env.FM_HK_LINEAR_SECRET_FILE ||
  path.join(hkRoot, "secrets", "linear-webhook-secret");
const worker =
  process.env.FM_HK_LINEAR_WORKER ||
  path.join(scriptDir, "fm-linear-event-worker.sh");

// Raw-delivery staging for the Linear leg, kept apart from the contract's
// normalized queue/ tree. inbox holds accepted-but-unprocessed raw bodies,
// done holds processed raw bodies (the reconcile sweep reads these), failed
// holds deliveries the worker could not normalize, claims dedups Linear-Delivery.
const linearDir = path.join(hkRoot, "linear");
const inboxDir = path.join(linearDir, "inbox");
const doneDir = path.join(linearDir, "done");
const failedDir = path.join(linearDir, "failed");
const claimsDir = path.join(linearDir, "claims");
const logFile = path.join(linearDir, "events.log");

// Listen address. FM_HK_LINEAR_ADDR is host:port; split on the last colon so an
// explicit host is preserved, defaulting to the documented 127.0.0.1:4481.
const listenAddr = process.env.FM_HK_LINEAR_ADDR || "127.0.0.1:4481";
const lastColon = listenAddr.lastIndexOf(":");
const host = lastColon > 0 ? listenAddr.slice(0, lastColon) : "127.0.0.1";
const port = Number.parseInt(
  lastColon > 0 ? listenAddr.slice(lastColon + 1) : listenAddr,
  10,
);

// Verification and dedup limits: a hard 1MiB body cap and a generous
// webhookTimestamp freshness window. Replay is already fully handled by the
// O_EXCL claims/ dedup dir, so a tight window buys no protection and only 401s
// healthy-but-late deliveries under clock skew or Linear delivery latency, and
// every such 401 counts toward Linear's three-strikes webhook auto-disable. The
// window defaults to 15 minutes and is env-tunable; set it to 0 to accept any
// timestamp and rely on the claims dir alone for replay defense.
const maxBody = 1048576;
const maxAgeMs = Number.parseInt(
  process.env.FM_HK_LINEAR_MAX_AGE_MS || "900000",
  10,
);
const allowedOrg = process.env.FM_HK_LINEAR_ORGANIZATION_ID || "";
const workerTimeoutMs = Number.parseInt(
  process.env.FM_HK_LINEAR_WORKER_TIMEOUT_MS || "180000",
  10,
);

let queue = Promise.resolve();

function fail(message) {
  process.stderr.write(`fm-linear-event-server: ${message}\n`);
  process.exit(2);
}

async function appendLog(message) {
  await mkdir(linearDir, { recursive: true });
  const fh = await open(logFile, "a", 0o600);
  try {
    await fh.appendFile(`${new Date().toISOString()} ${message}\n`);
  } finally {
    await fh.close();
  }
}

function safeEqualHex(actual, expected) {
  if (!/^[0-9a-f]{64}$/i.test(actual || "")) return false;
  const a = Buffer.from(actual, "hex");
  const b = Buffer.from(expected, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

function deliveryKey(req, body) {
  const supplied = String(req.headers["linear-delivery"] || "").trim();
  const raw = supplied || createHash("sha256").update(body).digest("hex");
  return createHash("sha256").update(raw).digest("hex");
}

async function atomicWrite(file, body) {
  const tmp = `${file}.tmp.${process.pid}.${Date.now()}`;
  const fh = await open(tmp, "wx", 0o600);
  try {
    await fh.writeFile(body);
    await fh.sync();
  } finally {
    await fh.close();
  }
  try {
    await rename(tmp, file);
  } catch (error) {
    await unlink(tmp).catch(() => {});
    throw error;
  }
}

function runWorker(file) {
  return new Promise((resolve, reject) => {
    const child = spawn(worker, [file], {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, FM_HK_ROOT: hkRoot },
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      if (stderr.length < 4096) stderr += chunk.toString();
    });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 2000).unref();
    }, workerTimeoutMs);
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`worker exit ${code ?? signal}: ${stderr.trim()}`));
    });
  });
}

function enqueue(file) {
  queue = queue.then(async () => {
    const base = path.basename(file);
    try {
      await runWorker(file);
      await rename(file, path.join(doneDir, base));
      await appendLog(`processed ${base}`);
    } catch (error) {
      await rename(file, path.join(failedDir, base)).catch(() => {});
      await appendLog(
        `failed ${base}: ${String(error.message || error)
          .replaceAll("\n", " ")
          .slice(0, 600)}`,
      );
    }
  });
}

async function receive(req, res, secret) {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"status":"ok"}\n');
    return;
  }
  if (req.method !== "POST" || req.url !== "/linear") {
    res.writeHead(404).end();
    return;
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBody) {
      res.writeHead(413).end();
      req.destroy();
      return;
    }
    chunks.push(chunk);
  }
  const body = Buffer.concat(chunks);
  const expected = createHmac("sha256", secret).update(body).digest("hex");
  if (!safeEqualHex(String(req.headers["linear-signature"] || ""), expected)) {
    res.writeHead(401).end();
    return;
  }

  let event;
  try {
    event = JSON.parse(body.toString("utf8"));
  } catch {
    res.writeHead(400).end();
    return;
  }
  const timestamp = Number(event.webhookTimestamp);
  if (!Number.isFinite(timestamp)) {
    res.writeHead(401).end();
    return;
  }
  if (
    Number.isFinite(maxAgeMs) &&
    maxAgeMs > 0 &&
    Math.abs(Date.now() - timestamp) > maxAgeMs
  ) {
    res.writeHead(401).end();
    return;
  }
  if (allowedOrg && event.organizationId !== allowedOrg) {
    res.writeHead(403).end();
    return;
  }

  const key = deliveryKey(req, body);
  const file = path.join(inboxDir, `${key}.json`);
  for (const dir of [inboxDir, doneDir, failedDir, claimsDir])
    await mkdir(dir, { recursive: true });
  try {
    await mkdir(path.join(claimsDir, key));
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"accepted":true,"duplicate":true}\n');
    return;
  }
  try {
    await atomicWrite(file, body);
  } catch (error) {
    await rmdir(path.join(claimsDir, key)).catch(() => {});
    throw error;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end('{"accepted":true,"duplicate":false}\n');
  enqueue(file);
}

if (!Number.isInteger(port) || port < 1 || port > 65535)
  fail(`invalid listen address: ${listenAddr}`);
const secret = (await readFile(secretFile, "utf8").catch(() => "")).trim();
if (!secret) fail(`missing webhook secret: ${secretFile}`);
for (const dir of [linearDir, inboxDir, doneDir, failedDir, claimsDir])
  await mkdir(dir, { recursive: true });

// Startup drain: reprocess any raw delivery persisted before a crash. This
// consumes only already-received, already-persisted bodies; it never reaches
// out to Linear.
for (const name of await readdir(inboxDir)) {
  if (/^[0-9a-f]{64}\.json$/.test(name)) enqueue(path.join(inboxDir, name));
}

const server = createServer((req, res) => {
  receive(req, res, secret).catch(async (error) => {
    await appendLog(
      `request error: ${String(error.message || error)
        .replaceAll("\n", " ")
        .slice(0, 600)}`,
    ).catch(() => {});
    if (!res.headersSent) res.writeHead(500);
    res.end();
  });
});
server.listen(port, host, () =>
  process.stdout.write(
    `fm-linear-event-server listening on http://${host}:${port}\n`,
  ),
);
