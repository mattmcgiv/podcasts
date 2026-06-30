# Dev toolchain image for Pods. Runs only inside the Apple container VM.
FROM docker.io/library/node:22-bookworm

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    CARGO_TARGET_DIR=/opt/target \
    PATH=/opt/cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 jq \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable \
      --component llvm-tools-preview --component clippy --component rustfmt

RUN rustup target add aarch64-apple-ios aarch64-apple-ios-sim

RUN curl -fsSL https://github.com/taiki-e/cargo-llvm-cov/releases/latest/download/cargo-llvm-cov-aarch64-unknown-linux-gnu.tar.gz \
    | tar xzf - -C /opt/cargo/bin

WORKDIR /work
