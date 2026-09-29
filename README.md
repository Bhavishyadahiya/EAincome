# EAincome

<p align="center">
  <img src="banner.jpg" alt="EAincome" width="900">
</p>

<p align="center">
  <b>EarnApp-only Docker automation with optional proxy-per-node networking.</b><br>
  Built from the structure of <a href="https://github.com/engageub/InternetIncome">Internet Income</a>, with the non-EarnApp components removed.
</p>

---

## What is EAincome?

EAincome is a Bash-based launcher that runs **EarnApp nodes in Docker**.

It supports two operating modes:

* **Direct mode:** one EarnApp container uses the host connection.
* **Proxy mode:** one EarnApp node is created for each proxy, with a dedicated `tun2proxy` sidecar.

The script handles:

* Docker installation
* EarnApp image building
* Node UUID generation
* Persistent node data
* Proxy validation
* DNS configuration
* Container creation
* Container cleanup
* Container restarting

> **Important:** EAincome does not bypass EarnApp service limits or guarantee earnings. Your IPs, proxies, and account must comply with EarnApp's current terms.

---

## Features

| Feature                         | Included |
| ------------------------------- | :------: |
| EarnApp Docker nodes            |     ✅    |
| One node per proxy              |     ✅    |
| HTTP / HTTPS / SOCKS4 / SOCKS5  |     ✅    |
| Local EarnApp image build       |     ✅    |
| Persistent node UUIDs           |     ✅    |
| `tun2proxy` networking          |     ✅    |
| Configurable DNS modes          |     ✅    |
| Docker log rotation             |     ✅    |
| Automatic container restart     |     ✅    |
| Native Linux certificate repair |     ✅    |

---

# Quick Start

## 1. Clone the repository

```bash
git clone https://github.com/Bhavishyadahiya/EAincome.git
cd EAincome
```

Check the files:

```bash
ls -la
```

You should see:

```text
EAincome.sh
properties.conf
proxies.txt
restart.sh
docker/
```

---

## 2. Install Docker

EAincome can install Docker for you:

```bash
sudo bash EAincome.sh --install
```

Verify Docker:

```bash
sudo docker version
```

Check that the Docker service is running:

```bash
sudo systemctl status docker --no-pager
```

---

## 3. Configure EAincome

Open the configuration file:

```bash
nano properties.conf
```

### Direct connection

If you want EarnApp to use the host's normal connection:

```bash
USE_PROXIES=false
```

### Proxy mode

If you want one EarnApp node per proxy:

```bash
USE_PROXIES=true
```

The current repository configuration already has proxy mode enabled.

---

# Proxy Configuration

Proxy mode requires:

```text
proxies.txt
```

Edit it:

```bash
nano proxies.txt
```

Put **one proxy per line**.

### Supported formats

```text
socks5://1.2.3.4:1080
```

```text
socks5://username:password@1.2.3.4:1080
```

```text
http://1.2.3.4:8080
```

```text
http://username:password@1.2.3.4:8080
```

```text
https://1.2.3.4:8443
```

```text
socks4://1.2.3.4:1080
```

Supported protocols:

```text
http
https
socks4
socks5
```

These are also accepted and normalized automatically:

```text
socks5h://
socks4a://
```

### Unsupported

```text
ss://
```

Shadowsocks proxies are not supported by the current `tun2proxy` setup.

---

## Example `proxies.txt`

```text
socks5://user:password@10.0.0.10:9001
socks5://user:password@10.0.0.11:9002
socks5://user:password@10.0.0.12:9003
```

With three proxies, EAincome creates a corresponding proxy tunnel and EarnApp node for each entry.

---

# Start EAincome

The recommended command is:

```bash
sudo bash EAincome.sh --start
```

On the first run, EAincome will:

1. Read `properties.conf`
2. Validate the proxy configuration
3. Build the local EarnApp image if enabled
4. Pull the required `tun2proxy` image
5. Create the proxy containers
6. Generate EarnApp node UUIDs
7. Create the EarnApp containers
8. Save the node URLs

