#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch, else the pane
# busy-signature) and reconciles the possibly-stale log against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch, active or terminal
#      (from `axi status`, or the coarse `no-mistakes runs` fallback)?
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
log_verb_of() {  # <line>
  local v=${1%%:*}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
log_note_of() {  # <line>
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *)   printf '%s' "$1" ;;
  esac
}
# Map a status-log verb onto a canonical state for the fallback path.
map_log_state() {  # <verb>
  case "$1" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(log_verb_of "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_pane_is_busy: the busy-signature fallback, backend-aware the same way -
# fm_backend_busy_state's native semantic state (herdr's agent.get) when
# available, else the shared tmux pane-regex reader (fm_pane_is_busy,
# bin/fm-tmux-lib.sh) unchanged for tmux/unknown.
#
# `busy` alone is trusted outright. Both `idle` and unknown/unparseable fall
# through to the shared tail-regex corroboration, NOT just unknown: herdr's
# agent.get reports generation state ("working" while the model is streaming
# a turn, "done"/"idle" once it is not - docs/herdr-backend.md "Busy state"),
# which is a narrower signal than "this crew's turn/tool call is still in
# progress". A crew blocked on its own long-running foreground tool call (e.g.
# `no-mistakes axi run` without --yes, which blocks synchronously until a gate
# or outcome - AGENTS.md section 11) is not generating for that whole span, so
# agent.get can read idle/blocked (bin/backends/herdr.sh maps both to `idle`)
# while the pane's own rendered text still shows the harness's busy banner
# (BUSY_REGEX, e.g. "esc to interrupt") for the entire tool call, exactly like
# tmux's regex-only reader would correctly report. Trusting herdr's `idle`
# outright (skipping that corroboration) is what let a still-working crew read
# as not-busy here, and - combined with a no-mistakes run-step lookup that also
# missed attribution (see nm_runs_status_for_branch) - as not provably working in
# fm-classify-lib.sh, triggering an immediate (non-wedge) stale wake instead of
# the absorb-then-escalate path. A genuinely human-blocked agent (a permission
# dialog, not mid-tool-call) does not render the busy banner, so this
# corroboration does not mask that case: it stays correctly not-busy.
crew_pane_is_busy() {  # <target>
  case "$TASK_BACKEND" in
    tmux) fm_pane_is_busy "$1" ;;
    *)
      local bs tail40
      bs=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
      case "$bs" in
        busy) return 0 ;;
        *)
          tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
          printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
            | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
          ;;
      esac
      ;;
  esac
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(log_note_of "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Sets COARSE_STATUS to the first
# (most recent) matching row's status word (running/completed/cancelled/failed),
# or empty when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
# Results come back through globals rather than stdout because the retry loop
# below also needs NM_RUNS_RESPONDED - whether the bounded `no-mistakes runs`
# call produced any output at all - and a command-substitution subshell could
# not report that second fact. `no-mistakes runs` always emits text when the
# CLI is alive (even with zero runs it prints a "no runs" line), so an empty
# capture reliably means the call timed out, never a legitimate empty answer.
nm_runs_status_for_branch() {  # <branch>; sets COARSE_STATUS + NM_RUNS_RESPONDED
  local branch=$1 out row st rest br
  COARSE_STATUS=""
  NM_RUNS_RESPONDED=0
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  NM_RUNS_RESPONDED=1
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    if [ "$br" = "$branch" ]; then
      COARSE_STATUS=$st
      return 0
    fi
  done <<< "$out"
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
NM_RUNS_RESPONDED=0
# Bounded retry/backoff around the run-attribution lookup. During an actively
# running pipeline the bounded no-mistakes calls can lose a race - time out to
# empty (the CLI is busy serving the run) - and leave HAVE_RUN=0. The caller
# would then fall through to the possibly-stale status log, which defeats the
# watcher's provably-working absorption and surfaces a validating crew as
# stale every poll (per-minute false stale wakes during long validations).
# Re-attempt a few times with a short backoff before accepting a
# non-authoritative verdict. Only an unresponsive attempt is retried, and an
# empty result from EITHER bounded call - `axi status` or the coarse
# `no-mistakes runs` list - is that timeout/race signature, because both
# commands emit non-empty text whenever the CLI is alive (`runs` prints a "no
# runs" line even with zero runs). An attempt is authoritative (no retry) only
# when every call that left HAVE_RUN=0 actually answered: `axi status`
# reported another branch's run AND the coarse runs list answered with no row
# for this branch. That definitive "no run for this branch" breaks the loop
# without retrying, because retrying cannot change an authoritative answer and
# would only add hot-path latency for the steady-state implementing crew
# (branch created, validation not yet started).
# This is the upstream replacement for the local state/.crew-state-retry.sh
# (FM_CREW_STATE_BIN) production mitigation, which wrapped this whole helper
# with the same retry-until-run-step/pane semantics.
# With FM_CREW_STATE_RETRIES=0 the loop runs exactly once, byte-identical to the
# original single-attempt behavior (used by the test suite to stay fast).
CREW_STATE_RETRIES=${FM_CREW_STATE_RETRIES:-2}
case "$CREW_STATE_RETRIES" in ''|*[!0-9]*) CREW_STATE_RETRIES=2 ;; esac
CREW_STATE_RETRY_DELAY=${FM_CREW_STATE_RETRY_DELAY:-2}
case "$CREW_STATE_RETRY_DELAY" in ''|*[!0-9]*) CREW_STATE_RETRY_DELAY=2 ;; esac
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  attempt=0
  while : ; do
    cli_responded=0
    RUN_OUT=$(nm_run axi status)
    if [ -n "$RUN_OUT" ]; then
      cli_responded=1
      run_branch=$(strip_quotes "$(nm_field branch)")
      if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ]; then
        HAVE_RUN=1
      else
        # The active-or-most-recent run is for another branch (the CLI is alive
        # and answered; only the attribution missed) - try the coarse fallback.
        # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
        # primary call means the CLI itself did not respond within this attempt,
        # so the coarse re-query would just double the wait; the retry loop below
        # is what gives the CLI another chance after a backoff instead.
        nm_runs_status_for_branch "$CREW_BRANCH"
        if [ -n "$COARSE_STATUS" ]; then
          HAVE_RUN=1
          RUN_SOURCE=coarse
        elif [ "$NM_RUNS_RESPONDED" = 0 ]; then
          cli_responded=0
        fi
      fi
    fi
    [ "$HAVE_RUN" = 1 ] && break
    [ "$cli_responded" = 0 ] || break
    [ "$attempt" -lt "$CREW_STATE_RETRIES" ] || break
    attempt=$((attempt + 1))
    [ "$CREW_STATE_RETRY_DELAY" -gt 0 ] && sleep "$CREW_STATE_RETRY_DELAY"
  done
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: captain decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    emit "done" status-log "$(log_note_of "$LOG_LINE")${SEP}run still monitoring PR"
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$BACKEND_TARGET"; then
  emit working pane "harness busy"
fi

if [ -n "$LOG_VERB" ]; then
  emit "$(map_log_state "$LOG_VERB")" status-log "$(log_note_of "$LOG_LINE")"
fi

emit unknown none "no current-state source available"
