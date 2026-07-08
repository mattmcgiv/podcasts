# Dev toolchain image for Pods. Runs only inside the Apple container VM.
FROM docker.io/library/node:22-bookworm

ENV PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
