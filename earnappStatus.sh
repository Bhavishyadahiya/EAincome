#!/usr/bin/env bash
# earnappStatus.sh -- read-only view of what the EarnApp dashboard thinks of your
# nodes, from the command line.
#
# Why this exists: the earnapp binary itself is silent once it is running. It
# writes nothing to stdout even with --verbose, NODE_DEBUG and DEBUG all set, and
# its own SDK log (/etc/earnapp/brd_sdk3.log) is encrypted. So a container that
# has stopped earning looks identical from the inside to one that is earning.
# The dashboard knows the difference, and the dashboard has an API.
#
# This script only reads. It never restarts anything -- see nodeWatchdog.sh for
# that. Run it to answer "which of my nodes are red right now, and which
# container is each one?"
#
# Authentication
#   The dashboard authenticates with the oauth-refresh-token cookie. To get it:
#     1. Sign in at https://earnapp.com/dashboard in a browser.
#     2. Open developer tools -> Application (or Storage) -> Cookies
#        -> https://earnapp.com
#     3. Copy the value of oauth-refresh-token.
#   Then put it in a file, readable only by you:
#     umask 077; printf '%s' 'PASTE_HERE' > ~/.earnapp_token
#   That token is equivalent to being signed in to your account, so do not
#   commit it, paste it into a chat, or pass it on a command line where it would
#   show up in ps output. This script reads it from a file for exactly that
#   reason, and hands it to curl through a 600-mode config file rather than argv.

set -uo pipefail

API='https://earnapp.com/dashboard/api'
APPID='earnapp'
VERSION='1.651.510'

TOKEN_FILE=''
MODE='table'
TIMEOUT=25

usage() {
  cat <<'EOF'
Usage: bash earnappStatus.sh [options]

Options:
  -t FILE     Token file. Default: $EARNAPP_TOKEN_FILE, then ./.earnapp_token,
              then ~/.earnapp_token
  --table     One row per node: container, node id, status, bandwidth, earnings.
              This is the default.
  --shape     Print the structure of every endpoint with values redacted. Use
              this when the API changes and the table stops making sense; the
              output is safe to share.
  --json      Print the raw device and status JSON, with identifying fields
              redacted.
  --raw       Print the raw JSON with nothing redacted. Contains your node IDs
              and proxy exit IPs. Do not paste the output anywhere.
  -h          This help.

Exit status is 0 if every node is earning, 1 if at least one is not, and 2 on
an error such as an expired token.
EOF
}

while (( $# )); do
  case "$1" in
    -t) TOKEN_FILE="${2:-}"; shift 2 ;;
    --table) MODE='table'; shift ;;
    --shape) MODE='shape'; shift ;;
    --json)  MODE='json'; shift ;;
    --raw)   MODE='raw'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for dep in curl python3; do
  command -v "$dep" >/dev/null 2>&1 || { printf '%s is required but not installed.\n' "$dep" >&2; exit 2; }
done

# Resolve the token file. Never accept the token itself as an argument.
if [[ -z "$TOKEN_FILE" ]]; then
  for candidate in "${EARNAPP_TOKEN_FILE:-}" './.earnapp_token' "$HOME/.earnapp_token"; do
    [[ -n "$candidate" && -s "$candidate" ]] && { TOKEN_FILE="$candidate"; break; }
  done
fi

if [[ -z "$TOKEN_FILE" || ! -s "$TOKEN_FILE" ]]; then
  cat >&2 <<'EOF'
No token file found.

Sign in at https://earnapp.com/dashboard, copy the oauth-refresh-token cookie
from developer tools -> Application -> Cookies, then:

  umask 077; printf '%s' 'PASTE_THE_COOKIE_VALUE' > ~/.earnapp_token

See the comments at the top of this script for the full walkthrough.
EOF
  exit 2
fi

perms=$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '')
if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
  printf 'Warning: %s is mode %s. That token is your dashboard session; chmod 600 it.\n' \
    "$TOKEN_FILE" "$perms" >&2
fi

TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
[[ -n "$TOKEN" ]] || { printf '%s is empty.\n' "$TOKEN_FILE" >&2; exit 2; }

# Hand the cookie to curl through a private config file so it never appears in
# the process list, and clean it up on any exit path.
WORKDIR=$(mktemp -d) || exit 2
chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT
CURLRC="$WORKDIR/curlrc"
umask 077
printf 'header = "Cookie: auth=1; auth-method=google; oauth-refresh-token=%s"\n' "$TOKEN" > "$CURLRC"
printf 'header = "Accept: application/json"\n' >> "$CURLRC"
printf 'silent\nshow-error\nlocation\n' >> "$CURLRC"

