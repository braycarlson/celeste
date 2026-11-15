from __future__ import annotations

import types

from dataclasses import dataclass

from typing_extensions import TYPE_CHECKING

from celeste_host.event import MAGIC, Direction, Event, EventKind
from celeste_host.roster import Roster, RosterError, Target

if TYPE_CHECKING:
    from collections.abc import Sequence


MICROSECOND_NS = 1_000
MILLISECOND_NS = 1_000_000
PARTITION_PERMILLE = 1000
SECOND_NS = 1_000_000_000


class FaultError(ValueError):
    pass


@dataclass(frozen=True)
class ClockJump:
    offset_ns: int

    @property
    def sentence(self) -> str:
        direction = 'forward' if self.offset_ns >= 0 else 'back'

        return f'jumped the clock {direction} {seconds(abs(self.offset_ns))}'


@dataclass(frozen=True)
class ClockSlew:
    duration_ns: int
    rate_ppm: int

    @property
    def sentence(self) -> str:
        return f'skewed the clock {self.rate_ppm} ppm for {seconds(self.duration_ns)}'


@dataclass(frozen=True)
class DiskFull:
    slack_kib: int

    @property
    def sentence(self) -> str:
        return f'filled the disk, leaving {self.slack_kib} KiB'


@dataclass(frozen=True)
class Kill:
    restart_delay_ns: int | None
    target: Target

    @property
    def sentence(self) -> str:
        if self.restart_delay_ns is None:
            return f'killed {self.target.name}'

        delay_ms = self.restart_delay_ns // MILLISECOND_NS

        return f'killed {self.target.name} and restarted it {delay_ms} ms later'


@dataclass(frozen=True)
class Memory:
    duration_ns: int
    immune: bool
    kills: int

    @property
    def sentence(self) -> str:
        return f'exhausted memory until the out-of-memory killer struck {self.kills} times'


@dataclass(frozen=True)
class Network:
    delay_ns: int
    direction: Direction
    duration_ns: int
    jitter_ns: int
    link: str
    loss_permille: int
    peers: int
    reorder_permille: int

    @property
    def partition(self) -> bool:
        return self.loss_permille == PARTITION_PERMILLE

    @property
    def sentence(self) -> str:
        duration = seconds(self.duration_ns)

        if self.partition:
            return f'cut {self.link} off ({self.sides}) for {duration}'

        loss = f'{self.loss_permille / 10:g}% loss'
        delay = f'{self.delay_ns // MICROSECOND_NS} µs delay'

        return f'degraded {self.link} ({self.sides}: {loss}, {delay}) for {duration}'

    @property
    def sides(self) -> str:
        if self.direction is Direction.BOTH:
            return 'both directions'

        return f'{self.direction.value} only'


@dataclass(frozen=True)
class Pause:
    duration_ns: int
    target: Target
    tree: bool

    @property
    def sentence(self) -> str:
        return f'froze {self.target.name} for {seconds(self.duration_ns)}'


@dataclass(frozen=True)
class ThreadPause:
    duration_ns: int
    target: Target
    thread: int

    @property
    def sentence(self) -> str:
        return f'froze one thread of {self.target.name} for {seconds(self.duration_ns)}'


@dataclass(frozen=True)
class Throttle:
    duration_ns: int
    permille: int
    target: Target

    @property
    def sentence(self) -> str:
        share = f'{self.permille / 10:g}%'

        return f'throttled {self.target.name} to {share} of a CPU for {seconds(self.duration_ns)}'


Fault = ClockJump | ClockSlew | DiskFull | Kill | Memory | Network | Pause | ThreadPause | Throttle


@dataclass(frozen=True)
class Applied:
    at_ns: int
    fault: Fault


def _clock_jump(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.CLOCK_JUMP
    assert isinstance(roster, Roster)

    return ClockJump(offset_ns=event.clock_jump_ns)


def _clock_slew(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.CLOCK_SLEW
    assert isinstance(roster, Roster)

    return ClockSlew(duration_ns=event.duration_ns, rate_ppm=event.clock_slew_ppm)


def _disk_full(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.DISK_FULL
    assert isinstance(roster, Roster)

    return DiskFull(slack_kib=event.disk_full_slack_kib)


def _kill(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.KILL
    assert event.restart in (0, 1)
    assert len(roster.targets) > 0

    restart_delay_ns = event.restart_delay_ns if event.restart == 1 else None

    return Kill(restart_delay_ns=restart_delay_ns, target=roster.target(event.target))


def _memory(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.MEMORY
    assert isinstance(roster, Roster)

    return Memory(
        duration_ns=event.duration_ns,
        immune=event.memory_immune == 1,
        kills=event.memory_kills,
    )


def _network(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.NETWORK
    assert len(roster.links) > 0

    return Network(
        delay_ns=event.network_delay_ns,
        direction=event.network_direction,
        duration_ns=event.duration_ns,
        jitter_ns=event.network_jitter_ns,
        link=roster.link(event.network_link),
        loss_permille=event.network_loss_permille,
        peers=event.network_peers,
        reorder_permille=event.network_reorder_permille,
    )


def _pause(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.PAUSE
    assert len(roster.targets) > 0

    return Pause(
        duration_ns=event.duration_ns,
        target=roster.target(event.target),
        tree=event.pause_tree == 1,
    )


def _thread_pause(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.THREAD_PAUSE
    assert len(roster.targets) > 0

    return ThreadPause(
        duration_ns=event.duration_ns,
        target=roster.target(event.target),
        thread=event.thread_choice,
    )


def _throttle(event: Event, roster: Roster) -> Fault:
    assert event.kind is EventKind.THROTTLE
    assert len(roster.targets) > 0

    return Throttle(
        duration_ns=event.duration_ns,
        permille=event.throttle_permille,
        target=roster.target(event.target),
    )


BUILDERS = types.MappingProxyType(
    {
        EventKind.CLOCK_JUMP: _clock_jump,
        EventKind.CLOCK_SLEW: _clock_slew,
        EventKind.DISK_FULL: _disk_full,
        EventKind.KILL: _kill,
        EventKind.MEMORY: _memory,
        EventKind.NETWORK: _network,
        EventKind.PAUSE: _pause,
        EventKind.THREAD_PAUSE: _thread_pause,
        EventKind.THROTTLE: _throttle,
    },
)


def fault_from_event(event: Event, roster: Roster) -> Fault | None:
    assert event.magic == MAGIC
    assert event.delay_ns >= 0
    assert isinstance(roster, Roster)
    assert event.kind in BUILDERS or event.kind is EventKind.NONE

    if event.kind is EventKind.NONE:
        return None

    try:
        fault = BUILDERS[event.kind](event, roster)
    except RosterError as error:
        message = f'a {event.kind} event names what the roster lacks: {error}'
        raise FaultError(message) from error

    return fault


def seconds(ns: int) -> str:
    assert ns >= 0

    return f'{ns / SECOND_NS:.2f} s'


def timeline(events: Sequence[Event], roster: Roster) -> tuple[Applied, ...]:
    assert all(event.magic == MAGIC for event in events)
    assert len(roster.targets) >= 0

    applied = []
    at_ns = 0

    for event in events:
        at_ns += event.delay_ns
        fault = fault_from_event(event, roster)

        if fault is not None:
            applied.append(Applied(at_ns=at_ns, fault=fault))

    return tuple(applied)
