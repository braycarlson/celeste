import http.client
import json
import os
import time
import types
import uuid

import psycopg2

import dst

from ledger.properties import EVENTUALLY


APP = os.environ.get("DST_APP", "ledger")
ACCEPTED = 202 if APP == "celery" else 200
APPLIED = """
    select id from ledger_transfer where id = any(%s::uuid[])
    union
    select id from ledger_rejection where id = any(%s::uuid[])
"""
CONFLICT = 409
ENDPOINT = "/enqueue" if APP == "celery" else "/transfer"
HEADERS = types.MappingProxyType({"Content-Type": "application/json"})
POLL_INTERVAL = 0.05
POSTGRES_SOCKET = "/var/run/postgresql"
REQUESTS = 8
RETRY_INTERVAL = 0.1


def _applied(identifiers):
    connection = psycopg2.connect(dbname="ledger", host=POSTGRES_SOCKET, user="ledger")

    try:
        cursor = connection.cursor()

        cursor.execute(APPLIED, (identifiers, identifiers))
        found = {str(row[0]) for row in cursor.fetchall()}
    finally:
        connection.close()

    return found


def _post(body):
    connection = http.client.HTTPConnection("127.0.0.1", 8000, timeout=10)

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


def _send(identifier, deadline_ns):
    transfer = {"amount": 1, "id": identifier, "source": "account-0", "target": "account-1"}
    body = json.dumps(transfer)

    while time.monotonic_ns() < deadline_ns:
        status = _post(body)

        if status == ACCEPTED:
            dst.ack(identifier)

            return True

        if status == CONFLICT:
            return True

        time.sleep(RETRY_INTERVAL)

    return False


def _settled(identifiers, deadline_ns):
    while time.monotonic_ns() < deadline_ns:
        try:
            found = _applied(identifiers)
        except psycopg2.Error:
            found = set()

        if found >= set(identifiers):
            return True

        time.sleep(POLL_INTERVAL)

    return False


def main():
    deadline_ns = time.monotonic_ns() + dst.eventually_ns()
    identifiers = [str(uuid.uuid4()) for _ in range(REQUESTS)]
    sent = sum(1 for identifier in identifiers if _send(identifier, deadline_ns))
    settled = APP != "celery" or _settled(identifiers, deadline_ns)
    details = {"sent": sent, "settled": settled}

    dst.eventually(sent == REQUESTS and settled, EVENTUALLY, details)


if __name__ == "__main__":
    main()
