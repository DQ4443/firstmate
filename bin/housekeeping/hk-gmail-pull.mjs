#!/usr/bin/env node
// hk-gmail-pull.mjs: the Gmail leg daemon.
//
// Long-poll a Pub/Sub PULL subscription (outbound only, no ingress). Each
// notification carries {emailAddress, historyId}; we read the stored history
// cursor, call Gmail users.history.list (messagesAdded, filtered to the
// gemini-notes label), fetch metadata + snippet for each new message, build a
// v1 event, pipe it to hk-classify.mjs, and advance the cursor atomically.
//
// HARD SCOPE: the label filter means only Gemini meeting summaries and their
// failure notices are ever visible. Nothing outside that label is read.
//
// Resilience: exponential backoff on errors capped at 5 minutes; a 404 from a
// too-old historyId falls back to messages.list over the label and resyncs.
//
// No npm dependencies; builtin fetch + child_process.

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { getPubsubToken, getGmailToken } from "./hk-google-auth.mjs";
import {
  readCursor,
  writeCursor,
  ensureDirs,
  buildEvent,
  serializeEvent,
  log,
} from "./hk-lib.mjs";
import { extractNotes } from "./hk-notes-extract.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLASSIFY = path.join(HERE, "hk-classify.mjs");

const GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me";
const PUBSUB_API = "https://pubsub.googleapis.com/v1";
const GCP_PROJECT = process.env.FM_HK_GCP_PROJECT || "firstmate-housekeeping";
const SUBSCRIPTION =
  process.env.FM_HK_GMAIL_SUB ||
  `projects/${GCP_PROJECT}/subscriptions/gmail-gemini-notes-pull`;
const LABEL_NAME = process.env.FM_HK_GMAIL_LABEL || "gemini-notes";
const NOTES_FROM = "gemini-notes@google.com";
const FAILURE_FROM = "meetings-noreply@google.com";
const FAILURE_SUBJECT = "problem with the notes";
const BACKOFF_CAP_MS = 5 * 60 * 1000;
const EXTRACT_TIMEOUT_MS = 60_000;

// ---- HTTP helpers -----------------------------------------------------------

async function gmailGet(pathPart, token) {
  const res = await fetch(`${GMAIL_API}${pathPart}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (res.status === 404) {
    const err = new Error(`gmail 404 on ${pathPart}`);
    err.status = 404;
    throw err;
  }
  if (!res.ok)
    throw new Error(
      `gmail GET ${pathPart} ${res.status}: ${(await res.text()).slice(0, 200)}`,
    );
  return res.json();
}

async function pubsubPost(action, body) {
  const token = await getPubsubToken();
  const res = await fetch(`${PUBSUB_API}/${SUBSCRIPTION}:${action}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok)
    throw new Error(
      `pubsub ${action} ${res.status}: ${(await res.text()).slice(0, 200)}`,
    );
  return res.status === 200 ? res.json().catch(() => ({})) : {};
}

// ---- Message shaping --------------------------------------------------------

function headerValue(headers, name) {
  const h = (headers || []).find(
    (x) => x.name.toLowerCase() === name.toLowerCase(),
  );
  return h ? h.value : "";
}

function parseEmailAddress(from) {
  const m = from.match(/<([^>]+)>/);
  return (m ? m[1] : from).trim().toLowerCase();
}

// Decide the mail kind from sender + subject, per the contract.
function mailKind(fromAddr, subject) {
  if (fromAddr === NOTES_FROM) return "notes";
  if (
    fromAddr === FAILURE_FROM &&
    subject.toLowerCase().includes(FAILURE_SUBJECT)
  )
    return "notes-failure";
  // The structural label filter should make this unreachable; keep it visible.
  return "unexpected";
}

// Fetch metadata + snippet for one message and build a v1 event.
async function buildMessageEvent(messageId, token) {
  const q =
    "?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date";
  const msg = await gmailGet(`/messages/${messageId}${q}`, token);
  const headers = msg.payload && msg.payload.headers;
  const from = headerValue(headers, "From");
  const subject = headerValue(headers, "Subject");
  const dateHeader = headerValue(headers, "Date");
  const fromAddr = parseEmailAddress(from);
  const kind = mailKind(fromAddr, subject);
  const ts = dateHeader
    ? new Date(dateHeader).toISOString()
    : msg.internalDate
      ? new Date(Number(msg.internalDate)).toISOString()
      : new Date().toISOString();

  const event = buildEvent({
    source: "gmail",
    id: messageId,
    ts,
    kind,
    action: kind,
    actor: fromAddr || from,
    title: subject || "(no subject)",
    url: `https://mail.google.com/mail/u/0/#all/${messageId}`,
    severity: "digest",
    detail: (msg.snippet || "").trim(),
  });
  return { event, kind };
}

// Enrich a notes event with distilled Drive-doc content, bounded in time.
async function enrichNotes(event) {
  try {
    const token = await getGmailToken();
    const result = await Promise.race([
      extractNotes(event.title, token),
      new Promise((resolve) =>
        setTimeout(
          () => resolve({ ok: false, text: "", reason: "timeout" }),
          EXTRACT_TIMEOUT_MS,
        ),
      ),
    ]);
    if (result.ok && result.text) {
      const base = event.detail ? `${event.detail}\n\n` : "";
      event.detail = `${base}Extracted:\n${result.text}`;
    } else {
      log("hk-gmail-pull", {
        status: "extract-skip",
        id: event.id,
        reason: result.reason || "no-text",
      });
    }
  } catch (err) {
    // Keep the snippet-only event; extraction is best-effort.
    log("hk-gmail-pull", {
      status: "extract-error",
      id: event.id,
      error: err.message,
    });
  }
  return event;
}

