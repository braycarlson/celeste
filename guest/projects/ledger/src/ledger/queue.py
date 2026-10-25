import time

import redis

from django.conf import settings


DRAIN_ATTEMPTS = 400
DRAIN_INTERVAL = 0.05
QUEUE = "celery"
QUEUE_UNACKED = "unacked"


def drain():
    client = redis.Redis(host=settings.REDIS_HOST, socket_connect_timeout=5, socket_timeout=5)

    for _ in range(DRAIN_ATTEMPTS):
        try:
            drained = client.llen(QUEUE) == 0 and client.hlen(QUEUE_UNACKED) == 0
        except redis.RedisError:
            drained = False

        if drained:
            return True

        time.sleep(DRAIN_INTERVAL)

    return False
