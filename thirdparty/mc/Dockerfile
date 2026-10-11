# syntax=docker/dockerfile:1
# MinIO client (mc), rebuilt from the pinned source tree (ADR-0015).
# Same rationale as thirdparty/minio: no anonymous upstream source remains for
# the pinned release, and operator-machine images are not a valid supply path.
# Build context = extracted source tree of minio/mc at the pinned commit.
FROM docker.io/library/golang:1.22-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY . .
ARG VERSION
ARG COMMIT
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags "-s -w \
      -X github.com/minio/mc/cmd.Version=${VERSION} \
      -X github.com/minio/mc/cmd.CopyrightYear=2024 \
      -X github.com/minio/mc/cmd.ReleaseTag=${VERSION} \
      -X github.com/minio/mc/cmd.CommitID=${COMMIT}" \
      -o /out/mc .

FROM docker.io/library/alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/mc /usr/bin/mc
COPY --from=build /src/LICENSE /licenses/LICENSE
COPY --from=build /src/CREDITS /licenses/CREDITS
ENTRYPOINT ["/usr/bin/mc"]
