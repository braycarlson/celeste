from __future__ import annotations

import pytest

import celeste

from typing_extensions import TYPE_CHECKING, Any

from celeste import console, draws, lifecycle, properties

if TYPE_CHECKING:
    from pathlib import Path


IDENTIFIER = '8b2c6f1e-4d3b-4f6a-9d0e-2a1b5c7d9e10'


@pytest.fixture
def lines(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)

    emitted: list[str] = []

    monkeypatch.setattr(console, 'write', emitted.append)
    monkeypatch.setattr(properties, '_maxima', {})
    monkeypatch.setattr(properties, '_reported', set())

    return emitted


def test_the_root_names_the_whole_surface() -> None:
    public = {name for name in dir(celeste) if not name.startswith('_')}
    modules = {'annotations', 'console', 'draws', 'lifecycle', 'ports', 'properties'}

    assert set(celeste.__all__) == public - modules
    assert celeste.INTERFACE_VERSION == 2


def test_an_always_pass_and_fail_each_report_once_with_details_on_the_failure(
    lines: list[str],
) -> None:
    assert lines == []

    celeste.always(condition=True, message='money is conserved')
    celeste.always(condition=True, message='money is conserved')
    celeste.always(condition=False, message='money is conserved', details={'total': -1, 'a': 2})
    celeste.always(condition=False, message='money is conserved', details={'total': -2})

    assert lines == [
        'CELESTE ALWAYS PASS money is conserved',
        'CELESTE ALWAYS FAIL money is conserved | {"a": 2, "total": -1}',
    ]


def test_sometimes_reachable_and_unreachable_lines(lines: list[str]) -> None:
    assert lines == []

    celeste.sometimes(condition=False, message='a transfer was rejected')
    celeste.sometimes(condition=True, message='a transfer was rejected')
    celeste.sometimes(condition=True, message='a transfer was rejected')
    celeste.reachable('the retry path ran')
    celeste.unreachable('a ledger went negative', details=['acc-1'])

    assert lines == [
        'CELESTE SOMETIMES a transfer was rejected',
        'CELESTE REACHABLE the retry path ran',
        'CELESTE UNREACHABLE a ledger went negative | ["acc-1"]',
    ]


def test_a_note_and_a_step_are_one_line_without_pipes(lines: list[str]) -> None:
    assert lines == []

    celeste.note('  the\tworkload |\nran  12 steps ')
    celeste.step(' place  order ')

    assert lines == ['CELESTE NOTE the workload / ran 12 steps', 'CELESTE STEP place order']


def test_an_empty_or_oversized_message_is_refused(lines: list[str]) -> None:
    assert lines == []

    with pytest.raises(AssertionError, match='at least one word'):
        celeste.note(' \n ')

    with pytest.raises(AssertionError, match='at most 1024 bytes'):
        celeste.note('x' * 1025)

    assert lines == []


def test_declare_emits_nothing_when_any_property_is_invalid(lines: list[str]) -> None:
    assert lines == []

    never: Any = 'never'
    conserved = celeste.Property(celeste.Kind.ALWAYS, 'money is conserved')
    bad_kind = celeste.Property(never, 'a ledger went negative')

    with pytest.raises(AssertionError, match="not 'never'"):
        celeste.declare([conserved, bad_kind])

    too_many = [
        celeste.Property(celeste.Kind.ALWAYS, f'property {index}')
        for index in range(properties.PROPERTIES_MAX + 1)
    ]

    with pytest.raises(AssertionError, match='at most 256 properties'):
        celeste.declare(too_many)

    assert lines == []

    celeste.declare([conserved])

    assert lines == ['CELESTE DECLARE always money is conserved']


