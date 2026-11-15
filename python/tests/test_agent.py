from __future__ import annotations

import errno
import functools
import json
import os
import subprocess
import types

import pytest

from pathlib import Path
from unittest import mock

from typing_extensions import Any

import celeste_agent as agent


LEDGER_FAULTS = Path(__file__).parents[2] / 'tests/fixtures/ledger/harness/faults.json'
POSTMASTER_PID = '/var/lib/postgresql/17/main/postmaster.pid'
POSTGRES_CLIENTS = ('[local]', '127.0.0.1(', '10.77.0.1(')
WORKLOAD_PID = 77

LEDGER_TARGETS = (
    'celery_worker',
    'gunicorn_worker',
    'postgres_backend',
    'postmaster',
    'rabbitmq',
    'redis_server',
    'workload',
)

PIDFILES = types.MappingProxyType(
    {'/run/celery.pid': 300, '/run/gunicorn.pid': 200, POSTMASTER_PID: 100},
)

PROCESSES = (
    (1, 0, '/init'),
    (100, 1, '/usr/lib/postgresql/17/bin/postgres -c config_file=/etc/postgresql'),
    (101, 100, 'postgres: ledger ledger [local] idle'),
    (102, 100, 'postgres: checkpointer'),
    (103, 100, 'postgres: ledger ledger 127.0.0.1(40112) idle'),
    (104, 100, 'postgres: ledger ledger 10.77.0.1(40113) idle'),
    (200, 1, '/opt/venv/bin/python /opt/venv/bin/gunicorn ledger.wsgi'),
    (201, 200, '/opt/venv/bin/python /opt/venv/bin/gunicorn ledger.wsgi'),
    (202, 200, '/opt/venv/bin/python /opt/venv/bin/gunicorn ledger.wsgi'),
    (300, 1, '/opt/venv/bin/python /opt/venv/bin/celery -A ledger.celery worker'),
    (301, 300, '/opt/venv/bin/python /opt/venv/bin/celery -A ledger.celery worker'),
    (400, 1, '/usr/lib/erlang/erts/bin/beam.smp -- -s rabbit boot'),
    (500, 1, 'redis-server 0.0.0.0:6379'),
    (600, 1, '/usr/bin/dockerd -H unix:///run/docker.sock'),
    (601, 1, '/usr/bin/containerd --config /etc/containerd/config.toml'),
    (700, 1, 'python /opt/project/harness/driver.py redis-server'),
)


def _backends(postmaster: int) -> list[int]:
    assert postmaster > 0

    backends = []

    for pid, ppid, command in PROCESSES:
        if ppid != postmaster:
            continue

        if any(client in command for client in POSTGRES_CLIENTS):
            backends.append(pid)

    return backends


def _children(parent: int) -> list[int]:
    assert parent > 0

    return [pid for pid, ppid, _ in PROCESSES if ppid == parent]


def _references() -> dict[str, list[int]]:
    return {
        'celery_worker': _children(PIDFILES['/run/celery.pid']),
        'gunicorn_worker': _children(PIDFILES['/run/gunicorn.pid']),
        'postgres_backend': _backends(PIDFILES[POSTMASTER_PID]),
        'postmaster': [PIDFILES[POSTMASTER_PID]],
        'rabbitmq': [pid for pid, _, command in PROCESSES if '-s rabbit' in command],
        'redis_server': [
            pid for pid, _, command in PROCESSES if command.startswith('redis-server')
        ],
        'workload': [WORKLOAD_PID],
    }


def _roster_load(tmp_path: Path, rules: Any, targets: str = '', links: str = '') -> Any:
    assert tmp_path.is_dir()
    assert rules is not None
    assert isinstance(targets, str)
    assert isinstance(links, str)

    path = tmp_path / 'faults.json'
    path.write_text(json.dumps(rules))

    environment = {'CELESTE_FAULTS': str(path), 'CELESTE_LINKS': links, 'CELESTE_TARGETS': targets}

    with mock.patch.dict(os.environ, environment):
        return agent._roster()


