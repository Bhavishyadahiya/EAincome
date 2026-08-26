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

Nodes started by EAincome are already covered. The image built by `--build` sets the
variable at build time, and the prebuilt-image path sets it on the `docker run`
command line alongside a bind-mounted bundle.

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

## Helper scripts

`fixEarnAppCerts.sh` repairs a native, non-Docker EarnApp install that will not
link. See the troubleshooting section above.

`restart.sh` restarts every container listed in `containernames.txt`.

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