def test_an_acknowledgement_identifier_is_a_canonical_uuid(lines: list[str]) -> None:
    assert lines == []

    celeste.ack(IDENTIFIER)
    celeste.present(IDENTIFIER)

    with pytest.raises(AssertionError, match='is a UUID'):
        celeste.ack('order-17')

    with pytest.raises(AssertionError, match='canonical lowercase'):
        celeste.present(IDENTIFIER.upper())

    assert lines == [f'CELESTE ACK {IDENTIFIER}', f'CELESTE PRESENT {IDENTIFIER}']


def test_eventually_reports_the_property_then_the_phase_verdict(lines: list[str]) -> None:
    assert lines == []

    celeste.eventually(condition=False, message='the queue drains', details={'pending': 3})
    celeste.eventually(condition=True, message='the queue drains')

    assert lines == [
        'CELESTE ALWAYS FAIL the queue drains | {"pending": 3}',
        'CELESTE EVENTUALLY FAIL',
        'CELESTE ALWAYS PASS the queue drains',
        'CELESTE EVENTUALLY PASS',
    ]


def test_checked_ends_the_check(lines: list[str]) -> None:
    assert lines == []

    celeste.checked()

    assert lines == ['CELESTE CHECK DONE']


def test_maximize_reports_only_a_new_maximum(monkeypatch: pytest.MonkeyPatch) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)

    reports: list[tuple[int, int]] = []

    monkeypatch.setattr(properties, '_maxima', {})
    monkeypatch.setattr(celeste.ports, 'guidance', lambda crc, value: reports.append((crc, value)))

    celeste.maximize('depth', 3)
    celeste.maximize('depth', 3)
    celeste.maximize('depth', 2)
    celeste.maximize('depth', 5)

    with pytest.raises(AssertionError, match='fits in 64 bits'):
        celeste.maximize('depth', -1)

    assert [value for _, value in reports] == [3, 5]
    assert len({crc for crc, _ in reports}) == 1


def test_draws_map_words_to_values_as_the_interface_fixes(monkeypatch: pytest.MonkeyPatch) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)

    words = iter([0, (1 << 64) - 1, 1 << 63, (1 << 63) - 1])

    monkeypatch.setattr(celeste.ports, 'draw', lambda: next(words))

    assert celeste.below(10) == 0
    assert celeste.below(10) == 9
    assert celeste.boolean() is True
    assert celeste.boolean() is False


def test_a_word_maps_below_a_limit_monotonically() -> None:
    values = [draws.word_below(1 << shift, 1000) for shift in range(64)]

    assert values == sorted(values)
    assert draws.word_below(1 << 63, 10) == 5

    with pytest.raises(AssertionError, match='64 bits'):
        draws.word_below(1 << 64, 10)


def test_a_draw_below_nothing_and_a_choice_of_nothing_are_refused() -> None:
    with pytest.raises(AssertionError, match='below 0'):
        celeste.below(0)

    with pytest.raises(AssertionError, match='at least one option'):
        celeste.choice([])


def test_choice_indexes_with_a_draw_below_the_length(monkeypatch: pytest.MonkeyPatch) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)

    monkeypatch.setattr(celeste.ports, 'draw', lambda: 1 << 63)

    assert celeste.choice(['a', 'b', 'c', 'd']) == 'c'


