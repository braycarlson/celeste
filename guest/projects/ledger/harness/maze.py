import sys
import time

import dst


MAZE_SOLVED = "the maze reached its last stage"
SECRET = (1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0)
SPINS_MAX = 1 << 22
STEPS_MAX = 4096
WORKLOAD_DEADLINE_NS = 600_000_000

PROPERTIES = (("unreachable", MAZE_SOLVED),)


def _coin():
    _tick_spins()

    return _tick_spins() & 1


def _tick_spins():
    start = time.monotonic_ns()
    spins = 0

    for _ in range(SPINS_MAX):
        if time.monotonic_ns() != start:
            break

        spins += 1

    return spins


def _run():
    dst.declare(PROPERTIES)
    dst.ready()

    deadline_ns = time.monotonic_ns() + WORKLOAD_DEADLINE_NS
    stages = _stages()
    stage = 0
    steps = 0

    for _ in range(STEPS_MAX):
        if time.monotonic_ns() >= deadline_ns:
            break

        steps += 1

        if _coin() != SECRET[stage]:
            stage = 0

            continue

        stages[stage]()
        stage += 1

        if stage == len(SECRET):
            dst.unreachable(MAZE_SOLVED, {"steps": steps})
            break

    dst.console(f"DST WORKLOAD DONE maze stage={stage} steps={steps}")
    dst.power_loss()


def _stage_0():
    return 0


def _stage_1():
    return 1


def _stage_2():
    return 2


def _stage_3():
    return 3


def _stage_4():
    return 4


def _stage_5():
    return 5


def _stage_6():
    return 6


def _stage_7():
    return 7


def _stage_8():
    return 8


def _stage_9():
    return 9


def _stage_10():
    return 10


def _stage_11():
    return 11


def _stage_12():
    return 12


def _stage_13():
    return 13


def _stage_14():
    return 14


def _stage_15():
    return 15


def _stage_16():
    return 16


def _stage_17():
    return 17


def _stage_18():
    return 18


def _stage_19():
    return 19


def _stage_20():
    return 20


def _stage_21():
    return 21


def _stages():
    return (
        _stage_0,
        _stage_1,
        _stage_2,
        _stage_3,
        _stage_4,
        _stage_5,
        _stage_6,
        _stage_7,
        _stage_8,
        _stage_9,
        _stage_10,
        _stage_11,
        _stage_12,
        _stage_13,
        _stage_14,
        _stage_15,
        _stage_16,
        _stage_17,
        _stage_18,
        _stage_19,
        _stage_20,
        _stage_21,
    )


def main():
    if sys.argv[1:] == ["check"]:
        dst.console("DST CHECK UP")
        dst.checked()

        return

    _run()


if __name__ == "__main__":
    main()
