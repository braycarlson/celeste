import fcntl
import json
import os
import threading
import time
import zlib

from dst import agent, ports
from dst.channel import console


ENTROPY_POOL = "/dev/urandom"
KINDS = ("always", "maximize", "reachable", "sometimes", "unreachable")
OOM_SCORE_ADJ = "/proc/self/oom_score_adj"
OOM_SCORE_IMMUNE = -1000
QUIET_MARKER = "/dev/shm/dst-quiet"
QUIET_POLL = 0.05
QUIET_POLLS_MAX = 12_000
RESEED_CRNG = 0x5207
WORD_BITS = 64

_maxima = {}
_maxima_lock = threading.Lock()
_reported = set()
_reported_lock = threading.Lock()


def _details(details):
    if details is None:
        return ""

    return " | " + json.dumps(details, default=str, sort_keys=True)


def _message(message):
    return " ".join(str(message).split()).replace("|", "/")


def _report(key, line):
    with _reported_lock:
        if key in _reported:
            return

        _reported.add(key)

    console(line)


def ack(identifier):
    console(f"DST ACK {identifier}")


def always(condition, message, details=None):
    outcome = "PASS" if condition else "FAIL"
    suffix = "" if condition else _details(details)

    _report(("always", outcome, message), f"DST ALWAYS {outcome} {_message(message)}{suffix}")


def below(limit):
    if limit <= 0:
        message = f"a draw below {limit} has no value to return"
        raise ValueError(message)

    return (random() * limit) >> WORD_BITS


def boolean():
    return random() >> (WORD_BITS - 1) == 1


def checked():
    console("DST CHECK DONE")


def choice(options):
    if not options:
        message = "a choice needs at least one option"
        raise ValueError(message)

    return options[below(len(options))]


def declare(properties):
    for kind, text in properties:
        if kind not in KINDS:
            message = f"a property kind must be one of {', '.join(KINDS)}, not {kind}"
            raise ValueError(message)

        console(f"DST DECLARE {kind} {_message(text)}")


def entropy_mix(value):
    with open(ENTROPY_POOL, "wb", buffering=0) as pool:
        pool.write(value.to_bytes(8, "little"))
        fcntl.ioctl(pool, RESEED_CRNG)


def eventually(condition, message, details=None):
    outcome = "PASS" if condition else "FAIL"

    always(condition, message, details)
    console(f"DST EVENTUALLY {outcome}")


def eventually_ns():
    return int(os.environ.get("DST_EVENTUALLY_NS", "0"))


def maximize(message, value):
    text = _message(message)

    with _maxima_lock:
        if _maxima.get(text, -1) >= value:
            return

        _maxima[text] = value

    ports.guidance(zlib.crc32(text.encode()), value)


def oom_immune():
    with open(OOM_SCORE_ADJ, "w") as adjustment:
        adjustment.write(str(OOM_SCORE_IMMUNE))


def power_loss():
    ports.control(ports.POWER_LOSS)


def present(identifier):
    console(f"DST PRESENT {identifier}")


def quiet_wait():
    for _ in range(QUIET_POLLS_MAX):
        if os.path.exists(QUIET_MARKER):
            return True

        time.sleep(QUIET_POLL)

    return False


def random():
    return ports.draw()


def reachable(message):
    _report(("reachable", message), f"DST REACHABLE {_message(message)}")


def ready():
    console(f"DST CPUS {len(os.sched_getaffinity(0))}")
    ports.control(ports.READY)

    run_seed = ports.seed()

    entropy_mix(run_seed)
    oom_immune()

    child = os.fork()

    if child == 0:
        agent.main()
        os._exit(0)

    return run_seed


def seed():
    return ports.seed()


def sometimes(condition, message):
    if condition:
        _report(("sometimes", message), f"DST SOMETIMES {_message(message)}")


def unreachable(message, details=None):
    line = f"DST UNREACHABLE {_message(message)}{_details(details)}"

    _report(("unreachable", message), line)
