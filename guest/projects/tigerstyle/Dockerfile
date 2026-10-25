FROM dst-base AS zig-build
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_VERSION=0.17.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sfLo /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar xJf /tmp/zig.tar.xz -C /opt \
    && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
    && rm /tmp/zig.tar.xz
COPY --from=scylla-source / /build/scylla
COPY --from=tigerstyle-source / /build/tigerstyle-lsp
WORKDIR /build/tigerstyle-lsp
RUN /opt/zig/zig build --release=safe

FROM dst-base AS root
COPY projects/tigerstyle/harness /opt/project/harness
COPY --from=guests tigerstyle-driver /opt/project/bin/
COPY --from=zig-build /build/tigerstyle-lsp/zig-out/bin/tigerstyle-lsp /opt/project/bin/
COPY --from=tigerstyle-source /src /opt/project/corpus
RUN rm -f /opt/project/harness/driver.zig \
    && chmod 0755 /opt/project/harness/* /opt/project/bin/* \
    && dst-normalize

FROM dst-ext4 AS ext4
ARG APP_EPOCH=1767225600
ARG APP_UUID=9e8d7c6b-5a49-4382-9170-6f5e4d3c2b1a
ARG APP_HASH_SEED=a1b2c3d4-e5f6-4071-8293-a4b5c6d7e8f9
COPY --from=root / /rootfs/
RUN dst-ext4 /rootfs /app.ext4 512M "${APP_UUID}" "${APP_HASH_SEED}" "${APP_EPOCH}"

FROM scratch
COPY --from=ext4 /app.ext4 /tigerstyle.ext4
