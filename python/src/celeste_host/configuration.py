from __future__ import annotations

from dataclasses import asdict, dataclass, field

from typing_extensions import Any

from celeste_host.roster import Roster, roster_fields


SECOND_NS = 1_000_000_000


@dataclass(frozen=True)
class Configuration:
    cmdline: str
    cmdline_reboot: str = ''
    cpus: int = 1
    crash_window_ns: int = 0
    disk: str = ''
    eventually_ns: int = 0
    fault_roster: Roster = field(default_factory=Roster)
    fault_window_ns: int = SECOND_NS
    faults: bool = False
    jitter_ns_max: int = 0
    kernel: str = ''
    memory_mib: int = 512
    preemption: bool = False
    replay_max: int = 0
    report_output: str = ''
    reproducer: str = ''
    runner: bool = False
    seed: int = 0
    seeds: int = 1
    shrink_output: str = ''
    time_limit_ns: int = 600 * SECOND_NS
    transcript_output: str = ''


def configuration_fields(configuration: Configuration) -> dict[str, Any]:
    assert isinstance(configuration, Configuration)

    plain = asdict(configuration)
    plain['fault_roster'] = roster_fields(configuration.fault_roster)

    return plain
