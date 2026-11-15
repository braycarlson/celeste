import types
import uuid

from django.conf import settings
from django.db import DatabaseError

from ledger.celery import app
from ledger.transfers import transfer_apply


RETRY_BACKOFF_MAX = 8
RETRY_LIMIT = 16

RETRY_OPTIONS = types.MappingProxyType(
    {
        "autoretry_for": (DatabaseError,),
        "max_retries": RETRY_LIMIT,
        "retry_backoff": 1,
        "retry_backoff_max": RETRY_BACKOFF_MAX,
        "retry_jitter": False,
    }
)

TASK_OPTIONS = RETRY_OPTIONS if settings.LEDGER_TASK_RETRY else types.MappingProxyType({})


@app.task(name="ledger.transfer", **TASK_OPTIONS)
def transfer_task(transfer_id, source_name, target_name, amount):
    return transfer_apply(uuid.UUID(transfer_id), source_name, target_name, amount)
