# gateway/Dockerfile — Caddy with the DuckDNS DNS-01 plugin.
#
# The test environment gets real Let's Encrypt certificates through the
# DuckDNS API (TLS_MODE=dns01, environments-design.md §4): no inbound
# internet, no router port-forward, no A record needed for issuance —
# Tailscale provides reachability instead. Production (TLS_MODE unset)
# keeps stock caddy:2.8.4 with HTTP-01.
#
# Built and published by .github/workflows/publish.yml as
# ghcr.io/<owner>/workforce-gateway.
FROM caddy:2.8.4-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/duckdns

FROM caddy:2.8.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
