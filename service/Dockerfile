# The SQLite driver is pure Go (modernc.org/sqlite), so the binary needs no libc
# and the release stage can be scratch.
FROM golang:1.27-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/zulu-notifyd ./cmd/zulu-notifyd

FROM alpine:3.21 AS certs
RUN apk add --no-cache ca-certificates \
 && mkdir -p /data && chown 65532:65532 /data

FROM scratch

# Zulip realms and APNs are both HTTPS, so the image needs the trust store.
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/zulu-notifyd /zulu-notifyd

# The database directory has to exist owned by the unprivileged user: a scratch
# image cannot chown at runtime, and a named volume inherits this ownership.
# A host bind mount does not — chown it on the host to 65532 first.
COPY --from=certs --chown=65532:65532 /data /data

# Nothing here runs as root: the service only ever writes to its database
# directory, which the compose file mounts.
USER 65532:65532

ENV ZULU_DATABASE_PATH=/data/zulu.db \
    ZULU_HTTP_ADDR=:8080

EXPOSE 8080
VOLUME ["/data"]

ENTRYPOINT ["/zulu-notifyd"]
