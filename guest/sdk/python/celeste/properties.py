from __future__ import annotations

import enum
import json
import threading
import uuid
import zlib

from dataclasses import dataclass
from typing import TYPE_CHECKING

from celeste import ports
from celeste.console import clean, emit

if TYPE_CHECKING:
    from collections.abc import Sequence
    from typing import Any


DETAILS_SEPARATOR = ' | '
IDENTIFIER_LENGTH = 36
PROPERTIES_MAX = 256
WORD_BITS = 64

_maxima: dict[str, int] = {}
_maxima_lock = threading.Lock()
_reported: set[tuple[str, ...]] = set()
_reported_lock = threading.Lock()


class Kind(enum.StrEnum):
    ALWAYS = 'always'
    MAXIMIZE = 'maximize'
    REACHABLE = 'reachable'
    SOMETIMES = 'sometimes'
    UNREACHABLE = 'unreachable'


@dataclass(frozen=True)
class Property:
    kind: Kind
    message: str


def _details(details: Any) -> str:
    assert details is not None

    return DETAILS_SEPARATOR + json.dumps(details, default=str, sort_keys=True)


def _identifier(identifier: str) -> str:
    assert len(identifier) == IDENTIFIER_LENGTH, (
        f'an acknowledgement identifier is a UUID, not {identifier!r}'
    )

    try:
        parsed = uuid.UUID(identifier)
    except ValueError:
        parsed = None

    assert parsed is not None, f'an acknowledgement identifier is a UUID, not {identifier!r}'
    assert str(parsed) == identifier, (
        f'an acknowledgement identifier is a canonical lowercase UUID, not {identifier!r}'
    )

    return identifier


def _report(key: tuple[str, ...], *words: str) -> None:
    assert len(key) > 0

    with _reported_lock:
        if key in _reported:
            return

        _reported.add(key)

    emit(*words)


def ack(identifier: str) -> None:
    assert isinstance(identifier, str)

    emit('ACK', _identifier(identifier))


def always(condition: bool, message: str, *, details: Any = None) -> None:
    assert isinstance(message, str)
    assert not callable(details)

    cleaned = clean(message)

    if condition:
        _report(('always', 'PASS', cleaned), 'ALWAYS', 'PASS', cleaned)
    else:
        suffix = '' if details is None else _details(details)

        _report(('always', 'FAIL', cleaned), 'ALWAYS', 'FAIL', cleaned + suffix)


def declare(properties: Sequence[Property]) -> None:
    assert len(properties) <= PROPERTIES_MAX, (
        f'a run declares at most {PROPERTIES_MAX} properties, not {len(properties)}'
    )

    declared = []

    for declared_property in properties:
        assert isinstance(declared_property.kind, Kind), (
            f'a property kind is a celeste.Kind, not {declared_property.kind!r}'
        )

        declared.append((declared_property.kind, clean(declared_property.message)))

    for kind, cleaned in declared:
        emit('DECLARE', kind.value, cleaned)


def eventually(condition: bool, message: str, *, details: Any = None) -> None:
    assert isinstance(message, str)
    assert not callable(details)

    always(condition, message, details=details)
    emit('EVENTUALLY', 'PASS' if condition else 'FAIL')


def maximize(message: str, value: int) -> None:
    assert isinstance(message, str)
    assert 0 <= value < 1 << WORD_BITS, (
        f'a maximized value fits in {WORD_BITS} bits, unlike {value}'
    )

    cleaned = clean(message)

    with _maxima_lock:
        if _maxima.get(cleaned, -1) >= value:
            return

        _maxima[cleaned] = value

    ports.guidance(zlib.crc32(cleaned.encode()), value)


def note(message: str) -> None:
    assert isinstance(message, str)

    emit('NOTE', clean(message))


def present(identifier: str) -> None:
    assert isinstance(identifier, str)

    emit('PRESENT', _identifier(identifier))


def reachable(message: str) -> None:
    assert isinstance(message, str)

    cleaned = clean(message)

    _report(('reachable', cleaned), 'REACHABLE', cleaned)


def sometimes(condition: bool, message: str) -> None:
    assert isinstance(message, str)

    if not condition:
        return

    cleaned = clean(message)

    _report(('sometimes', cleaned), 'SOMETIMES', cleaned)


def step(message: str) -> None:
    assert isinstance(message, str)

    emit('STEP', clean(message))


def unreachable(message: str, *, details: Any = None) -> None:
    assert isinstance(message, str)
    assert not callable(details)

    cleaned = clean(message)
    suffix = '' if details is None else _details(details)

    _report(('unreachable', cleaned), 'UNREACHABLE', cleaned + suffix)
