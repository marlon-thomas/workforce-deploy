#!/bin/sh
# Container entrypoint (spec §10.2: non-root runtime, secrets via mounted files).
#
# Runs briefly as root ONLY to copy Docker-secret files into a tmpfs directory
# readable by the `app` user (some storage drivers ignore secret `mode:`), then
# drops privileges for the JVM. Final application process = non-root.
set -eu

SRC_DIR=/run/secrets
DST_DIR=/tmp/app-secrets

if [ -d "$SRC_DIR" ] && [ -n "$(ls "$SRC_DIR" 2>/dev/null)" ]; then
    mkdir -p "$DST_DIR"
    for f in "$SRC_DIR"/*; do
        [ -f "$f" ] && cp "$f" "$DST_DIR/"
    done
    chown -R app:app "$DST_DIR"
    chmod 700 "$DST_DIR"
    chmod 600 "$DST_DIR"/*
fi

export SPRING_CONFIG_IMPORT="optional:configtree:${DST_DIR}/"

# Staging-TLS mode (deployment-spec §B3): when the gateway runs on non-production
# certificates (LE rate-limit override), the api's JVM must trust the gateway's
# chain to reach authentik's discovery endpoint. install.sh exports the gateway
# chain into secrets/api-truststore.jks and this entrypoint wires it into the JVM.
EXTRA_JAVA_OPTS=""
if [ -n "${WORKFORCE_TLS_TRUSTSTORE:-}" ] && [ -f "${WORKFORCE_TLS_TRUSTSTORE}" ]; then
    chown app:app "${WORKFORCE_TLS_TRUSTSTORE}" 2>/dev/null || true
    chmod 644 "${WORKFORCE_TLS_TRUSTSTORE}" 2>/dev/null || true
    EXTRA_JAVA_OPTS="-Djavax.net.ssl.trustStore=${WORKFORCE_TLS_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=changeit"
fi

# Drop to the unprivileged user; exec keeps PID1 signal semantics for graceful shutdown.
exec setpriv --reuid app --regid app --init-groups \
    sh -c "exec java $JAVA_OPTS $EXTRA_JAVA_OPTS -jar /app/app.jar"
