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
| `--start` | Starts one EarnApp node per proxy, or a single node on your direct connection |
| `--delete` | Stops and removes all containers, then cleans up stale ones |
| `--deleteBackup` | Removes `earnapp.txt`. Do this only if you want to abandon your node UUIDs |

`--delete` deliberately keeps `earnapp.txt`, so a stop/start cycle reuses the same
node UUIDs and your dashboard links stay valid.

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
| `EARNAPP_IMAGE` | `madereddy/earnapp:latest` | Supports amd64 and arm64. Upstream uses `fazalfarhan01/earnapp:lite` |
| `USE_PROXIES` | `false` | Requires `proxies.txt` |
| `TUN2PROXY_IMAGE` | `ghcr.io/tun2proxy/tun2proxy:v0.8.3` | Pinned deliberately |
| `TUN2PROXY_DNS_MODE` | blank | `virtual`, `over-tcp` or `direct` |
| `USE_DNS_OVER_HTTPS` | `false` | Selects `over-tcp` when the mode above is blank |
| `USE_SOCKS5_DNS` | `false` | **Deprecated.** Use `TUN2PROXY_DNS_MODE='direct'` |
| `ENABLE_LOGS` | `false` | Debugging only. Costs performance |

## Helper scripts

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

## Notes

Run one node per IP. Residential and home ISP IPs are what EarnApp pays for;
datacenter and VPS IPs are generally not accepted.

## Disclaimer

Provided as is, without warranty of any kind. You are responsible for complying
with EarnApp's terms of service and with the terms of any proxy provider you use.

Licensed under the terms in [LICENSE](LICENSE).
