# Production image: client build -> server build (embeds UI) -> slim runtime.
# Built on the deployment box, never on the dev host (see CLAUDE.md).

FROM node:22-bookworm AS client
WORKDIR /app/client
COPY client/package.json client/package-lock.json client/.npmrc ./
RUN npm ci
COPY client/ ./
RUN npm run build

FROM rust:1-bookworm AS server
WORKDIR /app/server
COPY server/ ./
# rust-embed resolves ../client/dist relative to the server crate
COPY --from=client /app/client/dist /app/client/dist
RUN cargo build --release --features ui

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 pods \
    && mkdir -p /data && chown pods:pods /data
COPY --from=server /app/server/target/release/pods-server /usr/local/bin/pods-server
USER pods
ENV DATABASE_PATH=/data/pods.sqlite \
    BIND_ADDR=0.0.0.0:8080 \
    RUST_LOG=pods_server=info
EXPOSE 8080
VOLUME /data
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS http://127.0.0.1:8080/ >/dev/null || exit 1
CMD ["pods-server"]
