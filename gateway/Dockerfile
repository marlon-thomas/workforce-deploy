# gateway/Dockerfile — Caddy with the DuckDNS DNS-01 plugin.
#
# The test environment gets real Let's Encrypt certificates through the
# DuckDNS API (TLS_MODE=dns01, environments-design.md §4): no inbound
# internet, no router port-forward, no A record needed for issuance —
# Tailscale provides reachability instead. Production (TLS_MODE unset)
# keeps stock caddy with HTTP-01.
#
# Caddy 2.10: the duckdns plugin requires it (v0.5.0 needs caddy >= 2.10,
# go >= 1.24 — pinned 2.8.4 builds fatal). Built and published by
# .github/workflows/publish.yml as ghcr.io/<owner>/workforce-gateway.
FROM caddy:2.10-builder AS builder
ENV GOTOOLCHAIN=auto
RUN xcaddy build --with github.com/caddy-dns/duckdns

FROM caddy:2.10
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
