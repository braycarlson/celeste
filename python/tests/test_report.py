from __future__ import annotations

import json

import pytest

from pathlib import Path

from typing_extensions import Any

from celeste import Kind
from celeste_host.event import MAGIC
from celeste_host.fault import Applied, Kill
from celeste_host.report import (
    Eventually,
    Report,
    ReportError,
    Violation,
    report_from_fields,
    report_load,
)
from celeste_host.roster import Roster, Target


def _event(**overrides: Any) -> dict[str, Any]:
    assert isinstance(overrides, dict)

    names = (
        'delay_ns',
        'duration_ns',
        'target',
        'choice',
        'restart',
        'restart_delay_ns',
        'clock_jump_ns',
        'clock_slew_ppm',
        'disk_full_slack_kib',
        'memory_immune',
        'memory_kills',
        'network_delay_ns',
        'network_jitter_ns',
        'network_link',
        'network_loss_permille',
        'network_peers',
        'network_reorder_permille',
        'pause_tree',
        'thread_choice',
        'throttle_permille',
    )
    values = dict.fromkeys(names, 0)

    return {'magic': MAGIC, 'kind': 'none', 'network_direction': 'both', **values, **overrides}


def _result(**overrides: Any) -> dict[str, Any]:
    assert isinstance(overrides, dict)

    result = {
        'acknowledged': 0,
        'checked': True,
        'detail': '',
        'events': [],
        'eventually': 'unreached',
        'failed_assertions': 0,
        'failure': None,
        'lost': 0,
        'passed': True,
        'present': 0,
        'reproducer': None,
        'seed': 1,
        'shrunk_events': [],
    }

    return {**result, **overrides}


def _report(results: list[dict[str, Any]], **overrides: Any) -> dict[str, Any]:
    assert isinstance(results, list)
    assert isinstance(overrides, dict)

    report = {
        'interface_version': 2,
        'results': results,
        'roster': {'links': ['postgres'], 'targets': [{'name': 'postmaster', 'restart': True}]},
        'seeds': len(results),
        'unreached': [],
        'violations': sum(not result['passed'] for result in results),
    }

    return {**report, **overrides}


def test_a_report_loads_into_typed_results(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    killed = _event(kind='kill', delay_ns=400000000, target=1)
    failed = _result(
        detail='stock never negative | {"product": 3}',
        eventually='failed',
        failed_assertions=1,
        passed=False,
        reproducer='/cache/run/shrunk.17.zon',
        seed=17,
        shrunk_events=[killed],
    )
    path = tmp_path / 'report.json'

    path.write_text(
        json.dumps(
            _report(
                [_result(), failed],
                unreached=[{'kind': 'sometimes', 'message': 'cancel order succeeds'}],
            )
        )
    )

    report = report_load(path)

    assert isinstance(report, Report)
    assert report.roster == Roster(
        links=('postgres',), targets=(Target('postmaster', restart=True),)
    )
    assert [result.passed for result in report.results] == [True, False]
    assert report.failed == (report.results[1],)
    assert report.failed[0].reproducer == Path('/cache/run/shrunk.17.zon')
    assert report.failed[0].eventually is Eventually.FAILED
    assert report.failed[0].violation == Violation(
        details='{"product": 3}', message='stock never negative'
    )
    assert report.failed[0].failure is None
    assert report.results[0].violation is None
    assert report.failed[0].shrunk_faults[0] == Applied(
        at_ns=400000000,
        fault=Kill(restart_delay_ns=None, target=Target('postmaster', restart=True)),
    )
    assert report.unreached[0].kind is Kind.SOMETIMES
    assert report.unreached[0].message == 'cancel order succeeds'


def test_a_report_of_another_interface_version_a_missing_one_or_a_malformed_one_is_refused(
    tmp_path: Path,
) -> None:
    assert tmp_path.is_dir()

    path = tmp_path / 'report.json'

    with pytest.raises(ReportError, match='no report'):
        report_load(path)

    path.write_text('{')

    with pytest.raises(ReportError, match='not JSON'):
        report_load(path)

    with pytest.raises(ReportError, match='interface version 1'):
        report_from_fields(_report([], interface_version=1))

    with pytest.raises(ReportError, match='claims 2 seeds'):
        report_from_fields(_report([_result()], seeds=2))

    with pytest.raises(ReportError, match='lacks the field lost'):
        report_from_fields(
            _report([{key: value for key, value in _result().items() if key != 'lost'}])
        )

    with pytest.raises(ReportError, match="not 'sideways'"):
        report_from_fields(_report([_result(eventually='sideways')]))

    with pytest.raises(ReportError, match='event list events is invalid'):
        report_from_fields(_report([_result(events=[_event(magic=1)])]))

    with pytest.raises(ReportError, match='roster is invalid'):
        report_from_fields(_report([], roster={'links': []}))

    with pytest.raises(ReportError, match="not 'never'"):
        report_from_fields(_report([], unreached=[{'kind': 'never', 'message': 'x'}]))

    with pytest.raises(ReportError, match='target 2 of a roster of 1'):
        report_from_fields(_report([_result(events=[_event(kind='kill', target=2)])]))
