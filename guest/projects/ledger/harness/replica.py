import os
import sys
import time

import redis

import dst


ACKED_KEPT = "every acknowledged write survives a failover to the replica"
KEYS_MAX = 600
KEYS_MIN = 400
LINK_POLL_WRITES = 10
PRIMARY = "primary"
PROGRESS = "/run/dst/progress/primary"
PROGRESS_INTERVAL = 0.02
PROGRESS_WRITES_MAX = 1 << 20
REPLICA = "replica"
SYNC_INTERVAL = 0.05
SYNC_POLLS = 400
TIMEOUT = 0.2
VERIFY_INTERVAL = 0.05
VERIFY_POLLS = 400
WRITES_ACKED = "the client had at least one write acknowledged"
WRITE_INTERVAL = 0.01

PROPERTIES = (("always", ACKED_KEPT), ("always", WRITES_ACKED))


def _client(host):
    return redis.Redis(host=host, socket_connect_timeout=TIMEOUT, socket_timeout=TIMEOUT)


def _failover(replica, index):
    replica.execute_command("REPLICAOF", "NO", "ONE")
    dst.console(f"DST REPLICA PROMOTED after write {index}")

    return replica


def _link_lost(replica, index):
    if replica is None:
        return False

    if index % LINK_POLL_WRITES != 0:
        return False

    return not _link_up(replica)


def _link_up(replica):
    try:
        return replica.info("replication").get("master_link_status") == "up"
    except redis.RedisError:
        return False


def _progress():
    for count in range(1, PROGRESS_WRITES_MAX + 1):
        with open(PROGRESS, "w") as progress:
            progress.write(str(count))

        time.sleep(PROGRESS_INTERVAL)

    message = f"the progress writer ran past {PROGRESS_WRITES_MAX} writes"
    raise RuntimeError(message)


def _progress_read():
    try:
        with open(PROGRESS) as progress:
            return progress.read().strip()
    except FileNotFoundError:
        return "none"


def _run():
    dst.declare(PROPERTIES)

    replicated = os.environ.get("DST_REPLICAS") != "0"
    primary = _client(PRIMARY)
    replica = _client(REPLICA) if replicated else None

    if replica is not None:
        _sync_wait(replica)

    dst.ready()

    count = KEYS_MIN + dst.below(KEYS_MAX - KEYS_MIN + 1)
    acked, survivor = _write_all(primary, replica, count)
    missing = _verify(survivor, acked)
    failover = survivor is not primary
    details = {"acknowledged": len(acked), "failover": failover, "missing": len(missing)}

    dst.console(f"DST REPLICA ACKED {len(acked)} MISSING {len(missing)} FAILOVER {failover}")
    dst.always(len(acked) > 0, WRITES_ACKED, details)
    dst.always(not missing, ACKED_KEPT, details)
    dst.console(f"DST PROGRESS primary {_progress_read()}")
    dst.power_loss()


def _sync_wait(replica):
    for _ in range(SYNC_POLLS):
        if _link_up(replica):
            return

        time.sleep(SYNC_INTERVAL)

    message = f"the replica never linked to the primary within {SYNC_POLLS} polls"
    raise RuntimeError(message)


def _verify(survivor, acked):
    keys = [f"key:{index}" for index in acked]

    for _ in range(VERIFY_POLLS):
        try:
            values = survivor.mget(keys) if keys else []
        except redis.RedisError:
            time.sleep(VERIFY_INTERVAL)
            continue

        return [index for index, value in zip(acked, values) if value is None]

    message = f"the surviving redis never answered the read back within {VERIFY_POLLS} polls"
    raise RuntimeError(message)


def _write(primary, index):
    try:
        primary.set(f"key:{index}", index)
    except redis.RedisError:
        return False

    return True


def _write_all(primary, replica, count):
    acked = []

    for index in range(count):
        if _write(primary, index):
            acked.append(index)

        if _link_lost(replica, index):
            return acked, _failover(replica, index)

        time.sleep(WRITE_INTERVAL)

    return acked, primary


def main():
    if sys.argv[1:] == ["check"]:
        dst.console("DST CHECK UP")
        dst.checked()

        return

    if sys.argv[1:] == ["progress"]:
        _progress()

        return

    _run()


if __name__ == "__main__":
    main()
