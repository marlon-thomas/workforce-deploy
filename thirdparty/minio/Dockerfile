# syntax=docker/dockerfile:1
# MinIO server, rebuilt from the pinned source tree (ADR-0015 — third-party
# supply self-containment). Upstream stopped shipping this release through any
# anonymous channel (quay.io namespace 401, Docker Hub repo 401, dl.min.io
# archives 410), and we refuse to seed registries from operator machines:
# the build input is the public git archive at a pinned commit, verified by
# the workflow's sha256 check BEFORE this file runs.
#
# Build context = extracted source tree of minio/minio at the pinned commit
# (the workflow copies this Dockerfile into it as Dockerfile).
FROM docker.io/library/golang:1.22-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY . .
ARG VERSION
ARG COMMIT
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags "-s -w \
      -X github.com/minio/minio/cmd.Version=${VERSION} \
      -X github.com/minio/minio/cmd.CopyrightYear=2024 \
      -X github.com/minio/minio/cmd.ReleaseTag=${VERSION} \
      -X github.com/minio/minio/cmd.CommitID=${COMMIT}" \
      -o /out/minio .

FROM docker.io/library/alpine:3.20
# alpine (not scratch/ubi-micro) on purpose: the object-storage init job in
# compose.yaml runs /bin/sh loops, and TZ needs tzdata (compose sets
# Europe/London). Static binary (CGO off) means no glibc deps.
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/minio /usr/bin/minio
COPY --from=build /src/dockerscripts/docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
COPY --from=build /src/LICENSE /licenses/LICENSE
COPY --from=build /src/CREDITS /licenses/CREDITS
# Same secret-file wiring as the upstream release image (Dockerfile.release).
ENV MINIO_ACCESS_KEY_FILE=access_key \
    MINIO_SECRET_KEY_FILE=secret_key \
    MINIO_ROOT_USER_FILE=access_key \
    MINIO_ROOT_PASSWORD_FILE=secret_key \
    MINIO_KMS_SECRET_KEY_FILE=kms_master_key \
    MINIO_UPDATE_MINISIGN_PUBKEY="RWTx5Zr1tiHQLwG9keckT0c45M3AGeHD6IvimQHpyRywVWGbP1aVSGav" \
    MINIO_CONFIG_ENV_FILE=config.env \
    MC_CONFIG_DIR=/tmp/.mc
EXPOSE 9000
VOLUME ["/data"]
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["minio"]
