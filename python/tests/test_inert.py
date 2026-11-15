from __future__ import annotations

import os
import subprocess
import sys

from pathlib import Path


SDK = Path(__file__).parents[2] / 'guest/sdk/python'

SCRIPT = """
import celeste

celeste.declare([celeste.Property(celeste.Kind.ALWAYS, "money is conserved")])
celeste.always(False, "money is conserved", details={"total": -1})
celeste.sometimes(True, "a transfer was rejected")
celeste.reachable("the retry path ran")
celeste.unreachable("a ledger went negative")
celeste.note("the workload ran 12 steps")
celeste.step("place order")
celeste.ack("00000000-0000-0000-0000-000000000000")
celeste.maximize("depth", 3)
words = [celeste.random() for _ in range(64)]
assert all(0 <= word < 1 << 64 for word in words)
assert len(set(words)) > 60
assert 0 <= celeste.below(10) < 10
assert celeste.choice(["a", "b"]) in ("a", "b")
assert celeste.ready() == 0
assert celeste.seed() == 0
celeste.power_loss()
celeste.checked()
print("INERT")
"""


def _python(code: str, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
    assert code
    assert isinstance(environment, dict)

    return subprocess.run(
        [sys.executable, '-c', code],
        capture_output=True,
        check=False,
        env={**environment, 'PYTHONPATH': str(SDK)},
        text=True,
    )


def test_outside_the_vm_every_call_returns_without_touching_ports_or_the_console() -> None:
    environment = {key: value for key, value in os.environ.items() if key != 'CELESTE_MODE'}
    completed = _python(SCRIPT, environment)

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == 'INERT\n'


def test_inside_the_vm_the_console_is_written() -> None:
    code = "import celeste; celeste.ack('00000000-0000-0000-0000-000000000000')"
    completed = _python(code, {**os.environ, 'CELESTE_MODE': 'run'})

    assert completed.returncode != 0
    assert '/dev/console' in completed.stderr
