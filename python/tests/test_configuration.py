from __future__ import annotations

from celeste_host.configuration import Configuration, configuration_fields
from celeste_host.roster import Roster, Target
from celeste_host.zon import dumps


def test_a_configuration_dumps_every_field_with_the_roster_as_the_hypervisor_reads_it() -> None:
    roster = Roster(links=('postgres',), targets=(Target('postmaster', restart=True),))
    configuration = Configuration(cmdline='console=ttyS0 celeste.mode=run', fault_roster=roster)
    fields = configuration_fields(configuration)

    assert fields['cmdline'] == 'console=ttyS0 celeste.mode=run'
    assert fields['fault_roster'] == {
        'links': ['postgres'],
        'targets': [{'kill': True, 'name': 'postmaster', 'restart': True}],
    }
    assert fields['seeds'] == 1
    assert fields['memory_mib'] == 512
    assert set(fields) == set(Configuration.__dataclass_fields__)

    text = dumps(fields)

    assert '.fault_roster = .{' in text
    assert '.name = "postmaster"' in text
