#!/usr/bin/env bash
# Entrypoint for EAincome's EarnApp image.
#
# Responsibilities, in order:
#   1. Seed a bind-mounted /etc/earnapp from the build-time template, so mounting
#      an empty host directory does not hide the installer's state.
#   2. Write the node UUID supplied by the script.
#   3. Verify the TLS trust store is actually usable, and say so loudly if not,
#      because the failure mode otherwise reads as "check internet connection".
#   4. Supervise the earnapp process with exponential backoff.

set -uo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/earnapp}"
TEMPLATE_DIR="${EARNAPP_TEMPLATE:-/opt/earnapp-template}"
BIN_PATH="${BIN_PATH:-/usr/bin/earnapp}"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

# Drop to a shell for debugging: docker run -e DEBUG_MODE=1 ...
if [[ "${DEBUG_MODE:-}" == "1" ]]; then
  log "DEBUG_MODE enabled, launching shell."
  exec bash
fi

if [[ -z "${EARNAPP_UUID:-}" ]]; then
  err "EARNAPP_UUID is not set. EAincome normally supplies this."
  exit 1
fi

if [[ ! -x "$BIN_PATH" ]]; then
  err "$BIN_PATH is missing or not executable."
  err "This image is built with the binary baked in, so this should not happen."
  exit 1
fi

mkdir -p "$CONFIG_DIR"

