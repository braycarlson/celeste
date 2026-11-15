from __future__ import annotations

import pytest

from celeste_host.roster import Roster, RosterError, Target, roster_fields, roster_from_fields


def test_a_roster_round_trips_through_its_fields() -> None:
    postmaster = Target(name='postmaster', restart=True)
    workload = Target(name='workload', kill=False)
    roster = Roster(links=('postgres',), targets=(postmaster, workload))
    fields = roster_fields(roster)

    assert fields == {
        'links': ['postgres'],
        'targets': [
            {'kill': True, 'name': 'postmaster', 'restart': True},
            {'kill': False, 'name': 'workload', 'restart': False},
        ],
    }
    assert roster_from_fields(fields) == roster
    assert roster_from_fields({'links': [], 'targets': [{'name': 'web'}]}).targets[0] == Target(
        'web'
    )


def test_events_name_targets_and_links_by_one_based_index() -> None:
    roster = Roster(links=('postgres', 'redis'), targets=(Target('web'), Target('db')))

    assert roster.target(1).name == 'web'
    assert roster.target(2).name == 'db'
    assert roster.link(2) == 'redis'

    with pytest.raises(RosterError, match='target 0 of a roster of 2'):
        roster.target(0)

    with pytest.raises(RosterError, match='link 3 of a roster of 2'):
        roster.link(3)


@pytest.mark.parametrize('name', ['', 'Web', 'web-worker', 'x' * 33])
def test_a_name_outside_the_interface_alphabet_is_refused(name: str) -> None:
    assert isinstance(name, str)

    with pytest.raises(RosterError):
        Target(name=name)

    with pytest.raises(RosterError):
        Roster(links=(name,))


def test_a_roster_over_its_bounds_or_with_a_repeated_name_is_refused() -> None:
    with pytest.raises(RosterError, match='at most 16 targets'):
        Roster(targets=tuple(Target(f't{index}') for index in range(17)))

    with pytest.raises(RosterError, match='at most 6 links'):
        Roster(links=tuple(f'l{index}' for index in range(7)))

    with pytest.raises(RosterError, match='each target once'):
        Roster(targets=(Target('web'), Target('web')))

    with pytest.raises(RosterError, match='lists its targets'):
        roster_from_fields({'links': []})
