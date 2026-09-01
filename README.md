# EAincome

An EarnApp-focused variant of [Internet Income](https://github.com/engageub/InternetIncome) by engageub.

It runs EarnApp nodes in Docker, either on your direct connection or one node per
proxy, and strips out every other app so there is less to configure and less to
go wrong.

## Quick start

```bash
# Install Docker if you don't have it
sudo bash EAincome.sh --install

# Edit properties.conf, then start
sudo bash EAincome.sh --start
```

The script prints an `https://earnapp.com/r/sdk-node-...` URL per node and writes
them all to `earnapp.txt`. Paste each URL into your EarnApp dashboard to link the
device.

| Command | What it does |
| :--- | :--- |
| `--install` | Installs Docker, plus binfmt emulation on ARM hosts |
| `--build` | Builds the EarnApp image without starting anything |
| `--start` | Starts one EarnApp node per proxy, or a single node on your direct connection |
| `--delete` | Stops and removes all containers, then cleans up stale ones |
| `--deleteBackup` | Removes `earnapp.txt`. Do this only if you want to abandon your node UUIDs |

`--delete` deliberately keeps `earnapp.txt`, so a stop/start cycle reuses the same
node UUIDs and your dashboard links stay valid.

## The EarnApp image

By default EAincome builds its own EarnApp image from the `docker/` folder rather
than pulling one from a registry. The build happens once, before the first node
starts, and every node afterwards reuses that same image, so a host running twenty
nodes runs twenty copies of one binary you built yourself.

Building beats pulling here for three reasons. You get a certificate store that is
as fresh as the day you built it, which is the difference between a node that links
and one that does not. You get whatever version EarnApp currently ships rather than
whatever version a third party last rebuilt: at the time of writing the local build
produces 1.651.510 while `madereddy/earnapp:latest` still carries 1.607.304. And
the contents stop changing underneath you, because nothing is being pulled from a
tag someone else controls.

The image is cached like any other, so `--start` on subsequent runs costs nothing.
When you want to pick up a newer EarnApp release, rebuild explicitly:

```bash
sudo bash EAincome.sh --build
```

The build also refuses to hand you a broken image. Before it installs anything it
verifies that the certificate store it just built can actually validate the real
BrightData and EarnApp TLS chains, and aborts if it cannot. The installer then
performs a genuine registration as it runs, which means the `earnapp` binary's own
TLS stack has exercised that store before the image is finished. A build that
succeeds is a build whose nodes can link.

Set `BUILD_EARNAPP_IMAGE=false` if you would rather pull `EARNAPP_IMAGE`. That path
still works, and the script compensates for the missing certificate store by
bind-mounting your host's bundle into the container, so your host needs the
`ca-certificates` package installed.

## Troubleshooting: nodes that will not link

If registration fails with

```
Failed registration: check internet connection and try again
```

your internet is almost certainly fine. The `earnapp` binary is a self-contained
Node application that bundles its own TLS stack, and it does not consult the
operating system certificate store unless `NODE_EXTRA_CA_CERTS` points at a bundle.
Certificate verification fails, and the binary reports that as a network problem.

Installing `ca-certificates` on its own does not fix it. That was tested directly:
an image with the package installed but the variable unset still failed to register,
and the same image registered within seconds once the variable was set. The variable
is the operative half.

Nodes started by EAincome are already covered, and covered in a way that does not
depend on the variable merely being set. The build verifies the store against the
live BrightData and EarnApp chains and fails rather than shipping an image that
cannot register. At startup the container checks the store again, because a bind
mount or an intercepting proxy can break it after the image was built; if the
variable is unset or points at nothing, it finds a usable bundle itself and says so
in the log. The prebuilt-image path sets the variable on the `docker run` command
line alongside a bind-mounted bundle from your host.

So if a node will not link, `docker logs <container>` tells you which of these
happened rather than leaving you to guess.

For a **native install** managed by systemd, run the helper:

```bash
sudo bash fixEarnAppCerts.sh
```

It refreshes your certificate store, finds the bundle wherever your distribution
keeps it, and adds the variable to `earnapp.service` through a drop-in at
`/etc/systemd/system/earnapp.service.d/override.conf`. A drop-in is used rather than
an edit to the unit file so that updating or reinstalling EarnApp cannot quietly
discard the fix. Afterwards, `sudo earnapp register` and claim the node.

## Using proxies

Set `USE_PROXIES=true` in `properties.conf` and add one proxy per line to
`proxies.txt`:

```
socks5://user:password@1.2.3.4:1080
http://proxy.example.com:8080
```

Every proxy is routed through [tun2proxy](https://github.com/tun2proxy/tun2proxy),
which supports `http`, `https`, `socks4` and `socks5`. `socks5h://` and
`socks4a://` are normalised automatically. Shadowsocks (`ss://`) is not supported
and is rejected with an explicit error rather than failing silently at runtime.
Proxy syntax is validated up front, so a typo stops the run before any container
is created.

Each proxy gets its own tun2proxy container, and the matching EarnApp container
joins that container's network namespace. EarnApp allows one device per IP, so use
one proxy per node.

### DNS

`TUN2PROXY_DNS_MODE` controls how names are resolved. Leave it blank and it is
derived from `USE_DNS_OVER_HTTPS` for backwards compatibility.

- **`virtual`** (default) answers lookups locally with synthetic IPs and passes the
  hostname to the proxy, so resolution happens at the exit node. No DNS query ever
  leaves the container.
- **`over-tcp`** sends DNS as TCP through the proxy. Slightly slower per lookup but
  returns real addresses.
- **`direct`** passes DNS through as UDP, which requires a proxy that supports UDP.

`virtual` and `over-tcp` both keep DNS geo-consistent with the exit IP. Earlier
versions of this script let DNS leave through the host's connection while traffic
exited at the proxy, which meant CDNs were resolved near your host rather than
near the node.

## Configuration reference

| Key | Default | Notes |
| :--- | :--- | :--- |
| `DEVICE_NAME` | `ubuntu` | Identification only |
| `EARNAPP` | `true` | Set false to start nothing |
| `BUILD_EARNAPP_IMAGE` | `true` | Build the image locally from `docker/` instead of pulling |
| `EARNAPP_LOCAL_TAG` | `eaincome/earnapp:local` | Tag given to the locally built image |
| `EARNAPP_IMAGE` | `madereddy/earnapp:latest` | Used only when `BUILD_EARNAPP_IMAGE=false`. Supports amd64 and arm64. Upstream uses `fazalfarhan01/earnapp:lite` |
| `USE_PROXIES` | `false` | Requires `proxies.txt` |
| `TUN2PROXY_IMAGE` | `ghcr.io/tun2proxy/tun2proxy:v0.8.3` | Pinned deliberately |
| `TUN2PROXY_DNS_MODE` | blank | `virtual`, `over-tcp` or `direct` |
| `USE_DNS_OVER_HTTPS` | `false` | Selects `over-tcp` when the mode above is blank |
| `USE_SOCKS5_DNS` | `false` | **Deprecated.** Use `TUN2PROXY_DNS_MODE='direct'` |
| `ENABLE_LOGS` | `false` | Debugging only. Costs performance |
| `LOG_MAX_SIZE` | `10m` | Log size per container before rotation, used only when `ENABLE_LOGS=true` |
| `LOG_MAX_FILES` | `3` | Rotated files kept per container. Worst case on disk is size x files x containers |
| `TUN2PROXY_LOG_LEVEL` | `info` | tun2proxy verbosity. Upstream uses `trace`, which logs every relayed connection on every node |

Upstream sets `max-size=100k` and leaves `max-file` at 1, which holds only two
or three minutes of a busy node's output -- by the time you go looking, the thing
you wanted to see has been truncated away. The defaults above hold roughly a day
per container. The log driver is fixed when a container is created, so changing
any of these needs `--delete` followed by `--start`.

## Helper scripts

`fixEarnAppCerts.sh` repairs a native, non-Docker EarnApp install that will not
link. See the troubleshooting section above.

`restart.sh` restarts every container listed in `containernames.txt`.

`nodeWatchdog.sh` finds nodes that have stopped doing any work and restarts them.
It needs no credentials, no configuration and asks you nothing -- everything it
uses comes from Docker and from `/proc`:

```bash
bash nodeWatchdog.sh                # report only, changes nothing (the default)
bash nodeWatchdog.sh --once         # act once, then exit
bash nodeWatchdog.sh --once -n      # say what it would do, do nothing
bash nodeWatchdog.sh --watch        # sample and act every INTERVAL seconds
bash nodeWatchdog.sh --cron         # print a crontab line to paste
```

Because the `earnapp` binary is silent once running, the watchdog judges a node
by what it does on the network rather than by what it says. It samples two things
per node from inside the container's network namespace: total bytes through every
interface except `lo`, and the number of established TCP connections to port 443.
A healthy node moves tens of megabytes an hour in each direction and holds
several connections at once; an idle one sits at a few bytes a second of
keepalive. A node is only called stalled when **both** signals agree, because
either one alone has a benign explanation -- a quiet period, or a momentary
reconnect.

It also fixes what happens after a host reboot. In proxy mode each node container
shares its `tun2proxy` container's network namespace, and at boot Docker starts
containers in arbitrary order, so a node that Docker tries to start before its
tunnel is up fails with `cannot join network namespace of a non running
container`. That is a *start* failure rather than a run failure, so `--restart
always` never rescues it and the node stays dead until something starts it by
hand. The watchdog starts the parent first and the node second, which is exactly
the ordering Docker's restart policy cannot provide.

Every threshold is an environment variable, so nothing in the script needs
editing:

| Variable | Default | Meaning |
| --- | --- | --- |
| `GRACE` | `900` | Ignore a node for this many seconds after it starts |
| `STALL_WINDOW` | `1800` | How far back to look when measuring traffic |
| `STALL_BYTES` | `1048576` | Less than this over the window counts as no traffic |
| `MIN_SOCKETS` | `2` | Fewer established `:443` connections than this counts as disconnected |
| `COOLDOWN` | `1800` | Minimum seconds between restarts of the same node |
| `CAP` / `CAP_WINDOW` | `3` / `21600` | Give up on a node after this many restarts in this window |
| `INTERVAL` | `60` | Seconds between samples in `--watch` |

Two honest caveats. The thresholds are derived from measurements of healthy nodes
rather than from a node caught in the act of not earning, which is why the
default mode changes nothing and why every run appends its samples to
`watchdog.state`: once you see a node go red in the dashboard you can look back
at what its numbers were doing and tighten the thresholds to match. And the
`CAP` exists because a restart is not a cure for everything -- a node that needs
restarting three times in six hours has a problem a restart will not fix, and the
watchdog says so in `watchdog.log` and then leaves it alone.

Run it as root or as a user in the `docker` group. Nodes are found by the
`EARNAPP_UUID` environment variable rather than by container name, so a `tun*`
container can never be picked as a candidate -- restarting one would tear the
network namespace out from under the node sharing it.

`earnappStatus.sh` is the optional counterpart: it asks the EarnApp dashboard
what it thinks of your nodes and prints one row per node, mapping each node ID
back to the container running it. It is the only way to see the dashboard's own
verdict from the command line, but unlike the watchdog it needs a session cookie,
so it is a diagnostic tool rather than something to automate.

To use it, sign in at
<https://earnapp.com/dashboard>, open developer tools, find the
`oauth-refresh-token` cookie for `earnapp.com`, and save it:

```bash
umask 077; printf '%s' 'PASTE_THE_COOKIE_VALUE' > ~/.earnapp_token
bash earnappStatus.sh
```

That cookie is equivalent to being signed in to your account. It is gitignored,
the script only ever reads it from a file, and it is passed to curl through a
private config file so it never appears in `ps` output. Never paste it into a
chat or a terminal argument.

The script only reads; it restarts nothing. It exits 0 when every node is
earning and 1 when at least one is not, so it also works as a cron check. Use
`--shape` if the output ever stops making sense -- the dashboard API is
undocumented and has changed before, and `--shape` prints the structure with all
values redacted, which is safe to share.

`updateProxies.sh` is a leftover that hot-swapped the proxy address inside
`xjasonlyu/tun2socks` containers. tun2proxy takes its proxy as a command-line
argument, so it cannot be swapped in place. The script now exits with an
explanation instead of silently doing nothing. To change proxies, edit
`proxies.txt` and run `--delete` followed by `--start`; your node UUIDs survive.

## Differences from upstream Internet Income

Only EarnApp is supported, so there is no Mysterium, browser-based app, or
extension-based app handling, and no `firefoxprofiledata.zip` /
`chromeprofiledata.zip` to download.

Upstream picks between three proxy backends (`hev-socks5-tunnel`, `tun2proxy` and
`xjasonlyu/tun2socks`) depending on your DNS settings and proxy protocol.
EAincome uses tun2proxy for everything, which is why `USE_SOCKS5_DNS` is
deprecated and `ss://` is unsupported.

`EARNAPP_IMAGE` and `TUN2PROXY_IMAGE` are configurable here but hardcoded upstream.

Upstream pulls a prebuilt EarnApp image. EAincome builds its own by default, which
is what makes `NODE_EXTRA_CA_CERTS` possible to guarantee rather than hope for.
The image also seeds a bind-mounted `/etc/earnapp` from a build-time template,
supervises the binary with exponential backoff, and reports an unregistered node as
unhealthy to `docker ps` instead of sitting there looking fine.

## Notes

Run one node per IP. Residential and home ISP IPs are what EarnApp pays for;
datacenter and VPS IPs are generally not accepted.

## Disclaimer

Provided as is, without warranty of any kind. You are responsible for complying
with EarnApp's terms of service and with the terms of any proxy provider you use.

Licensed under the terms in [LICENSE](LICENSE).
