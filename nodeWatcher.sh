#!/bin/bash
# nodeWatcher.sh -- restart the nodes a dashboard says are banned or offline.
#
# This is the external counterpart to running nodes blind. Nothing inside an
# EarnApp container knows whether its node still earns: the binary prints nothing
# once it is running, not even with --verbose, and its own SDK log is encrypted, so
# a banned node and a healthy one look identical from the inside. Inferring the
# answer from network behaviour is possible but it is inference, and it misfires --
# a node retrying a dead proxy moves plenty of bytes while relaying nothing, and a
# fleet-wide upstream blip looks exactly like every node failing at once.
#
# So this script does not guess. It asks a dashboard that already knows, over a
# read-only feed:
#
#   GET $WATCH_URL   with   Authorization: Bearer <token from a file>
#   -> { "banned": [ids], "offline": [ids], "ageSeconds": N,
#        "counts": { "known":N, "banned":N, "offline":N, "unknown":N,
#                    "unreadableAccounts":N } }
#
# The feed speaks in node ids and knows nothing about containers. nodemap.txt,
# written by EAincome.sh --start (or rebuilt with --nodemap), is what turns an id
# back into something restartable. That file is per folder, which is the whole
# safety model: a dashboard covering an entire fleet can be pointed at one folder
# and this script will only ever touch the nodes that folder started. An id it does
# not recognise is not its business and is counted, not acted on.
#
# It refuses to act, rather than acting on bad information, when:
#
#   - the fetch fails, or the body does not parse
#   - counts.unreadableAccounts > 0   the lists are missing nodes, so a node absent
#                                     from them proves nothing
#   - ageSeconds > MAX_AGE            the feed is stale; the dashboard polls every
#                                     five minutes, so this should be under 300
#   - too much of the folder is flagged at once (FLEET_MAX_BAD). Thirteen nodes
#     failing in the same minute is one upstream event, and no restart fixes it.
#
# Absence from both lists is not a clean bill of health either -- the node may be
# in counts.unknown, meaning the dashboard could not check it this round. This
# script only ever acts on a positive verdict, never on the absence of one.
#
# Banned and offline are different faults and get different fixes. Banned is a
# judgement about the exit address, so restarting the node changes nothing; the
# tun2proxy parent is restarted instead to get a fresh connection out. Offline is
# about the node itself, so the node container is restarted. A node in both lists
# is treated as banned, that being the deeper problem.

set -uo pipefail

# ---------------------------------------------------------------- configuration

# Where the feed lives. No default: a wrong guess here would be a silent no-op.
WATCH_URL=${WATCH_URL:-}

# The bearer token is read from a file and handed to curl through a config file on
# stdin, so it never appears in the command line, in ps output, or in this script's
# environment. Never pass it as an argument.
TOKEN_FILE=${TOKEN_FILE:-.watch_token}

# Written by EAincome.sh --start, one "<nodeid> <container>" pair per line.
MAP_FILE=${MAP_FILE:-nodemap.txt}
LOG_FILE=${LOG_FILE:-watcher.log}
MAX_LOG_LINES=${MAX_LOG_LINES:-20000}

INTERVAL=${INTERVAL:-300}      # the dashboard refreshes every 5 minutes; polling
                               # faster only costs requests
CURL_TIMEOUT=${CURL_TIMEOUT:-20}
MAX_AGE=${MAX_AGE:-900}        # refuse to act on a feed older than this

GRACE=${GRACE:-900}            # ignore a container for this long after it starts
COOLDOWN=${COOLDOWN:-1800}     # minimum gap between two restarts of one container
CAP=${CAP:-3}                  # most restarts of one container per CAP_WINDOW
CAP_WINDOW=${CAP_WINDOW:-21600}

# Percentage of this folder's mapped nodes that may be flagged before the pass is
# abandoned as an upstream event. 100 disables the guard.
FLEET_MAX_BAD=${FLEET_MAX_BAD:-50}

# What to restart. tunnel = the tun2proxy parent, which is how the exit address
# changes; node = the earnapp container; none = report only.
BANNED_ACTION=${BANNED_ACTION:-tunnel}
OFFLINE_ACTION=${OFFLINE_ACTION:-node}

