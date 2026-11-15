from __future__ import annotations

import dataclasses

import pytest

from typing_extensions import Any

from celeste_host.event import MAGIC, Event, EventError, event_from_echo, event_from_fields


def _event(**overrides: Any) -> Event:
    assert isinstance(overrides, dict)

    names = [entry.name for entry in dataclasses.fields(Event)]
    values: dict[str, Any] = dict.fromkeys(names, 0)

    values.update({'magic': MAGIC, 'kind': 'none', 'network_direction': 'both', **overrides})

    return event_from_fields(values)


def test_an_echo_decodes_to_the_same_event_the_report_carries() -> None:
    killed = _event(kind='kill', delay_ns=529321336, target=3, clock_jump_ns=-5)
    rendered = ' '.join(
        f'{name}={getattr(killed, name)}'
        for name in (entry.name for entry in dataclasses.fields(Event))
        if name != 'magic'
    )

    assert event_from_echo(f'CELESTE EVENT {rendered} END') == killed


@pytest.mark.parametrize(
    'line',
    [
        'CELESTE NOTE kind=kill END',
        'CELESTE EVENT kind=kill',
        'CELESTE EVENT kind END',
        'CELESTE EVENT kind=kill delay_ns=soon END',
    ],
)
def test_a_malformed_echo_is_refused(line: str) -> None:
    assert line.startswith('CELESTE ')

    with pytest.raises(EventError):
        event_from_echo(line)


def test_an_event_with_the_wrong_magic_a_missing_field_or_an_extra_field_is_refused() -> None:
    with pytest.raises(EventError, match='magic'):
        _event(magic=1)

    with pytest.raises(EventError, match='direction'):
        _event(network_direction='sideways')

    with pytest.raises(EventError, match='carries kind'):
        event_from_fields({'magic': MAGIC})

    with pytest.raises(EventError, match='no field named'):
        _event(teleport=1)

    with pytest.raises(EventError, match='is an integer'):
        _event(delay_ns=True)
