#!/usr/bin/env bash
# hk-digest.sh: fold pending digest events into a per-slot digest file.
#
# Timer target. Reads every severity=digest event in queue/incoming, renders a
# plain-text digest (notes-failure items first, then notes summaries, then
# Linear items grouped by issue), and moves the folded events to
# queue/processed. Blocker events are left untouched; they ride the alert path.
#
# No file is created when there are zero digest events.
#
# Usage: hk-digest.sh morning|afternoon
#
# JSON parsing uses node (a hard platform dependency of this daemon); no jq and
# no network are required.

set -euo pipefail

slot="${1:-}"
case "$slot" in
  morning | afternoon) ;;
  *)
    echo "usage: hk-digest.sh morning|afternoon" >&2
    exit 2
    ;;
esac

root="${FM_HK_ROOT:-$HOME/fm-state/housekeeping}"
incoming="$root/queue/incoming"
processed="$root/queue/processed"
digests="$root/digests/pending"
mkdir -p "$processed" "$digests"

date_utc="$(date -u +%Y-%m-%d)"
outfile="$digests/${date_utc}-${slot}.md"

# Emit the scalar fields of an event file one per line, in a fixed order, with
# detail base64-encoded so its own newlines cannot break the framing. One field
# per line preserves empty fields (a tab-split with read collapses them).
# Order: severity source kind action title actor url ts detail(base64).
jrow() {
  node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const f = ["severity", "source", "kind", "action", "title", "actor", "url", "ts"];
    const vals = f.map((k) => String(o[k] == null ? "" : o[k]).replace(/[\r\n]/g, " "));
    vals.push(Buffer.from(String(o.detail == null ? "" : o.detail)).toString("base64"));
    process.stdout.write(vals.join("\n") + "\n");
  ' "$1"
}

# Load an event file's fields into the global array FLD (indices per jrow).
# FLD[8] is the base64-encoded detail; use fld_detail to decode it.
FLD=()
load_fields() {
  FLD=()
  while IFS= read -r __line; do
    FLD+=("$__line")
  done < <(jrow "$1")
}
fld_detail() {
  printf '%s' "${FLD[8]:-}" | base64 --decode 2>/dev/null || true
}

# Collect the digest event files (sorted by filename, i.e. chronological).
files=()
while IFS= read -r line; do
  files+=("$line")
done < <(find "$incoming" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)

notes_failure=()
notes=()
linear_files=()
folded=()

for f in "${files[@]+"${files[@]}"}"; do
  [ -e "$f" ] || continue
  load_fields "$f"
  severity="${FLD[0]}"
  source="${FLD[1]}"
  kind="${FLD[2]}"
  [ "$severity" = "digest" ] || continue
  folded+=("$f")
  if [ "$source" = "gmail" ] && [ "$kind" = "notes-failure" ]; then
    notes_failure+=("$f")
  elif [ "$source" = "gmail" ] && [ "$kind" = "notes" ]; then
    notes+=("$f")
  elif [ "$source" = "gmail" ]; then
    # kind "unexpected" (label filter should prevent this); surface it visibly.
    notes+=("$f")
  else
    linear_files+=("$f")
  fi
done

# No digest events: create nothing and exit cleanly.
if [ "${#folded[@]}" -eq 0 ]; then
  exit 0
fi

# Render one gmail item: a "- title (actor) url" line plus indented detail.
render_mail_item() {
  load_fields "$1"
  local title="${FLD[4]}" actor="${FLD[5]}" url="${FLD[6]}" detail
  detail="$(fld_detail)"
  local line="- ${title}"
  [ -n "$actor" ] && line="${line} (${actor})"
  [ -n "$url" ] && line="${line} ${url}"
  printf '%s\n' "$line"
  if [ -n "$detail" ]; then
    printf '%s\n' "$detail" | sed '/^[[:space:]]*$/d' | head -n 6 | sed 's/^/    /'
  fi
}

# Render one linear item: "- action: title (actor) url".
render_linear_item() {
  load_fields "$1"
  local action="${FLD[3]}" title="${FLD[4]}" actor="${FLD[5]}" url="${FLD[6]}"
  local line="- "
  [ -n "$action" ] && line="${line}${action}: "
  line="${line}${title}"
  [ -n "$actor" ] && line="${line} (${actor})"
  [ -n "$url" ] && line="${line} ${url}"
  printf '%s\n' "$line"
}

# Derive an issue key (e.g. ENG-123) from a linear event's title/url.
issue_key() {
  load_fields "$1"
  local title="${FLD[4]}" url="${FLD[6]}" key
  key="$(printf '%s %s' "$title" "$url" | grep -oE '[A-Z]{2,}-[0-9]+' | head -n 1 || true)"
  printf '%s' "${key:-Other}"
}

# Build the digest block in a temp file in the digests dir (same filesystem as
# the target, so the mv into place is atomic and preserves the 0600 mode).
# mktemp creates the file 0600; the digest carries distilled meeting notes and
# grouped Linear items, so it must never be world-readable, not even briefly.
tmp="$(mktemp "$digests/.digest.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  printf 'Housekeeping digest - %s %s\n' "$date_utc" "$slot"

  if [ "${#notes_failure[@]}" -gt 0 ]; then
    printf '\nNotes failures\n'
    for f in "${notes_failure[@]}"; do render_mail_item "$f"; done
  fi

  if [ "${#notes[@]}" -gt 0 ]; then
    printf '\nMeeting notes\n'
    for f in "${notes[@]}"; do render_mail_item "$f"; done
  fi

  if [ "${#linear_files[@]}" -gt 0 ]; then
    printf '\nLinear\n'
    # Group by issue key, preserving first-seen order of keys.
    keys=()
    for f in "${linear_files[@]}"; do
      k="$(issue_key "$f")"
      seen=0
      for existing in "${keys[@]:-}"; do
        [ "$existing" = "$k" ] && seen=1 && break
      done
      [ "$seen" -eq 0 ] && keys+=("$k")
    done
    for k in "${keys[@]}"; do
      printf '%s\n' "$k"
      for f in "${linear_files[@]}"; do
        [ "$(issue_key "$f")" = "$k" ] && render_linear_item "$f"
      done
    done
  fi
} >"$tmp"

# Append to an existing slot file, else create it. The digest is kept 0600 in
# both paths: the create path moves the already-0600 temp file into place (no
# world-readable window), and the append path re-asserts 0600 after writing.
if [ -s "$outfile" ]; then
  {
    printf '\n'
    cat "$tmp"
  } >>"$outfile"
  chmod 600 "$outfile"
  rm -f "$tmp"
else
  chmod 600 "$tmp"
  mv "$tmp" "$outfile"
fi

# Move folded events to processed only after the digest is written.
for f in "${folded[@]}"; do
  mv "$f" "$processed/"
done

echo "wrote $outfile (${#folded[@]} events)" >&2