def test_waiting_for_quiet_ends_at_the_quiet_marker_an_agent_error_or_an_unhealed_fault(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    quiet = tmp_path / 'celeste-quiet'
    failed = tmp_path / 'celeste-agent-error'
    unhealed = tmp_path / 'celeste-unhealed'
    sleeps: list[float] = []

    monkeypatch.setattr(lifecycle, 'AGENT_ERROR_MARKER', failed)
    monkeypatch.setattr(lifecycle, 'QUIET_MARKER', quiet)
    monkeypatch.setattr(lifecycle, 'QUIET_POLLS_MAX', 3)
    monkeypatch.setattr(lifecycle, 'UNHEALED_MARKER', unhealed)
    monkeypatch.setattr(lifecycle.time, 'sleep', sleeps.append)

    assert not celeste.quiet_wait()
    assert len(sleeps) == 3

    unhealed.touch()

    assert not celeste.quiet_wait()
    assert len(sleeps) == 3

    unhealed.unlink()
    failed.touch()

    assert not celeste.quiet_wait()
    assert len(sleeps) == 3

    quiet.touch()

    assert celeste.quiet_wait()
    assert len(sleeps) == 3


def test_ready_opens_the_fault_window_only_once_the_agent_is_ready(
    lines: list[str],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(lines, list)
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    window = tmp_path / 'celeste-window'
    calls: list[str] = []

    def control(command: int) -> None:
        assert command == lifecycle.ports.READY

        calls.append(f'control {command} window {window.exists()}')

    monkeypatch.setattr(lifecycle, 'WINDOW_MARKER', window)
    monkeypatch.setattr(lifecycle, '_agent_spawn', lambda: calls.append('spawn'))
    monkeypatch.setattr(lifecycle, '_agent_wait', lambda: calls.append('wait'))
    monkeypatch.setattr(lifecycle, '_entropy_mix', lambda _value: calls.append('entropy'))
    monkeypatch.setattr(lifecycle, '_oom_immune', lambda: calls.append('oom'))
    monkeypatch.setattr(lifecycle.ports, 'ACTIVE', True)
    monkeypatch.setattr(lifecycle.ports, 'control', control)
    monkeypatch.setattr(lifecycle.ports, 'seed', lambda: 7)

    expected = [
        'oom',
        'spawn',
        'wait',
        f'control {lifecycle.ports.READY} window False',
        'entropy',
    ]

    assert lifecycle.ready() == 7
    assert calls == expected
    assert window.exists()
    assert lines[0].startswith('CELESTE CPUS ')


def test_ready_waits_for_the_agent_until_it_reports_ready_or_fails(
    lines: list[str],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    assert isinstance(lines, list)
    assert isinstance(monkeypatch, pytest.MonkeyPatch)
    assert tmp_path.is_dir()

    readied = tmp_path / 'celeste-agent-ready'
    failed = tmp_path / 'celeste-agent-error'
    sleeps: list[float] = []

    monkeypatch.setattr(lifecycle, 'AGENT_ERROR_MARKER', failed)
    monkeypatch.setattr(lifecycle, 'AGENT_POLLS_MAX', 3)
    monkeypatch.setattr(lifecycle, 'AGENT_READY_MARKER', readied)
    monkeypatch.setattr(lifecycle.time, 'sleep', sleeps.append)

    lifecycle._agent_wait()

    assert len(sleeps) == 3
    assert failed.exists()
    assert lines == ['CELESTE AGENT ERROR the agent was not ready within 3 polls of 0.005 s']

    failed.touch()
    lifecycle._agent_wait()

    assert len(sleeps) == 3

    failed.unlink()
    readied.touch()
    lifecycle._agent_wait()

    assert len(sleeps) == 3


def test_a_power_loss_waits_for_the_cut_on_the_hypervisor_and_returns_off_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert isinstance(monkeypatch, pytest.MonkeyPatch)

    controls: list[int] = []
    sleeps: list[float] = []

    monkeypatch.setattr(lifecycle.ports, 'control', controls.append)
    monkeypatch.setattr(lifecycle.time, 'sleep', sleeps.append)
    monkeypatch.setattr(lifecycle.ports, 'ACTIVE', False)

    celeste.power_loss()

    assert controls == [lifecycle.ports.POWER_LOSS]
    assert sleeps == []

    monkeypatch.setattr(lifecycle.ports, 'ACTIVE', True)

    celeste.power_loss()

    assert controls == [lifecycle.ports.POWER_LOSS, lifecycle.ports.POWER_LOSS]
    assert sleeps == [lifecycle.POWER_LOSS_WAIT] * lifecycle.POWER_LOSS_WAITS_MAX
