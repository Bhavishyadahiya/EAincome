#!/usr/bin/env bash
# nodeWatchdog.sh -- restart EarnApp nodes that have stopped doing any work.
#
# No credentials, no prompts, no configuration required. Everything it needs it
# reads from Docker and from the kernel.
#
# The problem it solves: a node can be running, registered and apparently
# healthy while earning nothing, and the earnapp binary will not tell you. It
# prints nothing to stdout once started, even with --verbose, and its own SDK log
# is encrypted. So instead of asking the process, this watches what the process
# actually does on the network:
#
#   bytes    -- total traffic through the node's network namespace. A relaying
#               node moves tens of megabytes an hour in each direction; an idle
#               one sits at a few bytes a second of keepalive.
#   sockets  -- established TCP connections to port 443. A working node holds
#               several at once and the peers churn as sessions come and go.
#
# A node that has moved almost nothing for half an hour *and* is holding almost
# no connections is stuck. Restarting it is the remedy that works, and it is
# cheap. Both conditions have to be true, because either one alone has a benign
# explanation: a quiet period, or a momentary reconnect.
#
# It also fixes the case where a node is simply not running. In proxy mode each
# earnapp container shares the network namespace of its tun2proxy parent, and if
# Docker starts the child first at boot the child dies immediately and its
# restart policy never applies, because the *start* failed rather than the run.
# This script starts the parent first and then the child.
#
# Honest caveat: the traffic and socket thresholds below are inferred from
# measurements of healthy nodes, not from a node caught red-handed in the
# dashboard. Every run appends its samples to watchdog.state, so once you see a
# node go red you can look back at what its numbers were doing and tighten these
# numbers to match reality. Start with --report for a day if you would rather
# look before it acts.
#
# Usage:
#   bash nodeWatchdog.sh                # report only, changes nothing (default)
#   bash nodeWatchdog.sh --once         # take action once, then exit
#   bash nodeWatchdog.sh --once --dry-run
#   bash nodeWatchdog.sh --watch        # sample and act every INTERVAL seconds
#   bash nodeWatchdog.sh --cron         # print a crontab line and exit
#
# It also runs as a container, which is the supervisor this host already has:
#
#   sudo bash EAincome.sh --watchdog
#
# Docker then keeps it alive and brings it back after a reboot, so there is no
# systemd unit to write and no crontab to maintain. Containerised it needs the
# Docker socket, the host's /proc mounted at PROC_ROOT, and EAINCOME_DIR pointing
# at the bind-mounted script folder so state and logs land on the host.
#
# Scope, in three tests a container has to pass before it is touched at all:
#
#   1. it is named in this folder's containernames.txt (SCOPE_FILE). That file is
#      written by the EAincome.sh copy that created the containers, so several
#      folders on one host each watch their own area and nothing else. Missing or
#      empty means watch nothing, deliberately -- only SCOPE_FILE= (explicitly
#      empty) falls back to the whole host.
#   2. its name starts with NODE_PREFIX, 'earnapp'. EAincome names a node
#      earnapp<UNIQUE_ID><n> and its tunnel tun<UNIQUE_ID><n>, and that file lists
#      both, plus the watchdog's own container. This drops the tunnels and the
#      watcher itself before anything is inspected.
#   3. it carries an EARNAPP_UUID variable, which is what actually makes it a node.
#
# Tests 2 and 3 overlap on purpose. Restarting a tun2proxy container would pull the
# network namespace out from under the node sharing it, so it is worth being sure
# twice, cheaply, that one can never be selected.
#
# Every threshold is an environment variable, so nothing needs editing:
#   GRACE STALL_WINDOW STALL_BYTES MIN_SOCKETS COOLDOWN CAP CAP_WINDOW INTERVAL

set -uo pipefail

GRACE=${GRACE:-900}                # ignore a node for this long after it starts
STALL_WINDOW=${STALL_WINDOW:-1800} # look back this far when measuring traffic
STALL_BYTES=${STALL_BYTES:-1048576}  # less than this over the window is a stall
MIN_SOCKETS=${MIN_SOCKETS:-2}      # fewer established :443 than this is a stall
COOLDOWN=${COOLDOWN:-1800}         # minimum gap between restarts of one node
CAP=${CAP:-3}                      # most restarts of one node per CAP_WINDOW
CAP_WINDOW=${CAP_WINDOW:-21600}
INTERVAL=${INTERVAL:-60}

