// Shared helpers for the housekeeping intake daemon.
// Paths, atomic writes, event schema, and dedup primitives.
// No npm dependencies; Node builtins only (>=24).

import { promises as fs, constants as fsc } from "node:fs";
import { existsSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";

// Runtime root on the box; overridable for tests via FM_HK_ROOT.
export function hkRoot() {
  return (
    process.env.FM_HK_ROOT ||
    path.join(os.homedir(), "fm-state", "housekeeping")
  );
}

// The fixed subdirectory layout under the runtime root.
export function hkPaths(root = hkRoot()) {
  return {
    root,
    incoming: path.join(root, "queue", "incoming"),
    processed: path.join(root, "queue", "processed"),
    alertsPending: path.join(root, "alerts", "pending"),
    digestsPending: path.join(root, "digests", "pending"),
    secrets: path.join(root, "secrets"),
    cursors: path.join(root, "cursors"),
  };
}

// Create the full directory tree, secrets locked to 0700.
export async function ensureDirs(root = hkRoot()) {
  const p = hkPaths(root);
  for (const dir of [
    p.incoming,
    p.processed,
    p.alertsPending,
    p.digestsPending,
    p.cursors,
  ]) {
    await fs.mkdir(dir, { recursive: true });
  }
  await fs.mkdir(p.secrets, { recursive: true, mode: 0o700 });
  // mkdir honours the umask; force the mode explicitly so secrets is 0700.
  await fs.chmod(p.secrets, 0o700).catch(() => {});
  return p;
}

// Atomic file write: write a sibling temp file then rename into place.
// rename is atomic on the same filesystem, so readers never see a partial file.
export async function atomicWrite(target, data, mode = 0o600) {
  const dir = path.dirname(target);
  await fs.mkdir(dir, { recursive: true });
  const tmp = path.join(
    dir,
    `.${path.basename(target)}.tmp.${process.pid}.${crypto.randomBytes(6).toString("hex")}`,
  );
  await fs.writeFile(tmp, data, { mode });
  await fs.rename(tmp, target);
}

// Read a cursor file, returning null when it is absent.
export async function readCursor(name, root = hkRoot()) {
  const file = path.join(hkPaths(root).cursors, name);
  try {
    return (await fs.readFile(file, "utf8")).trim();
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
}

// Write a cursor file atomically.
export async function writeCursor(name, value, root = hkRoot()) {
  const file = path.join(hkPaths(root).cursors, name);
  await atomicWrite(file, String(value), 0o644);
}

// Compact a timestamp into a sortable, filesystem-safe UTC stamp.
// "2026-07-19T01:53:04.123Z" -> "20260719T015304Z".
export function utcStamp(ts) {
  const d = ts ? new Date(ts) : new Date();
  const iso = Number.isNaN(d.getTime())
    ? new Date().toISOString()
    : d.toISOString();
  return iso.replace(/[-:]/g, "").replace(/\.\d+/, "").replace(/Z$/, "Z");
}

// Sanitize an arbitrary id into a filename-safe token.
export function safeId(id) {
  return (
    String(id)
      .replace(/[^A-Za-z0-9._-]/g, "_")
      .slice(0, 120) || "noid"
  );
}

// The nine required fields of event schema v1, in a stable order.
const EVENT_FIELDS = [
  "v",
  "source",
  "id",
  "ts",
  "kind",
  "action",
  "actor",
  "title",
  "url",
  "severity",
  "detail",
];

// Build a normalized v1 event, filling defaults and coercing types.
export function buildEvent(partial) {
  const e = {
    v: 1,
    source: partial.source,
    id: String(partial.id),
    ts: partial.ts || new Date().toISOString(),
    kind: partial.kind || "",
    action: partial.action || "",
    actor: partial.actor || "",
    title: partial.title || "",
    url: partial.url || "",
    severity: partial.severity || "digest",
    detail: partial.detail || "",
  };
  return e;
}

// Validate an event object; throw on a missing or malformed required field.
export function validateEvent(e) {
  if (e == null || typeof e !== "object")
    throw new Error("event is not an object");
  if (e.v !== 1) throw new Error(`unsupported schema version: ${e.v}`);
  if (e.source !== "linear" && e.source !== "gmail")
    throw new Error(`bad source: ${e.source}`);
  if (!e.id) throw new Error("missing id");
  if (e.severity !== "blocker" && e.severity !== "digest")
    throw new Error(`bad severity: ${e.severity}`);
  for (const f of ["ts", "kind", "action", "actor", "title", "url", "detail"]) {
    if (typeof e[f] !== "string")
      throw new Error(`field ${f} must be a string`);
  }
  return e;
}

// Serialize an event with fields in a stable order for readable files.
export function serializeEvent(e) {
  const ordered = {};
  for (const f of EVENT_FIELDS) ordered[f] = e[f];
  return JSON.stringify(ordered, null, 2) + "\n";
}

// The deterministic filename for an event: <utc-ts>-<source>-<id>.json.
export function eventFilename(e) {
  return `${utcStamp(e.ts)}-${e.source}-${safeId(e.id)}.json`;
}

// Has an event with this id already been recorded (incoming or processed)?
// Dedup is keyed on the id suffix so a timestamp reformat cannot leak a dupe.
export async function alreadyRecorded(e, root = hkRoot()) {
  const p = hkPaths(root);
  const suffix = `-${e.source}-${safeId(e.id)}.json`;
  for (const dir of [p.incoming, p.processed]) {
    let names;
    try {
      names = await fs.readdir(dir);
    } catch (err) {
      if (err.code === "ENOENT") continue;
      throw err;
    }
    if (names.some((n) => n.endsWith(suffix))) return true;
  }
  return false;
}

// Create a file only if it does not exist yet (O_EXCL).
// Returns true when created, false when it already existed.
export async function writeExclusive(target, data, mode = 0o600) {
  const dir = path.dirname(target);
  await fs.mkdir(dir, { recursive: true });
  let handle;
  try {
    handle = await fs.open(
      target,
      fsc.O_CREAT | fsc.O_EXCL | fsc.O_WRONLY,
      mode,
    );
  } catch (err) {
    if (err.code === "EEXIST") return false;
    throw err;
  }
  try {
    await handle.writeFile(data);
  } finally {
    await handle.close();
  }
  return true;
}

// Read all event objects currently in a queue directory.
export async function readQueue(dir) {
  let names;
  try {
    names = await fs.readdir(dir);
  } catch (err) {
    if (err.code === "ENOENT") return [];
    throw err;
  }
  const out = [];
  for (const name of names.filter((n) => n.endsWith(".json")).sort()) {
    const file = path.join(dir, name);
    try {
      const e = JSON.parse(await fs.readFile(file, "utf8"));
      out.push({ name, file, event: e });
    } catch {
      // Skip an unreadable or partially written file; the next sweep retries.
    }
  }
  return out;
}

// One-line structured log to stderr with an ISO timestamp.
export function log(component, fields = {}) {
  const parts = [new Date().toISOString(), component];
  for (const [k, v] of Object.entries(fields)) {
    const s = typeof v === "string" ? v : JSON.stringify(v);
    parts.push(`${k}=${s}`);
  }
  process.stderr.write(parts.join(" ") + "\n");
}

export function fileExists(p) {
  return existsSync(p);
}
