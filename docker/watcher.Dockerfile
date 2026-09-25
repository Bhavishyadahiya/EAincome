# Feed-driven node watcher image.
#
# Runs nodeWatcher.sh against the dashboard's banned/offline node-ID feed and
# restarts the nodes THIS folder started that the feed flags. It is built locally
# from a pinned base rather than pulled, because it is handed the host Docker
# socket (root-equivalent) and you should be running a binary you built.
#
# Two deliberate differences from the socket-watchdog image:
#   * it carries curl and jq, because it fetches and parses the JSON feed, and
#   * it is NOT run with --network none -- it must reach the dashboard.
#
# Build context is the repo root (so this one COPY can find nodeWatcher.sh); the
# Dockerfile copies only that file, so nothing else in the folder enters the image.
ARG DOCKER_CLI_TAG=28-cli
FROM docker:${DOCKER_CLI_TAG}

RUN apk add --no-cache bash gawk coreutils curl jq

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY nodeWatcher.sh /usr/local/bin/nodeWatcher.sh

# Fail the build now, not at 3am, if any assumption nodeWatcher.sh makes about its
# runtime is unmet: the script must parse, and gawk's mktime(), GNU date -d on a
# nanosecond ISO stamp, jq and curl must all actually work in this image.
RUN chmod +x /usr/local/bin/nodeWatcher.sh \
    && bash -n /usr/local/bin/nodeWatcher.sh \
    && command -v gawk >/dev/null \
    && command -v jq >/dev/null \
    && command -v curl >/dev/null \
    && gawk 'BEGIN { if (mktime("2020 01 01 00 00 00") <= 0) exit 1 }' \
    && date -d '2026-09-02T04:20:35.368000000Z' +%s >/dev/null \
    && jq --version >/dev/null \
    && curl --version >/dev/null

ENV EAINCOME_DIR=/eaincome
WORKDIR /eaincome

ENTRYPOINT ["/usr/local/bin/nodeWatcher.sh"]
CMD ["--watch"]