# Where this script's own files live. Overridden to the bind-mounted folder when
# containerised, so state and logs survive the container being recreated.
EAINCOME_DIR=${EAINCOME_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo .)"}
STATE_FILE=${STATE_FILE:-"$EAINCOME_DIR/watchdog.state"}
LOG_FILE=${LOG_FILE:-"$EAINCOME_DIR/watchdog.log"}
# Watch only the containers this EAincome folder created. Written by EAincome.sh
# as it creates them. Note the '-' rather than ':-': SCOPE_FILE= disables scoping
# and watches every EarnApp node on the host.
SCOPE_FILE=${SCOPE_FILE-"$EAINCOME_DIR/containernames.txt"}
# Names a node container can have. EAincome names them earnapp<UNIQUE_ID><n> and
# their tunnels tun<UNIQUE_ID><n>, so this one word excludes every tunnel by
# construction, before anything is inspected -- and excludes the watchdog's own
# container, which the scope file also lists so that --delete cleans it up. Note
# the '-' rather than ':-': NODE_PREFIX= turns the check off.
NODE_PREFIX=${NODE_PREFIX-earnapp}
# /proc of the machine the containers run on, which is not this container's own.
PROC_ROOT=${PROC_ROOT:-/proc}
MAX_STATE_LINES=${MAX_STATE_LINES:-50000}

MODE='report'
DRY_RUN=false

while (( $# )); do
  case "$1" in
    --report) MODE='report'; shift ;;
    --once)   MODE='once'; shift ;;
    --watch)  MODE='watch'; shift ;;
    --cron)   MODE='cron'; shift ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) printf 'Unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == 'cron' ]]; then
  cat <<EOF
Add this to root's crontab (crontab -e). It samples and acts every 5 minutes:

  */5 * * * * cd $EAINCOME_DIR && /bin/bash nodeWatchdog.sh --once >> watchdog.cron.log 2>&1

Sampling every 5 minutes is fine: STALL_WINDOW is ${STALL_WINDOW}s, so a stall
still needs several consistent samples before anything is restarted.

Or skip cron entirely and let Docker supervise it, which also brings it back
after a reboot and gives it a known-good awk and date:

  sudo bash EAincome.sh --watchdog
EOF
  exit 0
fi

command -v docker >/dev/null 2>&1 || { printf 'docker is required.\n' >&2; exit 2; }
if ! docker info >/dev/null 2>&1; then
  printf 'Cannot talk to Docker. Run this as root or a docker-group user, or, if\n' >&2
  printf 'this is the container form, mount /var/run/docker.sock into it.\n' >&2
  exit 2
fi

# Prefer gawk. The cooldown and the restart cap are worked out by parsing
# timestamps back out of the log with mktime(), which started life as a gawk
# extension: mawk only grew it in 1.3.4 and busybox awk does not have it at all.
# Without mktime every restart looks like the first one, so neither the cooldown
# nor the cap can be enforced -- and a node that a restart cannot fix would then
# be restarted forever. Refuse to act rather than risk that loop.
AWK=$(command -v gawk 2>/dev/null || command -v awk 2>/dev/null)
[[ -n "$AWK" ]] || { printf 'awk is required.\n' >&2; exit 2; }
if ! "$AWK" 'BEGIN { if (mktime("2020 01 01 00 00 00") <= 0) exit 1 }' >/dev/null 2>&1; then
  printf 'This awk (%s) has no working mktime(), so restart cooldowns and the\n' "$AWK" >&2
  printf 'restart cap cannot be enforced. Staying in report mode rather than\n' >&2
  printf 'risking a restart loop. Install gawk, or use the container form:\n' >&2
  printf '  sudo bash EAincome.sh --watchdog\n' >&2
  MODE='report'
fi

now() { date +%s; }
log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