fetch() { # fetch <endpoint-path> <outfile> -> prints HTTP status
  curl --config "$CURLRC" -m "$TIMEOUT" \
    -o "$2" -w '%{http_code}' \
    "$API/$1?appid=$APPID&version=$VERSION" 2>/dev/null
}

declare -A STATUS_CODE=()
for ep in devices device_statuses money user_data; do
  STATUS_CODE[$ep]=$(fetch "$ep" "$WORKDIR/$ep.json")
done

if [[ "${STATUS_CODE[devices]}" == "403" || "${STATUS_CODE[devices]}" == "401" ]]; then
  printf 'The dashboard rejected the token (HTTP %s).\n' "${STATUS_CODE[devices]}" >&2
  printf 'It has most likely expired -- copy a fresh oauth-refresh-token cookie into %s.\n' \
    "$TOKEN_FILE" >&2
  exit 2
fi

if [[ "${STATUS_CODE[devices]}" != "200" ]]; then
  printf 'Unexpected HTTP %s from %s/devices.\n' "${STATUS_CODE[devices]}" "$API" >&2
  head -c 300 "$WORKDIR/devices.json" >&2; echo >&2
  exit 2
fi

# Container inventory: node uuid -> container name(s). Built from the env var
# EAincome sets, not from names, so it survives the UNIQUE_ID changing per run
# and reveals the case where two batches share one node identity.
INVENTORY="$WORKDIR/containers.tsv"
: > "$INVENTORY"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r name; do
    [[ -n "$name" ]] || continue
    uuid=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
           | sed -n 's/^EARNAPP_UUID=//p' | head -1)
    [[ -n "$uuid" ]] || continue
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$uuid" "$name" "$state" >> "$INVENTORY"
  done
fi

export EA_MODE="$MODE" EA_DIR="$WORKDIR" EA_INVENTORY="$INVENTORY"
python3 - <<'PYEOF'
import json, os, re, sys

mode = os.environ.get("EA_MODE", "table")
d = os.environ["EA_DIR"]

def load(name):
    p = os.path.join(d, name + ".json")
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return None

data = {name: load(name) for name in ("devices", "device_statuses", "money", "user_data")}

SECRETISH = re.compile(
    r"(uuid|^id$|ips?$|addr|email|token|secret|key|referral|paypal|wise|payout)", re.I)
# device_statuses is keyed *by* node id, so keys need masking as well as values.
IDLIKE = re.compile(r"(sdk-node-|^[0-9a-f]{16,}$)", re.I)
_alias = {}

def mask_key(k):
    """Replace a node id used as a key with a stable placeholder. Numbered, so
    that masking twenty nodes does not collapse them into one entry."""
    k = str(k)
    if not IDLIKE.search(k):
        return k
    if k not in _alias:
        _alias[k] = "<node-%d>" % (len(_alias) + 1)
    return _alias[k]

def shape(obj, depth=0):
    """Structure only: keys and value types, never values. Safe to share."""
    pad = "  " * depth
    if isinstance(obj, dict):
        out = []
        for k, v in obj.items():
            kk = mask_key(k)
            if isinstance(v, (dict, list)):
                out.append("%s%s:" % (pad, kk))
                out.append(shape(v, depth + 1))
            else:
                out.append("%s%s: <%s>" % (pad, kk, type(v).__name__))
        return "\n".join(out)
    if isinstance(obj, list):
        if not obj:
            return pad + "<empty list>"
        return "%s[%d items, first:]\n%s" % (pad, len(obj), shape(obj[0], depth + 1))
    return "%s<%s>" % (pad, type(obj).__name__)

