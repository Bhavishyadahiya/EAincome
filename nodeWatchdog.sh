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
STATE_FILE=${STATE_FILE:-"$(dirname "${BASH_SOURCE[0]}")/watchdog.state"}
LOG_FILE=${LOG_FILE:-"$(dirname "${BASH_SOURCE[0]}")/watchdog.log"}
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

  */5 * * * * cd $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) && /bin/bash nodeWatchdog.sh --once >> watchdog.cron.log 2>&1

Sampling every 5 minutes is fine: STALL_WINDOW is ${STALL_WINDOW}s, so a stall
still needs several consistent samples before anything is restarted.
EOF
  exit 0
fi

command -v docker >/dev/null 2>&1 || { printf 'docker is required.\n' >&2; exit 2; }
docker info >/dev/null 2>&1 || { printf 'Cannot talk to Docker. Run this as root or a docker-group user.\n' >&2; exit 2; }

now() { date +%s; }
log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

# Every EarnApp node container, found by the env var EAincome sets rather than by
# name, so it keeps working when UNIQUE_ID changes and it never picks up a tun
# container by accident. Restarting a tun container would tear the network
# namespace out from under its child, so it must never be a candidate.
list_nodes() {
  local name uuid
  while read -r name; do
    [[ -n "$name" ]] || continue
    uuid=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
           | sed -n 's/^EARNAPP_UUID=//p' | head -1)
    [[ -n "$uuid" ]] && printf '%s\t%s\n' "$name" "$uuid"
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}

# Traffic and socket counts are read straight out of the container's network
# namespace via /proc, which works without a shell in the image and without
# docker exec. In proxy mode the namespace is the tun2proxy parent's and holds
# both the tunnel and the upstream leg, so the byte count double-counts -- which
# does not matter, because the only question asked of it is "roughly zero, or
# not".
sample() { # sample <pid> -> "<bytes> <established443>"
  local pid=$1 bytes=0 est=0
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || { printf '0 0'; return; }
  bytes=$(awk 'NR>2 { gsub(/:/,"",$1); if ($1 != "lo") t += $2 + $10 } END { print t+0 }' \
          "/proc/$pid/net/dev" 2>/dev/null) || bytes=0
  est=$(awk 'NR>1 && $4=="01" && $3 ~ /:01BB$/ { n++ } END { print n+0 }' \
        "/proc/$pid/net/tcp" "/proc/$pid/net/tcp6" 2>/dev/null) || est=0
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

restarts_since() { # <container> <epoch> -> count of recorded restarts since then
  [[ -f "$LOG_FILE" ]] || { printf '0'; return; }
  awk -v c="$1" -v since="$2" '
    $0 ~ ("RESTART " c "( |$)") {
      ts = $1 " " $2
      gsub(/-/, " ", ts); gsub(/:/, " ", ts)
      # mktime wants "YYYY MM DD HH MM SS"
      if (mktime(ts) >= since) n++
    }
    END { print n+0 }' "$LOG_FILE" 2>/dev/null || printf '0'
}

last_restart() { # <container> -> epoch of most recent restart, 0 if none
  [[ -f "$LOG_FILE" ]] || { printf '0'; return; }
  awk -v c="$1" '
    $0 ~ ("RESTART " c "( |$)") {
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
  awk -v c="$1" -v now="$2" -v win="$STALL_WINDOW" -F'\t' '
    $1 == c && (now - $2) <= win {
      n++
      if (oldest == 0 || $2 < oldest) { oldest = $2; bytes = $3 }
    }
    END { print bytes+0, (oldest ? now - oldest : 0), n+0 }' "$STATE_FILE" 2>/dev/null \
    || printf '0 0 0'
}

forget() { # drop a container's samples so a restart starts the window fresh
  [[ -f "$STATE_FILE" ]] || return 0
  awk -v c="$1" -F'\t' '$1 != c' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

human() { # bytes -> short readable form
  awk -v b="$1" 'BEGIN {
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

pass() {
  local t nodes name uuid status pid s bytes est up base_bytes base_age base_n delta rate
  local total=0 stalled=0 down=0 young=0
  t=$(now)
  nodes=$(list_nodes)
  if [[ -z "$nodes" ]]; then
    printf 'No EarnApp node containers found. Is EAincome.sh --start done?\n' >&2
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
    trap 'log "watchdog stopped"; exit 0' SIGTERM SIGINT
    while true; do
      pass
      sleep "$INTERVAL"
    done
    ;;
esac