// Pipe one event to hk-classify.mjs, resolving on a clean exit.
function pipeToClassify(event) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLASSIFY], {
      stdio: ["pipe", "inherit", "inherit"],
    });
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0 ? resolve() : reject(new Error(`classify exit ${code}`)),
    );
    child.stdin.write(serializeEvent(event));
    child.stdin.end();
  });
}

// ---- History processing -----------------------------------------------------

// Walk history.list from the stored cursor, classifying each added message.
// Returns the newest historyId observed so the caller can advance the cursor.
async function processHistory(startHistoryId, labelId, token) {
  let pageToken = null;
  let newestHistoryId = startHistoryId;
  const seen = new Set();
  do {
    let url = `/history?startHistoryId=${encodeURIComponent(startHistoryId)}&historyTypes=messageAdded`;
    if (labelId) url += `&labelId=${encodeURIComponent(labelId)}`;
    if (pageToken) url += `&pageToken=${encodeURIComponent(pageToken)}`;
    const data = await gmailGet(url, token);
    if (data.historyId) newestHistoryId = data.historyId;
    for (const h of data.history || []) {
      for (const added of h.messagesAdded || []) {
        const id = added.message && added.message.id;
        if (!id || seen.has(id)) continue;
        seen.add(id);
        const { event, kind } = await buildMessageEvent(id, token);
        if (kind === "notes") await enrichNotes(event);
        await pipeToClassify(event);
        log("hk-gmail-pull", { status: "classified", id, kind });
      }
    }
    pageToken = data.nextPageToken || null;
  } while (pageToken);
  return newestHistoryId;
}

// Fallback when the historyId is too old: list recent labelled messages and
// resync the cursor to the mailbox's current historyId.
async function resyncFromMessages(labelId, token) {
  log("hk-gmail-pull", { status: "resync-start" });
  let url = "/messages?maxResults=25";
  if (labelId) url += `&labelIds=${encodeURIComponent(labelId)}`;
  const list = await gmailGet(url, token);
  for (const m of list.messages || []) {
    const { event, kind } = await buildMessageEvent(m.id, token);
    if (kind === "notes") await enrichNotes(event);
    // Dedup in hk-classify prevents reprocessing anything already stored.
    await pipeToClassify(event);
  }
  const profile = await gmailGet("", token);
  if (profile.historyId)
    await writeCursor("gmail-history-id", profile.historyId);
  log("hk-gmail-pull", { status: "resync-done", historyId: profile.historyId });
}

// Handle one Pub/Sub notification: advance from the stored cursor.
async function handleNotification() {
  const token = await getGmailToken();
  const labelId = await readCursor("gmail-label-id");
  const startHistoryId = await readCursor("gmail-history-id");
  if (!startHistoryId) {
    // No cursor yet: resync so the first notification does not miss mail.
    await resyncFromMessages(labelId, token);
    return;
  }
  try {
    const newest = await processHistory(startHistoryId, labelId, token);
    if (newest && newest !== startHistoryId)
      await writeCursor("gmail-history-id", newest);
  } catch (err) {
    if (err.status === 404) {
      await resyncFromMessages(labelId, token);
    } else {
      throw err;
    }
  }
}

// ---- Pull loop --------------------------------------------------------------

// One long-poll pull cycle. Returns the number of messages handled.
async function pullOnce() {
  const resp = await pubsubPost("pull", {
    returnImmediately: false,
    maxMessages: 10,
  });
  const received = resp.receivedMessages || [];
  if (!received.length) return 0;

  // A single history walk covers all notifications in the batch; we still ack
  // every message. Any per-notification failure aborts before the ack so the
  // message redelivers.
  await handleNotification();
  const ackIds = received.map((m) => m.ackId).filter(Boolean);
  if (ackIds.length) await pubsubPost("acknowledge", { ackIds });
  log("hk-gmail-pull", { status: "batch-acked", count: received.length });
  return received.length;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function loop() {
  await ensureDirs();
  log("hk-gmail-pull", {
    status: "daemon-start",
    subscription: SUBSCRIPTION,
    label: LABEL_NAME,
  });
  let backoff = 1000;
  for (;;) {
    try {
      await pullOnce();
      backoff = 1000; // reset after any clean cycle
    } catch (err) {
      log("hk-gmail-pull", {
        status: "cycle-error",
        error: err.message,
        backoffMs: backoff,
      });
      await sleep(backoff);
      backoff = Math.min(backoff * 2, BACKOFF_CAP_MS);
    }
  }
}

async function main() {
  const arg = process.argv[2];
  if (arg === "--once") {
    await ensureDirs();
    const n = await pullOnce();
    log("hk-gmail-pull", { status: "once-done", handled: n });
    return;
  }
  await loop();
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    log("hk-gmail-pull", { status: "fatal", error: err.message });
    process.exit(1);
  });
}
