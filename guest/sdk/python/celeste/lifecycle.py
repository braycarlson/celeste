from __future__ import annotations

import fcntl
import os
import subprocess
import time

from pathlib import Path

from celeste import ports
from celeste.console import emit


AGENT_ARGV = ('/usr/bin/python3', '-m', 'celeste_agent')
AGENT_ERROR_MARKER = Path('/dev/shm/celeste-agent-error')
AGENT_POLL = 0.005
AGENT_POLLS_MAX = 2000
AGENT_READY_MARKER = Path('/dev/shm/celeste-agent-ready')
ENTROPY_POOL = '/dev/urandom'
OOM_SCORE_ADJ = '/proc/self/oom_score_adj'
OOM_SCORE_IMMUNE = -1000
POWER_LOSS_WAIT = 1.0
POWER_LOSS_WAITS_MAX = 600
QUIET_MARKER = Path('/dev/shm/celeste-quiet')
QUIET_POLL = 0.05
QUIET_POLLS_MAX = 12_000
RESEED_CRNG = 0x5207
UNHEALED_MARKER = Path('/dev/shm/celeste-unhealed')
WINDOW_MARKER = Path('/dev/shm/celeste-window')
WORD_BITS = 64

_agents: list[subprocess.Popen[bytes]] = []


def _agent_spawn() -> None:
    agent = subprocess.Popen(AGENT_ARGV)
    _agents.append(agent)


def _agent_wait() -> None:
    for _ in range(AGENT_POLLS_MAX):
        if AGENT_READY_MARKER.exists():
            return

        if AGENT_ERROR_MARKER.exists():
            return

        time.sleep(AGENT_POLL)

    message = f'the agent was not ready within {AGENT_POLLS_MAX} polls of {AGENT_POLL} s'

    emit('AGENT', 'ERROR', message)
    AGENT_ERROR_MARKER.touch()


def _entropy_mix(value: int) -> None:
    assert 0 <= value < 1 << WORD_BITS

    with open(ENTROPY_POOL, 'wb', buffering=0) as pool:
        pool.write(value.to_bytes(8, 'little'))
        fcntl.ioctl(pool, RESEED_CRNG)


def _oom_immune() -> None:
    with open(OOM_SCORE_ADJ, 'w') as adjustment:
        adjustment.write(str(OOM_SCORE_IMMUNE))


def checked() -> None:
    emit('CHECK', 'DONE')


def eventually_ns() -> int:
    return int(os.environ.get('CELESTE_EVENTUALLY_NS', '0'))


def power_loss() -> None:
    ports.control(ports.POWER_LOSS)

    if not ports.ACTIVE:
        return

    for _ in range(POWER_LOSS_WAITS_MAX):
        time.sleep(POWER_LOSS_WAIT)


def quiet_wait() -> bool:
    for _ in range(QUIET_POLLS_MAX):
        if QUIET_MARKER.exists():
            return True

        if AGENT_ERROR_MARKER.exists():
            return False

        if UNHEALED_MARKER.exists():
            return False

        time.sleep(QUIET_POLL)

    return False


def ready() -> int:
    if not ports.ACTIVE:
        return 0

    emit('CPUS', str(len(os.sched_getaffinity(0))))
    _oom_immune()
    _agent_spawn()
    _agent_wait()
    ports.control(ports.READY)

    run_seed = ports.seed()

    _entropy_mix(run_seed)
    WINDOW_MARKER.touch()

    return run_seed


def seed() -> int:
    return ports.seed()
