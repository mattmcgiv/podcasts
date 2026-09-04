# Build on the laptop (linux/amd64). Do not build this on the 2 GB VPS.
FROM rust:1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY include ./include
RUN cargo build --release --features passkey --bin pods-backend

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/pods-backend /usr/local/bin/pods-backend
ENTRYPOINT ["pods-backend"]
CMD ["/data/pods.sqlite"]
