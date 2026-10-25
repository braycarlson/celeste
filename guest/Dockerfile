FROM ubuntu:22.04@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401 AS kernel
ARG KERNEL_VERSION=6.1.128
ARG KERNEL_SHA256=874d67d3181570e69ac6b33853f0448f05fc90d4cf3e4baaadc4a9cede7c50f3
ARG UBUNTU_SNAPSHOT=20261010T000000Z
RUN snapshot="https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/" \
    && sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu/|${snapshot}|" \
        -e "s|http://security.ubuntu.com/ubuntu/|${snapshot}|" \
        /etc/apt/sources.list \
    && apt-get -o Acquire::https::Verify-Peer=false update \
    && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
        bc \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        curl \
        flex \
        kmod \
        libelf-dev \
        libssl-dev \
        python3 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl -sfLo linux.tar.xz \
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" \
    && echo "${KERNEL_SHA256}  linux.tar.xz" | sha256sum -c - \
    && tar xJf linux.tar.xz \
    && rm linux.tar.xz
WORKDIR /build/linux-${KERNEL_VERSION}
COPY rdtsc.patch /build/rdtsc.patch
RUN patch -p1 < /build/rdtsc.patch
COPY tsd.patch /build/tsd.patch
RUN patch -p1 < /build/tsd.patch
COPY accessed.patch /build/accessed.patch
RUN patch -p1 < /build/accessed.patch
COPY kernel.config .config
RUN scripts/config \
        --disable CONFIG_HZ_250 \
        --enable CONFIG_HZ_1000 \
        --set-val CONFIG_HZ 1000 \
        --disable CONFIG_RANDOMIZE_KSTACK_OFFSET \
        --disable CONFIG_RANDOM_TRUST_CPU \
        --enable CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES \
        --enable CONFIG_NET_SCH_PRIO \
        --enable CONFIG_NET_SCH_NETEM \
        --enable CONFIG_NET_CLS_U32 \
        --disable CONFIG_LRU_GEN \
        --set-val CONFIG_SERIAL_8250_NR_UARTS 2 \
        --set-val CONFIG_SERIAL_8250_RUNTIME_UARTS 2 \
        --set-str CONFIG_LOCALVERSION -celeste \
    && make olddefconfig
ARG KERNEL_EPOCH=1767225600
ARG KERNEL_JOBS=4
RUN KBUILD_BUILD_TIMESTAMP="$(date -u -d "@${KERNEL_EPOCH}")" \
        KBUILD_BUILD_HOST=dst \
        KBUILD_BUILD_USER=dst \
        KBUILD_BUILD_VERSION=1 \
        make -j"${KERNEL_JOBS}" vmlinux

FROM scratch AS kernel-image
COPY --from=kernel /build/linux-6.1.128/vmlinux /vmlinux

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS rootfs
ARG ROOTFS_EPOCH=1767225600
ARG ROOTFS_UUID=80b0cae9-2c5a-475b-bd22-7ca264a92858
ARG ROOTFS_HASH_SEED=bc832159-4b28-4e29-9e5f-373d8093606f
ARG UBUNTU_SNAPSHOT=20261010T000000Z
RUN snapshot="https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/" \
    && sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu/|${snapshot}|" \
        -e "s|http://security.ubuntu.com/ubuntu/|${snapshot}|" \
        /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::Verify-Peer=false update \
    && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
        busybox-static \
        e2fsprogs \
        gcc \
        libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY rootfs /rootfs
COPY probe /probe
RUN mkdir -p /rootfs/bin /rootfs/data /rootfs/dev /rootfs/proc /rootfs/sys \
    && cp "$(command -v busybox)" /rootfs/bin/busybox \
    && gcc -static -O2 -o /rootfs/bin/tsc-probe /probe/tsc.c \
    && find /rootfs -exec touch -h -d "@${ROOTFS_EPOCH}" {} + \
    && E2FSPROGS_FAKE_TIME="${ROOTFS_EPOCH}" mkfs.ext4 -q -b 4096 -d /rootfs \
        -U "${ROOTFS_UUID}" \
        -E "hash_seed=${ROOTFS_HASH_SEED},root_owner=0:0" \
        /rootfs.ext4 64M \
    && find /rootfs -mindepth 1 \
        | sed "s|^/rootfs\(.*\)|set_inode_field \1 ctime @${ROOTFS_EPOCH}|" > /ctime.debugfs \
    && echo "set_inode_field / ctime @${ROOTFS_EPOCH}" >> /ctime.debugfs \
    && E2FSPROGS_FAKE_TIME="${ROOTFS_EPOCH}" debugfs -w -f /ctime.debugfs /rootfs.ext4 > /dev/null

FROM scratch AS rootfs-image
COPY --from=rootfs /rootfs.ext4 /rootfs.ext4

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f \
    AS debian-snapshot
ARG DEBIAN_SNAPSHOT=20261010T000000Z
RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && printf '%s\n' \
        "Types: deb" \
        "URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
        "Suites: trixie trixie-updates" \
        "Components: main" \
        "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
        "Check-Valid-Until: no" \
        "" \
        "Types: deb" \
        "URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}" \
        "Suites: trixie-security" \
        "Components: main" \
        "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
        "Check-Valid-Until: no" \
        > /etc/apt/sources.list.d/snapshot.sources

FROM debian-snapshot AS base
ARG SOURCE_DATE_EPOCH=1767225600
RUN apt-get update \
    && SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" apt-get install -y --no-install-recommends \
        busybox-static \
        iproute2 \
        python3 \
    && rm -rf /var/lib/apt/lists/*
COPY sdk/python /opt/sdk
COPY base/service base/nodes /opt/sdk/
COPY base/init /init
COPY base/normalize /usr/local/sbin/dst-normalize
RUN chmod 0755 /init /opt/sdk/nodes /opt/sdk/service /usr/local/sbin/dst-normalize

FROM debian-snapshot AS ext4-tools
RUN apt-get update \
    && apt-get install -y --no-install-recommends e2fsprogs \
    && rm -rf /var/lib/apt/lists/*
COPY base/ext4 /usr/local/sbin/dst-ext4
RUN chmod 0755 /usr/local/sbin/dst-ext4

FROM scratch
COPY --from=kernel-image /vmlinux /vmlinux
COPY --from=rootfs-image /rootfs.ext4 /rootfs.ext4
