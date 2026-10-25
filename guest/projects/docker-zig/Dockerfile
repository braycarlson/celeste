FROM dst-base AS root
ARG SOURCE_DATE_EPOCH=1767225600
RUN apt-get update \
    && SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" apt-get install -y --no-install-recommends \
        containerd \
        docker.io \
        runc \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /tmp/busybox/bin /tmp/busybox/tmp \
    && cp /bin/busybox /tmp/busybox/bin/busybox \
    && for applet in cat echo sh sleep; do ln -s busybox "/tmp/busybox/bin/${applet}"; done \
    && mkdir -p /opt/project \
    && tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
        -cf /opt/project/busybox.tar -C /tmp/busybox . \
    && rm -rf /tmp/busybox
COPY projects/docker-zig/harness /opt/project/harness
COPY --from=guests docker-zig-driver /opt/project/bin/
RUN rm -f /opt/project/harness/driver.zig \
    && chmod 0755 /opt/project/harness/* /opt/project/bin/* \
    && dst-normalize

FROM dst-ext4 AS ext4
ARG APP_EPOCH=1767225600
ARG APP_UUID=3b7e1f0a-5c2d-4e8f-9a1b-6d4c3e2f1a0b
ARG APP_HASH_SEED=c4d5e6f7-0a1b-4c2d-8e3f-5a6b7c8d9e0f
COPY --from=root / /rootfs/
RUN dst-ext4 /rootfs /app.ext4 1536M "${APP_UUID}" "${APP_HASH_SEED}" "${APP_EPOCH}"

FROM scratch
COPY --from=ext4 /app.ext4 /docker-zig.ext4
