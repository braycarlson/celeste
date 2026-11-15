from __future__ import annotations

import ctypes
import functools
import heapq
import json
import mmap
import os
import shutil
import signal
import socket
import struct
import subprocess
import time
import types

from contextlib import suppress
from pathlib import Path
from typing import TYPE_CHECKING, Any

from celeste import ports
from celeste.console import CONSOLE, emit

if TYPE_CHECKING:
    from typing import Callable

    Action = Callable[['Agent'], None]
    Event = dict[str, Any]
    Heal = Callable[['Agent'], None]
    Rule = dict[str, Any]


AGENT_ERROR_MARKER = '/dev/shm/celeste-agent-error'
AGENT_READY_MARKER = '/dev/shm/celeste-agent-ready'
AGENT_ERRORS = (
    IndexError,
    KeyError,
    OSError,
    RuntimeError,
    TypeError,
    ValueError,
    struct.error,
    subprocess.SubprocessError,
)
CGROUP_NODES = '/sys/fs/cgroup/celeste'
CGROUP_ROOT = '/sys/fs/cgroup'
CPU_PERIOD_US = 100_000
CPU_QUOTA_US_MIN = 1000
DIRECTION_BANDS = types.MappingProxyType({'both': (0, 1), 'requests': (0,), 'replies': (1,)})
DIRECTION_SIDES = types.MappingProxyType(
    {
        'both': ('requests', 'replies'),
        'requests': ('requests',),
        'replies': ('replies',),
    },
)
FAULTS = '/opt/project/harness/faults.json'
FILLER = '/var/lib/celeste-filler'
FILTER_PRIO_BASE = 2
FREEZE_POLL_INTERVAL = 0.005
FREEZE_POLLS = 200
HOST_ADDRESS = '10.77.0.1'
IDLE_INTERVAL = 3600
IDLE_INTERVALS_MAX = 24 * 365
KERNEL_PATTERNS = (
    'Aborting journal',
    'Buffer I/O error',
    'EXT4-fs error',
    'I/O error',
    'Killed process',
    'Out of memory',
    'Remounting filesystem read-only',
    'invoked oom-killer',
)
KILL_ATTEMPTS = 8
KMSG = '/dev/kmsg'
KMSG_RECORD_MAX = 8192
KMSG_RECORDS_MAX = 1 << 24
LINK_BAND_FIRST = 4
LINK_RULE_KEYS = frozenset(('node_env', 'port'))
LINKS_MAX = 6
LOADER = '/lib64/ld-linux-x86-64.so.2'
MEMINFO = '/proc/meminfo'
MADV_POPULATE_WRITE = 23
MCL_CURRENT = 1
MCL_FUTURE = 2
MEMORY_CHUNK = 2 << 20
MEMORY_FLOOR = 32 << 20
NETEM_CLEAN = ('limit', '10000')
NETEM_LIMIT = '10000'
NODE_PRIOMAP = ('0',) * 16
OOM_SCORE_ADJ = '/proc/self/oom_score_adj'
OOM_SCORE_IMMUNE = '-1000'
OOM_POLL = 0.005
OOM_POLLS_MAX = 2000
OOM_POLLS_PER_REQUEST = 4
OOM_SCORE_PREFERRED = '1000'
PERMILLE = 1000
PRIO_BANDS_RESERVED = 3
PROC = '/proc'
PROGRESS = '/run/celeste/progress'
PTRACE_DETACH = 17
PTRACE_INTERRUPT = 0x4207
PTRACE_SEIZE = 0x4206
QUIET_MARKER = '/dev/shm/celeste-quiet'
ROOT_PROBE = '/var/lib/celeste-writable'
ROSTER_NAME_MAX = 32
SLEW_STEP_NS = 10_000_000
SYSRQ_OOM = 'f'
SYSRQ_TRIGGER = '/proc/sysrq-trigger'
TARGET_RULE_KEYS = frozenset(
    (
        'command_contains',
        'command_prefix',
        'node_env',
        'parent_pidfile',
        'pidfile',
        'program',
        'restart',
        'workload',
    ),
)
TARGET_SELECTORS = frozenset(
    ('command_contains', 'command_prefix', 'parent_pidfile', 'pidfile', 'program', 'workload'),
)
TARGETS_MAX = 16
TC_SOURCE = '/usr/sbin/tc'
TOOLS = '/dev/shm/celeste-tools'
TOOLS_TC = (
    f'{TOOLS}/{Path(LOADER).name}',
    '--library-path',
    TOOLS,
    f'{TOOLS}/{Path(TC_SOURCE).name}',
)
UNHEALED_MARKER = '/dev/shm/celeste-unhealed'
VMSTAT = '/proc/vmstat'
WAIT_ALL = 0x40000000
WINDOW_MARKER = '/dev/shm/celeste-window'
WINDOW_POLL = 0.005
WINDOW_POLLS_MAX = 2000


class Agent:
    def __init__(self, targets: list[Rule], links: list[Rule]) -> None:
        assert len(targets) <= TARGETS_MAX
        assert len(links) <= LINKS_MAX

        self.actions: list[tuple[int, int, Action]] = []
        self.bands: dict[int, list[tuple[int, list[str]]]] = {
            band: [] for link in links for band in link['bands']
        }
        self.heals: dict[int, Heal] = {}
        self.links = links
        self.network_ready = False
        self.node_devices: set[tuple[str, str]] = set()
        self.node_freezes: dict[str, int] = {}
        self.node_quotas: dict[str, list[tuple[int, int]]] = {}
        self.node_stacks: dict[tuple[str, str], list[tuple[int, list[str]]]] = {}
        self.sequence = 0
        self.targets = targets

    def add(self, due_ns: int, action: Action) -> None:
        assert due_ns > 0
        assert callable(action)

        entry = (due_ns, self.sequence, action)

        heapq.heappush(self.actions, entry)
        self.sequence += 1

    def key(self) -> int:
        self.sequence += 1
        return self.sequence


