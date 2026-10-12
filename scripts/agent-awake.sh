#!/bin/bash
# Keep the Mac awake (lid closed included) with `pmset -a disablesleep 1`
# only while a Claude Code agent is working. Uses the sudoers rule that
# Insomnia's install.sh writes to /etc/sudoers.d/insomnia.
#
#   agent-awake.sh acquire   hook: UserPromptSubmit / PreToolUse / PostToolUse (hook JSON on stdin)
#   agent-awake.sh release   hook: Stop / StopFailure / SessionEnd / Notification(idle_prompt)
#   agent-awake.sh status    print the current state
#   agent-awake.sh reset     drop every hold and restore sleep (manual recovery)
set -uo pipefail

STATE="${AGENT_AWAKE_HOME:-$HOME/.claude/agent-awake}"
HOLDS="$STATE/holds"
OURS="$STATE/ours"
LOG="$STATE/agent-awake.log"
WATCHDOG_PID="$STATE/watchdog.pid"
INSOMNIA_SESSION="${AGENT_AWAKE_INSOMNIA_SESSION:-$HOME/Library/Application Support/Insomnia/session.json}"
TTL_SECONDS="${AGENT_AWAKE_TTL:-10800}"
STALE_SECONDS="${AGENT_AWAKE_STALE:-300}"
INTERVAL="${AGENT_AWAKE_INTERVAL:-30}"
BATTERY_FLOOR="${AGENT_AWAKE_BATTERY_FLOOR:-10}"
PMSET="${AGENT_AWAKE_PMSET:-/usr/bin/pmset}"
SUDO="${AGENT_AWAKE_SUDO:-/usr/bin/sudo}"

mkdir -p "$HOLDS"

if [[ "${1:-}" == watchdog ]]; then
  while "$0" watchdog-tick; do sleep "$INTERVAL"; done
  rm -f "$WATCHDOG_PID"
  exit 0
fi

# shlock writes the holder's pid, so a dead holder's lock goes stale by itself,
# and no lock fd is inherited by the backgrounded watchdog.
LOCK="$STATE/.lock"
for (( i = 0; i < 100; i++ )); do
  /usr/bin/shlock -f "$LOCK" -p $$ && break
  sleep 0.1
done
(( i < 100 )) || { echo "agent-awake: lock busy" >&2; exit 0; }
trap 'rm -f "$LOCK"' EXIT

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$$" "$*" >> "$LOG"; }

sleep_disabled() { "$PMSET" -g | awk '/SleepDisabled/ {print $2}'; }

insomnia_active() { [[ -f "$INSOMNIA_SESSION" ]]; }

set_disablesleep() { # 0|1
  if "$SUDO" -n "$PMSET" -a disablesleep "$1" >/dev/null 2>&1; then
    log "pmset disablesleep $1"
  else
    log "ERROR: sudo -n pmset -a disablesleep $1 failed"
    return 1
  fi
}

# The pid of the Claude Code process that ran the hook; a hold dies with it.
owner_pid() {
  local pid=$PPID cmd
  for _ in 1 2 3 4; do
    cmd="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *claude*|*Claude*|*node*) echo "$pid"; return ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -z "$pid" || "$pid" -le 1 ]] && break
  done
  echo "$PPID"
}

HOOK_INPUT=""
read_input() { [[ -t 0 ]] || HOOK_INPUT="$(cat)"; }

session_id() {
  local sid
  sid="$(/usr/bin/jq -r '.session_id // empty' <<<"$HOOK_INPUT" 2>/dev/null || true)"
  sid="${sid//[^A-Za-z0-9_-]/}"
  echo "$sid"
}

transcript_path() { /usr/bin/jq -r '.transcript_path // empty' <<<"$HOOK_INPUT" 2>/dev/null || true; }

# An interrupt (Esc) does not run the Stop hook, so the last message in the
# transcript decides whether the turn is over:
#   interrupted: the last message is "[Request interrupted ..."
#   finished:    an assistant reply with no tool call, unchanged for STALE_SECONDS
#   busy:        anything else (a tool running, still generating, unreadable)
transcript_state() {
  local t="$1" last age
  [[ -n "$t" && -f "$t" ]] || { echo busy; return; }
  last="$(tail -n 60 "$t" | /usr/bin/jq -sc '[.[] | select(.type == "user" or .type == "assistant")] | last // {}' 2>/dev/null)"
  if /usr/bin/jq -e '.type == "user" and ((.message.content | tostring) | contains("[Request interrupted"))' <<<"$last" >/dev/null 2>&1; then
    echo interrupted; return
  fi
  age=$(( $(date +%s) - $(stat -f %m "$t") ))
  if (( age > STALE_SECONDS )) && /usr/bin/jq -e '.type == "assistant" and ([.message.content[]? | select(.type == "tool_use")] | length == 0)' <<<"$last" >/dev/null 2>&1; then
    echo finished; return
  fi
  echo busy
}

