# EAincome's own EarnApp image.
#
# Built locally rather than pulled, so you control the contents and the TLS trust
# store is as fresh as the day you build.
#
# The critical addition over the community images is NODE_EXTRA_CA_CERTS. The
# earnapp binary bundles its own TLS stack, and installing ca-certificates alone
# does not make it trust the system store. Without this variable a node fails with
#
#   Failed registration: check internet connection and try again
#
# which reads like a network fault but is certificate verification failing.
#
# Three bugs in the community Dockerfiles are fixed here:
#   1. The installer URL cdn-earnapp.b-cdn.net/static/earnapp/install.sh now 404s.
#      The live entry point is brightdata.com/static/earnapp/install.sh, which
#      redirects to a versioned script on cdn.earnapp.com.
#   2. "... && bash install.sh -y && earnapp stop || true" lets the || true rescue
#      a failed download or install, silently producing an image with no binary.
#      Failure is isolated here, and the build asserts the binary exists.
#   3. RUN executes via /bin/sh (dash on Debian), which has no brace expansion, so
#      the grouped rm -rf paths in the originals silently deleted nothing.

FROM debian:trixie-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG INSTALLER_URL=https://brightdata.com/static/earnapp/install.sh

ENV DEBIAN_FRONTEND=noninteractive \
    CONFIG_DIR=/etc/earnapp \
    EARNAPP_TEMPLATE=/opt/earnapp-template \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    MALLOC_ARENA_MAX=2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        hostname \
    && update-ca-certificates \
    # The installer probes for systemd tooling that does not exist in a container.
    # Inert shims stop it aborting. Written as static text on purpose: the
    # originals interpolated $(lsb_release -a) before lsb_release was installed,
    # so those shims ended up empty.
    && printf '#!/bin/sh\necho "Debian GNU/Linux"\n' > /usr/bin/lsb_release \
    && printf '#!/bin/sh\necho "Static hostname: earnapp-container"\n' > /usr/bin/hostnamectl \
    && printf '#!/bin/sh\nexit 0\n' > /usr/bin/systemctl \
    && chmod +x /usr/bin/lsb_release /usr/bin/hostnamectl /usr/bin/systemctl \
    && wget -qO /tmp/install.sh "$INSTALLER_URL" \
    && test -s /tmp/install.sh \
    && bash /tmp/install.sh -y \
    && { earnapp stop >/dev/null 2>&1 || true; }

# EAincome bind-mounts a host directory over /etc/earnapp for per-node state,
# which would hide everything the installer wrote there. Stash a template the
# entrypoint can seed the mount from.
#
# The installer registers a throwaway node during the build and writes its uuid,
# registered and status files. Those are a build-time identity, not part of the
# image, so they are stripped from both the template and /etc/earnapp. Otherwise
# every container would inherit one build's node identity and the healthcheck
# below would pass without the node ever having registered.
RUN mkdir -p "$EARNAPP_TEMPLATE" \
    && cp -a "$CONFIG_DIR"/. "$EARNAPP_TEMPLATE"/ \
    && rm -f "$EARNAPP_TEMPLATE"/uuid \
             "$EARNAPP_TEMPLATE"/registered \
             "$EARNAPP_TEMPLATE"/status \
             "$EARNAPP_TEMPLATE"/*.log \
             "$CONFIG_DIR"/uuid \
             "$CONFIG_DIR"/registered \
             "$CONFIG_DIR"/status \
             "$CONFIG_DIR"/*.log \
    && rm -rf /var/lib/apt/lists/* /tmp/install.sh /tmp/earnapp_* \
    && test -x /usr/bin/earnapp \
    && test -s /etc/ssl/certs/ca-certificates.crt \
    && test -s "$EARNAPP_TEMPLATE/ver" \
    && echo "Built earnapp $(cat "$EARNAPP_TEMPLATE/ver") with $(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt) trusted CAs"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# A container that is alive but never registered is the exact failure this image
# exists to prevent, so make it visible to docker ps rather than silent.
HEALTHCHECK --interval=5m --timeout=10s --start-period=120s --retries=3 \
    CMD test -f /etc/earnapp/registered || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
