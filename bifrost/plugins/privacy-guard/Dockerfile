# ============================================================================
# Bifrost with the KIRA privacy-guard plugin – built by /opt/kira/setup.sh (only with PRIVACY_GUARD on)
#
# The official Bifrost image is linked statically and cannot load Go plugins. This builds the same Bifrost version
# dynamically and the plugin in the SAME module and toolchain (Go plugins only load if Go version, libc and every shared
# package are identical). The base images are those of the official Dockerfile of that version (setup.sh reads them
# from GitHub and passes them as build arguments).
#
#   docker build --build-arg BIFROST_TAG=v2.6.0 --build-arg GO_IMAGE=… --build-arg NODE_IMAGE=… \
#                --build-arg RUNTIME_IMAGE=… -t kira/bifrost-guard:<tag> /opt/bifrost/plugins/privacy-guard
# ============================================================================
ARG NODE_IMAGE=node:25-alpine3.23
ARG GO_IMAGE=golang:1.27.4-alpine3.24
ARG RUNTIME_IMAGE=alpine:3.23

# --- Bifrost source of the requested version
FROM ${GO_IMAGE} AS src
ARG BIFROST_TAG
RUN test -n "$BIFROST_TAG" && apk add --no-cache git \
 && git clone --depth 1 --branch "transports/${BIFROST_TAG}" https://github.com/maximhq/bifrost /src

# --- web interface (embedded into the binary)
FROM ${NODE_IMAGE} AS ui
WORKDIR /app
COPY --from=src /src/ui/ ./
RUN npm ci && npm run build-enterprise

# --- Bifrost (dynamically linked) and the plugin from one module
FROM ${GO_IMAGE} AS builder
RUN apk add --no-cache gcc musl-dev sqlite-dev binutils binutils-gold
ENV CGO_ENABLED=1 GOOS=linux GOWORK=off
WORKDIR /app
COPY --from=src /src/transports/ ./
COPY --from=ui /app/out ./bifrost-http/ui
RUN go mod download
COPY kiraguard/ ./kiraguard/
ARG BIFROST_TAG
# unit tests of the guard logic (no network needed)
RUN go test ./kiraguard/guard/
RUN go build -ldflags="-w -s -X main.Version=${BIFROST_TAG}" -trimpath -o /app/main ./bifrost-http \
 && go build -buildmode=plugin -trimpath -o /app/privacy-guard.so ./kiraguard

# --- runtime: like the official image, plus the shared libraries of the dynamic build
FROM ${RUNTIME_IMAGE}
WORKDIR /app
RUN apk upgrade --no-cache && apk add --no-cache musl libgcc ca-certificates zlib sqlite-libs
COPY --from=builder /app/main .
COPY --from=builder /app/docker-entrypoint.sh .
COPY --from=builder /app/privacy-guard.so /app/plugins/privacy-guard.so
ARG ARG_APP_PORT=8080
ARG ARG_APP_HOST=0.0.0.0
ARG ARG_LOG_LEVEL=info
ARG ARG_LOG_STYLE=json
ARG ARG_APP_DIR=/app/data
ENV APP_PORT=$ARG_APP_PORT APP_HOST=$ARG_APP_HOST LOG_LEVEL=$ARG_LOG_LEVEL LOG_STYLE=$ARG_LOG_STYLE APP_DIR=$ARG_APP_DIR \
    GOGC="" GOMEMLIMIT=""
RUN mkdir -p "$APP_DIR/logs" \
 && adduser -D -s /bin/sh appuser \
 && chown -R appuser:appuser /app \
 && chown -R appuser:0 "$APP_DIR" \
 && chmod -R g=rwX "$APP_DIR" \
 && chmod +x /app/docker-entrypoint.sh \
 && chmod 0444 /app/plugins/privacy-guard.so
USER 1000:0
VOLUME ["/app/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:${APP_PORT}/health || exit 1
LABEL org.opencontainers.image.title="Bifrost with KIRA privacy guard" \
      org.opencontainers.image.source="https://github.com/maximhq/bifrost"
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["/app/main"]