def _action_name(action: Action) -> str:
    assert callable(action)

    function: Any = getattr(action, 'func', action)

    return function.__name__


def _agent_error(error: Exception) -> None:
    assert isinstance(error, AGENT_ERRORS)

    emit(f'AGENT ERROR {type(error).__name__}: {error}')

    with open(AGENT_ERROR_MARKER, 'w'):
        pass


def _ask(agent: Agent) -> None:
    assert isinstance(agent, Agent)

    delay_ns = ports.event_wait()

    agent.add(time.monotonic_ns() + delay_ns, _due)


def _band_drops(band: int) -> int:
    assert band >= LINK_BAND_FIRST

    command = [*TOOLS_TC, '-s', 'qdisc', 'show', 'dev', 'lo']
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    lines = completed.stdout.decode().splitlines()
    header = f'qdisc netem {band}0:'

    for index, line in enumerate(lines[:-1]):
        if line.startswith(header):
            dropped = int(lines[index + 1].split('dropped ')[1].split(',')[0])

            assert dropped >= 0

            return dropped

    return 0


def _clock_jump(jump_ns: int) -> None:
    assert isinstance(jump_ns, int)

    realtime_ns = time.clock_gettime_ns(time.CLOCK_REALTIME)

    time.clock_settime_ns(time.CLOCK_REALTIME, realtime_ns + jump_ns)
    emit(f'FAULT clock jump {jump_ns} ns')


