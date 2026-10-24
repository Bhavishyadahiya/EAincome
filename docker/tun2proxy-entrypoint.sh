#!/bin/sh
set -eu

rate="${MAX_BANDWIDTH_MBPS:-0}"
direction="${BANDWIDTH_LIMIT_DIRECTION:-both}"
delay="${BANDWIDTH_LIMIT_DELAY_SECONDS:-300}"
device="tun0"

case "$rate" in
  ''|*[!0-9]*) echo "MAX_BANDWIDTH_MBPS must be a non-negative integer" >&2; exit 2 ;;
esac
case "$direction" in
  upload|download|both) ;;
  *) echo "BANDWIDTH_LIMIT_DIRECTION must be upload, download, or both" >&2; exit 2 ;;
esac
case "$delay" in
  ''|*[!0-9]*) echo "BANDWIDTH_LIMIT_DELAY_SECONDS must be a non-negative integer" >&2; exit 2 ;;
esac

apply_tunnel_limits() {
  if [ "$direction" = upload ] || [ "$direction" = both ]; then
    if ! tc qdisc show dev "$device" | grep -q 'qdisc tbf'; then
      tc qdisc replace dev "$device" root tbf rate "${rate}mbit" burst 64k latency 100ms \
        || { echo "Failed to apply the tunnel upload limit" >&2; return 1; }
      echo "Limited tunnel upload to ${rate} Mbps"
    fi
  fi

  if [ "$direction" = download ] || [ "$direction" = both ]; then
    if ! tc qdisc show dev "$device" | grep -q 'qdisc ingress'; then
      tc qdisc replace dev "$device" handle ffff: ingress \
        || { echo "Failed to add the tunnel download limiter" >&2; return 1; }
    fi
    if ! tc filter show dev "$device" parent ffff: | grep -q 'matchall'; then
      tc filter replace dev "$device" parent ffff: protocol all matchall action \
        police rate "${rate}mbit" burst 64k drop \
        || { echo "Failed to apply the tunnel download limit" >&2; return 1; }
      echo "Limited tunnel download to ${rate} Mbps"
    fi
  fi
}

limit_tunnel() {
  if [ "$delay" -gt 0 ]; then
    echo "Waiting ${delay}s before applying the tunnel bandwidth limit"
    sleep "$delay"
  fi

  while ! ip link show dev "$device" >/dev/null 2>&1; do
    sleep 1
  done

  while :; do
    if ! apply_tunnel_limits; then
      echo "Stopping tun2proxy because its bandwidth limit could not be enforced" >&2
      kill -TERM "$PPID" 2>/dev/null || true
      exit 1
    fi
    sleep 5
  done
}

if [ "$rate" -gt 0 ]; then
  limit_tunnel &
fi

exec /usr/bin/tun2proxy-bin --setup "$@"
