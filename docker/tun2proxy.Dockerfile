ARG TUN2PROXY_BASE_IMAGE=ghcr.io/tun2proxy/tun2proxy:v0.8.5
FROM ${TUN2PROXY_BASE_IMAGE} AS tun2proxy

FROM alpine:3.22

RUN apk add --no-cache iproute2

COPY --from=tun2proxy /usr/bin/tun2proxy-bin /usr/bin/tun2proxy-bin
COPY docker/tun2proxy-entrypoint.sh /usr/local/bin/tun2proxy-entrypoint.sh

RUN chmod +x /usr/local/bin/tun2proxy-entrypoint.sh \
    && tc -V \
    && ip -V

ENTRYPOINT ["/usr/local/bin/tun2proxy-entrypoint.sh"]