def _clock_slew(ppm: int, key: int, agent: Agent) -> None:
    assert isinstance(ppm, int)
    assert key > 0
    assert isinstance(agent, Agent)

    if key not in agent.heals:
        return

    realtime_ns = time.clock_gettime_ns(time.CLOCK_REALTIME)
    step = functools.partial(_clock_slew, ppm, key)

    time.clock_settime_ns(time.CLOCK_REALTIME, realtime_ns + SLEW_STEP_NS * ppm // 1_000_000)
    agent.add(time.monotonic_ns() + SLEW_STEP_NS, step)


def _clock_slew_end(_agent: Agent) -> None:
    _ = _agent

    emit('FAULT clock slew end')


def _clock_slew_start(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'clock_slew'
    assert isinstance(agent, Agent)

    key = agent.key()

    emit(f'FAULT clock slew {event["clock_slew_ppm"]} ppm')
    _heal_register(agent, key, _clock_slew_end, event['duration_ns'])
    _clock_slew(event['clock_slew_ppm'], key, agent)


def _disk_full(slack_kib: int, agent: Agent) -> None:
    assert slack_kib >= 0
    assert isinstance(agent, Agent)

    stats = os.statvfs('/')
    size = stats.f_bavail * stats.f_frsize - slack_kib * 1024
    outcome = 'filled'

    if size > 0:
        descriptor = os.open(FILLER, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

        try:
            os.posix_fallocate(descriptor, 0, size)
        except OSError as error:
            outcome = f'partly filled ({error.strerror})'
        finally:
            os.close(descriptor)

    after = os.statvfs('/')
    available = after.f_bavail * after.f_frsize

    emit(f'FAULT disk full {outcome} asking {max(size, 0)} leaving {available}')
    agent.heals[agent.key()] = _disk_full_end


def _disk_full_end(_agent: Agent) -> None:
    _ = _agent

    try:
        Path(FILLER).unlink()
    except FileNotFoundError:
        emit('FAULT disk full end, the filler was already gone')
    else:
        emit('FAULT disk full end')


def _due(agent: Agent) -> None:
    assert isinstance(agent, Agent)

    event = ports.event()

    if event['kind'] == 'none':
        if _eventually():
            agent.add(time.monotonic_ns() + event['delay_ns'], _heal_all)

        return

    emit(f'EVENT {ports.event_render(event)} END')
    _event_run(event, agent)


def _event_apply(event: Event, agent: Agent) -> None:
    assert event['kind'] != 'none'
    assert isinstance(agent, Agent)

    kind = event['kind']

    match kind:
        case 'clock_jump':
            _clock_jump(event['clock_jump_ns'])
        case 'clock_slew':
            _clock_slew_start(event, agent)
        case 'disk_full':
            _disk_full(event['disk_full_slack_kib'], agent)
        case 'kill':
            _kill(event, agent)
        case 'memory':
            _memory_hog(event, agent)
        case 'network':
            _network(event, agent)
        case 'pause':
            _pause(event, agent)
        case 'thread_pause':
            _thread_pause(event, agent)
        case 'throttle':
            _throttle(event, agent)
        case _:
            message = f'the event names an unknown kind {kind}'
            raise RuntimeError(message)


def _event_run(event: Event, agent: Agent) -> None:
    assert event['kind'] != 'none'
    assert isinstance(agent, Agent)

    try:
        _event_apply(event, agent)
    except OSError as error:
        emit(f'FAULT unavailable {event["kind"]}: {error}')

    agent.add(time.monotonic_ns(), _ask)


def _eventually() -> bool:
    return int(os.environ.get('CELESTE_EVENTUALLY_NS', '0')) > 0


def _heal_all(agent: Agent) -> None:
    assert isinstance(agent, Agent)

    if agent.network_ready:
        command = [*TOOLS_TC, 'qdisc', 'del', 'dev', 'lo', 'root']

        _tc(command)
        agent.network_ready = False
        agent.bands = {band: [] for band in agent.bands}

    for node, side in sorted(agent.node_devices):
        tc, device = _node_device(node, side)
        command = [*tc, 'qdisc', 'del', 'dev', device, 'root']

        _tc(command)

    agent.node_devices = set()
    agent.node_stacks = {}

    down = _targets_down(agent)
    unhealed = 0

    for key in sorted(agent.heals):
        try:
            _heal_run(key, agent)
        except OSError as error:
            emit(f'FAULT unhealed: {error}')
            agent.heals.pop(key)
            unhealed += 1

    for target in down:
        emit(f'FAULT down {target["name"]} at the quiet point')

        try:
            _restart(target, agent)
        except OSError as error:
            emit(f'FAULT unhealed: {error}')
            unhealed += 1

    refused = _root_write_refused()

    if refused:
        emit(f'FAULT unhealed: the root filesystem refuses writes: {refused}')
        unhealed += 1

    ports.control(ports.QUIET)

    with open(UNHEALED_MARKER if unhealed else QUIET_MARKER, 'w'):
        pass

    emit('QUIET')


def _heal_register(agent: Agent, key: int, heal: Heal, duration_ns: int) -> None:
    assert isinstance(agent, Agent)
    assert key > 0
    assert callable(heal)
    assert duration_ns >= 0

    agent.heals[key] = heal

    agent.add(time.monotonic_ns() + duration_ns, functools.partial(_heal_run, key))


def _heal_run(key: int, agent: Agent) -> None:
    assert key > 0
    assert isinstance(agent, Agent)

    heal = agent.heals.get(key)

    if heal is None:
        return

    heal(agent)

    del agent.heals[key]


def _idle() -> None:
    for _ in range(IDLE_INTERVALS_MAX):
        time.sleep(IDLE_INTERVAL)

    message = f'the agent idled past {IDLE_INTERVALS_MAX} intervals of {IDLE_INTERVAL} s'
    raise RuntimeError(message)


def _kernel_forward() -> None:
    descriptor = os.open(KMSG, os.O_RDONLY)

    os.lseek(descriptor, 0, os.SEEK_END)

    for _ in range(KMSG_RECORDS_MAX):
        try:
            record = os.read(descriptor, KMSG_RECORD_MAX).decode(errors='replace')
        except BrokenPipeError:
            continue

        message = record.partition(';')[2].partition('\n')[0]

        if any(pattern in message for pattern in KERNEL_PATTERNS):
            emit(f'KERNEL {message}')

    message = f'the kernel log forwarded more than {KMSG_RECORDS_MAX} records'
    raise RuntimeError(message)


def _kernel_forward_start() -> None:
    forwarder = os.fork()

    if forwarder == 0:
        try:
            _kernel_forward()
        except AGENT_ERRORS as error:
            _agent_error(error)
        finally:
            os._exit(0)


def _kill(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'kill'
    assert isinstance(agent, Agent)

    target = _target_rule(agent, event['target'])
    node = _node_of(target)

    if node:
        _node_kill(event, target, node, agent)

        return

    killed = False

    for _ in range(KILL_ATTEMPTS):
        pids = _targets(target)

        if not pids:
            emit(f'FAULT kill {target["name"]} absent')

            return

        killed = _kill_pid(target['name'], pids[event['choice'] % len(pids)])

        if killed:
            break

    _restart_register(event, target, killed, agent)


def _kill_pid(target: str, pid: int) -> bool:
    assert target
    assert pid > 0

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        emit(f'FAULT kill {target} pid {pid} already gone')

        return False

    emit(f'FAULT kill {target} pid {pid}')

    return True


def _link_rule(agent: Agent, index: int) -> Rule:
    assert isinstance(agent, Agent)
    assert isinstance(index, int)

    if not 1 <= index <= len(agent.links):
        message = f'the event names link {index} of a roster of {len(agent.links)}'
        raise RuntimeError(message)

    return agent.links[index - 1]


def _meminfo(name: str) -> int:
    assert name

    with open(MEMINFO) as meminfo:
        for line in meminfo:
            key, _, value = line.partition(':')

            if key == name:
                size = int(value.split()[0]) * 1024

                assert size >= 0

                return size

    message = f'{name} is missing from {MEMINFO}'
    raise RuntimeError(message)


def _memory_chunk() -> mmap.mmap:
    chunk = mmap.mmap(-1, MEMORY_CHUNK, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)

    chunk.madvise(mmap.MADV_HUGEPAGE)
    chunk.madvise(MADV_POPULATE_WRITE)

    return chunk


def _memory_end(pid: int, _agent: Agent) -> None:
    assert pid > 0
    _ = _agent

    with suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)

    os.waitpid(pid, 0)
    emit(f'FAULT memory hog pid {pid} end')


def _memory_full(event: Event, kills_start: int) -> bool:
    assert event['kind'] == 'memory'
    assert kills_start >= 0

    if not event['memory_immune']:
        return False

    if event['memory_kills'] == 0:
        return _meminfo('MemAvailable') <= MEMORY_FLOOR

    return _oom_kills() - kills_start >= event['memory_kills']


def _memory_hog(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'memory'
    assert isinstance(agent, Agent)

    child = os.fork()

    if child == 0:
        try:
            _memory_hold(event)
        finally:
            os._exit(0)

    emit(f'FAULT memory hog pid {child}')
    agent.heals[agent.key()] = functools.partial(_memory_end, child)


def _memory_hold(event: Event) -> None:
    assert event['kind'] == 'memory'

    adjustment = OOM_SCORE_IMMUNE if event['memory_immune'] else OOM_SCORE_PREFERRED

    with open(OOM_SCORE_ADJ, 'w') as score:
        score.write(adjustment)

    kills_start = _oom_kills()
    chunks: list[mmap.mmap] = []

    for _ in range(_meminfo('MemTotal') // MEMORY_CHUNK + 1):
        if _memory_full(event, kills_start):
            break

        if _meminfo('MemAvailable') <= MEMORY_FLOOR:
            break

        try:
            chunk = _memory_chunk()
        except OSError:
            break

        chunks.append(chunk)

    for _ in range(event['memory_kills'] + 1):
        if _memory_full(event, kills_start):
            break

        _oom_invoke()

    held = len(chunks) * MEMORY_CHUNK
    kills = _oom_kills() - kills_start

    emit(f'FAULT memory hog holding {held} after {kills} kills')
    time.sleep(event['duration_ns'] / 1e9)


def _memory_lock() -> None:
    libc = ctypes.CDLL(None, use_errno=True)

    if libc.mlockall(MCL_CURRENT | MCL_FUTURE) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def _netem_apply(band: int, arguments: list[str]) -> None:
    assert band >= LINK_BAND_FIRST
    assert len(arguments) > 0

    qdisc = ['dev', 'lo', 'parent', f'1:{band}', 'handle', f'{band}0:']
    command = [*TOOLS_TC, 'qdisc', 'change', *qdisc, 'netem', *arguments]

    _tc(command)


def _netem_arguments(event: Event) -> list[str]:
    assert event['kind'] == 'network'

    arguments = ['limit', NETEM_LIMIT]

    if event['network_delay_ns'] > 0:
        arguments += ['delay', f'{max(1, event["network_delay_ns"] // 1000)}us']

        if event['network_jitter_ns'] > 0:
            arguments.append(f'{max(1, event["network_jitter_ns"] // 1000)}us')

    if event['network_loss_permille'] > 0:
        arguments += ['loss', f'{event["network_loss_permille"] / 10}%']

    if event['network_reorder_permille'] > 0:
        arguments += ['reorder', f'{event["network_reorder_permille"] / 10}%']

    return arguments


def _network(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'network'
    assert isinstance(agent, Agent)

    link = _link_rule(agent, event['network_link'])
    node = _node_of(link)

    if node:
        _node_network(event, node, agent)

        return

    direction = event['network_direction']
    bands = [link['bands'][side] for side in DIRECTION_BANDS[direction]]
    arguments = _netem_arguments(event)
    key = agent.key()

    if not agent.network_ready:
        _network_setup(agent)
        agent.network_ready = True

    for band in bands:
        entry = (key, arguments)

        agent.bands[band].append(entry)
        _netem_apply(band, arguments)

    name = _network_name(event)
    netem = ' '.join(arguments)

    emit(f'FAULT network {name} start {link["name"]} {direction} netem {netem}')

    end = functools.partial(_network_end, event, key, bands)

    agent.add(time.monotonic_ns() + event['duration_ns'], end)


def _network_end(event: Event, key: int, bands: list[int], agent: Agent) -> None:
    assert event['kind'] == 'network'
    assert key > 0
    assert 1 <= len(bands) <= 2
    assert isinstance(agent, Agent)

    if not agent.network_ready:
        return

    for band in bands:
        active = [entry for entry in agent.bands[band] if entry[0] != key]
        arguments = active[-1][1] if active else list(NETEM_CLEAN)
        agent.bands[band] = active

        _netem_apply(band, arguments)

    link = _link_rule(agent, event['network_link'])
    direction = event['network_direction']
    requests_band, replies_band = link['bands']
    drops = f'dropped requests {_band_drops(requests_band)} replies {_band_drops(replies_band)}'

    emit(f'FAULT network {_network_name(event)} end {link["name"]} {direction} {drops}')


def _network_name(event: Event) -> str:
    assert event['kind'] == 'network'

    return 'partition' if event['network_loss_permille'] == PERMILLE else 'impairment'


def _network_setup(agent: Agent) -> None:
    assert isinstance(agent, Agent)

    bands = str(PRIO_BANDS_RESERVED + 2 * len(agent.links))
    root = [*TOOLS_TC, 'qdisc', 'add', 'dev', 'lo', 'root', 'handle', '1:', 'prio', 'bands', bands]
    match = [*TOOLS_TC, 'filter', 'add', 'dev', 'lo', 'parent', '1:', 'protocol', 'ip', 'prio', '1']

    _tc(root)

    for link in agent.links:
        port = str(link['port'])

        for band, field in zip(link['bands'], ('dport', 'sport'), strict=True):
            parent = ['parent', f'1:{band}', 'handle', f'{band}0:']
            netem = [*TOOLS_TC, 'qdisc', 'add', 'dev', 'lo', *parent, 'netem', *NETEM_CLEAN]
            flow = [*match, 'u32', 'match', 'ip', field, port, '0xffff', 'flowid', f'1:{band}']

            _tc(netem)
            _tc(flow)


def _node_device(node: str, side: str) -> tuple[list[str], str]:
    assert node
    assert side in ('requests', 'replies')

    if side == 'requests':
        return [*TOOLS_TC], f'veth-{node}'

    return [*TOOLS_TC, '-n', node], 'eth0'


def _node_device_setup(node: str, side: str, agent: Agent) -> None:
    assert node
    assert side in ('requests', 'replies')
    assert isinstance(agent, Agent)

    if (node, side) in agent.node_devices:
        return

    tc, device = _node_device(node, side)
    add = [*tc, 'qdisc', 'add', 'dev', device]
    prio = [*add, 'root', 'handle', '1:', 'prio', 'bands', '2', 'priomap', *NODE_PRIOMAP]
    pass_band = [*add, 'parent', '1:1', 'handle', '10:', 'netem', *NETEM_CLEAN]
    drop = ['netem', 'limit', NETEM_LIMIT, 'loss', '100%']
    drop_band = [*add, 'parent', '1:2', 'handle', '20:', *drop]

    _tc(prio)
    _tc(pass_band)
    _tc(drop_band)
    agent.node_devices.add((node, side))
    agent.node_stacks[(node, side)] = []


def _node_filters_add(node: str, side: str, key: int, peers: list[str] | None) -> None:
    assert node
    assert side in ('requests', 'replies')
    assert key > 0
    assert isinstance(peers, (list, type(None)))

    tc, device = _node_device(node, side)
    field = 'src' if side == 'requests' else 'dst'
    prio = ['parent', '1:', 'protocol', 'ip', 'prio', str(FILTER_PRIO_BASE + key), 'u32']
    add = [*tc, 'filter', 'add', 'dev', device, *prio]

    if peers is None:
        everyone = [*add, 'match', 'u32', '0', '0', 'flowid', '1:2']

        _tc(everyone)

        return

    for address in peers:
        peer = [*add, 'match', 'ip', field, f'{address}/32', 'flowid', '1:2']

        _tc(peer)


def _node_filters_delete(node: str, side: str, key: int) -> None:
    assert node
    assert side in ('requests', 'replies')
    assert key > 0

    tc, device = _node_device(node, side)
    prio = ['parent', '1:', 'protocol', 'ip', 'prio', str(FILTER_PRIO_BASE + key)]
    command = [*tc, 'filter', 'del', 'dev', device, *prio]

    _tc(command)


def _node_frozen(node: str) -> bool:
    assert node

    with open(f'{CGROUP_NODES}/{node}/cgroup.events') as events:
        for line in events:
            key, _, value = line.partition(' ')

            if key == 'frozen':
                return value.strip() == '1'

    message = f'cgroup.events of node {node} has no frozen line'
    raise RuntimeError(message)


def _node_frozen_wait(node: str) -> int:
    assert node

    for _ in range(FREEZE_POLLS):
        if _node_frozen(node):
            return 1

        time.sleep(FREEZE_POLL_INTERVAL)

    return 0


def _node_kill(event: Event, target: Rule, node: str, agent: Agent) -> None:
    assert event['kind'] == 'kill'
    assert 'name' in target
    assert node
    assert isinstance(agent, Agent)

    group = f'{CGROUP_NODES}/{node}'
    members = _read(f'{group}/cgroup.procs').split()

    _write(f'{group}/cgroup.kill', '1')
    emit(f'FAULT kill node {node} {target["name"]} processes {len(members)}')
    _restart_register(event, target, bool(members), agent)


def _node_netem_apply(node: str, side: str, arguments: list[str]) -> None:
    assert node
    assert side in ('requests', 'replies')
    assert len(arguments) > 0

    tc, device = _node_device(node, side)
    command = [*tc, 'qdisc', 'change', 'dev', device, 'parent', '1:1', 'handle', '10:', 'netem']
    change = [*command, *arguments]

    _tc(change)


def _node_network(event: Event, node: str, agent: Agent) -> None:
    assert event['kind'] == 'network'
    assert node
    assert isinstance(agent, Agent)

    direction = event['network_direction']
    partition = event['network_loss_permille'] == PERMILLE
    peers = _node_peers(event['network_peers'], node) if partition else []
    key = agent.key()

    for side in DIRECTION_SIDES[direction]:
        _node_device_setup(node, side, agent)

    if partition:
        for side in DIRECTION_SIDES[direction]:
            _node_filters_add(node, side, key, peers)

        detail = 'from all' if peers is None else 'from ' + (' '.join(peers) or 'none')
    else:
        arguments = _netem_arguments(event)

        for side in DIRECTION_SIDES[direction]:
            entry = (key, arguments)

            agent.node_stacks[(node, side)].append(entry)
            _node_netem_apply(node, side, arguments)

        detail = 'netem ' + ' '.join(arguments)

    emit(f'FAULT network {_network_name(event)} start node {node} {direction} {detail}')

    end = functools.partial(_node_network_end, event, node, key, peers)

    agent.add(time.monotonic_ns() + event['duration_ns'], end)


def _node_network_end(
    event: Event,
    node: str,
    key: int,
    peers: list[str] | None,
    agent: Agent,
) -> None:
    assert event['kind'] == 'network'
    assert node
    assert key > 0
    assert isinstance(peers, (list, type(None)))
    assert isinstance(agent, Agent)

    direction = event['network_direction']
    sides = [side for side in DIRECTION_SIDES[direction] if (node, side) in agent.node_devices]

    for side in sides:
        if event['network_loss_permille'] == PERMILLE:
            if peers != []:
                _node_filters_delete(node, side, key)

            continue

        active = [entry for entry in agent.node_stacks[(node, side)] if entry[0] != key]
        arguments = active[-1][1] if active else list(NETEM_CLEAN)
        agent.node_stacks[(node, side)] = active

        _node_netem_apply(node, side, arguments)

    if sides:
        emit(f'FAULT network {_network_name(event)} end node {node} {direction}')


def _node_of(rule: Rule) -> str:
    assert isinstance(rule, dict)

    if 'node_env' not in rule:
        return ''

    return os.environ.get(rule['node_env'], '')


def _node_pause(event: Event, node: str, agent: Agent) -> None:
    assert event['kind'] == 'pause'
    assert node
    assert isinstance(agent, Agent)

    freezes = agent.node_freezes.get(node, 0)
    agent.node_freezes[node] = freezes + 1

    if freezes == 0:
        _write(f'{CGROUP_NODES}/{node}/cgroup.freeze', '1')

    frozen = _node_frozen_wait(node)
    progress = _node_progress(node)

    emit(f'FAULT pause node {node} frozen {frozen} progress {progress} start')

    end = functools.partial(_node_pause_end, node)

    _heal_register(agent, agent.key(), end, event['duration_ns'])


def _node_pause_end(node: str, agent: Agent) -> None:
    assert node
    assert isinstance(agent, Agent)

    progress = _node_progress(node)
    agent.node_freezes[node] -= 1

    if agent.node_freezes[node] == 0:
        _write(f'{CGROUP_NODES}/{node}/cgroup.freeze', '0')

    emit(f'FAULT pause node {node} progress {progress} end')


def _node_peers(mask: int, node: str) -> list[str] | None:
    assert mask >= 0
    assert node

    if mask == 0:
        return None

    names = ['host', *os.environ.get('CELESTE_NODES', '').split()]
    peers = []

    for bit, name in enumerate(names):
        if not mask & (1 << bit):
            continue

        if name == node:
            continue

        peers.append(HOST_ADDRESS if bit == 0 else socket.gethostbyname(name))

    return peers


def _node_progress(node: str) -> str:
    assert node

    try:
        progress = _read(f'{PROGRESS}/{node}')
    except FileNotFoundError:
        return 'none'

    return progress.strip() or 'none'


def _node_throttle(event: Event, node: str, agent: Agent) -> None:
    assert event['kind'] == 'throttle'
    assert node
    assert isinstance(agent, Agent)

    key = agent.key()
    quota = max(CPU_QUOTA_US_MIN, CPU_PERIOD_US * event['throttle_permille'] // PERMILLE)
    entry = (key, quota)

    agent.node_quotas.setdefault(node, []).append(entry)
    _write(f'{CGROUP_NODES}/{node}/cpu.max', f'{quota} {CPU_PERIOD_US}')
    emit(f'FAULT throttle node {node} {event["throttle_permille"]}/1000 start')

    end = functools.partial(_node_throttle_end, node, key)

    _heal_register(agent, key, end, event['duration_ns'])


def _node_throttle_end(node: str, key: int, agent: Agent) -> None:
    assert node
    assert key > 0
    assert isinstance(agent, Agent)

    active = [entry for entry in agent.node_quotas[node] if entry[0] != key]
    quota = str(active[-1][1]) if active else 'max'
    agent.node_quotas[node] = active

    _write(f'{CGROUP_NODES}/{node}/cpu.max', f'{quota} {CPU_PERIOD_US}')
    emit(f'FAULT throttle node {node} end')


def _oom_invoke() -> None:
    kills = _oom_kills()

    for poll in range(OOM_POLLS_MAX):
        if poll % OOM_POLLS_PER_REQUEST == 0:
            with open(SYSRQ_TRIGGER, 'w') as trigger:
                trigger.write(SYSRQ_OOM)

        time.sleep(OOM_POLL)

        if _oom_kills() > kills:
            return


def _oom_kills() -> int:
    with open(VMSTAT) as vmstat:
        for line in vmstat:
            key, _, value = line.partition(' ')

            if key == 'oom_kill':
                return int(value)

    message = f'oom_kill is missing from {VMSTAT}'
    raise RuntimeError(message)


def _pause(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'pause'
    assert isinstance(agent, Agent)

    target = _target_rule(agent, event['target'])
    node = _node_of(target)

    if node:
        _node_pause(event, node, agent)

        return

    pid = _target_pick(target, event['choice'], 'pause')

    if pid is None:
        return

    paused = _tree(target, pid) if event['pause_tree'] else [pid]
    stopped = _signal_all(paused, signal.SIGSTOP)

    emit(f'FAULT pause {target["name"]} pid {pid} processes {stopped} start')

    end = functools.partial(_pause_end, target['name'], pid, paused)

    _heal_register(agent, agent.key(), end, event['duration_ns'])


def _pause_end(target: str, pid: int, paused: list[int], _agent: Agent) -> None:
    assert target
    assert pid > 0
    assert len(paused) > 0
    _ = _agent

    resumed = _signal_all(paused, signal.SIGCONT)

    emit(f'FAULT pause {target} pid {pid} processes {resumed} end')


def _pid_file(path: str) -> int | None:
    assert path.startswith('/')

    try:
        with open(path) as pid_file:
            pid = int(pid_file.readline().strip())
    except (OSError, ValueError):
        return None

    if not Path(f'{PROC}/{pid}').exists():
        return None

    return pid


def _processes() -> list[tuple[int, int, str]]:
    entries = []

    for entry in Path(PROC).iterdir():
        if not entry.name.isdigit():
            continue

        try:
            with open(entry / 'stat') as stat:
                state = stat.read().rpartition(')')[2].split()

            with open(entry / 'cmdline', 'rb') as cmdline:
                command = cmdline.read().replace(b'\0', b' ').decode(errors='replace').strip()
        except OSError:
            continue

        process = (int(entry.name), int(state[1]), command)
        entries.append(process)

    return sorted(entries)


def _program(command: str) -> str:
    assert isinstance(command, str)

    return Path(command.partition(' ')[0]).name


def _ptrace(request: int, tid: int) -> None:
    assert request in (PTRACE_DETACH, PTRACE_INTERRUPT, PTRACE_SEIZE)
    assert tid > 0

    libc = ctypes.CDLL(None, use_errno=True)
    libc.ptrace.argtypes = (ctypes.c_long, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
    libc.ptrace.restype = ctypes.c_long

    if libc.ptrace(request, tid, None, None) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def _read(path: str) -> str:
    assert path.startswith('/')

    with open(path) as source:
        return source.read()


def _restart(target: Rule, _agent: Agent) -> None:
    assert 'restart' in target
    _ = _agent

    output = os.open(CONSOLE, os.O_WRONLY | os.O_NOCTTY)

    try:
        subprocess.Popen(
            target['restart'],
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
        )
    finally:
        os.close(output)

    emit(f'FAULT restart {target["name"]}')


def _restart_register(event: Event, target: Rule, stopped: bool, agent: Agent) -> None:
    assert event['kind'] == 'kill'
    assert 'name' in target
    assert isinstance(agent, Agent)

    restart = functools.partial(_restart, target)

    if event['restart']:
        _heal_register(agent, agent.key(), restart, event['restart_delay_ns'])

        return

    if not stopped:
        return

    if 'restart' in target:
        agent.heals[agent.key()] = restart


def _root_write_refused() -> str:
    try:
        descriptor = os.open(ROOT_PROBE, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    except OSError as error:
        return str(error)

    os.close(descriptor)

    with suppress(OSError):
        Path(ROOT_PROBE).unlink()

    return ''


def _roster() -> tuple[list[Rule], list[Rule]]:
    target_names = _roster_names('CELESTE_TARGETS', TARGETS_MAX)
    link_names = _roster_names('CELESTE_LINKS', LINKS_MAX)

    if not target_names:
        if not link_names:
            return [], []

    path = os.environ.get('CELESTE_FAULTS', FAULTS)

    with open(path) as source:
        rules = json.load(source)

    if not isinstance(rules, dict):
        message = f'{path} holds a {type(rules).__name__}, not an object of targets and links'
        raise TypeError(message)

    targets = [_roster_target(path, rules, name) for name in target_names]
    links = [_roster_link(path, rules, name) for name in link_names]

    for index, link in enumerate(links):
        first = LINK_BAND_FIRST + 2 * index
        link['bands'] = (first, first + 1)

    return targets, links


def _roster_link(path: str, rules: dict[str, Any], name: str) -> Rule:
    assert path
    assert isinstance(rules, dict)
    assert name

    rule = _roster_rule(path, rules, 'links', name, LINK_RULE_KEYS)
    port = rule.get('port')

    if type(port) is not int:
        message = f'{path} gives link {name} the port {port!r}, not an integer'
        raise TypeError(message)

    if not 0 < port < 65536:
        message = f'{path} gives link {name} the port {port}, not one in 1..65535'
        raise ValueError(message)

    return rule


def _roster_names(variable: str, count_max: int) -> list[str]:
    assert variable.startswith('CELESTE_')
    assert count_max > 0

    names = [name for name in os.environ.get(variable, '').split(',') if name]

    if len(names) > count_max:
        message = f'{variable} names {len(names)} entries, more than {count_max}'
        raise ValueError(message)

    for name in names:
        if len(name) > ROSTER_NAME_MAX:
            message = f'{variable} names {name}, longer than {ROSTER_NAME_MAX} characters'
            raise ValueError(message)

    if len(set(names)) != len(names):
        message = f'{variable} names an entry twice: {",".join(names)}'
        raise ValueError(message)

    return names


def _roster_rule(
    path: str,
    rules: dict[str, Any],
    section: str,
    name: str,
    keys: frozenset[str],
) -> Rule:
    assert path
    assert isinstance(rules, dict)
    assert section in ('links', 'targets')
    assert name
    assert len(keys) > 0

    table = rules.get(section, {})

    if not isinstance(table, dict):
        message = f'{path} holds {section} as a {type(table).__name__}, not an object'
        raise TypeError(message)

    if name not in table:
        message = f'{path} has no rule for the {section} entry {name} the roster names'
        raise KeyError(message)

    rule = table[name]

    if not isinstance(rule, dict):
        message = f'{path} gives {section} entry {name} a {type(rule).__name__}, not an object'
        raise TypeError(message)

    unknown = sorted(set(rule) - keys)

    if unknown:
        message = f'{path} gives {section} entry {name} unknown fields {", ".join(unknown)}'
        raise ValueError(message)

    return {**rule, 'name': name}


def _roster_target(path: str, rules: dict[str, Any], name: str) -> Rule:
    assert path
    assert isinstance(rules, dict)
    assert name

    rule = _roster_rule(path, rules, 'targets', name, TARGET_RULE_KEYS)

    if not TARGET_SELECTORS & set(rule):
        message = f'{path} gives target {name} no selector, so it would match every process'
        raise ValueError(message)

    for key in ('command_contains', 'restart'):
        if key not in rule:
            continue

        if not _strings(rule, key):
            message = f'{path} gives target {name} a {key} that is not a list of strings'
            raise TypeError(message)

    return rule


def _run(agent: Agent) -> None:
    assert isinstance(agent, Agent)

    while agent.actions:
        due_ns, _, action = heapq.heappop(agent.actions)
        delay_ns = due_ns - time.monotonic_ns()

        if delay_ns > 0:
            time.sleep(delay_ns / 1e9)

        try:
            action(agent)
        except OSError as error:
            emit(f'FAULT unavailable {_action_name(action)}: {error}')
        except AGENT_ERRORS as error:
            _agent_error(error)


def _signal_all(pids: list[int], number: int) -> int:
    assert isinstance(pids, list)
    assert number in (signal.SIGCONT, signal.SIGSTOP)

    signaled = 0

    for pid in pids:
        try:
            os.kill(pid, number)
        except ProcessLookupError:
            continue

        signaled += 1

    return signaled


def _strings(rule: Rule, key: str) -> bool:
    assert key in rule

    value = rule[key]

    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _target_pick(target: Rule, choice: int, action: str) -> int | None:
    assert 'name' in target
    assert choice >= 0
    assert action in ('pause', 'thread pause', 'throttle')

    pids = _targets(target)

    if not pids:
        emit(f'FAULT {action} {target["name"]} absent')

        return None

    pid = pids[choice % len(pids)]

    assert pid > 0

    return pid


def _target_rule(agent: Agent, index: int) -> Rule:
    assert isinstance(agent, Agent)
    assert isinstance(index, int)

    if not 1 <= index <= len(agent.targets):
        message = f'the event names target {index} of a roster of {len(agent.targets)}'
        raise RuntimeError(message)

    return agent.targets[index - 1]


def _targets(target: Rule) -> list[int]:
    assert 'name' in target

    if target.get('workload'):
        return [os.getppid()]

    processes = _processes()

    if 'pidfile' in target:
        pid = _pid_file(target['pidfile'])
        processes = [entry for entry in processes if entry[0] == pid]

    if 'parent_pidfile' in target:
        parent = _pid_file(target['parent_pidfile'])
        processes = [entry for entry in processes if entry[1] == parent]

    if 'program' in target:
        processes = [entry for entry in processes if _program(entry[2]) == target['program']]

    if 'command_prefix' in target:
        prefix = target['command_prefix']
        processes = [entry for entry in processes if entry[2].startswith(prefix)]

    if 'command_contains' in target:
        markers = target['command_contains']
        processes = [entry for entry in processes if any(mark in entry[2] for mark in markers)]

    return [pid for pid, _, _ in processes]


def _targets_down(agent: Agent) -> list[Rule]:
    assert isinstance(agent, Agent)

    pending = set()

    for heal in agent.heals.values():
        if not isinstance(heal, functools.partial):
            continue

        if heal.func is _restart:
            pending.add(heal.args[0]['name'])

    down = []

    for target in agent.targets:
        if 'restart' not in target:
            continue

        if _node_of(target):
            continue

        if target['name'] in pending:
            continue

        if not _targets(target):
            down.append(target)

    assert len(down) <= len(agent.targets)

    return down


def _tc(arguments: list[str]) -> None:
    assert len(arguments) > 0

    completed = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )

    if completed.returncode != 0:
        detail = completed.stderr.decode().strip()
        message = f'{" ".join(arguments)} exited {completed.returncode}: {detail}'

        raise RuntimeError(message)


def _thread_pause(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'thread_pause'
    assert isinstance(agent, Agent)

    target = _target_rule(agent, event['target'])
    pid = _target_pick(target, event['choice'], 'thread pause')

    if pid is None:
        return

    tids = sorted(int(task.name) for task in Path(f'{PROC}/{pid}/task').iterdir())
    tid = tids[event['thread_choice'] % len(tids)]

    _ptrace(PTRACE_SEIZE, tid)
    _ptrace(PTRACE_INTERRUPT, tid)
    os.waitpid(tid, WAIT_ALL)
    emit(f'FAULT thread pause {target["name"]} pid {pid} tid {tid} start')

    end = functools.partial(_thread_pause_end, target['name'], pid, tid)

    _heal_register(agent, agent.key(), end, event['duration_ns'])


def _thread_pause_end(target: str, pid: int, tid: int, _agent: Agent) -> None:
    assert target
    assert pid > 0
    assert tid > 0
    _ = _agent

    try:
        _ptrace(PTRACE_DETACH, tid)
    except ProcessLookupError:
        with suppress(ChildProcessError):
            os.waitpid(tid, WAIT_ALL | os.WNOHANG)

        emit(f'FAULT thread pause {target} pid {pid} tid {tid} already gone')
    else:
        emit(f'FAULT thread pause {target} pid {pid} tid {tid} end')


def _throttle(event: Event, agent: Agent) -> None:
    assert event['kind'] == 'throttle'
    assert isinstance(agent, Agent)

    target = _target_rule(agent, event['target'])
    node = _node_of(target)

    if node:
        _node_throttle(event, node, agent)

        return

    pid = _target_pick(target, event['choice'], 'throttle')

    if pid is None:
        return

    key = agent.key()
    group = f'{CGROUP_ROOT}/celeste-throttle-{key}'
    permille = event['throttle_permille']
    quota = max(CPU_QUOTA_US_MIN, CPU_PERIOD_US * permille // PERMILLE)

    Path(group).mkdir()
    _write(f'{group}/cpu.max', f'{quota} {CPU_PERIOD_US}')
    _write(f'{group}/cgroup.procs', str(pid))
    emit(f'FAULT throttle {target["name"]} pid {pid} {permille}/1000 start')

    end = functools.partial(_throttle_end, target['name'], pid, group)

    _heal_register(agent, key, end, event['duration_ns'])


def _throttle_end(target: str, pid: int, group: str, _agent: Agent) -> None:
    assert target
    assert pid > 0
    assert group.startswith(CGROUP_ROOT)
    _ = _agent

    _write(f'{group}/cpu.max', f'max {CPU_PERIOD_US}')
    emit(f'FAULT throttle {target} pid {pid} end')


def _tools_stage() -> list[str]:
    listed = subprocess.run(
        [LOADER, '--list', TC_SOURCE],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
    )

    if listed.returncode != 0:
        detail = listed.stderr.decode().strip()
        message = f'{LOADER} could not list the libraries of {TC_SOURCE}: {detail}'
        raise RuntimeError(message)

    libraries = [word for word in listed.stdout.decode().split() if word.startswith('/')]

    if LOADER not in libraries:
        message = f'{LOADER} did not list itself as the loader of {TC_SOURCE}'
        raise RuntimeError(message)

    sources = sorted({TC_SOURCE, *libraries})

    Path(TOOLS).mkdir(exist_ok=True)

    return [shutil.copy(source, TOOLS) for source in sources]


def _tree(target: Rule, pid: int) -> list[int]:
    assert 'name' in target
    assert pid > 0

    root = _pid_file(target['parent_pidfile']) if 'parent_pidfile' in target else pid
    processes = _processes()
    tree = [root or pid]

    for _ in range(len(processes)):
        offspring = [child for child, parent, _ in processes if parent in tree]
        grown = [child for child in offspring if child not in tree]

        if not grown:
            break

        tree += grown

    return tree


def _window_wait() -> None:
    for _ in range(WINDOW_POLLS_MAX):
        if Path(WINDOW_MARKER).exists():
            return

        time.sleep(WINDOW_POLL)

    message = f'the fault window did not open within {WINDOW_POLLS_MAX} polls of {WINDOW_POLL} s'
    raise RuntimeError(message)


def _write(path: str, text: str) -> None:
    assert path.startswith('/')
    assert text

    with open(path, 'w') as target:
        target.write(text)


def main() -> None:
    try:
        agent = Agent(*_roster())

        _tools_stage()
        _memory_lock()

        with open(AGENT_READY_MARKER, 'w'):
            pass

        _window_wait()
        _kernel_forward_start()
        agent.add(time.monotonic_ns(), _ask)
        _run(agent)
    except AGENT_ERRORS as error:
        _agent_error(error)

    _idle()


if __name__ == '__main__':
    main()
