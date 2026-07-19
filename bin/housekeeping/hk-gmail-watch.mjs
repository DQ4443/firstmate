#!/usr/bin/env node
// hk-gmail-watch.mjs: manage the Gmail push watch on the gemini-notes label.
//
// Subcommands:
//   bootstrap  Run the OAuth installed-app consent flow and store the refresh
//              token. Loopback redirect (http://127.0.0.1:PORT) with
//              --callback-port, plus a paste fallback for a redirect URL or code.
//   register   Resolve the gemini-notes label id, call users.watch with
//              labelIds=[that id], labelFilterBehavior=INCLUDE, the configured
//              Pub/Sub topic, and store the historyId + watch expiry cursors.
//   renew      Re-register (daily-timer target) and log the new expiry.
//   status     Print the stored cursors and label resolution.
//
// No npm dependencies; builtin fetch + a tiny loopback http server.

import http from "node:http";
import {
  getGmailToken,
  buildConsentUrl,
  exchangeCode,
  GMAIL_SCOPES,
} from "./hk-google-auth.mjs";
import { ensureDirs, writeCursor, readCursor, log } from "./hk-lib.mjs";

const GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me";
const LABEL_NAME = process.env.FM_HK_GMAIL_LABEL || "gemini-notes";
const GCP_PROJECT = process.env.FM_HK_GCP_PROJECT || "firstmate-housekeeping";
const TOPIC =
  process.env.FM_HK_GMAIL_TOPIC ||
  `projects/${GCP_PROJECT}/topics/gmail-gemini-notes`;
const OOB_REDIRECT = "urn:ietf:wg:oauth:2.0:oob";

async function gmailGet(pathPart, token) {
  const res = await fetch(`${GMAIL_API}${pathPart}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok)
    throw new Error(
      `gmail GET ${pathPart} ${res.status}: ${(await res.text()).slice(0, 200)}`,
    );
  return res.json();
}

async function gmailPost(pathPart, token, body) {
  const res = await fetch(`${GMAIL_API}${pathPart}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok)
    throw new Error(
      `gmail POST ${pathPart} ${res.status}: ${(await res.text()).slice(0, 200)}`,
    );
  return res.json();
}

// Resolve the label id for the gemini-notes label; throws if it is absent.
export async function resolveLabelId(token) {
  const data = await gmailGet("/labels", token);
  const match = (data.labels || []).find((l) => l.name === LABEL_NAME);
  if (!match)
    throw new Error(
      `label "${LABEL_NAME}" not found; create the Gmail filter+label first`,
    );
  return match.id;
}

// Parse an authorization code out of either a bare code or a full redirect URL.
function parseCode(input) {
  const trimmed = input.trim();
  if (!trimmed) return null;
  if (trimmed.startsWith("http")) {
    try {
      return new URL(trimmed).searchParams.get("code");
    } catch {
      return null;
    }
  }
  return trimmed;
}

// Read one line from stdin (for the paste fallback).
function readLine(promptText) {
  process.stderr.write(promptText);
  return new Promise((resolve) => {
    process.stdin.resume();
    process.stdin.once("data", (d) => {
      process.stdin.pause();
      resolve(d.toString());
    });
  });
}

// Run the loopback consent flow: print the URL, wait for the browser redirect.
async function bootstrapLoopback(port) {
  const redirectUri = `http://127.0.0.1:${port}`;
  const url = await buildConsentUrl(redirectUri, GMAIL_SCOPES);
  const codePromise = new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const code = new URL(req.url, redirectUri).searchParams.get("code");
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(
        code
          ? "Authorization received. You can close this tab."
          : "No code in redirect.",
      );
      server.close();
      if (code) resolve(code);
      else reject(new Error("redirect carried no code"));
    });
    server.on("error", reject);
    server.listen(port, "127.0.0.1");
  });
  process.stderr.write(
    `Open this URL in a browser and grant access:\n\n${url}\n\nListening on ${redirectUri} ...\n`,
  );
  const code = await codePromise;
  await exchangeCode(code, redirectUri);
  log("hk-gmail-watch", { status: "bootstrapped", flow: "loopback" });
}

// Run the paste fallback: print the URL, read a code or redirect URL on stdin.
async function bootstrapPaste() {
  const url = await buildConsentUrl(OOB_REDIRECT, GMAIL_SCOPES);
  process.stderr.write(
    `Open this URL, grant access, then paste the code or full redirect URL:\n\n${url}\n\n`,
  );
  const line = await readLine("code/url> ");
  const code = parseCode(line);
  if (!code) throw new Error("no authorization code parsed from input");
  await exchangeCode(code, OOB_REDIRECT);
  log("hk-gmail-watch", { status: "bootstrapped", flow: "paste" });
}

async function cmdBootstrap(args) {
  await ensureDirs();
  const portFlag = args.indexOf("--callback-port");
  if (portFlag !== -1 && args[portFlag + 1]) {
    await bootstrapLoopback(Number(args[portFlag + 1]));
  } else {
    await bootstrapPaste();
  }
}

// Register (or re-register) the watch and store the resulting cursors.
export async function registerWatch() {
  await ensureDirs();
  const token = await getGmailToken();
  const labelId = await resolveLabelId(token);
  const resp = await gmailPost("/watch", token, {
    topicName: TOPIC,
    labelIds: [labelId],
    labelFilterBehavior: "INCLUDE",
  });
  // Seed the pull cursor only on first register. A daily renew re-issues watch
  // and returns the mailbox's *current* historyId; overwriting the cursor with
  // it would jump the pull cursor forward to now, silently skipping every
  // message the pull daemon had not yet processed (e.g. while it was down).
  // The pull daemon owns advancing gmail-history-id from here on.
  const existingHistoryId = await readCursor("gmail-history-id");
  if (existingHistoryId == null) {
    await writeCursor("gmail-history-id", resp.historyId);
  }
  // watch expiration is epoch millis as a string.
  await writeCursor("gmail-watch-expiry", resp.expiration);
  await writeCursor("gmail-label-id", labelId);
  const expiryIso = resp.expiration
    ? new Date(Number(resp.expiration)).toISOString()
    : "unknown";
  log("hk-gmail-watch", {
    status: "registered",
    historyId: resp.historyId,
    expiry: expiryIso,
    topic: TOPIC,
  });
  return resp;
}

async function cmdStatus() {
  const historyId = await readCursor("gmail-history-id");
  const expiry = await readCursor("gmail-watch-expiry");
  const labelId = await readCursor("gmail-label-id");
  const expiryIso = expiry ? new Date(Number(expiry)).toISOString() : "none";
  process.stdout.write(
    `label: ${LABEL_NAME} (${labelId || "unresolved"})\n` +
      `topic: ${TOPIC}\n` +
      `historyId: ${historyId || "none"}\n` +
      `watch expiry: ${expiryIso}\n`,
  );
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "bootstrap":
      await cmdBootstrap(args);
      break;
    case "register":
      await registerWatch();
      break;
    case "renew":
      await registerWatch();
      break;
    case "status":
      await cmdStatus();
      break;
    default:
      process.stderr.write(
        "usage: hk-gmail-watch.mjs bootstrap|register|renew|status [--callback-port N]\n",
      );
      process.exit(2);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    log("hk-gmail-watch", { status: "error", error: err.message });
    process.exit(1);
  });
}
