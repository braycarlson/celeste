import ctypes
import functools
import heapq
import mmap
import os
import signal
import socket
import struct
import subprocess
import threading
import time
import types

from dst import ports
from dst.channel import CONSOLE, console


AGENT_ERRORS = (
    IndexError,
    KeyError,
    OSError,
    RuntimeError,
    ValueError,
    struct.error,
    subprocess.SubprocessError,
)
CELERY_PID = "/run/celery.pid"
CGROUP_NODES = "/sys/fs/cgroup/dst"
CGROUP_ROOT = "/sys/fs/cgroup"
CPU_PERIOD_US = 100_000
CPU_QUOTA_US_MIN = 1000
DIRECTION_BANDS = types.MappingProxyType({"both": (0, 1), "requests": (0,), "replies": (1,)})
DIRECTION_SIDES = types.MappingProxyType(
    {
        "both": ("requests", "replies"),
        "requests": ("requests",),
        "replies": ("replies",),
    }
)
FILLER = "/var/lib/dst-filler"
FILTER_PRIO_BASE = 2
FREEZE_POLL_INTERVAL = 0.005
FREEZE_POLLS = 200
GUNICORN_PID = "/run/gunicorn.pid"
HOST_ADDRESS = "10.77.0.1"
IDLE_INTERVAL = 3600
IDLE_INTERVALS_MAX = 24 * 365
KERNEL_PATTERNS = (
    "Aborting journal",
    "Buffer I/O error",
    "EXT4-fs error",
    "I/O error",
    "Killed process",
    "Out of memory",
    "Remounting filesystem read-only",
    "invoked oom-killer",
)
KILL_ATTEMPTS = 8
KMSG = "/dev/kmsg"
KMSG_RECORD_MAX = 8192
KMSG_RECORDS_MAX = 1 << 24
LINK_BANDS = types.MappingProxyType({"postgres": (4, 5), "rabbitmq": (6, 7), "redis": (8, 9)})
LINK_PORTS = types.MappingProxyType({"postgres": 5432, "rabbitmq": 5672, "redis": 6379})
LINK_SERVICES = types.MappingProxyType(
    {"postgres": "POSTGRES", "rabbitmq": "RABBITMQ", "redis": "REDIS"}
)
MEMINFO = "/proc/meminfo"
MADV_POPULATE_WRITE = 23
MEMORY_CHUNK = 2 << 20
MEMORY_FLOOR = 32 << 20
NETEM_BANDS = "9"
NETEM_CLEAN = ("limit", "10000")
NETEM_LIMIT = "10000"
NODE_PRIOMAP = ("0",) * 16
OOM_SCORE_ADJ = "/proc/self/oom_score_adj"
OOM_SCORE_IMMUNE = "-1000"
OOM_SCORE_PREFERRED = "1000"
PERMILLE = 1000
POSTGRES_CLIENTS = ("[local]", "127.0.0.1(", f"{HOST_ADDRESS}(")
POSTMASTER_PID = "/var/lib/postgresql/17/main/postmaster.pid"
PROGRESS = "/run/dst/progress"
PTRACE_DETACH = 17
PTRACE_INTERRUPT = 0x4207
PTRACE_SEIZE = 0x4206
QUIET_MARKER = "/dev/shm/dst-quiet"
RESTART_SERVICES = types.MappingProxyType(
    {"postmaster": "postgres", "rabbitmq": "rabbitmq", "redis_server": "redis"}
)
SERVICE = "/opt/sdk/service"
SLEW_STEP_NS = 10_000_000
TARGET_SERVICES = types.MappingProxyType(
    {
        "postgres_backend": "POSTGRES",
        "postmaster": "POSTGRES",
        "rabbitmq": "RABBITMQ",
        "redis_server": "REDIS",
    }
)
TREE_ROOTS = types.MappingProxyType(
    {
        "celery_worker": CELERY_PID,
        "gunicorn_worker": GUNICORN_PID,
        "postgres_backend": POSTMASTER_PID,
    }
)
VMSTAT = "/proc/vmstat"
WAIT_ALL = 0x40000000


class Agent:
    def __init__(self):
        self.actions = []
        self.bands = {band: [] for pair in LINK_BANDS.values() for band in pair}
        self.heals = {}
        self.network_ready = False
        self.node_devices = set()
        self.node_freezes = {}
        self.node_quotas = {}
        self.node_stacks = {}
        self.sequence = 0

    def add(self, due_ns, action):
        heapq.heappush(self.actions, (due_ns, self.sequence, action))
        self.sequence += 1

    def key(self):
        self.sequence += 1
        return self.sequence


