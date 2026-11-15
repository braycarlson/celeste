import sys
import time

import celeste


COUNTER_SOLVED = "the counter reached its last stage"
SECRET = (1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 0, 1, 1, 0)
SPINS_MAX = 1 << 22
STAGE = "the counter stage"
STEPS_MAX = 4096
WORKLOAD_DEADLINE_NS = 600_000_000

PROPERTIES = (
    celeste.Property(celeste.Kind.MAXIMIZE, STAGE),
    celeste.Property(celeste.Kind.UNREACHABLE, COUNTER_SOLVED),
)


def _coin():
    _tick_spins()

    return _tick_spins() & 1


def _run():
    celeste.declare(PROPERTIES)
    celeste.ready()

    deadline_ns = time.monotonic_ns() + WORKLOAD_DEADLINE_NS
    stage = 0
    steps = 0

    for _ in range(STEPS_MAX):
        if time.monotonic_ns() >= deadline_ns:
            break

        steps += 1
        stage = stage + 1 if _coin() == SECRET[stage] else 0

        celeste.maximize(STAGE, stage)

        if stage == len(SECRET):
            celeste.unreachable(COUNTER_SOLVED, details={"steps": steps})
            break

    celeste.note(f"workload done counter stage={stage} steps={steps}")
    celeste.power_loss()


def _tick_spins():
    start = time.monotonic_ns()
    spins = 0

    for _ in range(SPINS_MAX):
        if time.monotonic_ns() != start:
            break

        spins += 1

    return spins


def main():
    if sys.argv[1:] == ["check"]:
        celeste.note("check up")
        celeste.checked()

        return

    _run()


if __name__ == "__main__":
    main()
