from __future__ import annotations

import subprocess

import pytest

from typing_extensions import TYPE_CHECKING, Any

from celeste_host.artifacts import CHECKOUT
from celeste_host.zon import Literal, ZonError, dumps

if TYPE_CHECKING:
    from pathlib import Path


BINARY = CHECKOUT / 'zig-out/bin/celeste'

EXPECTED = (
    '.{\n'
    '    .cmdline = "console=ttyS0 \\"quoted\\" \\\\ tab\\there\\nline\\x01",\n'
    '    .empty = .{},\n'
    '    .enabled = true,\n'
    '    .kind = .kill,\n'
    '    .missing = null,\n'
    '    .nested = .{\n'
    '        .targets = .{\n'
    '            .{\n'
    '                .name = "cache",\n'
    '                .restart = true,\n'
    '            },\n'
    '        },\n'
    '    },\n'
    '    .offset = -5,\n'
    '    .@"type" = "keyword",\n'
    '    .@"not an identifier" = 1,\n'
    '}\n'
)


def _nested(depth: int) -> list[Any]:
    assert depth >= 0

    root: list[Any] = []
    current = root

    for _ in range(depth):
        inner: list[Any] = []
        current.append(inner)
        current = inner

    return root


def test_every_python_value_has_its_zig_spelling() -> None:
    value = {
        'cmdline': 'console=ttyS0 "quoted" \\ tab\there\nline\x01',
        'empty': [],
        'enabled': True,
        'kind': Literal('kill'),
        'missing': None,
        'nested': {'targets': [{'name': 'cache', 'restart': True}]},
        'offset': -5,
        'type': 'keyword',
        'not an identifier': 1,
    }

    assert dumps(value) == EXPECTED


@pytest.mark.parametrize('value', [1.5, {1: 'a'}, {'a': {1, 2}}, _nested(40), b'bytes'])
def test_a_value_zon_cannot_spell_is_refused(value: object) -> None:
    assert value is not None

    with pytest.raises(ZonError):
        dumps(value)


def test_nesting_at_the_limit_is_written_and_one_past_it_is_refused() -> None:
    assert dumps(_nested(32)).count('.{') == 33

    with pytest.raises(ZonError):
        dumps(_nested(33))


@pytest.mark.skipif(not BINARY.is_file(), reason='needs a built celeste binary')
def test_celeste_parses_a_generated_config_up_to_the_missing_kernel(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    config = {
        'cmdline': 'console=ttyS0 celeste.mode=run "quoted"',
        'fault_plan': {'script': [{'delay_ns': 9, 'kind': Literal('kill'), 'target': 1}]},
        'fault_roster': {
            'links': ['database'],
            'targets': [{'name': 'web_worker'}, {'kill': False, 'name': 'workload'}],
        },
        'kernel': '/nonexistent/vmlinux',
        'runner': True,
    }

    path = tmp_path / 'celeste.zon'
    path.write_text(dumps(config))

    completed = subprocess.run(
        [str(BINARY), str(path)],
        capture_output=True,
        check=False,
        text=True,
        timeout=60,
    )

    output = completed.stdout + completed.stderr

    assert completed.returncode != 0
    assert 'FileNotFound' in output
    assert 'ParseZon' not in output