def _action_name(action):
    return getattr(action, "func", action).__name__


def _ask(agent):
    delay_ns = ports.event_wait()

    agent.add(time.monotonic_ns() + delay_ns, _due)


def _band_drops(band):
    completed = subprocess.run(
        ["tc", "-s", "qdisc", "show", "dev", "lo"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    lines = completed.stdout.decode().splitlines()
    header = f"qdisc netem {band}0:"

    for index, line in enumerate(lines[:-1]):
        if line.startswith(header):
            return int(lines[index + 1].split("dropped ")[1].split(",")[0])

    return 0


def _children(parent):
    return [pid for pid, ppid, _ in _processes() if ppid == parent]


def _clock_jump(jump_ns):
    realtime_ns = time.clock_gettime_ns(time.CLOCK_REALTIME)

    time.clock_settime_ns(time.CLOCK_REALTIME, realtime_ns + jump_ns)
    console(f"DST FAULT clock jump {jump_ns} ns")


def _clock_slew(ppm, key, agent):
    if key not in agent.heals:
        return

    realtime_ns = time.clock_gettime_ns(time.CLOCK_REALTIME)
    step = functools.partial(_clock_slew, ppm, key)

    time.clock_settime_ns(time.CLOCK_REALTIME, realtime_ns + SLEW_STEP_NS * ppm // 1_000_000)
    agent.add(time.monotonic_ns() + SLEW_STEP_NS, step)


def _clock_slew_end(agent):
    console("DST FAULT clock slew end")


def _clock_slew_start(event, agent):
    key = agent.key()

    console(f"DST FAULT clock slew {event['clock_slew_ppm']} ppm")
    _heal_register(agent, key, _clock_slew_end, event["duration_ns"])
    _clock_slew(event["clock_slew_ppm"], key, agent)


def _disk_full(slack_kib, agent):
    stats = os.statvfs("/")
    size = stats.f_bavail * stats.f_frsize - slack_kib * 1024
    outcome = "filled"

    if size > 0:
        descriptor = os.open(FILLER, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

        try:
            os.posix_fallocate(descriptor, 0, size)
        except OSError as error:
            outcome = f"partly filled ({error.strerror})"
        finally:
            os.close(descriptor)

    after = os.statvfs("/")
    available = after.f_bavail * after.f_frsize

    console(f"DST FAULT disk full {outcome} asking {max(size, 0)} leaving {available}")
    agent.heals[agent.key()] = _disk_full_end


def _disk_full_end(agent):
    try:
        os.unlink(FILLER)
    except FileNotFoundError:
        console("DST FAULT disk full end, the filler was already gone")
    else:
        console("DST FAULT disk full end")


def _due(agent):
    event = ports.event()

    if event["kind"] == "none":
        if _eventually():
            agent.add(time.monotonic_ns() + event["delay_ns"], _heal_all)

        return

    console(f"DST EVENT {ports.event_render(event)} END")
    _event_run(event, agent)


def _event_apply(event, agent):
    kind = event["kind"]

    match kind:
        case "clock_jump":
            _clock_jump(event["clock_jump_ns"])
        case "clock_slew":
            _clock_slew_start(event, agent)
        case "disk_full":
            _disk_full(event["disk_full_slack_kib"], agent)
        case "kill":
            _kill(event, agent)
        case "memory":
            _memory_hog(event, agent)
        case "network":
            _network(event, agent)
        case "pause":
            _pause(event, agent)
        case "thread_pause":
            _thread_pause(event, agent)
        case "throttle":
            _throttle(event, agent)
        case _:
            message = f"the event names an unknown kind {kind}"
            raise RuntimeError(message)


def _event_run(event, agent):
    try:
        _event_apply(event, agent)
    except OSError as error:
        console(f"DST FAULT unavailable {event['kind']}: {error}")

    agent.add(time.monotonic_ns(), _ask)


def _eventually():
    return int(os.environ.get("DST_EVENTUALLY_NS", "0")) > 0


def _heal_all(agent):
    if agent.network_ready:
        _tc(["tc", "qdisc", "del", "dev", "lo", "root"])
        agent.network_ready = False
        agent.bands = {band: [] for band in agent.bands}

    for node, side in sorted(agent.node_devices):
        tc, device = _node_device(node, side)

        _tc(tc + ["qdisc", "del", "dev", device, "root"])

    agent.node_devices = set()
    agent.node_stacks = {}

    for key in sorted(agent.heals):
        _heal_run(key, agent)

    ports.control(ports.QUIET)

    with open(QUIET_MARKER, "w"):
        pass

    console("DST QUIET")


def _heal_register(agent, key, heal, duration_ns):
    agent.heals[key] = heal

    agent.add(time.monotonic_ns() + duration_ns, functools.partial(_heal_run, key))


def _heal_run(key, agent):
    heal = agent.heals.pop(key, None)

    if heal is not None:
        heal(agent)


def _idle():
    for _ in range(IDLE_INTERVALS_MAX):
        time.sleep(IDLE_INTERVAL)

    message = f"the agent idled past {IDLE_INTERVALS_MAX} intervals of {IDLE_INTERVAL} s"
    raise RuntimeError(message)


def _kernel_forward():
    descriptor = os.open(KMSG, os.O_RDONLY)

    os.lseek(descriptor, 0, os.SEEK_END)

    for _ in range(KMSG_RECORDS_MAX):
        try:
            record = os.read(descriptor, KMSG_RECORD_MAX).decode(errors="replace")
        except BrokenPipeError:
            continue

        message = record.partition(";")[2].partition("\n")[0]

        if any(pattern in message for pattern in KERNEL_PATTERNS):
            console(f"DST KERNEL {message}")

    message = f"the kernel log forwarded more than {KMSG_RECORDS_MAX} records"
    raise RuntimeError(message)


def _kill(event, agent):
    target = event["target"]
    node = _target_node(target)

    if node:
        _node_kill(event, node, agent)

        return

    killed = False

    for _ in range(KILL_ATTEMPTS):
        pids = _targets(target)

        if not pids:
            console(f"DST FAULT kill {target} absent")

            return

        killed = _kill_pid(target, pids[event["choice"] % len(pids)])

        if killed:
            break

    _restart_register(event, target, killed, agent)


def _kill_pid(target, pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        console(f"DST FAULT kill {target} pid {pid} already gone")

        return False

    console(f"DST FAULT kill {target} pid {pid}")

    return True


def _meminfo(name):
    with open(MEMINFO) as meminfo:
        for line in meminfo:
            key, _, value = line.partition(":")

            if key == name:
                return int(value.split()[0]) * 1024

    message = f"{name} is missing from {MEMINFO}"
    raise RuntimeError(message)


def _memory_chunk():
    chunk = mmap.mmap(-1, MEMORY_CHUNK, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)

    chunk.madvise(mmap.MADV_HUGEPAGE)
    chunk.madvise(MADV_POPULATE_WRITE)

    return chunk


def _memory_end(pid, agent):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

    os.waitpid(pid, 0)
    console(f"DST FAULT memory hog pid {pid} end")


def _memory_full(event, kills_start):
    if not event["memory_immune"]:
        return False

    if event["memory_kills"] == 0:
        return _meminfo("MemAvailable") <= MEMORY_FLOOR

    return _oom_kills() - kills_start >= event["memory_kills"]


def _memory_hog(event, agent):
    child = os.fork()

    if child == 0:
        try:
            _memory_hold(event)
        finally:
            os._exit(0)

    console(f"DST FAULT memory hog pid {child}")
    agent.heals[agent.key()] = functools.partial(_memory_end, child)


def _memory_hold(event):
    adjustment = OOM_SCORE_IMMUNE if event["memory_immune"] else OOM_SCORE_PREFERRED

    with open(OOM_SCORE_ADJ, "w") as score:
        score.write(adjustment)

    kills_start = _oom_kills()
    chunks = []

    for _ in range(_meminfo("MemTotal") // MEMORY_CHUNK + 1):
        if _memory_full(event, kills_start):
            break

        try:
            chunk = _memory_chunk()
        except OSError:
            break

        chunks.append(chunk)

    held = len(chunks) * MEMORY_CHUNK
    kills = _oom_kills() - kills_start

    console(f"DST FAULT memory hog holding {held} after {kills} kills")
    time.sleep(event["duration_ns"] / 1e9)


def _netem_apply(band, arguments):
    change = ["tc", "qdisc", "change", "dev", "lo", "parent", f"1:{band}", "handle", f"{band}0:"]

    _tc(change + ["netem"] + arguments)


def _netem_arguments(event):
    arguments = ["limit", NETEM_LIMIT]

    if event["network_delay_ns"] > 0:
        arguments += ["delay", f"{max(1, event['network_delay_ns'] // 1000)}us"]

        if event["network_jitter_ns"] > 0:
            arguments.append(f"{max(1, event['network_jitter_ns'] // 1000)}us")

    if event["network_loss_permille"] > 0:
        arguments += ["loss", f"{event['network_loss_permille'] / 10}%"]

    if event["network_reorder_permille"] > 0:
        arguments += ["reorder", f"{event['network_reorder_permille'] / 10}%"]

    return arguments


def _network(event, agent):
    link = event["network_link"]
    node = _node(LINK_SERVICES[link])

    if node:
        _node_network(event, node, agent)

        return

    direction = event["network_direction"]
    bands = [LINK_BANDS[link][side] for side in DIRECTION_BANDS[direction]]
    arguments = _netem_arguments(event)
    key = agent.key()

    if not agent.network_ready:
        _network_setup()
        agent.network_ready = True

    for band in bands:
        agent.bands[band].append((key, arguments))
        _netem_apply(band, arguments)

    name = _network_name(event)

    console(f"DST FAULT network {name} start {link} {direction} netem {' '.join(arguments)}")

    end = functools.partial(_network_end, event, key, bands)

    agent.add(time.monotonic_ns() + event["duration_ns"], end)


def _network_end(event, key, bands, agent):
    if not agent.network_ready:
        return

    for band in bands:
        active = [entry for entry in agent.bands[band] if entry[0] != key]
        arguments = active[-1][1] if active else list(NETEM_CLEAN)
        agent.bands[band] = active

        _netem_apply(band, arguments)

    link = event["network_link"]
    direction = event["network_direction"]
    requests_band, replies_band = LINK_BANDS[link]
    drops = f"dropped requests {_band_drops(requests_band)} replies {_band_drops(replies_band)}"

    console(f"DST FAULT network {_network_name(event)} end {link} {direction} {drops}")


def _network_name(event):
    return "partition" if event["network_loss_permille"] == PERMILLE else "impairment"


def _network_setup():
    root = ["tc", "qdisc", "add", "dev", "lo", "root", "handle", "1:", "prio", "bands", NETEM_BANDS]
    match = ["tc", "filter", "add", "dev", "lo", "parent", "1:", "protocol", "ip", "prio", "1"]

    _tc(root)

    for link, bands in LINK_BANDS.items():
        port = str(LINK_PORTS[link])

        for band, field in zip(bands, ("dport", "sport")):
            parent = ["parent", f"1:{band}", "handle", f"{band}0:"]
            netem = ["tc", "qdisc", "add", "dev", "lo"] + parent

            _tc(netem + ["netem", *NETEM_CLEAN])
            _tc(match + ["u32", "match", "ip", field, port, "0xffff", "flowid", f"1:{band}"])


def _node(service):
    return os.environ.get(f"DST_NODE_{service}", "")


def _node_device(node, side):
    if side == "requests":
        return ["tc"], f"veth-{node}"

    return ["tc", "-n", node], "eth0"


def _node_device_setup(node, side, agent):
    if (node, side) in agent.node_devices:
        return

    tc, device = _node_device(node, side)
    add = tc + ["qdisc", "add", "dev", device]
    prio = ["root", "handle", "1:", "prio", "bands", "2", "priomap", *NODE_PRIOMAP]
    drop = ["parent", "1:2", "handle", "20:", "netem", "limit", NETEM_LIMIT, "loss", "100%"]

    _tc(add + prio)
    _tc(add + ["parent", "1:1", "handle", "10:", "netem", *NETEM_CLEAN])
    _tc(add + drop)
    agent.node_devices.add((node, side))
    agent.node_stacks[(node, side)] = []


def _node_filters_add(node, side, key, peers):
    tc, device = _node_device(node, side)
    field = "src" if side == "requests" else "dst"
    prio = ["parent", "1:", "protocol", "ip", "prio", str(FILTER_PRIO_BASE + key), "u32"]
    add = tc + ["filter", "add", "dev", device] + prio

    if peers is None:
        _tc(add + ["match", "u32", "0", "0", "flowid", "1:2"])

        return

    for address in peers:
        _tc(add + ["match", "ip", field, f"{address}/32", "flowid", "1:2"])


def _node_filters_delete(node, side, key):
    tc, device = _node_device(node, side)
    prio = ["parent", "1:", "protocol", "ip", "prio", str(FILTER_PRIO_BASE + key)]

    _tc(tc + ["filter", "del", "dev", device] + prio)


def _node_frozen(node):
    with open(f"{CGROUP_NODES}/{node}/cgroup.events") as events:
        for line in events:
            key, _, value = line.partition(" ")

            if key == "frozen":
                return value.strip() == "1"

    message = f"cgroup.events of node {node} has no frozen line"
    raise RuntimeError(message)


def _node_frozen_wait(node):
    for _ in range(FREEZE_POLLS):
        if _node_frozen(node):
            return 1

        time.sleep(FREEZE_POLL_INTERVAL)

    return 0


def _node_kill(event, node, agent):
    target = event["target"]
    group = f"{CGROUP_NODES}/{node}"
    members = _read(f"{group}/cgroup.procs").split()

    _write(f"{group}/cgroup.kill", "1")
    console(f"DST FAULT kill node {node} {target} processes {len(members)}")
    _restart_register(event, target, bool(members), agent)


def _node_netem_apply(node, side, arguments):
    tc, device = _node_device(node, side)
    change = ["parent", "1:1", "handle", "10:", "netem"] + arguments

    _tc(tc + ["qdisc", "change", "dev", device] + change)


def _node_network(event, node, agent):
    direction = event["network_direction"]
    partition = event["network_loss_permille"] == PERMILLE
    peers = _node_peers(event["network_peers"], node) if partition else []
    key = agent.key()

    for side in DIRECTION_SIDES[direction]:
        _node_device_setup(node, side, agent)

    if partition:
        for side in DIRECTION_SIDES[direction]:
            _node_filters_add(node, side, key, peers)

        detail = "from all" if peers is None else "from " + (" ".join(peers) or "none")
    else:
        arguments = _netem_arguments(event)

        for side in DIRECTION_SIDES[direction]:
            agent.node_stacks[(node, side)].append((key, arguments))
            _node_netem_apply(node, side, arguments)

        detail = "netem " + " ".join(arguments)

    console(f"DST FAULT network {_network_name(event)} start node {node} {direction} {detail}")

    end = functools.partial(_node_network_end, event, node, key, peers)

    agent.add(time.monotonic_ns() + event["duration_ns"], end)


def _node_network_end(event, node, key, peers, agent):
    direction = event["network_direction"]
    sides = [side for side in DIRECTION_SIDES[direction] if (node, side) in agent.node_devices]

    for side in sides:
        if event["network_loss_permille"] == PERMILLE:
            if peers != []:
                _node_filters_delete(node, side, key)

            continue

        active = [entry for entry in agent.node_stacks[(node, side)] if entry[0] != key]
        arguments = active[-1][1] if active else list(NETEM_CLEAN)
        agent.node_stacks[(node, side)] = active

        _node_netem_apply(node, side, arguments)

    if sides:
        console(f"DST FAULT network {_network_name(event)} end node {node} {direction}")


def _node_pause(event, node, agent):
    freezes = agent.node_freezes.get(node, 0)
    agent.node_freezes[node] = freezes + 1

    if freezes == 0:
        _write(f"{CGROUP_NODES}/{node}/cgroup.freeze", "1")

    frozen = _node_frozen_wait(node)

    console(f"DST FAULT pause node {node} frozen {frozen} progress {_node_progress(node)} start")

    end = functools.partial(_node_pause_end, node)

    _heal_register(agent, agent.key(), end, event["duration_ns"])


def _node_pause_end(node, agent):
    progress = _node_progress(node)
    agent.node_freezes[node] -= 1

    if agent.node_freezes[node] == 0:
        _write(f"{CGROUP_NODES}/{node}/cgroup.freeze", "0")

    console(f"DST FAULT pause node {node} progress {progress} end")


def _node_peers(mask, node):
    if mask == 0:
        return None

    names = ["host"] + os.environ.get("DST_NODES", "").split()
    peers = []

    for bit, name in enumerate(names):
        if not mask & (1 << bit):
            continue

        if name == node:
            continue

        peers.append(HOST_ADDRESS if bit == 0 else socket.gethostbyname(name))

    return peers


def _node_progress(node):
    try:
        return _read(f"{PROGRESS}/{node}").strip() or "none"
    except FileNotFoundError:
        return "none"


def _node_throttle(event, node, agent):
    key = agent.key()
    quota = max(CPU_QUOTA_US_MIN, CPU_PERIOD_US * event["throttle_permille"] // PERMILLE)

    agent.node_quotas.setdefault(node, []).append((key, quota))
    _write(f"{CGROUP_NODES}/{node}/cpu.max", f"{quota} {CPU_PERIOD_US}")
    console(f"DST FAULT throttle node {node} {event['throttle_permille']}/1000 start")

    end = functools.partial(_node_throttle_end, node, key)

    _heal_register(agent, key, end, event["duration_ns"])


def _node_throttle_end(node, key, agent):
    active = [entry for entry in agent.node_quotas[node] if entry[0] != key]
    quota = str(active[-1][1]) if active else "max"
    agent.node_quotas[node] = active

    _write(f"{CGROUP_NODES}/{node}/cpu.max", f"{quota} {CPU_PERIOD_US}")
    console(f"DST FAULT throttle node {node} end")


def _oom_kills():
    with open(VMSTAT) as vmstat:
        for line in vmstat:
            key, _, value = line.partition(" ")

            if key == "oom_kill":
                return int(value)

    message = f"oom_kill is missing from {VMSTAT}"
    raise RuntimeError(message)


def _pause(event, agent):
    target = event["target"]
    node = _target_node(target)

    if node:
        _node_pause(event, node, agent)

        return

    pid = _target_pick(target, event["choice"], "pause")

    if pid is None:
        return

    paused = _tree(target, pid) if event["pause_tree"] else [pid]
    stopped = _signal_all(paused, signal.SIGSTOP)

    console(f"DST FAULT pause {target} pid {pid} processes {stopped} start")

    end = functools.partial(_pause_end, target, pid, paused)

    _heal_register(agent, agent.key(), end, event["duration_ns"])


def _pause_end(target, pid, paused, agent):
    resumed = _signal_all(paused, signal.SIGCONT)

    console(f"DST FAULT pause {target} pid {pid} processes {resumed} end")


def _pid_file(path):
    try:
        with open(path) as pid_file:
            pid = int(pid_file.readline().strip())
    except (OSError, ValueError):
        return None

    if not os.path.exists(f"/proc/{pid}"):
        return None

    return pid


def _processes():
    entries = []

    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue

        try:
            with open(f"/proc/{name}/stat") as stat:
                state = stat.read().rpartition(")")[2].split()

            with open(f"/proc/{name}/cmdline", "rb") as cmdline:
                command = cmdline.read().replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            continue

        entries.append((int(name), int(state[1]), command))

    return sorted(entries)


def _program(command):
    return os.path.basename(command.split(" ")[0])


def _ptrace(request, tid):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.ptrace.argtypes = (ctypes.c_long, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
    libc.ptrace.restype = ctypes.c_long

    if libc.ptrace(request, tid, None, None) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def _read(path):
    with open(path) as source:
        return source.read()


def _restart(target, agent):
    service = RESTART_SERVICES[target]
    output = os.open(CONSOLE, os.O_WRONLY | os.O_NOCTTY)

    try:
        subprocess.Popen(
            [SERVICE, service],
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
        )
    finally:
        os.close(output)

    console(f"DST FAULT restart {target}")


def _restart_register(event, target, stopped, agent):
    restart = functools.partial(_restart, target)

    if event["restart"]:
        _heal_register(agent, agent.key(), restart, event["restart_delay_ns"])

        return

    if not stopped:
        return

    if target in RESTART_SERVICES:
        agent.heals[agent.key()] = restart


def _run(agent):
    while agent.actions:
        due_ns, _, action = heapq.heappop(agent.actions)
        delay_ns = due_ns - time.monotonic_ns()

        if delay_ns > 0:
            time.sleep(delay_ns / 1e9)

        try:
            action(agent)
        except OSError as error:
            console(f"DST FAULT unavailable {_action_name(action)}: {error}")
        except AGENT_ERRORS as error:
            console(f"DST AGENT ERROR {type(error).__name__}: {error}")


def _signal_all(pids, number):
    signaled = 0

    for pid in pids:
        try:
            os.kill(pid, number)
        except ProcessLookupError:
            continue

        signaled += 1

    return signaled


def _target_node(target):
    service = TARGET_SERVICES.get(target)
    return _node(service) if service else ""


def _target_pick(target, choice, action):
    pids = _targets(target)

    if not pids:
        console(f"DST FAULT {action} {target} absent")

        return None

    return pids[choice % len(pids)]


def _targets(target):
    postmaster = _pid_file(POSTMASTER_PID)

    if target == "postmaster":
        return [postmaster] if postmaster else []

    if target == "postgres_backend":
        processes = _processes()
        children = [(pid, command) for pid, ppid, command in processes if ppid == postmaster]

        return [
            pid
            for pid, command in children
            if any(client in command for client in POSTGRES_CLIENTS)
        ]

    if target == "gunicorn_worker":
        master = _pid_file(GUNICORN_PID)
        return _children(master) if master else []

    if target == "celery_worker":
        main = _pid_file(CELERY_PID)
        return _children(main) if main else []

    if target == "rabbitmq":
        return [pid for pid, _, command in _processes() if "-s rabbit" in command]

    if target == "redis_server":
        return [pid for pid, _, command in _processes() if command.startswith("redis-server")]

    if target in ("containerd", "dockerd"):
        return [pid for pid, _, command in _processes() if _program(command) == target]

    if target == "workload":
        return [os.getppid()]

    message = f"the event names an unknown kill target {target}"
    raise RuntimeError(message)


def _tc(arguments):
    completed = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )

    if completed.returncode != 0:
        detail = completed.stderr.decode().strip()
        message = f"{' '.join(arguments)} exited {completed.returncode}: {detail}"

        raise RuntimeError(message)


def _thread_pause(event, agent):
    target = event["target"]
    pid = _target_pick(target, event["choice"], "thread pause")

    if pid is None:
        return

    tids = sorted(int(name) for name in os.listdir(f"/proc/{pid}/task"))
    tid = tids[event["thread_choice"] % len(tids)]

    _ptrace(PTRACE_SEIZE, tid)
    _ptrace(PTRACE_INTERRUPT, tid)
    os.waitpid(tid, WAIT_ALL)
    console(f"DST FAULT thread pause {target} pid {pid} tid {tid} start")

    end = functools.partial(_thread_pause_end, target, pid, tid)

    _heal_register(agent, agent.key(), end, event["duration_ns"])


def _thread_pause_end(target, pid, tid, agent):
    _ptrace(PTRACE_DETACH, tid)
    console(f"DST FAULT thread pause {target} pid {pid} tid {tid} end")


def _throttle(event, agent):
    target = event["target"]
    node = _target_node(target)

    if node:
        _node_throttle(event, node, agent)

        return

    pid = _target_pick(target, event["choice"], "throttle")

    if pid is None:
        return

    key = agent.key()
    group = f"{CGROUP_ROOT}/dst-throttle-{key}"
    quota = max(CPU_QUOTA_US_MIN, CPU_PERIOD_US * event["throttle_permille"] // PERMILLE)

    os.mkdir(group)
    _write(f"{group}/cpu.max", f"{quota} {CPU_PERIOD_US}")
    _write(f"{group}/cgroup.procs", str(pid))
    console(f"DST FAULT throttle {target} pid {pid} {event['throttle_permille']}/1000 start")

    end = functools.partial(_throttle_end, target, pid, group)

    _heal_register(agent, key, end, event["duration_ns"])


def _throttle_end(target, pid, group, agent):
    _write(f"{group}/cpu.max", f"max {CPU_PERIOD_US}")
    console(f"DST FAULT throttle {target} pid {pid} end")


def _tree(target, pid):
    root = _pid_file(TREE_ROOTS[target]) if target in TREE_ROOTS else pid
    processes = _processes()
    tree = [root or pid]

    for _ in range(len(processes)):
        offspring = [child for child, parent, _ in processes if parent in tree]
        grown = [child for child in offspring if child not in tree]

        if not grown:
            break

        tree += grown

    return tree


def _write(path, text):
    with open(path, "w") as target:
        target.write(text)


def main():
    agent = Agent()

    try:
        threading.Thread(target=_kernel_forward, daemon=True).start()
        agent.add(time.monotonic_ns(), _ask)
        _run(agent)
    except AGENT_ERRORS as error:
        console(f"DST AGENT ERROR {type(error).__name__}: {error}")

    _idle()


if __name__ == "__main__":
    main()