prune() {
  local f pid transcript now age state
  now="$(date +%s)"
  for f in "$HOLDS"/*; do
    [[ -f "$f" ]] || continue
    pid="$(sed -n 1p "$f" 2>/dev/null)"
    transcript="$(sed -n 2p "$f" 2>/dev/null)"
    age=$(( now - $(stat -f %m "$f") ))
    if ! kill -0 "$pid" 2>/dev/null; then
      log "drop hold $(basename "$f"): owner pid $pid gone"; rm -f "$f"
    elif (( age > TTL_SECONDS )); then
      log "drop hold $(basename "$f"): idle ${age}s > ${TTL_SECONDS}s"; rm -f "$f"
    else
      state="$(transcript_state "$transcript")"
      if [[ "$state" != busy ]]; then
        log "drop hold $(basename "$f"): transcript says $state"; rm -f "$f"
      fi
    fi
  done
}

hold_count() { find "$HOLDS" -type f | wc -l | tr -d ' '; }

battery_low() {
  local out pct
  out="$("$PMSET" -g batt)"
  grep -q "'Battery Power'" <<<"$out" || return 1
  pct="$(grep -Eo '[0-9]+%' <<<"$out" | head -1 | tr -d '%')"
  [[ -n "$pct" ]] && (( pct <= BATTERY_FLOOR ))
}

# Keep disablesleep 1 while any hold exists; with none, clear it only if we set it.
reconcile() {
  prune
  if (( $(hold_count) > 0 )) && battery_low; then
    log "battery <= ${BATTERY_FLOOR}% on battery power: releasing all holds"
    rm -f "$HOLDS"/*
  fi
  if (( $(hold_count) > 0 )); then
    if [[ "$(sleep_disabled)" != 1 ]]; then
      set_disablesleep 1 && touch "$OURS"
    fi
  elif [[ -f "$OURS" ]]; then
    if insomnia_active; then
      log "Insomnia session active: leaving disablesleep to Insomnia"
    elif [[ "$(sleep_disabled)" == 1 ]]; then
      set_disablesleep 0 || return 1
    fi
    rm -f "$OURS"
  fi
}

ensure_watchdog() {
  local pid
  pid="$(cat "$WATCHDOG_PID" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return; fi
  nohup "$0" watchdog </dev/null >/dev/null 2>&1 &
  echo $! > "$WATCHDOG_PID"
  log "watchdog started pid $!"
}

case "${1:-}" in
  acquire)
    read_input
    sid="$(session_id)"
    [[ -n "$sid" ]] || exit 0
    printf '%s\n%s\n' "$(owner_pid)" "$(transcript_path)" > "$HOLDS/$sid"
    reconcile
    ensure_watchdog
    ;;
  release)
    read_input
    sid="$(session_id)"
    if [[ -n "$sid" && -f "$HOLDS/$sid" ]]; then rm -f "$HOLDS/$sid"; log "release $sid"; fi
    reconcile
    ;;
  watchdog-tick)
    reconcile
    (( $(hold_count) > 0 )) || exit 3
    ;;
  status)
    echo "SleepDisabled=$(sleep_disabled) ours=$([[ -f "$OURS" ]] && echo yes || echo no) insomnia_session=$(insomnia_active && echo yes || echo no)"
    echo "holds:"; for f in "$HOLDS"/*; do [[ -f "$f" ]] && echo "  $(basename "$f") pid=$(sed -n 1p "$f") transcript=$(sed -n 2p "$f")"; done
    pid="$(cat "$WATCHDOG_PID" 2>/dev/null || true)"
    echo "watchdog: $([[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "running ($pid)" || echo stopped)"
    ;;
  reset)
    rm -f "$HOLDS"/*
    touch "$OURS"
    reconcile
    ;;
  *)
    echo "usage: $0 acquire|release|status|reset" >&2; exit 2 ;;
esac
exit 0