DRY_RUN=false
MODE=report

# Set if an append to LOG_FILE ever fails. The log is the cooldown and cap record,
# so losing it means losing the rate limits, and this script would rather stop than
# restart the same container every pass forever.
LOG_BROKEN=false

# ---------------------------------------------------------------------- plumbing

log() { # <message...>
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  # stderr is redirected before the append, so a failing append is silent here and
  # reported once, by whoever needed the ledger.
  if ! printf '%s\n' "$line" 2>/dev/null >> "$LOG_FILE"; then
    LOG_BROKEN=true
    return 0
  fi
  # Keep the ledger bounded. It is also the cooldown and cap record, so it is
  # trimmed from the front rather than truncated.
  local n
  n=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if (( n > MAX_LOG_LINES )); then
    tail -n $(( MAX_LOG_LINES / 2 )) "$LOG_FILE" > "$LOG_FILE.trim" 2>/dev/null \
      && mv "$LOG_FILE.trim" "$LOG_FILE"
  fi
}

die() { log "FATAL $*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash nodeWatcher.sh [mode] [options]

Modes:
  --report        one pass, print the verdict, change nothing   (default)
  --once          one pass, act on it
  --watch         loop every INTERVAL, acting each pass

Options:
  -n, --dry-run   never restart anything; log what would have happened
  -h, --help      this text

Configuration is read from the environment. WATCH_URL is required; the bearer
token is read from TOKEN_FILE (default .watch_token) and never from an argument.
See the comments at the top of this file for the rest.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --report) MODE=report ;;
    --once) MODE=once ;;
    --watch) MODE=watch ;;
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# gawk, for mktime(). The log is the cooldown and cap ledger, and reading it means
# turning timestamps back into epochs.
AWK=$(command -v gawk 2>/dev/null || command -v awk)

preflight() {
  local missing=()
  for cmd in docker curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "missing required command(s): ${missing[*]}"
  echo | "$AWK" 'BEGIN { if (mktime("2020 01 01 00 00 00") <= 0) exit 1 }' \
    || die "this awk has no working mktime(); install gawk"
  [[ -n "$WATCH_URL" ]] || die "WATCH_URL is not set. Nothing to watch."
  [[ -f "$MAP_FILE" ]] || die "$MAP_FILE does not exist. Run EAincome.sh --nodemap first."
  [[ -f "$TOKEN_FILE" ]] || die "$TOKEN_FILE does not exist. Put the bearer token in it."
  [[ -s "$TOKEN_FILE" ]] || die "$TOKEN_FILE is empty."
  printf '' 2>/dev/null >> "$LOG_FILE" \
    || die "cannot write $LOG_FILE. That file is the cooldown and cap record, so without it there are no rate limits and nothing here should be restarted."
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon."
}

# ------------------------------------------------------------------- the feed

FEED=''

