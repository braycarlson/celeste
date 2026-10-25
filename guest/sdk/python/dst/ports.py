import fcntl
import os
import struct


CONTROL_PORT = 0x505
DIRECTIONS = ("both", "requests", "replies")
DRAW_LATCH = 1
DRAW_LOCK = "/dev/shm/dst-draw"
DRAW_PORT = 0x5E0
EVENT_DUE = 5
EVENT_FIELDS = (
    ("magic", "Q"),
    ("kind", "Q"),
    ("delay_ns", "Q"),
    ("duration_ns", "Q"),
    ("target", "Q"),
    ("choice", "Q"),
    ("restart", "Q"),
    ("restart_delay_ns", "Q"),
    ("clock_jump_ns", "q"),
    ("clock_slew_ppm", "q"),
    ("disk_full_slack_kib", "Q"),
    ("memory_immune", "Q"),
    ("memory_kills", "Q"),
    ("network_delay_ns", "Q"),
    ("network_direction", "Q"),
    ("network_jitter_ns", "Q"),
    ("network_link", "Q"),
    ("network_loss_permille", "Q"),
    ("network_peers", "Q"),
    ("network_reorder_permille", "Q"),
    ("pause_tree", "Q"),
    ("thread_choice", "Q"),
    ("throttle_permille", "Q"),
)
EVENT_FORMAT = "<" + "".join(code for _, code in EVENT_FIELDS)
EVENT_KINDS = (
    "none",
    "clock_jump",
    "clock_slew",
    "disk_full",
    "kill",
    "memory",
    "network",
    "pause",
    "thread_pause",
    "throttle",
)
EVENT_MAGIC = 0x31544E5645545344
EVENT_PORT = 0x510
EVENT_WAIT = 3
GUIDANCE_PORT = 0x5F4
KILL_TARGETS = (
    "none",
    "celery_worker",
    "gunicorn_worker",
    "postgres_backend",
    "postmaster",
    "rabbitmq",
    "redis_server",
    "workload",
    "containerd",
    "dockerd",
)
LINKS = ("none", "postgres", "rabbitmq", "redis")
PORT_PATH = "/dev/port"
POWER_LOSS = 1
QUIET = 4
READY = 2
SEED_PORT = 0x508
WORD_BYTES = 8


def _event_read(command):
    raw = _exchange(CONTROL_PORT, command, EVENT_PORT, struct.calcsize(EVENT_FORMAT))
    values = struct.unpack(EVENT_FORMAT, raw)
    fields = dict(zip((name for name, _ in EVENT_FIELDS), values))

    if fields["magic"] != EVENT_MAGIC:
        message = f"the event ports read magic {fields['magic']:#x}, not {EVENT_MAGIC:#x}"
        raise RuntimeError(message)

    fields["kind"] = EVENT_KINDS[fields["kind"]]
    fields["target"] = KILL_TARGETS[fields["target"]]
    fields["network_direction"] = DIRECTIONS[fields["network_direction"]]
    fields["network_link"] = LINKS[fields["network_link"]]

    return fields


def _exchange(command_port, command, read_port, length):
    lock = os.open(DRAW_LOCK, os.O_RDWR | os.O_CREAT, 0o666)

    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        port = os.open(PORT_PATH, os.O_RDWR)

        try:
            os.pwrite(port, bytes([command]), command_port)
            raw = os.pread(port, length, read_port)
        finally:
            os.close(port)
    finally:
        os.close(lock)

    return raw


def _read(port, length):
    with open(PORT_PATH, "rb", buffering=0) as ports:
        ports.seek(port)

        return ports.read(length)


def _write_locked(port_first, raw):
    lock = os.open(DRAW_LOCK, os.O_RDWR | os.O_CREAT, 0o666)

    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        port = os.open(PORT_PATH, os.O_WRONLY)

        try:
            os.pwrite(port, raw, port_first)
        finally:
            os.close(port)
    finally:
        os.close(lock)


def control(command):
    with open(PORT_PATH, "r+b", buffering=0) as ports:
        ports.seek(CONTROL_PORT)
        ports.write(bytes([command]))


def draw():
    raw = _exchange(DRAW_PORT, DRAW_LATCH, DRAW_PORT + 1, WORD_BYTES)
    return int.from_bytes(raw, "little")


def event():
    return _event_read(EVENT_DUE)


def event_render(fields):
    return " ".join(f"{name}={fields[name]}" for name, _ in EVENT_FIELDS[1:])


def event_wait():
    return _event_read(EVENT_WAIT)["delay_ns"]


def guidance(crc, value):
    raw = crc.to_bytes(4, "little") + value.to_bytes(WORD_BYTES, "little")

    _write_locked(GUIDANCE_PORT, raw)


def seed():
    return int.from_bytes(_read(SEED_PORT, WORD_BYTES), "little")
