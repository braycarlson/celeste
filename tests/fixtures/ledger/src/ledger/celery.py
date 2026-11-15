import os

from celery import Celery


os.environ.setdefault("DJANGO_SETTINGS_MODULE", "ledger.settings")

app = Celery("ledger", include=["ledger.tasks"])
app.config_from_object("django.conf:settings", namespace="CELERY")
