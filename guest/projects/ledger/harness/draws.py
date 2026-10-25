import os
import sys

import dst


DRAWS = 1000
LINE_WORDS = 16
PROCESSES = 4


def _draws_report(index):
    words = [dst.random() for _ in range(DRAWS)]

    for start in range(0, DRAWS, LINE_WORDS):
        line = " ".join(f"{word:x}" for word in words[start:start + LINE_WORDS])

        dst.console(f"DST DRAWS {index} {line}")


def _run():
    dst.ready()

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

    dst.console("DST DRAWS DONE")
    dst.power_loss()


def main():
    if sys.argv[1:] == ["check"]:
        dst.console("DST CHECK UP")
        dst.checked()

        return

    _run()


if __name__ == "__main__":
    main()
