import os


ALLOWED_HOSTS = ("127.0.0.1", "localhost")
BROKER_TIMEOUT = float(os.environ.get("DST_BROKER_TIMEOUT", "0"))
BROKER_TIMEOUTS = {"socket_timeout": BROKER_TIMEOUT} if BROKER_TIMEOUT > 0 else {}
CELERY_BROKER_CONNECTION_RETRY_ON_STARTUP = True
CELERY_BROKER_TRANSPORT_OPTIONS = {"visibility_timeout": 10, **BROKER_TIMEOUTS}
CELERY_BROKER_URL = f"redis://{os.environ.get('DST_HOST_REDIS', '127.0.0.1')}:6379/0"
CELERY_TASK_ACKS_LATE = os.environ.get("DST_ACKS_LATE", "0") == "1"
CELERY_TASK_REJECT_ON_WORKER_LOST = os.environ.get("DST_REJECT_LOST", "0") == "1"
CELERY_WORKER_HIJACK_ROOT_LOGGER = False
CELERY_WORKER_PREFETCH_MULTIPLIER = 1
DATABASE_HOST = os.environ.get("DST_HOST_POSTGRES", "")
DATABASE_TCP = DATABASE_HOST != "" or os.environ.get("DST_PG", "socket") == "tcp"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "HOST": DATABASE_HOST or ("127.0.0.1" if DATABASE_TCP else "/var/run/postgresql"),
        "NAME": "ledger",
        "OPTIONS": {"connect_timeout": 5, "tcp_user_timeout": 5000} if DATABASE_TCP else {},
        "USER": "ledger",
    },
}

DEBUG = False
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
INSTALLED_APPS = ("ledger",)
LEDGER_APP = os.environ.get("DST_APP", "ledger")
LEDGER_CRITICAL_MS = int(os.environ.get("DST_CRITICAL_MS", "0"))
LEDGER_CRITICAL_SPIN = int(os.environ.get("DST_CRITICAL_SPIN", "0"))
LEDGER_LEASE_MS = int(os.environ.get("DST_LEASE_MS", "5000"))
LEDGER_LOCKING = os.environ.get("DST_LOCKING", "row")
LEDGER_TASK_RETRY = os.environ.get("DST_TASK_RETRY", "0") == "1"
MIDDLEWARE = ()
REDIS_HOST = os.environ.get("DST_HOST_REDIS", "127.0.0.1")
ROOT_URLCONF = "ledger.urls_queue" if LEDGER_APP == "celery" else "ledger.urls"
SECRET_KEY = "dst"
TIME_ZONE = "UTC"
USE_TZ = True
WSGI_APPLICATION = "ledger.wsgi.application"