# Which containers are worth looking at. containernames.txt scopes the watchdog to
# one EAincome folder's own nodes, which is what makes several copies of the script
# on one host safe: each watches its own area instead of sampling, and restarting,
# another folder's containers. It is a filter and never the selector, because the
# file lists every container the script created -- tunnels included -- along with
# stale names from batches that have since been removed.
#
# A configured scope file that is missing or empty yields nothing, deliberately.
# Widening to the whole host would be the wrong way to fail: --delete removes that
# file, so a watchdog whose own folder had been deleted would otherwise adopt every
# other folder's nodes. It is re-read every pass, so one that starts before
# --start has run sits idle and picks its nodes up as soon as the file appears.
# Only SCOPE_FILE= (explicitly empty) watches the whole host.
#
# Names are then held to NODE_PREFIX, which is what keeps a tunnel out: EAincome
# names a node earnapp<UNIQUE_ID><n> and its tunnel tun<UNIQUE_ID><n>, so the two
# differ in the one place that costs nothing to check. The scope file lists the
# tunnels and the watchdog's own container as well, and this drops all of them
# before a single docker inspect is run.
candidate_names() {
  local names
  if [[ -z "${SCOPE_FILE:-}" ]]; then
    names=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
  elif [[ -s "$SCOPE_FILE" ]]; then
    names=$(cat "$SCOPE_FILE" 2>/dev/null)
  else
    return 0
  fi
  printf '%s\n' "$names" | "$AWK" -v prefix="${NODE_PREFIX-earnapp}" '
    { sub(/\r$/, ""); gsub(/[[:space:]]/, "") }
    $0 == ""                                  { next }
    prefix != "" && index($0, prefix) != 1    { next }
    !seen[$0]++'
}

# Every EarnApp node among the candidates, confirmed by the env var EAincome sets
# rather than by name alone. The name check has already dropped the tunnels and the
# watchdog's own container; this is the second, independent reason neither can ever
# be restarted, and it is what keeps the script working if the naming scheme
# changes.
list_nodes() {
  local name uuid
  while read -r name; do
    [[ -n "$name" ]] || continue
    uuid=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
           | sed -n 's/^EARNAPP_UUID=//p' | head -1)
    [[ -n "$uuid" ]] && printf '%s\t%s\n' "$name" "$uuid"
  done < <(candidate_names)
}

# Traffic and socket counts are read straight out of the container's network
# namespace via /proc, which works without a shell in the image and without
# docker exec. PROC_ROOT is the host's /proc, bind-mounted when this runs as a
# container: the PIDs come from docker inspect and belong to the host's namespace,
# not to whatever /proc the watchdog itself was given. In proxy mode the namespace
# is the tun2proxy parent's and holds both the tunnel and the upstream leg, so the
# byte count double-counts -- which does not matter, because the only question
# asked of it is "roughly zero, or not".
sample() { # sample <pid> -> "<bytes> <established443>"
  local pid=$1 bytes=0 est=0
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || { printf '0 0'; return; }
  bytes=$("$AWK" 'NR>2 { gsub(/:/,"",$1); if ($1 != "lo") t += $2 + $10 } END { print t+0 }' \
          "$PROC_ROOT/$pid/net/dev" 2>/dev/null) || bytes=0
  est=$("$AWK" 'NR>1 && $4=="01" && $3 ~ /:01BB$/ { n++ } END { print n+0 }' \
        "$PROC_ROOT/$pid/net/tcp" "$PROC_ROOT/$pid/net/tcp6" 2>/dev/null) || est=0
  printf '%s %s' "${bytes:-0}" "${est:-0}"
}

started_epoch() { # container -> unix time it last started, 0 if never
  local raw
  raw=$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null)
  [[ -n "$raw" && "$raw" != "0001-01-01T00:00:00Z" ]] || { printf '0'; return; }
  date -d "$raw" +%s 2>/dev/null || printf '0'
}

# In proxy mode HostConfig.NetworkMode is container:<id>. A child cannot start
# while its parent is down, and Docker's restart policy will not rescue it,
# because it is the start that fails rather than the run.
parent_of() {
  local mode
  mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$1" 2>/dev/null)
  [[ "$mode" == container:* ]] && printf '%s' "${mode#container:}"
}

