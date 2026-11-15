from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from celeste_host.event import ECHO_PREFIX, event_from_echo
from celeste_host.fault import Applied, fault_from_event
from celeste_host.roster import Roster


FAILURE_PREFIX = 'CELESTE ALWAYS FAIL '
LINES_MAX = 1_000_000
PROTOCOL_MARKER = 'CELESTE '
STEP_PREFIX = 'CELESTE STEP '


class TranscriptError(ValueError):
    pass


@dataclass(frozen=True)
class Failure:
    message: str


@dataclass(frozen=True)
class Step:
    message: str


def _protocol_line(line: str) -> str:
    assert '\n' not in line

    start = line.find(PROTOCOL_MARKER)

    return line if start < 0 else line[start:]


def transcript_entries(lines: list[str], roster: Roster) -> list[Step | Applied | Failure]:
    assert isinstance(lines, list)
    assert isinstance(roster, Roster)

    if len(lines) > LINES_MAX:
        message = f'a transcript holds at most {LINES_MAX} lines, not {len(lines)}'
        raise TranscriptError(message)

    entries: list[Step | Applied | Failure] = []
    at_ns = 0

    for raw in lines:
        line = _protocol_line(raw.rstrip('\r'))

        if line.startswith(FAILURE_PREFIX):
            entries.append(Failure(message=line[len(FAILURE_PREFIX) :]))

            return entries

        if line.startswith(STEP_PREFIX):
            entries.append(Step(message=line[len(STEP_PREFIX) :]))

            continue

        if not line.startswith(ECHO_PREFIX):
            continue

        event = event_from_echo(line)
        fault = fault_from_event(event, roster)
        at_ns += event.delay_ns

        if fault is not None:
            entries.append(Applied(at_ns=at_ns, fault=fault))

    return entries


def transcript_load(path: Path, roster: Roster) -> list[Step | Applied | Failure]:
    assert isinstance(path, Path)
    assert isinstance(roster, Roster)

    if not path.is_file():
        message = f'celeste wrote no transcript at {path}'
        raise TranscriptError(message)

    return transcript_entries(path.read_text(errors='replace').splitlines(), roster)


def transcript_path(output: Path, seed: int, *, shrunk: bool) -> Path:
    assert isinstance(output, Path)
    assert seed >= 0

    suffix = '.shrunk' if shrunk else ''

    return output.with_name(f'{output.name}.{seed}{suffix}')