fetch() {
  local token cfg tmp code
  token=$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null)
  if [[ -z "$token" ]]; then
    log "ERROR $TOKEN_FILE is empty; doing nothing this pass"
    return 1
  fi
  # A quote or backslash would break out of the curl config value below. A bearer
  # token has no business containing either, so refuse rather than sanitise.
  if [[ "$token" == *'"'* || "$token" == *'\'* ]]; then
    log "ERROR the token in $TOKEN_FILE contains a quote or backslash; refusing to use it"
    return 1
  fi
  # url and header go through a config file on stdin so the token never reaches the
  # command line. Everything on the command line here is harmless.
  cfg=$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nsilent\nmax-time = %s\n' \
        "$WATCH_URL" "$token" "$CURL_TIMEOUT")
  tmp=$(mktemp) || { log "ERROR cannot create a temporary file"; return 1; }
  code=$(printf '%s' "$cfg" | curl --config - --output "$tmp" --write-out '%{http_code}' 2>/dev/null)
  if [[ "$code" != 200 ]]; then
    log "ERROR feed returned HTTP ${code:-no-response}; doing nothing this pass"
    rm -f "$tmp"
    return 1
  fi
  if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    log "ERROR feed body is not a JSON object; doing nothing this pass"
    rm -f "$tmp"
    return 1
  fi
  FEED=$(cat "$tmp")
  rm -f "$tmp"
  return 0
}

# ------------------------------------------------------------------ the mapping

# nodeid -> container, for the nodes this folder started. Nothing else is in here,
# which is why a fleet-wide feed can be consumed safely from a single folder.
declare -A NODE_CONTAINER=()
# The same ids again, in the order the map lists them, which is the order the nodes
# were started. Iterating an associative array is unordered, and an unordered log is
# harder to compare against the previous pass than it needs to be.
declare -a MAP_ORDER=()
MAP_COUNT=0

load_map() {
  NODE_CONTAINER=()
  MAP_ORDER=()
  MAP_COUNT=0
  local line id cname rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    # The map is written by EAincome.sh, but it can also be hand-edited, and it is
    # edited on Windows often enough that a stray CR is a real failure mode: it
    # would travel into a container name and every lookup for that node would
    # report the container missing.
    line=${line//$'\r'/}
    read -r id cname rest <<<"$line"
    [[ -z "$id" || "$id" == \#* || -z "$cname" ]] && continue
    # Container names go to docker as arguments. Docker's own naming rule is the
    # cheapest way to be sure a mangled line cannot become a strange argument.
    if [[ ! "$cname" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      log "WARN $MAP_FILE has an entry whose container name is not a container name; ignoring that line"
      continue
    fi
    if [[ -n "${NODE_CONTAINER[$id]+set}" ]]; then
      # Two containers claiming one node id is the duplicate-identity trap, and it
      # is a problem where the nodes were started, not here. Keep the first and say
      # so, rather than silently picking whichever line came last.
      log "WARN $MAP_FILE lists $(short_id "$id") twice; keeping ${NODE_CONTAINER[$id]} and ignoring $cname"
      continue
    fi
    NODE_CONTAINER["$id"]="$cname"
    MAP_ORDER+=("$id")
    MAP_COUNT=$((MAP_COUNT + 1))
  done < "$MAP_FILE"
  (( MAP_COUNT > 0 )) || { log "ERROR $MAP_FILE has no usable entries; doing nothing"; return 1; }
  return 0
}

# Node ids arrive from a web request, and they end up as arguments to docker. Only
# the shape the dashboard actually emits is allowed through; anything else is not a
# node id, whatever it is.
valid_id() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; }

# --------------------------------------------------------------- docker questions

# The tun2proxy parent. Node containers join the tunnel with
# --network container:<tunnel>, so the tunnel is the node's network namespace and
# restarting it is what changes the exit address a ban was passed on.
parent_of() { # <container> -> parent container name on stdout
  local mode
  mode=$(docker inspect --type container "$1" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null) \
    || return 1
  [[ "$mode" == container:* ]] || return 1
  docker inspect --type container "${mode#container:}" --format '{{.Name}}' 2>/dev/null \
    | sed 's|^/||'
}

age_of() { # <container> -> seconds since it last started, on stdout
  local started epoch
  started=$(docker inspect --type container "$1" --format '{{.State.StartedAt}}' 2>/dev/null) \
    || return 1
  epoch=$(date -d "$started" +%s 2>/dev/null) || return 1
  echo $(( $(date +%s) - epoch ))
}

# --------------------------------------------------------------------- the ledger

# There is no state file. The log is the record, which means the rate limits survive
# a restart of this script and are auditable by reading the same lines a human reads.
# A dry run reads its own DRY-RUN lines, so rehearsing does not inherit the real
# run's history and vice versa.
ledger() { # <container> <window> -> "<last_restart_epoch> <restarts_in_window>"
  if [[ ! -f "$LOG_FILE" ]]; then
    printf '0 0'
    return 0
  fi
  "$AWK" -v c="$1" -v win="$2" -v dry="$DRY_RUN" -v now="$(date +%s)" '
    function ts(d, t) { gsub(/-/, " ", d); gsub(/:/, " ", t); return mktime(d " " t) }
    {
      hit = (dry == "true") ? ($3 == "DRY-RUN" && $6 == c) : ($3 == "RESTART" && $4 == c)
      if (!hit) next
      e = ts($1, $2)
      if (e <= 0) next
      if (e > last) last = e
      if (now - e <= win) n++
    }
    END { printf "%d %d", last + 0, n + 0 }' "$LOG_FILE" 2>/dev/null || printf '0 0'
}

restart_container() { # <container> <reason...>
  local c="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN would RESTART $c ($*)"
    return 0
  fi
  if docker restart "$c" >/dev/null 2>&1; then
    log "RESTART $c ($*)"
    return 0
  fi
  log "ERROR docker restart $c failed ($*)"
  return 1
}

# A node id is an account-level secret, and this log is meant to be readable and
# pasteable. Enough of the id to tell two nodes apart, not enough to be the id.
short_id() { printf '%s…' "${1:0:13}"; }

# ------------------------------------------------------------------- one verdict

act() { # <nodeid> <node container> <banned|offline>
  local id="$1" c="$2" verdict="$3"
  local action target last count started

  # No ledger, no rate limits. Restarting under those conditions would mean
  # restarting the same container every pass for as long as the fault lasts, which
  # is the failure this script's whole cooldown and cap design exists to avoid.
  if [[ "$LOG_BROKEN" == true ]]; then
    log "SKIP $c $verdict, but $LOG_FILE cannot be written, so there is no cooldown or cap record to restart against"
    return 0
  fi

  case "$verdict" in
    banned)  action="$BANNED_ACTION" ;;
    offline) action="$OFFLINE_ACTION" ;;
    *)       return 0 ;;
  esac

  if [[ "$action" == none ]]; then
    log "SKIP $c $verdict, but the action for $verdict is none"
    return 0
  fi

  if ! docker inspect --type container "$c" >/dev/null 2>&1; then
    log "SKIP $c $verdict, but no container by that name exists here any more; $MAP_FILE is stale"
    return 0
  fi

  if [[ "$action" == tunnel ]]; then
    # A ban is a judgement about the exit address, so the only useful restart is the
    # one that changes it. If the node is not behind a tunnel there is no such
    # restart, and bouncing the node instead would be a loop that fixes nothing.
    target=$(parent_of "$c") || target=''
    if [[ -z "$target" ]]; then
      log "SKIP $c $verdict, but it has no tun2proxy parent, so nothing here can change its exit address"
      return 0
    fi
  else
    target="$c"
  fi

  started=$(age_of "$target") || started=''
  if [[ -n "$started" ]] && (( started < GRACE )); then
    log "SKIP $target ${started}s old, inside the ${GRACE}s grace window ($verdict $(short_id "$id"))"
    return 0
  fi

  read -r last count < <(ledger "$target" "$CAP_WINDOW")
  local now; now=$(date +%s)

  if (( last > 0 && now - last < COOLDOWN )); then
    log "SKIP $target restarted $(( now - last ))s ago, under the ${COOLDOWN}s cooldown ($verdict $(short_id "$id"))"
    return 0
  fi

  if (( count >= CAP )); then
    log "SKIP $target has been restarted $count time(s) in the last $(( CAP_WINDOW / 3600 ))h, at the cap of $CAP ($verdict $(short_id "$id"))"
    return 0
  fi

  restart_container "$target" "$verdict $(short_id "$id") node $c"
}

# ---------------------------------------------------------------------- one pass

pass() {
  fetch || return 0

  local age unreadable
  age=$(jq -r '.ageSeconds // empty' <<<"$FEED" 2>/dev/null)
  unreadable=$(jq -r '.counts.unreadableAccounts // empty' <<<"$FEED" 2>/dev/null)

  # Staleness and completeness are two of the four reasons to do nothing, so a feed
  # that does not report them cannot be acted on at all.
  if [[ ! "$age" =~ ^[0-9]+$ ]]; then
    log "ERROR feed has no usable ageSeconds, so its freshness cannot be judged; doing nothing this pass"
    return 0
  fi
  if [[ ! "$unreadable" =~ ^[0-9]+$ ]]; then
    log "ERROR feed has no usable counts.unreadableAccounts, so completeness cannot be judged; doing nothing this pass"
    return 0
  fi
  if (( unreadable > 0 )); then
    log "HOLD feed reports $unreadable unreadable account(s), so the lists are missing nodes; doing nothing this pass"
    return 0
  fi
  if (( age > MAX_AGE )); then
    log "HOLD feed is ${age}s old, past the ${MAX_AGE}s limit; doing nothing this pass"
    return 0
  fi

  load_map || return 0

  # A positive verdict per mapped node, and a tally of everything the feed flagged
  # that this folder did not start. Foreign ids are counted so the operator can see
  # the watcher is deliberately staying out of another folder's business, not
  # silently failing to see it.
  local -A verdict=()
  local -A foreign=()
  local id

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! valid_id "$id"; then
      log "WARN feed sent a banned entry that is not shaped like a node id; ignoring it"
      continue
    fi
    if [[ -n "${NODE_CONTAINER[$id]+set}" ]]; then
      verdict["$id"]=banned
    else
      foreign["$id"]=1
    fi
  done < <(jq -r '(.banned // [])[] | select(type == "string")' <<<"$FEED" 2>/dev/null)

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! valid_id "$id"; then
      log "WARN feed sent an offline entry that is not shaped like a node id; ignoring it"
      continue
    fi
    if [[ -n "${NODE_CONTAINER[$id]+set}" ]]; then
      # In both lists means banned. Banned is the deeper fault, and the fix for it
      # is the one that also brings a node back.
      [[ -n "${verdict[$id]+set}" ]] || verdict["$id"]=offline
    else
      foreign["$id"]=1
    fi
  done < <(jq -r '(.offline // [])[] | select(type == "string")' <<<"$FEED" 2>/dev/null)

  local flagged=${#verdict[@]} others=${#foreign[@]}

  if (( flagged == 0 )); then
    log "OK nothing of ours is flagged: $MAP_COUNT mapped, $others flagged id(s) belong elsewhere, feed ${age}s old"
    return 0
  fi

  local pct=$(( flagged * 100 / MAP_COUNT ))
  if (( FLEET_MAX_BAD < 100 && pct > FLEET_MAX_BAD )); then
    log "HOLD $flagged of $MAP_COUNT mapped node(s) flagged (${pct}%, limit ${FLEET_MAX_BAD}%); that shape is one upstream event, not $flagged broken nodes, and no restart fixes it. Doing nothing this pass"
    return 0
  fi

  log "VERDICT $flagged of $MAP_COUNT mapped node(s) flagged, $others elsewhere, feed ${age}s old"
  for id in "${MAP_ORDER[@]}"; do
    [[ -n "${verdict[$id]+set}" ]] || continue
    log "FLAG ${verdict[$id]} $(short_id "$id") -> ${NODE_CONTAINER[$id]}"
  done

  if [[ "$MODE" == report ]]; then
    log "REPORT only, changing nothing"
    return 0
  fi

  for id in "${MAP_ORDER[@]}"; do
    [[ -n "${verdict[$id]+set}" ]] || continue
    act "$id" "${NODE_CONTAINER[$id]}" "${verdict[$id]}"
  done
  return 0
}

# --------------------------------------------------------------------------- main

preflight

log "start mode=$MODE dry-run=$DRY_RUN url=$WATCH_URL map=$MAP_FILE banned=$BANNED_ACTION offline=$OFFLINE_ACTION"

case "$MODE" in
  report|once)
    pass
    ;;
  watch)
    SLEEP_PID=''
    trap 'log "stopping"; [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null; exit 0' INT TERM
    while true; do
      pass
      # Sleep in the background and wait on it, so a stop signal is handled the
      # moment it arrives. Slept in the foreground, bash would hold the signal until
      # the sleep finished, and a container being stopped would sit there for up to
      # INTERVAL seconds and then be killed instead of exiting.
      sleep "$INTERVAL" &
      SLEEP_PID=$!
      wait "$SLEEP_PID" || true
    done
    ;;
esac