---

# Claim Your EarnApp Nodes

Generated node URLs are saved to:

```text
earnapp.txt
```

View them with:

```bash
cat earnapp.txt
```

You will see URLs similar to:

```text
https://earnapp.com/r/sdk-node-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Open each URL in your EarnApp dashboard and claim/link the corresponding node.

---

# Build the EarnApp Image

EAincome builds its own EarnApp image by default.

To build the image without starting nodes:

```bash
sudo bash EAincome.sh --build
```

The local image is:

```text
eaincome/earnapp:local
```

Check it:

```bash
sudo docker images | grep eaincome
```

Or:

```bash
sudo docker image inspect eaincome/earnapp:local
```

After building:

```bash
sudo bash EAincome.sh --start
```

The image is cached and reused for subsequent starts.

---

# Rebuild the Image

If you want to force a fresh build:

```bash
sudo bash EAincome.sh --build
```

Then restart the nodes:

```bash
sudo bash EAincome.sh --delete
sudo bash EAincome.sh --start
```

---

# Using a Prebuilt Image

The default configuration uses a locally built image:

```bash
BUILD_EARNAPP_IMAGE=true
```

To use the configured registry image instead:

```bash
nano properties.conf
```

Set:

```bash
BUILD_EARNAPP_IMAGE=false
```

and:

```bash
EARNAPP_IMAGE='madereddy/earnapp:latest'
```

Then:

```bash
sudo bash EAincome.sh --start
```

When using a prebuilt image, EAincome searches for the host's CA certificate bundle and passes it into the container using:

```text
NODE_EXTRA_CA_CERTS
```

For the most controlled setup, the local build is the default.

---

# Configuration Reference

Edit:

```bash
nano properties.conf
```

## General

| Variable              | Default                    | Description                                    |
| --------------------- | -------------------------- | ---------------------------------------------- |
| `DEVICE_NAME`         | `ubuntu`                   | Device identification value                    |
| `EARNAPP`             | `true`                     | Enable EarnApp startup                         |
| `BUILD_EARNAPP_IMAGE` | `true`                     | Build the EarnApp image locally                |
| `EARNAPP_LOCAL_TAG`   | `eaincome/earnapp:local`   | Local Docker image tag                         |
| `EARNAPP_IMAGE`       | `madereddy/earnapp:latest` | Prebuilt image when local building is disabled |

## Networking

| Variable             | Description                     |
| -------------------- | ------------------------------- |
| `USE_PROXIES`        | Enable proxy-per-node mode      |
| `TUN2PROXY_IMAGE`    | tun2proxy Docker image          |
| `TUN2PROXY_DNS_MODE` | DNS mode                        |
| `USE_DNS_OVER_HTTPS` | Legacy DNS selector             |
| `USE_SOCKS5_DNS`     | Deprecated compatibility option |

## Logging

| Variable              | Default | Description                 |
| --------------------- | ------- | --------------------------- |
| `ENABLE_LOGS`         | `false` | Enable Docker JSON logs     |
| `LOG_MAX_SIZE`        | `10m`   | Maximum size per log file   |
| `LOG_MAX_FILES`       | `3`     | Number of rotated log files |
| `TUN2PROXY_LOG_LEVEL` | `info`  | tun2proxy log verbosity     |

---

# Current Recommended Proxy Settings

For proxy mode:

```bash
USE_PROXIES=true
TUN2PROXY_DNS_MODE=over-tcp
ENABLE_LOGS=false
```

The current repository's `properties.conf` already uses proxy mode with:

```bash
USE_PROXIES=true
```

and:

```bash
TUN2PROXY_DNS_MODE=over-tcp
```

---

# DNS Modes

EAincome supports three `tun2proxy` DNS modes.

## `virtual`

```bash
TUN2PROXY_DNS_MODE=virtual
```

Uses tun2proxy's virtual DNS handling.

---

## `over-tcp`

```bash
TUN2PROXY_DNS_MODE=over-tcp
```

Sends DNS over TCP through the proxy.

This is the mode currently configured in the repository.

---

## `direct`

```bash
TUN2PROXY_DNS_MODE=direct
```

Uses UDP DNS.

The proxy must support UDP for this mode.

---

# Docker Commands

## List running containers

```bash
sudo docker ps
```

## List all containers

```bash
sudo docker ps -a
```

## Show EAincome containers

```bash
sudo docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E 'earnapp|tun'
```

## Inspect a container

```bash
sudo docker inspect <container_name>
```

## View logs

```bash
sudo docker logs <container_name>
```

## Follow logs live

```bash
sudo docker logs -f <container_name>
```

---

# Enable Logs

By default:

```bash
ENABLE_LOGS=false
```

This avoids unnecessary Docker log overhead.

For debugging:

```bash
nano properties.conf
```

Set:

```bash
ENABLE_LOGS=true
```

Then recreate the containers:

```bash
sudo bash EAincome.sh --delete
sudo bash EAincome.sh --start
```

View logs:

```bash
sudo docker logs -f <container_name>
```

---

# Restart Containers

EAincome stores container names in:

```text
containernames.txt
```

Restart all tracked containers:

```bash
bash restart.sh
```

Or:

```bash
sudo bash restart.sh
```

---

# Stop and Remove Containers

Run:

```bash
sudo bash EAincome.sh --delete
```

This removes the containers and networks created by EAincome and cleans its runtime files.

### Node UUIDs are preserved

`earnapp.txt` is intentionally preserved.

Therefore you can safely do:

```bash
sudo bash EAincome.sh --delete
sudo bash EAincome.sh --start
```

without intentionally deleting the saved node URLs.

---

# Delete Saved Node UUIDs

If you intentionally want to remove the saved node UUIDs:

```bash
sudo bash EAincome.sh --deleteBackup
```

This removes:

```text
earnapp.txt
```

The next newly created node will receive a new UUID.

> Only use `--deleteBackup` if you actually want to discard the saved node links.

---

# Complete Command Reference

| Command                                | What it does                                        |
| -------------------------------------- | --------------------------------------------------- |
| `sudo bash EAincome.sh --install`      | Installs Docker / required components               |
| `sudo bash EAincome.sh --build`        | Builds the local EarnApp image                      |
| `sudo bash EAincome.sh --start`        | Starts EarnApp nodes                                |
| `sudo bash EAincome.sh --delete`       | Stops/removes EAincome containers and runtime state |
| `sudo bash EAincome.sh --deleteBackup` | Removes saved node UUIDs                            |
| `bash restart.sh`                      | Restarts tracked containers                         |

---

# Changing Proxies

Edit:

```bash
nano proxies.txt
```

After changing the proxy list, recreate the containers:

```bash
sudo bash EAincome.sh --delete
sudo bash EAincome.sh --start
```

Changing `proxies.txt` does **not** modify an already-created `tun2proxy` container.

---

# Troubleshooting

## `Failed registration: check internet connection and try again`

This error does not necessarily mean your internet connection is broken.

The EarnApp runtime can fail TLS certificate verification and report the problem as a connectivity error.

Check the container:

```bash
sudo docker logs <earnapp-container>
```

Look for:

```text
TLS trust store:
```

and:

```text
TLS check passed:
```

or:

```text
TLS check FAILED:
```

EAincome's locally built image sets:

```text
NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
```

The entrypoint also checks for a usable certificate bundle when the container starts.

---

# Native EarnApp Certificate Fix

`fixEarnAppCerts.sh` is intended for a **native Linux EarnApp installation**, not the EAincome Docker containers.

Run:

```bash
sudo bash fixEarnAppCerts.sh
```

The script refreshes the certificate store and creates a systemd drop-in containing:

```text
NODE_EXTRA_CA_CERTS
```

Afterward:

```bash
sudo earnapp register
```

Then:

```bash
sudo earnapp status
```

---

# Check Saved Nodes

Display all generated node links:

```bash
cat earnapp.txt
```

Count them:

```bash
grep -c 'https://earnapp.com/r/' earnapp.txt
```

---

# Check Docker Images

List images:

```bash
sudo docker images
```

Check the EAincome image:

```bash
sudo docker image inspect eaincome/earnapp:local
```

Check tun2proxy:

```bash
sudo docker image inspect ghcr.io/tun2proxy/tun2proxy:v0.8.3
```

---

# Clean Start

To remove the existing containers while keeping saved node UUIDs:

```bash
sudo bash EAincome.sh --delete
sudo bash EAincome.sh --start
```

To completely reset the containers **and** remove saved node UUIDs:

```bash
sudo bash EAincome.sh --delete
sudo bash EAincome.sh --deleteBackup
sudo bash EAincome.sh --start
```

---

# File Structure

```text
EAincome/
├── EAincome.sh
├── fixEarnAppCerts.sh
├── restart.sh
├── properties.conf
├── proxies.txt
├── banner.jpg
├── LICENSE
├── README.md
└── docker/
    ├── Dockerfile
    └── entrypoint.sh
