import os


CONSOLE = "/dev/console"


def console(line):
    descriptor = os.open(CONSOLE, os.O_WRONLY | os.O_NOCTTY)

    try:
        os.write(descriptor, (line + "\n").encode())
    finally:
        os.close(descriptor)
