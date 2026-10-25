import sys
import time

import dst


COUNTER_SOLVED = "the counter reached its last stage"
SECRET = (1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 0, 1, 1, 0)
SPINS_MAX = 1 << 22
STAGE = "the counter stage"
STEPS_MAX = 4096
WORKLOAD_DEADLINE_NS = 600_000_000

PROPERTIES = (("maximize", STAGE), ("unreachable", COUNTER_SOLVED))


def _coin():
    _tick_spins()

    return _tick_spins() & 1


def _run():
    dst.declare(PROPERTIES)
    dst.ready()

    deadline_ns = time.monotonic_ns() + WORKLOAD_DEADLINE_NS
    stage = 0
    steps = 0

    for _ in range(STEPS_MAX):
        if time.monotonic_ns() >= deadline_ns:
            break

        steps += 1
        stage = stage + 1 if _coin() == SECRET[stage] else 0

        dst.maximize(STAGE, stage)

        if stage == len(SECRET):
            dst.unreachable(COUNTER_SOLVED, {"steps": steps})
            break

    dst.console(f"DST WORKLOAD DONE counter stage={stage} steps={steps}")
    dst.power_loss()


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
        dst.console("DST CHECK UP")
        dst.checked()

        return

    _run()


if __name__ == "__main__":
    main()
