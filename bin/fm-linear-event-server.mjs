#!/usr/bin/env node

import { createHmac, createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, open, readFile, readdir, rename, rmdir, unlink } from "node:fs/promises";
import { spawn } from "node:child_process";
import path from "node:path";

const host = process.env.FM_LINEAR_EVENT_HOST || "127.0.0.1";
const port = Number.parseInt(process.env.FM_LINEAR_EVENT_PORT || "4481", 10);
const stateDir = process.env.FM_LINEAR_EVENT_STATE || path.join(process.cwd(), "state", "linear-events");
const secretFile = process.env.FM_LINEAR_EVENT_SECRET_FILE || path.join(stateDir, "webhook-secret");
const worker = process.env.FM_LINEAR_EVENT_WORKER || path.join(process.cwd(), "bin", "fm-linear-event-worker.sh");
const maxBody = Number.parseInt(process.env.FM_LINEAR_EVENT_MAX_BODY || "1048576", 10);
const maxAgeMs = Number.parseInt(process.env.FM_LINEAR_EVENT_MAX_AGE_MS || "60000", 10);
const allowedOrg = process.env.FM_LINEAR_EVENT_ORGANIZATION_ID || "";
const inboxDir = path.join(stateDir, "inbox");
const doneDir = path.join(stateDir, "done");
const failedDir = path.join(stateDir, "failed");
const claimsDir = path.join(stateDir, "claims");
const logFile = path.join(stateDir, "events.log");

let queue = Promise.resolve();

function fail(message) {
  process.stderr.write(`fm-linear-event-server: ${message}\n`);
  process.exit(2);
}

async function appendLog(message) {
  await mkdir(stateDir, { recursive: true });
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
      env: process.env,
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      if (stderr.length < 4096) stderr += chunk.toString();
    });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 2000).unref();
    }, Number.parseInt(process.env.FM_LINEAR_EVENT_WORKER_TIMEOUT_MS || "180000", 10));
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
      await appendLog(`failed ${base}: ${String(error.message || error).replaceAll("\n", " ").slice(0, 600)}`);
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
  if (!Number.isFinite(timestamp) || Math.abs(Date.now() - timestamp) > maxAgeMs) {
    res.writeHead(401).end();
    return;
  }
  if (allowedOrg && event.organizationId !== allowedOrg) {
    res.writeHead(403).end();
    return;
  }

  const key = deliveryKey(req, body);
  const file = path.join(inboxDir, `${key}.json`);
  for (const dir of [inboxDir, doneDir, failedDir, claimsDir]) await mkdir(dir, { recursive: true });
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

if (!Number.isInteger(port) || port < 1 || port > 65535) fail("invalid port");
const secret = (await readFile(secretFile, "utf8").catch(() => "")).trim();
if (!secret) fail(`missing webhook secret: ${secretFile}`);
for (const dir of [stateDir, inboxDir, doneDir, failedDir, claimsDir]) await mkdir(dir, { recursive: true });

for (const name of await readdir(inboxDir)) {
  if (/^[0-9a-f]{64}\.json$/.test(name)) enqueue(path.join(inboxDir, name));
}

const server = createServer((req, res) => {
  receive(req, res, secret).catch(async (error) => {
    await appendLog(`request error: ${String(error.message || error).replaceAll("\n", " ").slice(0, 600)}`).catch(() => {});
    if (!res.headersSent) res.writeHead(500);
    res.end();
  });
});
server.listen(port, host, () => process.stdout.write(`fm-linear-event-server listening on http://${host}:${port}\n`));
