# The node watchdog, as a container.
#
# Why containerise a shell script: Docker is already the supervisor on this host.
# Running the watchdog under it means no systemd unit to write and no crontab to
# maintain, and it comes back by itself after a reboot -- which is precisely when
# the nodes need it, because a node whose tun2proxy parent had not started yet
# fails to start rather than failing to run, so its own restart policy never
# rescues it and it stays dead until something starts the pair in order.
#
# It also pins down the environment the script runs in. The cooldown and the
# restart cap are worked out with awk's mktime(), which busybox awk lacks entirely
# and mawk only gained in 1.3.4, and container start times are ISO 8601 with
# fractional seconds, which busybox date will not parse. Both failures are silent
# and both would weaken the guards that stop a node being restarted in a loop. So
# rather than hope the host ships a suitable awk and date, ship gawk and GNU
# coreutils and prove them at build time.
#
# Build from the repository root, not from docker/, because the script lives
# there:
#
#   docker build -f docker/watchdog.Dockerfile -t eaincome/watchdog:local .
#
# EAincome.sh --watchdog does that for you, and the .dockerignore beside this file
# keeps everything but the script itself out of the build context -- earnapp.txt
# and proxies.txt have no business being sent to the daemon.

ARG DOCKER_CLI_TAG=28-cli
FROM docker:${DOCKER_CLI_TAG}

RUN apk add --no-cache bash gawk coreutils

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY nodeWatchdog.sh /usr/local/bin/nodeWatchdog.sh

# Prove the two things the guards depend on, and that the script parses at all.
# A watchdog that silently cannot enforce its own cooldown is worse than none.
RUN chmod +x /usr/local/bin/nodeWatchdog.sh \
    && bash -n /usr/local/bin/nodeWatchdog.sh \
    && command -v gawk >/dev/null \
    && gawk 'BEGIN { if (mktime("2020 01 01 00 00 00") <= 0) exit 1 }' \
    && date -d '2026-09-02T04:20:35.368000000Z' +%s >/dev/null \
    && echo "Verified: gawk mktime() and GNU date -d both handle what the script needs."

# EAINCOME_DIR is the bind-mounted script folder. containernames.txt is read from
# it, which is what scopes this watchdog to one EAincome deployment, and
# watchdog.state and watchdog.log are written back into it so the sample history
# survives the container being recreated.
#
# PROC_ROOT is the host's /proc, mounted read-only. The PIDs come from the Docker
# API and belong to the host's PID namespace, so they mean nothing against this
# container's own /proc.
ENV EAINCOME_DIR=/eaincome \
    PROC_ROOT=/host/proc

WORKDIR /eaincome

# Needs no network of its own: it talks to Docker over a unix socket and reads
# files. Run it with --network none.
#
# The default is deliberately the harmless one. Restarting a node is cheap but not
# free, and the stall thresholds are still inferred from healthy nodes rather than
# from one caught not earning, so the image reports what it would do until you
# pass --watch on its own.
ENTRYPOINT ["/usr/local/bin/nodeWatchdog.sh"]
CMD ["--watch", "--dry-run"]
