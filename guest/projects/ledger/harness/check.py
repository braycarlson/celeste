import os

import psycopg2

import dst

from ledger.constants import ACCOUNT_BALANCE, ACCOUNT_NAMES
from ledger.properties import BALANCED, CONSERVED, SOLVENT
from ledger.queue import drain


APP = os.environ.get("DST_APP", "ledger")
BALANCES = "select name, balance from ledger_account order by name"
REJECTIONS = "select id from ledger_rejection order by id"

TRANSFERS = """
    select transfer.id, source.name, target.name, transfer.amount
    from ledger_transfer transfer
    join ledger_account source on source.id = transfer.source_id
    join ledger_account target on target.id = transfer.target_id
    order by transfer.id
"""


def _expected(transfers):
    expected = {name: ACCOUNT_BALANCE for name in ACCOUNT_NAMES}

    for _, source, target, amount in transfers:
        expected[source] -= amount
        expected[target] += amount

    return expected


def _invariants_check(balances, transfers):
    expected = _expected(transfers)
    total = sum(balances.values())
    negative = {name: balance for name, balance in balances.items() if balance < 0}

    unbalanced = {
        name: balances.get(name)
        for name in ACCOUNT_NAMES
        if balances.get(name) != expected[name]
    }

    dst.always(total == ACCOUNT_BALANCE * len(ACCOUNT_NAMES), CONSERVED, {"total": total})
    dst.always(not unbalanced, BALANCED, unbalanced)
    dst.always(not negative, SOLVENT, negative)


def main():
    dst.console("DST CHECK UP")

    if APP == "celery":
        dst.console(f"DST QUEUE DRAINED {drain()}")

    connection = psycopg2.connect(dbname="ledger", host="/var/run/postgresql", user="ledger")
    cursor = connection.cursor()

    cursor.execute(BALANCES)
    balances = dict(cursor.fetchall())

    cursor.execute(TRANSFERS)
    transfers = cursor.fetchall()

    cursor.execute(REJECTIONS)
    rejections = cursor.fetchall()

    for transfer in transfers:
        dst.present(transfer[0])

    for rejection in rejections:
        dst.present(rejection[0])

    _invariants_check(balances, transfers)
    dst.checked()


if __name__ == "__main__":
    main()
