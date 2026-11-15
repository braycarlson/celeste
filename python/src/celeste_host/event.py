from __future__ import annotations

import enum

from dataclasses import dataclass, fields

from typing_extensions import Any


ECHO_PREFIX = 'CELESTE EVENT '
ECHO_SUFFIX = ' END'
MAGIC = 0x32455453454C4543
PERMILLE = 1000


class Direction(enum.StrEnum):
    BOTH = 'both'
    REQUESTS = 'requests'
    REPLIES = 'replies'


class EventError(ValueError):
    pass


class EventKind(enum.StrEnum):
    NONE = 'none'
    CLOCK_JUMP = 'clock_jump'
    CLOCK_SLEW = 'clock_slew'
    DISK_FULL = 'disk_full'
    KILL = 'kill'
    MEMORY = 'memory'
    NETWORK = 'network'
    PAUSE = 'pause'
    THREAD_PAUSE = 'thread_pause'
    THROTTLE = 'throttle'


@dataclass(frozen=True)
class Event:
    magic: int
    kind: EventKind
    delay_ns: int
    duration_ns: int
    target: int
    choice: int
    restart: int
    restart_delay_ns: int
    clock_jump_ns: int
    clock_slew_ppm: int
    disk_full_slack_kib: int
    memory_immune: int
    memory_kills: int
    network_delay_ns: int
    network_direction: Direction
    network_jitter_ns: int
    network_link: int
    network_loss_permille: int
    network_peers: int
    network_reorder_permille: int
    pause_tree: int
    thread_choice: int
    throttle_permille: int

    def __post_init__(self) -> None:
        if self.magic != MAGIC:
            message = f'an event carries magic {self.magic:#x}, not {MAGIC:#x}'
            raise EventError(message)

        _permille_validate(self.network_loss_permille, 'network_loss_permille')
        _permille_validate(self.network_reorder_permille, 'network_reorder_permille')
        _permille_validate(self.throttle_permille, 'throttle_permille')


SCHEMA: tuple[tuple[str, type[int | enum.StrEnum]], ...] = (
    ('magic', int),
    ('kind', EventKind),
    ('delay_ns', int),
    ('duration_ns', int),
    ('target', int),
    ('choice', int),
    ('restart', int),
    ('restart_delay_ns', int),
    ('clock_jump_ns', int),
    ('clock_slew_ppm', int),
    ('disk_full_slack_kib', int),
    ('memory_immune', int),
    ('memory_kills', int),
    ('network_delay_ns', int),
    ('network_direction', Direction),
    ('network_jitter_ns', int),
    ('network_link', int),
    ('network_loss_permille', int),
    ('network_peers', int),
    ('network_reorder_permille', int),
    ('pause_tree', int),
    ('thread_choice', int),
    ('throttle_permille', int),
)

assert tuple(name for name, _ in SCHEMA) == tuple(entry.name for entry in fields(Event))


def _integer(name: str, value: Any) -> int:
    assert len(name) > 0
    assert value is not None

    if isinstance(value, bool):
        message = f'the event field {name} is an integer, not {value!r}'
        raise EventError(message)

    if isinstance(value, int):
        return value

    if not isinstance(value, str):
        message = f'the event field {name} is an integer, not {value!r}'
        raise EventError(message)

    if not value.removeprefix('-').isdigit():
        message = f'the event field {name} is an integer, not {value!r}'
        raise EventError(message)

    return int(value)


def _member[Member: enum.StrEnum](name: str, value: Any, kind: type[Member]) -> Member:
    assert len(name) > 0
    assert value is not None
    assert issubclass(kind, enum.StrEnum)

    if not isinstance(value, str):
        message = f'the event field {name} is a name, not {value!r}'
        raise EventError(message)

    if value not in kind:
        names = [member.value for member in kind]
        message = f'the event field {name} is one of {names}, not {value!r}'
        raise EventError(message)

    return kind(value)


def _permille_validate(value: int, name: str) -> None:
    assert isinstance(value, int)
    assert name.endswith('_permille')

    if not 0 <= value <= PERMILLE:
        message = f'an event {name} is 0 to {PERMILLE}, not {value}'
        raise EventError(message)


def event_from_echo(line: str) -> Event:
    assert isinstance(line, str)

    if not line.startswith(ECHO_PREFIX):
        message = f'an event echo starts with {ECHO_PREFIX!r}, unlike {line!r}'
        raise EventError(message)

    if not line.endswith(ECHO_SUFFIX):
        message = f'an event echo ends with {ECHO_SUFFIX!r}, unlike {line!r}'
        raise EventError(message)

    body = line.removeprefix(ECHO_PREFIX).removesuffix(ECHO_SUFFIX)
    values: dict[str, Any] = {'magic': MAGIC}

    for word in body.split(' '):
        name, separator, value = word.partition('=')

        if not separator:
            message = f'an event echo is made of name=value pairs, unlike {word!r} in {line!r}'
            raise EventError(message)

        values[name] = value

    return event_from_fields(values)


def event_from_fields(values: dict[str, Any]) -> Event:
    assert isinstance(values, dict)

    unknown = sorted(set(values) - {name for name, _ in SCHEMA})

    if unknown:
        message = f'an event carries no field named {unknown}'
        raise EventError(message)

    decoded: dict[str, Any] = {}

    for name, kind in SCHEMA:
        if name not in values:
            message = f'an event carries {name}, unlike {sorted(values)}'
            raise EventError(message)

        if issubclass(kind, enum.StrEnum):
            decoded[name] = _member(name, values[name], kind)
        else:
            decoded[name] = _integer(name, values[name])

    return Event(**decoded)
