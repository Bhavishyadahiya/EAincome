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
# Setting the variable is not the same as proving it works, so the build proves it:
# it validates the real EarnApp and BrightData TLS chains against the bundle and
# refuses to produce an image if any of them cannot be verified. An image that
# builds is therefore an image whose nodes can register, rather than one that only
# looks correct. The entrypoint repeats the check on every start, since a trust
# store can be broken later by a bind mount or by something intercepting TLS, and it
# probes client.earnapp.com separately so that a firewalled host is reported as the
# network fault it is instead of being mistaken for a certificate one.
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
        openssl \
        wget \
        hostname \
    # --fresh rebuilds the bundle from the shipped certificates instead of
    # amending whatever happened to be there already.
    && update-ca-certificates --fresh \
    && test -s "$NODE_EXTRA_CA_CERTS" \
    # Prove the bundle can actually validate the chains this node will meet.
    # brightdata.com and cdn.earnapp.com are already hard dependencies of this
    # build, and client.earnapp.com is where registration happens, so a network
    # outage would fail the build anyway. What this catches is the case that
    # matters: a store that is present but cannot verify these hosts, which yields
    # an image that looks fine and whose nodes never link.
    && for host in brightdata.com cdn.earnapp.com earnapp.com; do \
         if openssl s_client -connect "$host:443" -servername "$host" \
              -CAfile "$NODE_EXTRA_CA_CERTS" -verify_return_error -brief \
              </dev/null >/dev/null 2>&1; then \
           echo "TLS verified: $host"; \
         else \
           echo "TLS verification FAILED for $host using $NODE_EXTRA_CA_CERTS"; \
           echo "Refusing to build an image whose nodes would not be able to register."; \
           exit 1; \
         fi; \
       done \
    # client.earnapp.com is the host 'earnapp start' POSTs /install_device to, and
    # it is firewalled on machines that reach earnapp.com perfectly well. Probe it,
    # but do not fail the build over it: an image may legitimately be built on one
    # host and run on another, and reachability is a property of the host, not of
    # the image. A store that cannot verify it would have been caught above.
    && if timeout 8 bash -c 'exec 3<>/dev/tcp/client.earnapp.com/443' 2>/dev/null; then \
         echo "Reachability: client.earnapp.com:443 is open from this build host."; \
       else \
         echo "WARNING: client.earnapp.com:443 could not be opened from this build host."; \
         echo "That is where registration POSTs /install_device. Nodes run on this host"; \
         echo "will report 'check internet connection and try again' until it opens."; \
       fi \
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
    && { earnapp stop >/dev/null 2>&1 || true; } \
    # The installer performs a real registration while it runs, which means the
    # earnapp binary's own bundled TLS stack validated this store using this
    # variable. That is the exact operation that fails for everyone hitting the
    # linking bug, so record whether it worked. The throwaway node identity it
    # creates is stripped in the next layer.
    && if [ -f "$CONFIG_DIR/registered" ]; then \
         echo "Verified end to end: the earnapp binary completed a real registration during the build."; \
       else \
         echo "Note: the installer left no registration marker. The TLS checks above passed, so read the client.earnapp.com reachability line before suspecting the trust store."; \
       fi

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
