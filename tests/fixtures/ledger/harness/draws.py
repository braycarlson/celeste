import os
import sys

import celeste


DRAWS = 1000
LINE_WORDS = 16
PROCESSES = 4


def _draws_report(index):
    words = [celeste.random() for _ in range(DRAWS)]

    for start in range(0, DRAWS, LINE_WORDS):
        line = " ".join(f"{word:x}" for word in words[start:start + LINE_WORDS])

        celeste.note(f"draws {index} {line}")


def _run():
    celeste.ready()

    children = []

    for index in range(PROCESSES):
        child = os.fork()

        if child == 0:
            try:
                _draws_report(index)
            finally:
                os._exit(0)

        children.append(child)

    for child in children:
        os.waitpid(child, 0)

    celeste.note("draws done")
    celeste.power_loss()


def main():
    if sys.argv[1:] == ["check"]:
        celeste.note("check up")
        celeste.checked()

        return

    _run()


if __name__ == "__main__":
    main()