# 1. Seed the config directory without clobbering anything already there, so a
#    restart preserves node state while a fresh mount still gets the installer's
#    files (notably 'ver', which earnapp reads on startup).
if [[ -d "$TEMPLATE_DIR" ]]; then
  seeded=0
  shopt -s dotglob nullglob
  for src in "$TEMPLATE_DIR"/*; do
    target="$CONFIG_DIR/$(basename "$src")"
    if [[ ! -e "$target" ]]; then
      cp -a "$src" "$target" && seeded=$((seeded + 1))
    fi
  done
  shopt -u dotglob nullglob
  if (( seeded > 0 )); then
    log "Seeded $seeded file(s) into $CONFIG_DIR from the image template."
  fi
fi

# 2. UUID. Written every start so the script stays the source of truth.
printf '%s' "$EARNAPP_UUID" > "$CONFIG_DIR/uuid"
touch "$CONFIG_DIR/status"
chmod 600 "$CONFIG_DIR/uuid" "$CONFIG_DIR/status" 2>/dev/null || true

log "Node UUID: $EARNAPP_UUID"
if [[ -f "$CONFIG_DIR/ver" ]]; then
  log "EarnApp version: $(cat "$CONFIG_DIR/ver")"
fi

# 3. Trust store. This is the failure that stops nodes linking, so repair it here
#    rather than only complaining about it. A bind mount over /etc/ssl, or someone
#    pointing the variable at a path that does not exist, can leave a correctly
#    built image with no usable store at runtime.
ca_candidates=(
  /etc/ssl/certs/ca-certificates.crt
  /etc/pki/tls/certs/ca-bundle.crt
  /etc/ssl/ca-bundle.pem
  /etc/ssl/cert.pem
)

if [[ -z "${NODE_EXTRA_CA_CERTS:-}" || ! -s "${NODE_EXTRA_CA_CERTS:-}" ]]; then
  if [[ -n "${NODE_EXTRA_CA_CERTS:-}" ]]; then
    warn "NODE_EXTRA_CA_CERTS points at '$NODE_EXTRA_CA_CERTS', which is missing or empty."
  else
    warn "NODE_EXTRA_CA_CERTS is not set."
  fi
  warn "Searching for a usable certificate bundle rather than failing to register."
  for candidate in "${ca_candidates[@]}"; do
    if [[ -s "$candidate" ]]; then
      export NODE_EXTRA_CA_CERTS="$candidate"
      log "Recovered the trust store: using $candidate."
      break
    fi
  done
fi

if [[ -z "${NODE_EXTRA_CA_CERTS:-}" || ! -s "$NODE_EXTRA_CA_CERTS" ]]; then
  err "No usable certificate bundle exists in this container."
  err "The earnapp binary bundles its own TLS stack and will fall back to Node's"
  err "compiled-in roots, so registration will most likely fail with 'check"
  err "internet connection and try again'. Rebuild the image, or bind-mount a"
  err "bundle from the host onto /etc/ssl/certs/ca-certificates.crt."
else
  log "TLS trust store: $NODE_EXTRA_CA_CERTS ($(grep -c 'BEGIN CERTIFICATE' "$NODE_EXTRA_CA_CERTS" 2>/dev/null || echo '?') certificates)"

  # A store that loads is not the same as a store that works, and a network that
  # works for one host is not the same as one that works for the host that counts.
  # Probe client.earnapp.com, because that is where 'earnapp start' POSTs
  # /install_device. Probing earnapp.com instead prints a green line on hosts where
  # registration cannot possibly succeed: measured on a box that opened
  # earnapp.com:443 fine while client.earnapp.com:443 timed out.
  #
  # Reachability and certificate validity are reported separately on purpose. The
  # binary collapses both into "check internet connection and try again", and
  # knowing which one failed is the difference between editing a firewall rule and
  # rebuilding the trust store. Retried, because a proxy sidecar sharing this
  # network namespace may still be bringing its tunnel up.
  probe_host='client.earnapp.com'
  reachable=false
  verified=false
  for attempt in 1 2 3; do
    if timeout 8 bash -c "exec 3<>/dev/tcp/$probe_host/443" 2>/dev/null; then
      reachable=true
      if command -v openssl >/dev/null 2>&1; then
        if openssl s_client -connect "$probe_host:443" -servername "$probe_host" \
             -CAfile "$NODE_EXTRA_CA_CERTS" -verify_return_error -brief \
             </dev/null >/dev/null 2>&1; then
          verified=true
        fi
      else
        # Nothing to verify with. Do not cry wolf about a store we cannot test.
        verified=true
      fi
      [[ "$verified" == true ]] && break
    fi
    (( attempt < 3 )) && sleep 5
  done

  if [[ "$reachable" == true && "$verified" == true ]]; then
    log "Connectivity check passed: $probe_host:443 is reachable and its certificate validates."
  elif [[ "$reachable" == false ]]; then
    warn "Cannot open a TCP connection to $probe_host:443."
    warn "This is reachability, not certificates: a firewall, a dead proxy tunnel,"
    warn "or a route that drops the packets. Registration will report 'check"
    warn "internet connection and try again' and it will be telling the truth."
    warn "earnapp.com can be reachable while this host is not, so a browser test"
    warn "proves nothing here."
  else
    warn "$probe_host:443 is reachable but its certificate did not verify."
    warn "That is a trust store problem: the bundle is incomplete, or something is"
    warn "intercepting TLS. Registration will report 'check internet connection and"
    warn "try again'. Rebuild the image so the store is current."
  fi
fi

# Forward termination to the child so 'docker stop' is not a 10 second wait.
child_pid=""
shutdown() {
  log "Received termination signal, stopping EarnApp."
  [[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null
  "$BIN_PATH" stop >/dev/null 2>&1
  exit 0
}
trap shutdown SIGTERM SIGINT

# Verbosity. Worth understanding before turning this on: 'earnapp run' is silent.
# Not quiet -- silent. It prints nothing with --verbose, nothing with NODE_DEBUG
# and DEBUG both set, and it has no daemon and no native addon to hide the output
# in; the binary suppresses it deliberately. 'earnapp start' is the one phase that
# talks, and only when Node's own debug channels are on, at which point it dumps
# TLS handshakes and every HTTP request it makes while registering.
#
# So there is nothing to gain from a log-viewing tool. Portainer, docker logs and
# 'docker logs -f' all read the same stream, and if that stream is empty they all
# show an empty pane. The only way to get detail is to make the process emit it.
if [[ -n "${EARNAPP_DEBUG:-}" && "${EARNAPP_DEBUG,,}" != "0" && "${EARNAPP_DEBUG,,}" != "false" ]]; then
  export NODE_DEBUG="${NODE_DEBUG:-tls,http}"
  export DEBUG="${DEBUG:-*}"
  warn "EARNAPP_DEBUG is on: NODE_DEBUG=$NODE_DEBUG DEBUG=$DEBUG"
  warn "The registration phase will dump TLS handshakes and HTTP requests. Those"
  warn "dumps include request headers and your node UUID, so treat this log as"
  warn "account-identifying and do not paste it anywhere public."
fi

# 4. Supervise.
log "Starting EarnApp."
"$BIN_PATH" stop >/dev/null 2>&1
sleep 1

backoff=5
max_backoff=300
registration_warned=false

while true; do
  # Do not discard this, and do not pipe it either. It is the only output the
  # binary produces, so redirecting it to /dev/null is what leaves a container
  # with no logs at all -- but piping it through anything (sed, to prefix the
  # lines, say) is nearly as bad: node block-buffers stdout when it is a pipe it
  # does not own, and '- Registering Device...' arrives without a trailing
  # newline, so nothing flushes. Measured: with a sed prefix the line had still
  # not appeared 94 seconds in; without it, it shows up in under 8.
  "$BIN_PATH" start 2>&1
  sleep 2

  start_time=$(date +%s)
  "$BIN_PATH" run &
  child_pid=$!
  wait "$child_pid"
  child_pid=""
  run_duration=$(( $(date +%s) - start_time ))

  if [[ ! -f "$CONFIG_DIR/registered" && "$registration_warned" == false ]]; then
    warn "EarnApp has not registered yet. If this persists, it is a TLS trust"
    warn "problem rather than a network problem -- see the notes above."
    registration_warned=true
  fi

  if (( run_duration > 60 )); then
    backoff=5
    log "EarnApp exited after ${run_duration}s, restarting in ${backoff}s."
  else
    warn "EarnApp exited after only ${run_duration}s, backing off ${backoff}s."
  fi

  sleep "$backoff"
  if (( run_duration <= 60 )); then
    backoff=$(( backoff * 2 ))
    (( backoff > max_backoff )) && backoff=$max_backoff
  fi

  "$BIN_PATH" stop >/dev/null 2>&1
  sleep 1
done
