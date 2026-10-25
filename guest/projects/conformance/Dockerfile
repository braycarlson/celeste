FROM rust:1.99-slim-trixie@sha256:2752b332db73fdbb7dc576f06c82ed1f312005784ef913d7e04a28f5f55dc581 \
    AS rust-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends binutils gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY sdk/c /build/sdk/c
COPY sdk/rust /build/sdk/rust
COPY projects/conformance/rust /build/projects/conformance/rust
WORKDIR /build/projects/conformance/rust
RUN RUSTFLAGS="-Cpasses=sancov-module -Cllvm-args=-sanitizer-coverage-level=3 \
        -Cllvm-args=-sanitizer-coverage-trace-pc-guard" \
    cargo build --release --offline --target x86_64-unknown-linux-gnu

FROM golang:1.26-trixie@sha256:f06b7122f888680048afb247c4e5f49c0069eb6c4c1ccae0f3f4834527a8d22c \
    AS go-build
COPY sdk/c /build/sdk/c
COPY sdk/go /build/sdk/go
COPY projects/conformance/go /build/projects/conformance/go
WORKDIR /build/projects/conformance/go
RUN CGO_ENABLED=1 go build -tags libfuzzer -gcflags=all=-d=libfuzzer -trimpath \
        -o conformance-go .

FROM dst-base AS root
COPY projects/conformance/harness /opt/project/harness
COPY --from=guests conformance-zig /opt/project/bin/
COPY --from=rust-build \
    /build/projects/conformance/rust/target/x86_64-unknown-linux-gnu/release/conformance-rust \
    /opt/project/bin/
COPY --from=go-build /build/projects/conformance/go/conformance-go /opt/project/bin/
RUN chmod 0755 /opt/project/harness/* /opt/project/bin/* \
    && dst-normalize

FROM dst-ext4 AS ext4
ARG APP_EPOCH=1767225600
ARG APP_UUID=7c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f
ARG APP_HASH_SEED=2f3e4d5c-6b7a-4998-8776-655443322110
COPY --from=root / /rootfs/
RUN dst-ext4 /rootfs /app.ext4 256M "${APP_UUID}" "${APP_HASH_SEED}" "${APP_EPOCH}"

FROM scratch
COPY --from=ext4 /app.ext4 /conformance.ext4
