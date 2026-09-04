# Build on the laptop (linux/amd64). Do not build this on the 2 GB VPS.
FROM rust:1-bookworm AS rust-build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY include ./include
RUN cargo build --release --bin pods-transcribe

FROM debian:bookworm-slim AS parakeet-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates cmake g++ git make \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# ggml Parakeet runtime used for the 110M TDT-CTC checkpoint.
RUN git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/mudler/parakeet.cpp.git \
    && cmake -S parakeet.cpp -B parakeet.cpp/build -DCMAKE_BUILD_TYPE=Release -DPARAKEET_BUILD_CLI=ON \
    && cmake --build parakeet.cpp/build --config Release -j"$(nproc)" \
    && find parakeet.cpp/build -type f -name parakeet-cli -exec cp {} /usr/local/bin/parakeet-cli \; \
    && find parakeet.cpp/build \( -name 'libggml*.so*' -o -name 'libparakeet*.so*' \) -exec cp -a {} /usr/local/lib/ \; \
    && ldconfig

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=rust-build /src/target/release/pods-transcribe /usr/local/bin/pods-transcribe
COPY --from=parakeet-build /usr/local/bin/parakeet-cli /usr/local/bin/parakeet-cli
COPY --from=parakeet-build /usr/local/lib/ /usr/local/lib/
RUN ldconfig
ENV LD_LIBRARY_PATH=/usr/local/lib
ENV PODS_BIND=0.0.0.0:18181
ENV PODS_PARAKEET_BIN=parakeet-cli
ENV PODS_PARAKEET_MODEL=/models/tdt_ctc-110m-q8_0.gguf
EXPOSE 18181
ENTRYPOINT ["pods-transcribe"]