def redact(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if SECRETISH.search(str(k)):
                # Covers "ips": ["1.2.3.4"] as well as plain scalars; a list of
                # proxy exit addresses is exactly what you do not want to share.
                out[mask_key(k)] = "<redacted>" if not isinstance(v, dict) else redact(v)
            else:
                out[mask_key(k)] = redact(v)
        return out
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj

if mode == "shape":
    for name, obj in data.items():
        print("=== %s ===" % name)
        print("(endpoint returned nothing usable)" if obj is None else shape(obj))
        print()
    sys.exit(0)

if mode in ("json", "raw"):
    payload = {k: v for k, v in data.items() if v is not None}
    print(json.dumps(payload if mode == "raw" else redact(payload),
                     indent=2, sort_keys=True))
    sys.exit(0)

# --- table -------------------------------------------------------------------
# Field names are discovered rather than assumed: this API is undocumented and
# has changed before. If the table looks wrong, run --shape and adjust here.

def as_list(obj):
    if obj is None:
        return []
    if isinstance(obj, list):
        return [x for x in obj if isinstance(x, dict)]
    if isinstance(obj, dict):
        for key in ("devices", "data", "items", "result"):
            if isinstance(obj.get(key), list):
                return [x for x in obj[key] if isinstance(x, dict)]
        # uuid -> record mapping
        if all(isinstance(v, dict) for v in obj.values()) and obj:
            out = []
            for k, v in obj.items():
                rec = dict(v)
                rec.setdefault("uuid", k)
                out.append(rec)
            return out
    return []

def pick(rec, *names):
    for n in names:
        for k in rec:
            if k.lower() == n:
                return rec[k]
    return None

devices = as_list(data["devices"])
statuses = {}
for rec in as_list(data["device_statuses"]):
    uid = pick(rec, "uuid", "id", "device_id")
    if uid:
        statuses[str(uid)] = rec

inventory = {}
try:
    with open(os.environ["EA_INVENTORY"], "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                inventory.setdefault(parts[0], []).append((parts[1], parts[2]))
except Exception:
    pass

TRUTHY_BAD = ("banned", "blocked", "stopped", "suspended", "disabled", "offline")

def verdict(rec):
    """Return (label, reason). Conservative: only says NOT EARNING when the API
    actually says so, because a wrong answer here restarts a healthy node."""
    reason = pick(rec, "reason", "msg", "message", "error", "details", "why",
                  "stopped_reason", "offline_reason")
    reason = "" if reason in (None, "", [], {}) else str(reason)
    for key in ("earning", "is_earning", "active", "online", "connected", "ok"):
        val = pick(rec, key)
        if isinstance(val, bool):
            if val:
                return ("earning", reason)
            return ("NOT EARNING", reason or key + "=false")
    raw = pick(rec, "status", "state", "health")
    if isinstance(raw, str):
        low = raw.lower()
        if any(b in low for b in TRUTHY_BAD):
            return ("NOT EARNING", reason or raw)
        return (raw, reason)
    return ("unknown", reason)

rows = []
bad = 0
seen = set()

def short(uid):
    """Enough of the node id to match it against the dashboard, without pasting
    the whole thing around -- these ids are effectively account secrets."""
    tail = uid.split("sdk-node-")[-1]
    return ("..." + tail[-12:]) if len(tail) > 12 else tail

for dev in devices:
    uid = str(pick(dev, "uuid", "id", "device_id") or "")
    if not uid:
        continue
    seen.add(uid)
    merged = dict(dev)
    merged.update(statuses.get(uid, {}))
    label, reason = verdict(merged)
    if label == "NOT EARNING":
        bad += 1
    containers = inventory.get(uid, [])
    where = ", ".join("%s(%s)" % (n, s) for n, s in containers) if containers else "-"
    if len(containers) > 1:
        where += "  <-- DUPLICATE IDENTITY"
    bw = pick(merged, "bw", "total_bw", "bandwidth")
    earned = pick(merged, "earned", "earned_total", "money", "balance")
    rows.append((where, short(uid), label, reason[:38], str(bw), str(earned)))

# Containers running a node the dashboard does not list at all -- usually a node
# that was never claimed, or one claimed under a different account.
for uid, containers in inventory.items():
    if uid in seen:
        continue
    for name, state in containers:
        rows.append(("%s(%s)" % (name, state), short(uid), "not on dashboard",
                     "unclaimed?", "-", "-"))

hdr = ("CONTAINER", "NODE", "VERDICT", "REASON", "BW", "EARNED")
widths = [max(len(hdr[i]), max((len(r[i]) for r in rows), default=0)) for i in range(6)]
fmt = "  ".join("%-" + str(w) + "s" for w in widths)
print(fmt % hdr)
print(fmt % tuple("-" * w for w in widths))
for r in sorted(rows, key=lambda r: (r[2] != "NOT EARNING", r[0])):
    print(fmt % r)

print()
print("%d node(s) on the dashboard, %d not earning." % (len(seen), bad))
if not statuses:
    print("Note: device_statuses returned nothing usable, so VERDICT came from")
    print("      /devices alone. Run with --shape to see what the API is sending.")
money = data.get("money")
if isinstance(money, dict):
    bits = [(k, v) for k, v in money.items()
            if isinstance(v, (int, float)) and not SECRETISH.search(k)]
    if bits:
        print("Account: " + "  ".join("%s=%s" % kv for kv in bits))

sys.exit(1 if bad else 0)
PYEOF
