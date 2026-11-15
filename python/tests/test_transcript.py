from __future__ import annotations

import dataclasses

import pytest

from pathlib import Path

from celeste_host.event import Event
from celeste_host.fault import Applied, Kill
from celeste_host.roster import Roster, Target
from celeste_host.transcript import (
    Failure,
    Step,
    TranscriptError,
    transcript_entries,
    transcript_load,
    transcript_path,
)


ROSTER = Roster(links=('postgres',), targets=(Target('web'), Target('db')))


def _echo(**overrides: int | str) -> str:
    assert isinstance(overrides, dict)

    values: dict[str, int | str] = {
        name: 0 for name in (entry.name for entry in dataclasses.fields(Event)) if name != 'magic'
    }

    values.update({'kind': 'none', 'network_direction': 'both', **overrides})

    return 'CELESTE EVENT ' + ' '.join(f'{name}={value}' for name, value in values.items()) + ' END'


def test_a_transcript_yields_steps_and_events_in_order(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    lines = [
        'CELESTE GUEST UP',
        'CELESTE STEP place order',
        'CELESTE NOTE workload seed 7',
        _echo(kind='kill', target=2, delay_ns=5),
        'CELESTE STEP browse catalogue\r',
        'CELESTE ALWAYS PASS stock never negative',
    ]
    path = tmp_path / 'transcript.17.shrunk'

    path.write_text('\n'.join(lines) + '\n')

    entries = transcript_load(path, ROSTER)

    assert entries == transcript_entries(lines, ROSTER)
    assert entries == [
        Step('place order'),
        Applied(at_ns=5, fault=Kill(restart_delay_ns=None, target=Target('db'))),
        Step('browse catalogue'),
    ]


def test_a_transcript_ends_at_the_first_failed_assertion() -> None:
    lines = [
        'CELESTE STEP place order',
        'CELESTE ALWAYS FAIL stock never negative | -3',
        'CELESTE STEP browse catalogue',
        _echo(kind='kill', target=2, delay_ns=5),
        'CELESTE ALWAYS FAIL stock never negative',
    ]

    entries = transcript_entries(lines, ROSTER)

    assert entries == [Step('place order'), Failure('stock never negative | -3')]
    assert transcript_entries(lines[:1], ROSTER) == [Step('place order')]


def test_a_transcript_path_follows_the_hypervisor_naming() -> None:
    output = Path('/cache/run/transcript')

    assert transcript_path(output, 17, shrunk=False) == Path('/cache/run/transcript.17')
    assert transcript_path(output, 17, shrunk=True) == Path('/cache/run/transcript.17.shrunk')


def test_a_missing_or_oversized_transcript_is_refused(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    with pytest.raises(TranscriptError, match='no transcript'):
        transcript_load(tmp_path / 'transcript.1', ROSTER)

    with pytest.raises(TranscriptError, match='at most 1000000 lines'):
        transcript_entries([''] * 1_000_001, ROSTER)


def test_a_protocol_line_after_another_writers_unfinished_output_is_still_read() -> None:
    lines = [
        'waiting for server to start....CELESTE STEP place order',
        '.' + _echo(kind='kill', target=2, delay_ns=5),
        'CELESTE STEP browse catalogueCELESTE ALWAYS FAIL stock never negative',
    ]

    entries = transcript_entries(lines, ROSTER)

    assert entries == [
        Step('place order'),
        Applied(at_ns=5, fault=Kill(restart_delay_ns=None, target=Target('db'))),
        Step('browse catalogueCELESTE ALWAYS FAIL stock never negative'),
    ]
