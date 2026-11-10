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
# Both images pinned by digest and the plugin by version (Workforce issue 53), so a rebuild makes the same gateway.
FROM caddy:2.10.2-builder@sha256:01668408cc26e2e00c9d067c30cb43b2ba14ad1f2808beda55503cb2a31f59dc AS builder
ENV GOTOOLCHAIN=auto
RUN xcaddy build --with github.com/caddy-dns/duckdns@v0.5.0

FROM caddy:2.10.2@sha256:c3d7ee5d2b11f9dc54f947f68a734c84e9c9666c92c88a7f30b9cba5da182adb
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
