import contextlib
import os
import time

import redis

import dst

from django.conf import settings
from django.db import transaction

from ledger.models import Account, Rejection, Transfer
from ledger.properties import LEASE_LOST, REJECTED, REPEATED


APPLIED = "applied"
DUPLICATE = "duplicate"
INSUFFICIENT = "insufficient"
LOCK_WAIT = 30
LOCKING_NONE = "0"
LOCKING_REDIS = "redis"

_spun = set()


def _accounts_load(names):
    accounts = Account.objects.filter(name__in=names).order_by("name")

    if settings.LEDGER_LOCKING not in (LOCKING_NONE, LOCKING_REDIS):
        accounts = accounts.select_for_update()

    return {account.name: account for account in accounts}


def _critical_spin(iterations):
    if iterations == 0:
        return

    if os.getpid() in _spun:
        return

    _spun.add(os.getpid())
    start_ns = time.monotonic_ns()

    for _ in range(iterations):
        pass

    dst.console(f"DST CRITICAL SPIN {iterations} took {time.monotonic_ns() - start_ns} ns")


def _lease_release(lock, name):
    try:
        lock.release()
    except redis.exceptions.LockNotOwnedError:
        dst.unreachable(LEASE_LOST, {"account": name})


@contextlib.contextmanager
def _locks_held(names):
    if settings.LEDGER_LOCKING != LOCKING_REDIS:
        yield

        return

    client = redis.Redis(host=settings.REDIS_HOST, socket_connect_timeout=5, socket_timeout=5)

    with contextlib.ExitStack() as stack:
        for name in sorted(names):
            lock = client.lock(
                f"ledger:account:{name}",
                timeout=settings.LEDGER_LEASE_MS / 1000,
                blocking_timeout=LOCK_WAIT,
            )

            if not lock.acquire():
                message = f"the lock on {name} stayed taken for {LOCK_WAIT} s"
                raise RuntimeError(message)

            stack.callback(_lease_release, lock, name)

        yield


def _transfer_apply_locked(transfer_id, source_name, target_name, amount):
    with transaction.atomic():
        repeated = (
            Transfer.objects.filter(id=transfer_id).exists()
            or Rejection.objects.filter(id=transfer_id).exists()
        )

        if repeated:
            dst.reachable(REPEATED)

            return DUPLICATE

        names = [source_name, target_name]
        accounts = _accounts_load(names)
        source = accounts[source_name]
        target = accounts[target_name]
        rejected = source.balance < amount

        dst.sometimes(rejected, REJECTED)

        if rejected:
            Rejection.objects.create(id=transfer_id, reason=INSUFFICIENT)

            return INSUFFICIENT

        time.sleep(settings.LEDGER_CRITICAL_MS / 1000)
        _critical_spin(settings.LEDGER_CRITICAL_SPIN)

        source.balance -= amount
        target.balance += amount

        source.save(update_fields=["balance"])
        target.save(update_fields=["balance"])
        Transfer.objects.create(amount=amount, id=transfer_id, source=source, target=target)

    return APPLIED


def transfer_apply(transfer_id, source_name, target_name, amount):
    names = [source_name, target_name]

    with _locks_held(names):
        return _transfer_apply_locked(transfer_id, source_name, target_name, amount)
