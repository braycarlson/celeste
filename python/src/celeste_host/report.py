from __future__ import annotations

import enum
import json

from dataclasses import dataclass
from pathlib import Path

from typing_extensions import Any

from celeste import Kind
from celeste_host.event import EventError, event_from_fields
from celeste_host.fault import Applied, FaultError, timeline
from celeste_host.roster import Roster, RosterError, roster_from_fields


DETAILS_SEPARATOR = ' | '
INTERFACE_VERSION = 2


class Eventually(enum.StrEnum):
    UNREACHED = 'unreached'
    PASSED = 'passed'
    FAILED = 'failed'


class ReportError(ValueError):
    pass


@dataclass(frozen=True)
class Failure:
    detail: str
    error: str


@dataclass(frozen=True)
class Property:
    kind: Kind
    message: str


@dataclass(frozen=True)
class Result:
    acknowledged: int
    checked: bool
    eventually: Eventually
    failed_assertions: int
    failure: Failure | None
    faults: tuple[Applied, ...]
    lost: int
    passed: bool
    present: int
    reproducer: Path | None
    seed: int
    shrunk_faults: tuple[Applied, ...]
    violation: Violation | None


@dataclass(frozen=True)
class Violation:
    details: str | None
    message: str


@dataclass(frozen=True)
class Report:
    interface_version: int
    results: tuple[Result, ...]
    roster: Roster
    seeds: int
    unreached: tuple[Property, ...]
    violations: int

    @property
    def failed(self) -> tuple[Result, ...]:
        return tuple(result for result in self.results if not result.passed)


def _faults(fields: dict[str, Any], name: str, roster: Roster) -> tuple[Applied, ...]:
    assert isinstance(fields, dict)
    assert name in ('events', 'shrunk_events')
    assert isinstance(roster, Roster)

    raw = _field(fields, name, list)

    try:
        events = [event_from_fields(entry) for entry in raw]
        faults = timeline(events, roster)
    except (EventError, FaultError) as error:
        message = f'the report event list {name} is invalid: {error}'
        raise ReportError(message) from error

    return faults


def _field[Value](fields: dict[str, Any], name: str, kind: type[Value]) -> Value:
    assert isinstance(fields, dict)
    assert len(name) > 0
    assert isinstance(kind, type)

    if name not in fields:
        message = f'the report lacks the field {name}'
        raise ReportError(message)

    value = fields[name]

    if kind is int:
        if isinstance(value, bool):
            message = f'the report field {name} is an integer, not {value!r}'
            raise ReportError(message)

    if not isinstance(value, kind):
        message = f'the report field {name} is a {kind.__name__}, not {value!r}'
        raise ReportError(message)

    return value


def _optional(fields: dict[str, Any], name: str) -> str | None:
    assert isinstance(fields, dict)
    assert len(name) > 0

    value = fields.get(name)

    if value is None:
        return None

    if not isinstance(value, str):
        message = f'the report field {name} is text or null, not {value!r}'
        raise ReportError(message)

    return value


def _property(fields: dict[str, Any]) -> Property:
    assert isinstance(fields, dict)

    kind = _field(fields, 'kind', str)

    if kind not in Kind:
        message = f'a property kind is one of {[entry.value for entry in Kind]}, not {kind!r}'
        raise ReportError(message)

    return Property(kind=Kind(kind), message=_field(fields, 'message', str))


def _result(fields: dict[str, Any], roster: Roster) -> Result:
    assert isinstance(fields, dict)
    assert isinstance(roster, Roster)

    eventually = _field(fields, 'eventually', str)

    if eventually not in Eventually:
        message = f'the eventually phase ends unreached, passed, or failed, not {eventually!r}'
        raise ReportError(message)

    reproducer = _optional(fields, 'reproducer')
    detail = _field(fields, 'detail', str)
    error = _optional(fields, 'failure')
    failed_assertions = _field(fields, 'failed_assertions', int)

    return Result(
        acknowledged=_field(fields, 'acknowledged', int),
        checked=_field(fields, 'checked', bool),
        eventually=Eventually(eventually),
        failed_assertions=failed_assertions,
        failure=Failure(detail=detail, error=error) if error is not None else None,
        faults=_faults(fields, 'events', roster),
        lost=_field(fields, 'lost', int),
        passed=_field(fields, 'passed', bool),
        present=_field(fields, 'present', int),
        reproducer=Path(reproducer) if reproducer is not None else None,
        seed=_field(fields, 'seed', int),
        shrunk_faults=_faults(fields, 'shrunk_events', roster),
        violation=_violation(detail) if failed_assertions > 0 else None,
    )


def _violation(detail: str) -> Violation:
    assert len(detail) > 0

    message, separator, details = detail.partition(DETAILS_SEPARATOR)

    return Violation(details=details if separator else None, message=message)


def report_from_fields(fields: dict[str, Any]) -> Report:
    assert isinstance(fields, dict)

    interface_version = _field(fields, 'interface_version', int)

    if interface_version != INTERFACE_VERSION:
        message = (
            f'the report speaks interface version {interface_version}, not {INTERFACE_VERSION}'
        )

        raise ReportError(message)

    try:
        roster = roster_from_fields(_field(fields, 'roster', dict))
    except RosterError as error:
        message = f'the report roster is invalid: {error}'
        raise ReportError(message) from error

    results = tuple(_result(entry, roster) for entry in _field(fields, 'results', list))
    unreached = tuple(_property(entry) for entry in _field(fields, 'unreached', list))
    seeds = _field(fields, 'seeds', int)

    if seeds != len(results):
        message = f'the report claims {seeds} seeds and carries {len(results)} results'
        raise ReportError(message)

    return Report(
        interface_version=interface_version,
        results=results,
        roster=roster,
        seeds=seeds,
        unreached=unreached,
        violations=_field(fields, 'violations', int),
    )


def report_load(path: Path) -> Report:
    assert isinstance(path, Path)

    if not path.is_file():
        message = f'celeste wrote no report at {path}'
        raise ReportError(message)

    try:
        fields = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        message = f'the report at {path} is not JSON: {error}'
        raise ReportError(message) from error

    if not isinstance(fields, dict):
        message = f'the report at {path} is not a JSON object'
        raise ReportError(message)

    return report_from_fields(fields)
