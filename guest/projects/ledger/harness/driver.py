import collections
import http.client
import json
import os
import subprocess
import threading
import time
import types
import uuid

import psycopg2

import dst

from ledger.constants import ACCOUNT_NAMES
from ledger.properties import EVENTUALLY, PROPERTIES
from ledger.queue import drain


APP = os.environ.get("DST_APP", "ledger")
ACCEPTED = 202 if APP == "celery" else 200
AMOUNT_MAX = 200
ATTEMPTS = 4
CHECKPOINTS_MAX = 1 << 20
CHECKPOINT_INTERVAL_MS = int(os.environ.get("DST_CHECKPOINT_MS", "0"))
CONNECT_ATTEMPTS = 200
ENDPOINT = "/enqueue" if APP == "celery" else "/transfer"
EVENTUALLY_HOOK = "/opt/project/harness/eventually"
HEADERS = types.MappingProxyType({"Content-Type": "application/json"})
POSTGRES_SOCKET = "/var/run/postgresql"
RETRY_INTERVAL = 0.1
SERVER_ERROR = 500
SETTLE_CHECKPOINTS = 4
THREADS = 4
TRANSFERS_MAX = 50
WORKLOAD_DEADLINE_NS = 10_000_000_000


class Tally:
    def __init__(self):
        self.counts = collections.Counter()
        self.lock = threading.Lock()

    def count(self, outcome):
        with self.lock:
            self.counts[outcome] += 1

    def render(self):
        names = (
            "acknowledged",
            "rejected",
            "abandoned",
            "retries",
            "checkpoints",
            "checkpoints_failed",
        )

        with self.lock:
            return " ".join(f"{name}={self.counts[name]}" for name in names)


def _checkpoint(connection):
    if connection is None:
        connection = psycopg2.connect(dbname="postgres", host=POSTGRES_SOCKET, user="postgres")
        connection.autocommit = True

    connection.cursor().execute("CHECKPOINT")

    return connection


def _checkpoints_run(stop, tally):
    connection = None

    for _ in range(CHECKPOINTS_MAX):
        if stop.wait(CHECKPOINT_INTERVAL_MS / 1000):
            return

        try:
            connection = _checkpoint(connection)
        except psycopg2.Error:
            connection = None

            tally.count("checkpoints_failed")
        else:
            tally.count("checkpoints")

    message = f"the checkpointer ran past {CHECKPOINTS_MAX} checkpoints"
    raise RuntimeError(message)


def _connection():
    return http.client.HTTPConnection("127.0.0.1", 8000, timeout=60)


def _server_wait():
    for _ in range(CONNECT_ATTEMPTS):
        connection = _connection()

        try:
            connection.connect()
        except OSError:
            time.sleep(0.05)
        else:
            return
        finally:
            connection.close()

    raise RuntimeError("gunicorn did not accept connections")


def _transfer_post(body):
    connection = _connection()

    try:
        connection.request("POST", ENDPOINT, body, HEADERS)
        response = connection.getresponse()

        response.read()
    except (OSError, http.client.HTTPException):
        status = None
    else:
        status = response.status
    finally:
        connection.close()

    return status


def _transfer_send(body, transfer_id, deadline_ns, tally):
    for attempt in range(ATTEMPTS):
        if time.monotonic_ns() >= deadline_ns:
            break

        status = _transfer_post(body)

        if status == ACCEPTED:
            dst.ack(transfer_id)
            tally.count("acknowledged")

            return

        if status is not None:
            if status < SERVER_ERROR:
                tally.count("rejected")

                return

        tally.count("retries")
        time.sleep(RETRY_INTERVAL * (attempt + 1))

    tally.count("abandoned")


def _transfers_run(count, deadline_ns, tally):
    for _ in range(count):
        source = dst.choice(ACCOUNT_NAMES)
        target = dst.choice([name for name in ACCOUNT_NAMES if name != source])
        amount = 1 + dst.below(AMOUNT_MAX)
        transfer_id = uuid.uuid4()

        body = json.dumps(
            {
                "amount": amount,
                "id": str(transfer_id),
                "source": source,
                "target": target,
            }
        )

        _transfer_send(body, transfer_id, deadline_ns, tally)


def _uptime():
    with open("/proc/uptime") as uptime:
        return uptime.read().split()[0]


def _eventually_run():
    if not dst.quiet_wait():
        dst.console("DST EVENTUALLY UNREACHED the agent never reported quiet")

        return

    subprocess.run([EVENTUALLY_HOOK], check=False)


def main():
    phase = dst.eventually_ns() > 0
    properties = PROPERTIES + (("always", EVENTUALLY),) if phase else PROPERTIES

    _server_wait()
    dst.declare(properties)

    run_seed = dst.ready()
    deadline_ns = time.monotonic_ns() + WORKLOAD_DEADLINE_NS
    tally = Tally()
    counts = [dst.below(TRANSFERS_MAX + 1) for _ in range(THREADS)]

    threads = [
        threading.Thread(target=_transfers_run, args=(count, deadline_ns, tally))
        for count in counts
    ]

    dst.console(f"DST WORKLOAD SEED {run_seed} TRANSFERS {sum(counts)} UPTIME {_uptime()}")

    stop = threading.Event()
    checkpointer = threading.Thread(target=_checkpoints_run, args=(stop, tally))

    if CHECKPOINT_INTERVAL_MS > 0:
        checkpointer.start()

    for thread in threads:
        thread.start()

    for thread in threads:
        thread.join()

    if APP == "celery":
        dst.console(f"DST QUEUE DRAINED {drain()}")

    if CHECKPOINT_INTERVAL_MS > 0:
        time.sleep(SETTLE_CHECKPOINTS * CHECKPOINT_INTERVAL_MS / 1000)

    stop.set()

    if CHECKPOINT_INTERVAL_MS > 0:
        checkpointer.join()

    dst.console(f"DST WORKLOAD DONE {tally.render()} UPTIME {_uptime()}")

    if phase:
        _eventually_run()

    dst.power_loss()


if __name__ == "__main__":
    main()
