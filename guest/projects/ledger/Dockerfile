FROM dst-base AS root
ARG SOURCE_DATE_EPOCH=1767225600
RUN apt-get update \
    && SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" apt-get install -y --no-install-recommends \
        postgresql-common \
    && sed -i "s/^#* *create_main_cluster *=.*/create_main_cluster = false/" \
        /etc/postgresql-common/createcluster.conf \
    && SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" apt-get install -y --no-install-recommends \
        postgresql \
        python3-venv \
        redis-server \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.lock /opt/requirements.lock
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --no-compile --require-hashes \
        -r /opt/requirements.lock
COPY harness /opt/project/harness
COPY src /opt/project/src
RUN cd /opt/project/harness \
    && chmod 0755 check eventually run setup start \
    && cd /opt/project/src \
    && DJANGO_SETTINGS_MODULE=ledger.settings PYTHONPATH=/opt/sdk /opt/venv/bin/python manage.py \
        makemigrations --check --dry-run \
    && dst-normalize

FROM dst-ext4 AS ext4
ARG APP_EPOCH=1767225600
ARG APP_UUID=5f1c8b62-7d3a-4f0e-9a8b-2c6d4e1f3a59
ARG APP_HASH_SEED=0b7e6c2d-1f4a-4c9e-8d3b-5a2f7e9c1d64
COPY --from=root / /rootfs/
RUN dst-ext4 /rootfs /app.ext4 1G "${APP_UUID}" "${APP_HASH_SEED}" "${APP_EPOCH}"

FROM scratch
COPY --from=ext4 /app.ext4 /app.ext4
