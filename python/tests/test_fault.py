from __future__ import annotations

import dataclasses

import pytest

from typing_extensions import Any

from celeste_host.event import MAGIC, Direction, Event, EventError, EventKind, event_from_fields
from celeste_host.fault import (
    Applied,
    ClockJump,
    FaultError,
    Kill,
    Network,
    fault_from_event,
    timeline,
)
from celeste_host.roster import Roster, Target


LINKS = ('postgres', 'redis')
TARGETS = ('gunicorn_worker', 'postgres_backend', 'postmaster', 'redis_server', 'workload')
ROSTER = Roster(links=LINKS, targets=tuple(Target(name) for name in TARGETS))


def _event(**overrides: Any) -> Event:
    assert set(overrides) <= {entry.name for entry in dataclasses.fields(Event)}

    names = [entry.name for entry in dataclasses.fields(Event)]
    values: dict[str, Any] = dict.fromkeys(names, 0)

    values.update({'magic': MAGIC, 'kind': 'none', 'network_direction': 'both', **overrides})

    return event_from_fields(values)


def _link(name: str) -> int:
    assert name in LINKS

    return LINKS.index(name) + 1


def _target(name: str) -> int:
    assert name in TARGETS

    return TARGETS.index(name) + 1


SENTENCES = (
    (
        _event(kind='kill', target=_target('redis_server'), restart=1, restart_delay_ns=300000000),
        'killed redis_server and restarted it 300 ms later',
    ),
    (_event(kind='kill', target=_target('gunicorn_worker'), choice=1), 'killed gunicorn_worker'),
    (
        _event(
            kind='network',
            duration_ns=2000000000,
            network_link=_link('postgres'),
            network_loss_permille=1000,
        ),
        'cut postgres off (both directions) for 2.00 s',
    ),
    (
        _event(
            kind='network',
            duration_ns=500000000,
            network_delay_ns=2000000,
            network_direction='replies',
            network_link=_link('redis'),
            network_loss_permille=200,
        ),
        'degraded redis (replies only: 20% loss, 2000 µs delay) for 0.50 s',
    ),
    (
        _event(kind='pause', duration_ns=7000000000, pause_tree=1, target=_target('postmaster')),
        'froze postmaster for 7.00 s',
    ),
    (
        _event(
            kind='thread_pause', duration_ns=800000000, target=_target('workload'), thread_choice=1
        ),
        'froze one thread of workload for 0.80 s',
    ),
    (
        _event(
            kind='throttle',
            duration_ns=8000000000,
            target=_target('gunicorn_worker'),
            throttle_permille=10,
        ),
        'throttled gunicorn_worker to 1% of a CPU for 8.00 s',
    ),
    (_event(kind='clock_jump', clock_jump_ns=-5000000000), 'jumped the clock back 5.00 s'),
    (
        _event(kind='clock_slew', clock_slew_ppm=200, duration_ns=1000000000),
        'skewed the clock 200 ppm for 1.00 s',
    ),
    (_event(kind='disk_full', disk_full_slack_kib=64), 'filled the disk, leaving 64 KiB'),
    (
        _event(kind='memory', duration_ns=500000000, memory_immune=1, memory_kills=2),
        'exhausted memory until the out-of-memory killer struck 2 times',
    ),
)


@pytest.mark.parametrize(('event', 'sentence'), SENTENCES)
def test_each_fault_the_hypervisor_serves_reads_as_a_sentence(event: Event, sentence: str) -> None:
    assert event.kind is not EventKind.NONE
    assert len(sentence) > 0

    fault = fault_from_event(event, ROSTER)

    assert fault is not None
    assert fault.sentence == sentence


def test_an_event_resolves_its_roster_indices_and_flags_into_typed_fields() -> None:
    killed = fault_from_event(_event(kind='kill', target=_target('postmaster'), restart=1), ROSTER)
    cut = fault_from_event(
        _event(
            kind='network',
            network_direction='requests',
            network_link=_link('redis'),
            network_loss_permille=1000,
            network_peers=5,
        ),
        ROSTER,
    )

    assert killed == Kill(restart_delay_ns=0, target=Target('postmaster'))
    assert isinstance(cut, Network)
    assert cut.link == 'redis'
    assert cut.direction is Direction.REQUESTS
    assert cut.partition
    assert cut.peers == 5
    assert fault_from_event(_event(kind='none', delay_ns=7), ROSTER) is None


def test_a_timeline_accumulates_the_delays_and_drops_the_closing_none() -> None:
    events = [
        _event(kind='clock_jump', delay_ns=400000000, clock_jump_ns=5),
        _event(kind='kill', delay_ns=600000000, target=_target('postmaster')),
        _event(kind='none', delay_ns=2000000000),
    ]

    assert timeline(events, ROSTER) == (
        Applied(at_ns=400000000, fault=ClockJump(offset_ns=5)),
        Applied(at_ns=1000000000, fault=Kill(restart_delay_ns=None, target=Target('postmaster'))),
    )


def test_an_event_outside_the_roster_or_the_permille_range_is_refused() -> None:
    with pytest.raises(
        FaultError, match=f'target {len(TARGETS) + 1} of a roster of {len(TARGETS)}'
    ):
        fault_from_event(_event(kind='kill', target=len(TARGETS) + 1), ROSTER)

    with pytest.raises(FaultError, match='link 0 of a roster of 2'):
        fault_from_event(_event(kind='network', network_link=0), ROSTER)

    with pytest.raises(EventError, match='throttle_permille is 0 to 1000'):
        _event(kind='throttle', target=1, throttle_permille=1001)