# Which log lines count as "this node was acted on", for the cooldown and the cap.
# A log line is "<date> <time> <message>", so the action word is $3.
#
#   live      RESTART <container> -- <reason>          -> $3, $4
#   dry run   DRY-RUN would RESTART <container> -- ...  -> $3, $6
#
# The two are kept apart on purpose. Matching the text loosely (the old
# 'RESTART <name>' regex) made a dry run's own "would RESTART" line look like a
# real restart, so a preview put the node straight into cooldown and went quiet
# after CAP hits -- exactly the mode you are told to leave running for a day.
# Keeping the ledgers separate means a dry run obeys the same cooldown and cap a
# live run would, giving a faithful preview, while a live run ignores DRY-RUN
# history so switching over never inherits a cooldown that never happened.
LEDGER_MATCH='(dry ? ($3 == "DRY-RUN" && $6 == c) : ($3 == "RESTART" && $4 == c))'

restarts_since() { # <container> <epoch> -> count of recorded restarts since then
  [[ -f "$LOG_FILE" ]] || { printf '0'; return; }
  local dry=0
  if [[ "$DRY_RUN" == true ]]; then dry=1; fi
  "$AWK" -v c="$1" -v since="$2" -v dry="$dry" '
    '"$LEDGER_MATCH"' {
      ts = $1 " " $2
      gsub(/-/, " ", ts); gsub(/:/, " ", ts)
      # mktime wants "YYYY MM DD HH MM SS"
      if (mktime(ts) >= since) n++
    }
    END { print n+0 }' "$LOG_FILE" 2>/dev/null || printf '0'
}

last_restart() { # <container> -> epoch of most recent restart, 0 if none
  [[ -f "$LOG_FILE" ]] || { printf '0'; return; }
  local dry=0
  if [[ "$DRY_RUN" == true ]]; then dry=1; fi
  "$AWK" -v c="$1" -v dry="$dry" '
    '"$LEDGER_MATCH"' {
      ts = $1 " " $2; gsub(/-/, " ", ts); gsub(/:/, " ", ts)
      t = mktime(ts); if (t > best) best = t
    }
    END { print best+0 }' "$LOG_FILE" 2>/dev/null || printf '0'
}

record() { # append a sample; trim occasionally so the file cannot grow forever
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATE_FILE"
  local lines
  lines=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
  if (( lines > MAX_STATE_LINES )); then
    tail -n $(( MAX_STATE_LINES / 2 )) "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

# Oldest sample for this container that is still inside the window, plus how many
# samples we have. Returns "<bytes> <age_seconds> <count>"; age 0 means we do not
# have enough history yet to judge anything.
baseline() { # <container> <now>
  [[ -f "$STATE_FILE" ]] || { printf '0 0 0'; return; }
  "$AWK" -v c="$1" -v now="$2" -v win="$STALL_WINDOW" -F'\t' '
    $1 == c && (now - $2) <= win {
      n++
      if (oldest == 0 || $2 < oldest) { oldest = $2; bytes = $3 }
    }
    END { print bytes+0, (oldest ? now - oldest : 0), n+0 }' "$STATE_FILE" 2>/dev/null \
    || printf '0 0 0'
}

forget() { # drop a container's samples so a restart starts the window fresh
  [[ -f "$STATE_FILE" ]] || return 0
  "$AWK" -v c="$1" -F'\t' '$1 != c' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

human() { # bytes -> short readable form
  "$AWK" -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i]
  }'
}

act() { # act <container> <reason>
  local c=$1 reason=$2 t last count
  t=$(now)
  if [[ "$MODE" == 'report' ]]; then
    printf '      would restart: %s\n' "$reason"
    return
  fi
  last=$(last_restart "$c")
  if (( last > 0 && t - last < COOLDOWN )); then
    printf '      stalled but in cooldown (%ds of %ds elapsed)\n' "$(( t - last ))" "$COOLDOWN"
    return
  fi
  count=$(restarts_since "$c" "$(( t - CAP_WINDOW ))")
  if (( count >= CAP )); then
    log "SKIP $c -- already restarted $count times in the last $(( CAP_WINDOW / 3600 ))h, not touching it again. Something other than a restart is wrong."
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN would RESTART $c -- $reason"
    return
  fi
  if docker restart "$c" >/dev/null 2>&1; then
    log "RESTART $c -- $reason"
    forget "$c"
  else
    log "FAILED to restart $c"
  fi
}

