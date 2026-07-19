#!/usr/bin/env node
// hk-classify.mjs: classify one event and file it into the queue.
//
// stdin = one event JSON (schema v1). Applies the deterministic contract
// classification, dedups by id against queue/incoming and queue/processed,
// writes queue/incoming/<utc-ts>-<source>-<id>.json, and for blockers also
// writes alerts/pending/<ts>-<id> whose FIRST LINE is a one-sentence alert.
//
// Idempotent and safe to call concurrently: the incoming file is created with
// O_EXCL, so a collision means another writer already handled this event and
// we exit 0. A previously processed id (already folded into a digest) is
// detected by the dedup scan and also exits 0.
//
// The classifier is the single source of truth for routing: it recomputes
// severity from the contract rather than trusting the incoming severity field.

import { promises as fs } from "node:fs";
import path from "node:path";
import {
  hkRoot,
  hkPaths,
  ensureDirs,
  buildEvent,
  validateEvent,
  serializeEvent,
  eventFilename,
  safeId,
  utcStamp,
  alreadyRecorded,
  writeExclusive,
  log,
} from "./hk-lib.mjs";

// David's Linear identity, for the native-notification drop rules.
const DAVID_EMAIL = "david.qu@kronosai.co";
const DAVID_LINEAR_ID = "448a6290-609b-4651-b416-768eb0ac9c93";

// Read all of stdin as a UTF-8 string.
async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

// Decide routing for a Linear event.
// Returns { decision: "drop" } or { decision: "store", severity }.
function classifyLinear(e) {
  const action = (e.action || "").toLowerCase();
  const kind = (e.kind || "").toLowerCase();

  // Issue SLA breached or highRisk is the only blocker path.
  const isSla = kind.includes("sla") || action.includes("sla");
  if (
    isSla &&
    (action.includes("breach") ||
      action.includes("highrisk") ||
      action.includes("high-risk"))
  ) {
    return { decision: "store", severity: "blocker" };
  }

  // Drop events whose only content is something Linear natively notifies David
  // about: a direct assignment to David, or a comment that @mentions David.
  // The Linear leg encodes these with a dedicated action so the drop is
  // deterministic; we also match the literal identity as a defensive fallback.
  const targetsDavid =
    action === "assigned-to-david" ||
    action === "mention-david" ||
    action === "mentioned-david" ||
    ((action === "assigned" || action === "assign") &&
      (e.detail || "").toLowerCase().includes("assignee=" + DAVID_LINEAR_ID)) ||
    ((action === "mention" || action === "mentioned") &&
      (e.detail || "").toLowerCase().includes(DAVID_EMAIL));
  if (targetsDavid)
    return { decision: "drop", reason: "native-linear-notification" };

  // Everything else Linear (state changes by others, new unassigned
  // Engineering issues, others' comments, project create/update) is a digest.
  return { decision: "store", severity: "digest" };
}

// Decide routing for a Gmail event. The label filter guarantees only Gemini
// notes reach us, so everything is a digest; kind is set by the pull leg.
function classifyGmail(e) {
  return { decision: "store", severity: "digest" };
}

// Apply the full contract classification, dispatching on source.
export function classify(e) {
  if (e.source === "linear") return classifyLinear(e);
  if (e.source === "gmail") return classifyGmail(e);
  // Unknown source should not occur; keep it as a digest rather than drop.
  return { decision: "store", severity: "digest" };
}

// Compose the one-sentence alert line for a blocker.
function alertSentence(e) {
  const who = e.actor ? ` (${e.actor})` : "";
  const link = e.url ? ` ${e.url}` : "";
  return `Blocker: ${e.title || e.kind || "Linear issue"}${who}.${link}`.trim();
}

async function main() {
  const root = hkRoot();
  const p = hkPaths(root);
  await ensureDirs(root);

  const raw = (await readStdin()).trim();
  if (!raw) {
    log("hk-classify", { status: "empty-stdin" });
    process.exit(2);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    log("hk-classify", { status: "bad-json", error: err.message });
    process.exit(2);
  }

  let event;
  try {
    event = validateEvent(buildEvent(parsed));
  } catch (err) {
    log("hk-classify", { status: "invalid-event", error: err.message });
    process.exit(2);
  }

  const decision = classify(event);

  if (decision.decision === "drop") {
    log("hk-classify", {
      status: "drop",
      id: event.id,
      source: event.source,
      reason: decision.reason || "",
    });
    process.exit(0);
  }

  // Recompute severity from the contract; do not trust the inbound value.
  event.severity = decision.severity;

  // Dedup against what we have already recorded (incoming or processed).
  if (await alreadyRecorded(event, root)) {
    log("hk-classify", {
      status: "duplicate",
      id: event.id,
      source: event.source,
    });
    process.exit(0);
  }

  const incomingFile = path.join(p.incoming, eventFilename(event));
  const created = await writeExclusive(incomingFile, serializeEvent(event));
  if (!created) {
    // Lost a concurrent race; the other writer owns this event.
    log("hk-classify", {
      status: "race-duplicate",
      id: event.id,
      source: event.source,
    });
    process.exit(0);
  }

  let alertFile = "";
  if (event.severity === "blocker") {
    alertFile = path.join(
      p.alertsPending,
      `${utcStamp(event.ts)}-${safeId(event.id)}`,
    );
    const body = `${alertSentence(event)}\n\n${serializeEvent(event)}`;
    await writeExclusive(alertFile, body).catch(async (err) => {
      // An existing alert file is fine; anything else is a real error.
      if (err.code !== "EEXIST") throw err;
    });
  }

  log("hk-classify", {
    status: "stored",
    id: event.id,
    source: event.source,
    kind: event.kind,
    severity: event.severity,
    file: path.basename(incomingFile),
    alert: alertFile ? path.basename(alertFile) : "",
  });
  process.exit(0);
}

// Only run when invoked directly, not when imported by a test.
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    log("hk-classify", { status: "error", error: err.message });
    process.exit(1);
  });
}