@pytest.fixture(autouse=True)
def root_probe_in_the_test_directory(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    monkeypatch.setattr(agent, 'ROOT_PROBE', str(tmp_path / 'celeste-writable'))


def test_a_link_gets_its_bands_in_roster_order_and_an_empty_roster_reads_no_file(
    tmp_path: Path,
) -> None:
    assert tmp_path.is_dir()

    rules = {'links': {'cache': {'port': 6379}, 'database': {'port': 5432}}}
    targets, links = _roster_load(tmp_path, rules, links='database,cache')
    environment = {'CELESTE_FAULTS': '/nonexistent', 'CELESTE_LINKS': '', 'CELESTE_TARGETS': ''}

    assert targets == []
    assert [link['name'] for link in links] == ['database', 'cache']
    assert [link['bands'] for link in links] == [(4, 5), (6, 7)]

    with mock.patch.dict(os.environ, environment):
        assert agent._roster() == ([], [])


@pytest.mark.parametrize(
    ('rules', 'error'),
    [
        ({'targets': {}}, KeyError),
        ({'targets': {'cache': {}}}, ValueError),
        ({'targets': {'cache': {'program': 'redis', 'colour': 1}}}, ValueError),
        ({'targets': {'cache': {'command_contains': 'redis'}}}, TypeError),
        ({'targets': {'cache': {'program': 'redis', 'restart': 'service'}}}, TypeError),
        ({'targets': []}, TypeError),
        ({'targets': {'cache': 'redis'}}, TypeError),
        ([], TypeError),
    ],
)
def test_a_target_without_a_rule_or_with_a_rule_it_cannot_read_is_refused(
    error: type[Exception],
    rules: Any,
    tmp_path: Path,
) -> None:
    assert issubclass(error, Exception)
    assert rules is not None
    assert tmp_path.is_dir()

    with pytest.raises(error):
        _roster_load(tmp_path, rules, targets='cache')


@pytest.mark.parametrize(
    'rules',
    [
        {'links': {'cache': {}}},
        {'links': {'cache': {'port': '6379'}}},
        {'links': {'cache': {'port': True}}},
        {'links': {'cache': {'port': 0}}},
        {'links': {'cache': {'port': 70000}}},
    ],
)
def test_a_link_without_a_usable_port_is_refused(rules: Any, tmp_path: Path) -> None:
    assert isinstance(rules, dict)
    assert tmp_path.is_dir()

    with pytest.raises((TypeError, ValueError), match='port'):
        _roster_load(tmp_path, rules, links='cache')


def test_a_roster_naming_an_entry_twice_is_refused(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    rules = {'targets': {'cache': {'program': 'redis'}}}

    with pytest.raises(ValueError, match='twice'):
        _roster_load(tmp_path, rules, targets='cache,cache')


def test_the_ledger_rules_select_what_the_hardcoded_selection_did(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    rules = json.loads(LEDGER_FAULTS.read_text())
    targets, _ = _roster_load(tmp_path, rules, targets=','.join(LEDGER_TARGETS))

    with (
        mock.patch.object(agent, '_processes', return_value=sorted(PROCESSES)),
        mock.patch.object(agent, '_pid_file', side_effect=PIDFILES.get),
        mock.patch.object(agent.os, 'getppid', return_value=WORKLOAD_PID),
    ):
        selected = {target['name']: agent._targets(target) for target in targets}

    references = _references()

    for name in LEDGER_TARGETS:
        assert selected[name] == references[name], name
        assert selected[name] != [], name


def test_a_program_rule_matches_the_executable_name_alone(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    rules = {
        'targets': {'containerd': {'program': 'containerd'}, 'dockerd': {'program': 'dockerd'}},
    }
    targets, _ = _roster_load(tmp_path, rules, targets='containerd,dockerd')

    with mock.patch.object(agent, '_processes', return_value=sorted(PROCESSES)):
        assert agent._targets(targets[0]) == [601]
        assert agent._targets(targets[1]) == [600]


def test_a_missing_pidfile_selects_nothing_rather_than_everything() -> None:
    parented = {'name': 'cache', 'parent_pidfile': '/run/absent.pid'}
    owned = {'name': 'cache', 'pidfile': '/run/absent.pid'}

    with (
        mock.patch.object(agent, '_processes', return_value=sorted(PROCESSES)),
        mock.patch.object(agent, '_pid_file', return_value=None),
    ):
        assert agent._targets(parented) == []
        assert agent._targets(owned) == []


@pytest.mark.parametrize('index', [0, 2, -1])
def test_an_index_outside_the_roster_is_refused_instead_of_wrapping(index: int) -> None:
    assert index != 1

    roster = agent.Agent([{'name': 'cache', 'program': 'redis'}], [])

    with pytest.raises(RuntimeError, match='roster'):
        agent._target_rule(roster, index)

    with pytest.raises(RuntimeError, match='roster'):
        agent._link_rule(roster, 1)

    assert agent._target_rule(roster, 1)['name'] == 'cache'


def test_an_agent_error_is_reported_and_marked_for_a_workload_waiting_on_quiet(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    lines: list[str] = []
    marker = tmp_path / 'celeste-agent-error'

    monkeypatch.setattr(agent, 'AGENT_ERROR_MARKER', str(marker))
    monkeypatch.setattr(agent, 'emit', lines.append)

    agent._agent_error(KeyError('postgres'))

    assert lines == ["AGENT ERROR KeyError: 'postgres'"]
    assert marker.is_file()


def test_an_immune_hog_asks_the_oom_killer_for_each_kill_once_it_reaches_the_floor(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    kernel = {'available': 100 << 20, 'kills': 0}
    lines: list[str] = []
    trigger = tmp_path / 'sysrq-trigger'
    event = {'kind': 'memory', 'duration_ns': 0, 'memory_immune': 1, 'memory_kills': 2}

    def chunk() -> object:
        kernel['available'] -= agent.MEMORY_CHUNK

        return object()

    def meminfo(name: str) -> int:
        assert name in ('MemAvailable', 'MemTotal')

        return {'MemAvailable': kernel['available'], 'MemTotal': 1 << 30}[name]

    def sleep(seconds: float) -> None:
        assert seconds >= 0

        if not trigger.is_file():
            return

        assert trigger.read_text() == agent.SYSRQ_OOM

        trigger.unlink()
        kernel['available'] += 50 << 20
        kernel['kills'] += 1

    monkeypatch.setattr(agent, 'OOM_SCORE_ADJ', str(tmp_path / 'oom_score_adj'))
    monkeypatch.setattr(agent, 'SYSRQ_TRIGGER', str(trigger))
    monkeypatch.setattr(agent, '_memory_chunk', chunk)
    monkeypatch.setattr(agent, '_meminfo', meminfo)
    monkeypatch.setattr(agent, '_oom_kills', lambda: kernel['kills'])
    monkeypatch.setattr(agent, 'emit', lines.append)
    monkeypatch.setattr(agent.time, 'sleep', sleep)

    agent._memory_hold(event)

    held = 100 - 32
    assert kernel['kills'] == 2
    assert kernel['available'] > agent.MEMORY_FLOOR - agent.MEMORY_CHUNK
    assert lines == [f'FAULT memory hog holding {held << 20} after 2 kills']


def test_a_timed_heal_that_fails_stays_registered_so_the_quiet_point_retries_it(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    lines: list[str] = []
    attempts: list[int] = []
    quiet = tmp_path / 'celeste-quiet'
    unhealed = tmp_path / 'celeste-unhealed'
    state = agent.Agent([], [])

    def restart(_agent: agent.Agent) -> None:
        assert _agent is state

        attempts.append(len(attempts))

        if len(attempts) == 1:
            raise OSError(5, 'Input/output error')

    monkeypatch.setattr(agent, 'QUIET_MARKER', str(quiet))
    monkeypatch.setattr(agent, 'UNHEALED_MARKER', str(unhealed))
    monkeypatch.setattr(agent, 'emit', lines.append)
    monkeypatch.setattr(agent.ports, 'control', lambda _value: None)

    agent._heal_register(state, 1, restart, 0)
    agent._run(state)

    assert attempts == [0]
    assert 1 in state.heals

    agent._heal_all(state)

    assert attempts == [0, 1]
    assert state.heals == {}
    assert quiet.is_file()
    assert not unhealed.exists()
    assert lines == ['FAULT unavailable _heal_run: [Errno 5] Input/output error', 'QUIET']


def test_a_failing_heal_runs_the_heals_after_it_and_marks_the_quiet_point_unhealed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    lines: list[str] = []
    controls: list[int] = []
    healed: list[str] = []
    quiet = tmp_path / 'celeste-quiet'
    unhealed = tmp_path / 'celeste-unhealed'
    state = agent.Agent([], [])

    def vanished(_agent: agent.Agent) -> None:
        assert _agent is state

        raise ProcessLookupError(3, 'No such process')

    def restart(_agent: agent.Agent) -> None:
        assert _agent is state

        healed.append('postmaster')

    state.heals = {1: vanished, 2: restart}

    monkeypatch.setattr(agent, 'QUIET_MARKER', str(quiet))
    monkeypatch.setattr(agent, 'UNHEALED_MARKER', str(unhealed))
    monkeypatch.setattr(agent, 'emit', lines.append)
    monkeypatch.setattr(agent.ports, 'control', controls.append)

    agent._heal_all(state)

    assert healed == ['postmaster']
    assert state.heals == {}
    assert controls == [agent.ports.QUIET]
    assert unhealed.is_file()
    assert not quiet.exists()
    assert lines == ['FAULT unhealed: [Errno 3] No such process', 'QUIET']

    agent._heal_all(state)

    assert quiet.is_file()


def test_the_quiet_point_restarts_each_restartable_target_found_down_once(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    lines: list[str] = []
    restarted: list[str] = []
    quiet = tmp_path / 'celeste-quiet'
    unhealed = tmp_path / 'celeste-unhealed'
    rules = json.loads(LEDGER_FAULTS.read_text())
    names = 'gunicorn_worker,postmaster,rabbitmq,redis_server'
    targets, links = _roster_load(tmp_path, rules, targets=names)
    state = agent.Agent(targets, links)
    alive = [entry for entry in PROCESSES if entry[0] not in {100, 400}]
    pidfiles = {**PIDFILES, POSTMASTER_PID: None}
    rabbitmq = targets[2]

    def restart(target: Any, _agent: agent.Agent) -> None:
        assert 'restart' in target
        assert _agent is state

        restarted.append(target['name'])

    monkeypatch.setattr(agent, 'QUIET_MARKER', str(quiet))
    monkeypatch.setattr(agent, 'UNHEALED_MARKER', str(unhealed))
    monkeypatch.setattr(agent, 'emit', lines.append)
    monkeypatch.setattr(agent, '_pid_file', pidfiles.get)
    monkeypatch.setattr(agent, '_processes', lambda: sorted(alive))
    monkeypatch.setattr(agent, '_restart', restart)
    monkeypatch.setattr(agent.ports, 'control', lambda _value: None)

    state.heals = {1: functools.partial(agent._restart, rabbitmq)}

    agent._heal_all(state)

    assert rabbitmq['name'] == 'rabbitmq'
    assert restarted == ['rabbitmq', 'postmaster']
    assert state.heals == {}
    assert quiet.is_file()
    assert not unhealed.exists()
    assert not Path(agent.ROOT_PROBE).exists()
    assert lines == ['FAULT down postmaster at the quiet point', 'QUIET']


def test_a_root_that_refuses_writes_marks_the_quiet_point_unhealed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    lines: list[str] = []
    quiet = tmp_path / 'celeste-quiet'
    unhealed = tmp_path / 'celeste-unhealed'
    state = agent.Agent([], [])

    def refused(path: str, flags: int, mode: int = 0o777) -> int:
        assert path == agent.ROOT_PROBE
        assert flags & os.O_CREAT
        assert mode >= 0

        message = 'Read-only file system'
        raise OSError(errno.EROFS, message, path)

    monkeypatch.setattr(agent, 'QUIET_MARKER', str(quiet))
    monkeypatch.setattr(agent, 'UNHEALED_MARKER', str(unhealed))
    monkeypatch.setattr(agent, 'emit', lines.append)
    monkeypatch.setattr(agent.os, 'open', refused)
    monkeypatch.setattr(agent.ports, 'control', lambda _value: None)

    agent._heal_all(state)

    refusal = f"[Errno 30] Read-only file system: '{agent.ROOT_PROBE}'"

    assert unhealed.is_file()
    assert not quiet.exists()
    assert lines == [f'FAULT unhealed: the root filesystem refuses writes: {refusal}', 'QUIET']


def test_a_thread_pause_ends_quietly_when_its_process_was_killed_meanwhile(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)

    lines: list[str] = []
    reaped: list[tuple[int, int]] = []

    def detach(request: int, tid: int) -> None:
        assert request == agent.PTRACE_DETACH
        assert tid == 299

        raise OSError(3, 'No such process')

    def waitpid(pid: int, options: int) -> tuple[int, int]:
        assert pid > 0
        assert options & os.WNOHANG

        reaped.append((pid, options))

        return pid, 9

    monkeypatch.setattr(agent, '_ptrace', detach)
    monkeypatch.setattr(agent, 'emit', lines.append)
    monkeypatch.setattr(agent.os, 'waitpid', waitpid)

    agent._thread_pause_end('postmaster', 299, 299, agent.Agent([], []))

    assert reaped == [(299, agent.WAIT_ALL | os.WNOHANG)]
    assert lines == ['FAULT thread pause postmaster pid 299 tid 299 already gone']


def test_an_oom_request_is_repeated_while_the_last_victim_is_still_exiting(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    kernel = {'kills': 0, 'requests': 0}
    trigger = tmp_path / 'sysrq-trigger'

    def sleep(seconds: float) -> None:
        assert seconds == agent.OOM_POLL

        if not trigger.is_file():
            return

        trigger.unlink()
        kernel['requests'] += 1

        if kernel['requests'] == 2:
            kernel['kills'] += 1

    monkeypatch.setattr(agent, 'SYSRQ_TRIGGER', str(trigger))
    monkeypatch.setattr(agent, '_oom_kills', lambda: kernel['kills'])
    monkeypatch.setattr(agent.time, 'sleep', sleep)

    agent._oom_invoke()

    assert kernel == {'kills': 1, 'requests': 2}


def test_the_agent_waits_for_ready_to_open_the_fault_window(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    window = tmp_path / 'window'

    monkeypatch.setattr(agent, 'WINDOW_MARKER', str(window))
    monkeypatch.setattr(agent, 'WINDOW_POLL', 0)
    monkeypatch.setattr(agent, 'WINDOW_POLLS_MAX', 2)

    with pytest.raises(RuntimeError):
        agent._window_wait()

    window.touch()
    agent._window_wait()


def test_the_staged_tc_resolves_every_library_from_the_staging_directory(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    tools = tmp_path / 'tools'

    monkeypatch.setattr(agent, 'TOOLS', str(tools))

    staged = agent._tools_stage()

    loader = tools / Path(agent.LOADER).name
    tc = tools / Path(agent.TC_SOURCE).name
    prefix = [str(loader), '--library-path', str(tools)]
    listing = [*prefix, '--list', str(tc)]
    listed = subprocess.run(listing, capture_output=True, check=True, text=True)
    resolved = [word for word in listed.stdout.split() if word.startswith('/')]
    loaded = {Path(word) for word in resolved if word != agent.LOADER}
    version = subprocess.run([*prefix, str(tc), '-V'], capture_output=True, check=True, text=True)

    assert sorted(staged) == sorted(str(path) for path in tools.iterdir())
    assert {loader, tc} <= {Path(path) for path in staged}
    assert all(path.parent == tools for path in loaded)
    assert loaded | {tc} == {Path(path) for path in staged}
    assert version.stdout.startswith('tc utility')