revive() { # a node that is not running at all
  local c=$1 parent pname p_status
  parent=$(parent_of "$c")
  if [[ -n "$parent" ]]; then
    # NetworkMode gives an id, not a name; log the name so the line is readable.
    pname=$(docker inspect -f '{{.Name}}' "$parent" 2>/dev/null)
    pname="${pname#/}"; [[ -n "$pname" ]] || pname="${parent:0:12}"
    p_status=$(docker inspect -f '{{.State.Status}}' "$parent" 2>/dev/null)
    if [[ "$p_status" != 'running' ]]; then
      if [[ "$MODE" == 'report' || "$DRY_RUN" == true ]]; then
        printf '      would start its proxy container first (%s is %s)\n' "$pname" "${p_status:-missing}"
      else
        docker start "$parent" >/dev/null 2>&1 && log "STARTED parent $pname for $c" \
          || log "FAILED to start parent $pname for $c"
        sleep 3
      fi
    fi
  fi
  if [[ "$MODE" == 'report' ]]; then
    printf '      would start it\n'
  elif [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN would START $c"
  elif docker start "$c" >/dev/null 2>&1; then
    log "RESTART $c -- was not running"
  else
    log "FAILED to start $c"
  fi
}

# One line describing what this run is allowed to look at. Used by the startup log
# and by the nothing-to-do message, so the two can never disagree.
scope_description() {
  local prefix="${NODE_PREFIX-earnapp}"
  if [[ -z "${SCOPE_FILE:-}" ]]; then
    printf 'every %s* container on this host (SCOPE_FILE is empty)' "${prefix:-}"
  elif [[ -s "$SCOPE_FILE" ]]; then
    printf 'the %d %s* container(s) named in %s' \
      "$(candidate_names | wc -l)" "${prefix:-}" "$SCOPE_FILE"
  else
    printf 'nothing yet: %s does not exist or is empty' "$SCOPE_FILE"
  fi
}

pass() {
  local t nodes name uuid status pid s bytes est up base_bytes base_age base_n delta rate
  local total=0 stalled=0 down=0 young=0
  t=$(now)
  nodes=$(list_nodes)
  if [[ -z "$nodes" ]]; then
    local listed=0 matched prefix="${NODE_PREFIX-earnapp}"
    if [[ -n "${SCOPE_FILE:-}" && -s "$SCOPE_FILE" ]]; then
      listed=$("$AWK" 'NF' "$SCOPE_FILE" 2>/dev/null | wc -l)
    fi
    matched=$(candidate_names | wc -l)
    if [[ -n "${SCOPE_FILE:-}" && ! -s "$SCOPE_FILE" ]]; then
      printf 'Nothing to watch: %s does not exist or is empty.\n' "$SCOPE_FILE" >&2
      printf 'EAincome.sh --start writes it and --delete removes it, so this is what a\n' >&2
      printf 'folder with no nodes started looks like. It is re-read every pass, so the\n' >&2
      printf 'nodes will be picked up on their own once --start has run. Deliberately no\n' >&2
      printf 'fallback to every node on this host: another EAincome folder on this host\n' >&2
      printf 'is not this one to look after. Set SCOPE_FILE= to watch all of them.\n' >&2
    elif [[ -n "${SCOPE_FILE:-}" && "${matched:-0}" -eq 0 ]]; then
      printf 'Nothing to watch yet: none of the %d name(s) in %s starts with %s.\n' \
        "$listed" "$SCOPE_FILE" "${prefix:-<any>}" >&2
      printf 'This is what a folder looks like when --watchdog ran before --start: the\n' >&2
      printf 'only name in there is the watchdog container itself, recorded so that\n' >&2
      printf '%s\n' '--delete removes it too. The file is re-read every pass, so the nodes' >&2
      printf 'will be picked up on their own once --start has created them.\n' >&2
    elif [[ -n "${SCOPE_FILE:-}" ]]; then
      printf 'None of the %d %s* container(s) named in %s carries an EARNAPP_UUID.\n' \
        "$matched" "${prefix:-}" "$SCOPE_FILE" >&2
      printf 'That file is written by EAincome.sh --start. Set SCOPE_FILE= to look\n' >&2
      printf 'at every node on this host instead.\n' >&2
    else
      printf 'No EarnApp node containers found. Is EAincome.sh --start done?\n' >&2
    fi
    return 0
  fi

  printf '%-22s %-10s %8s %7s %10s  %s\n' \
    'CONTAINER' 'STATE' 'UPTIME' 'SOCK443' 'TRAFFIC' 'VERDICT'
  printf '%-22s %-10s %8s %7s %10s  %s\n' \
    '----------------------' '----------' '--------' '-------' '----------' '-------'

  while IFS=$'\t' read -r name uuid; do
    [[ -n "$name" ]] || continue
    total=$(( total + 1 ))
    status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)

    if [[ "$status" != 'running' ]]; then
      down=$(( down + 1 ))
      printf '%-22s %-10s %8s %7s %10s  %s\n' "$name" "${status:-gone}" '-' '-' '-' 'NOT RUNNING'
      revive "$name"
      continue
    fi

    pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null)
    read -r bytes est <<<"$(sample "$pid")"
    up=$(( t - $(started_epoch "$name") ))
    record "$name" "$t" "$bytes" "$est"
    read -r base_bytes base_age base_n <<<"$(baseline "$name" "$t")"

    if (( up < GRACE )); then
      young=$(( young + 1 ))
      printf '%-22s %-10s %7dm %7s %10s  %s\n' "$name" "$status" "$(( up / 60 ))" \
        "$est" "$(human "$bytes")" "starting up, ignored for $(( (GRACE - up) / 60 ))m"
      continue
    fi

    if (( base_age < STALL_WINDOW * 3 / 4 || base_n < 2 )); then
      printf '%-22s %-10s %7dh %7s %10s  %s\n' "$name" "$status" "$(( up / 3600 ))" \
        "$est" "$(human "$bytes")" "watching, need $(( (STALL_WINDOW - base_age) / 60 ))m more history"
      continue
    fi

    delta=$(( bytes - base_bytes ))
    (( delta < 0 )) && delta=0   # counters reset when the container restarted
    rate="$(human "$delta")/$(( base_age / 60 ))m"

    if (( delta < STALL_BYTES && est < MIN_SOCKETS )); then
      stalled=$(( stalled + 1 ))
      printf '%-22s %-10s %7dh %7s %10s  %s\n' "$name" "$status" "$(( up / 3600 ))" \
        "$est" "$rate" 'STALLED'
      act "$name" "moved $(human "$delta") in $(( base_age / 60 ))m holding $est connections"
    else
      printf '%-22s %-10s %7dh %7s %10s  %s\n' "$name" "$status" "$(( up / 3600 ))" \
        "$est" "$rate" 'working'
    fi
  done <<<"$nodes"

  printf '\n%d node(s): %d stalled, %d not running, %d still starting up.\n' \
    "$total" "$stalled" "$down" "$young"
  if [[ "$MODE" == 'report' ]]; then
    printf 'Report only -- nothing was changed. Use --once to let it act.\n'
  fi
}

case "$MODE" in
  report|once) pass ;;
  watch)
    log "watchdog started: stall = under $(human "$STALL_BYTES") and fewer than $MIN_SOCKETS connections over ${STALL_WINDOW}s; grace ${GRACE}s; cooldown ${COOLDOWN}s; cap $CAP per $(( CAP_WINDOW / 3600 ))h"
    log "scope: $(scope_description)"
    [[ "$DRY_RUN" == true ]] && log "dry run: nothing will actually be restarted"
    trap 'log "watchdog stopped"; exit 0' SIGTERM SIGINT
    while true; do
      pass
      # Backgrounded on purpose: bash will not run a trap until the current
      # foreground command finishes, so a plain sleep would make 'docker stop'
      # sit out the rest of the interval and then be killed at the timeout.
      sleep "$INTERVAL" &
      wait $! 2>/dev/null || true
    done
    ;;
esac
