import os

import psycopg2

import celeste

from ledger.constants import ACCOUNT_BALANCE, ACCOUNT_NAMES
from ledger.properties import BALANCED, CONSERVED, SOLVENT
from ledger.queue import drain


APP = os.environ.get("CELESTE_APP", "ledger")
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

    celeste.always(total == ACCOUNT_BALANCE * len(ACCOUNT_NAMES), CONSERVED, details={"total": total})
    celeste.always(not unbalanced, BALANCED, details=unbalanced)
    celeste.always(not negative, SOLVENT, details=negative)


def main():
    celeste.note("check up")

    if APP == "celery":
        celeste.note(f"queue drained {drain()}")

    connection = psycopg2.connect(dbname="ledger", host="/var/run/postgresql", user="ledger")
    cursor = connection.cursor()

    cursor.execute(BALANCES)
    balances = dict(cursor.fetchall())

    cursor.execute(TRANSFERS)
    transfers = cursor.fetchall()

    cursor.execute(REJECTIONS)
    rejections = cursor.fetchall()

    for transfer in transfers:
        celeste.present(str(transfer[0]))

    for rejection in rejections:
        celeste.present(str(rejection[0]))

    _invariants_check(balances, transfers)
    celeste.checked()


if __name__ == "__main__":
    main()