```

---

# Runtime Files

EAincome creates additional files/directories while running:

```text
earnapp.txt
earnappdata/
containernames.txt
networks.txt
resolv.conf
process.pid
```

These are runtime files and should not normally be committed to Git.

---

# How It Works

```text
                         EAincome.sh
                             │
                 ┌───────────┴───────────┐
                 │                       │
           Direct mode              Proxy mode
                 │                       │
            EarnApp #1          ┌────────┴────────┐
                                │                 │
                           tun2proxy #1      tun2proxy #2
                                │                 │
                           EarnApp #1        EarnApp #2
```

In proxy mode:

```text
Proxy
  │
  ▼
tun2proxy
  │
  ▼
EarnApp
```

Each EarnApp container shares the network namespace of its matching `tun2proxy` container.

This keeps the proxy path associated with its corresponding EarnApp node.

---

# Docker Image

The repository contains its own Docker build:

```text
docker/Dockerfile
docker/entrypoint.sh
```

The image is built from Debian and installs EarnApp during the Docker build.

The image includes a CA certificate store and configures:

```text
NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
```

The entrypoint then:

1. Initializes `/etc/earnapp`
2. Writes the supplied node UUID
3. Checks the certificate store
4. Performs a TLS check
5. Starts EarnApp
6. Restarts it if it exits
7. Uses exponential backoff when the process repeatedly exits

---

# Security

Do **not** commit account credentials or proxy credentials.

The repository ignores sensitive runtime files such as:

```text
earnapp.txt
proxies.txt
.earnapp_token
```

Keep these private.

Never paste your EarnApp dashboard/session cookie into:

* GitHub issues
* GitHub commits
* Screenshots
* Public logs
* Discord
* Chat
* Public documentation

---

# Requirements

You need:

* Linux
* Bash
* `sudo`
* Docker
* Internet connectivity
* CA certificates
* Supported proxies when proxy mode is enabled

For proxy mode, make sure your proxy provider permits the traffic and supports the protocol you are using.

---

# Credits

EAincome is an EarnApp-focused variant based on the structure and ideas of:

* [Internet Income](https://github.com/engageub/InternetIncome) by **engageub**
* [tun2proxy](https://github.com/tun2proxy/tun2proxy)

EarnApp is a separate service and is not owned or operated by this repository.

---

# Disclaimer

This project is provided **as is**, without warranty.

You are responsible for:

* complying with EarnApp's terms and policies,
* complying with your proxy provider's terms,
* securing your credentials,
* ensuring your IPs/proxies are permitted for your use,
* complying with applicable laws and network policies.

---

# License

See [LICENSE](LICENSE).
