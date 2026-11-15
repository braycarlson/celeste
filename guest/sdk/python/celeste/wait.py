from __future__ import annotations

import socket
import sys
import time


ATTEMPTS_MAX = 100_000
CONNECT_TIMEOUT = 1
PORT_MAX = 65535
USAGE = 'usage: python3 -m celeste.wait <host> <port> <attempts>'
WAIT_INTERVAL = 0.1


def _reachable(host: str, port: int) -> bool:
    assert host
    assert 0 < port <= PORT_MAX

    try:
        connection = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    except OSError:
        return False

    connection.close()

    return True


def main(arguments: list[str]) -> int:
    assert len(arguments) > 0

    if len(arguments) != 4:
        print(USAGE, file=sys.stderr)

        return 2

    host = arguments[1]
    port = int(arguments[2])
    attempts = int(arguments[3])

    if not 1 <= attempts <= ATTEMPTS_MAX:
        print(f'{USAGE}; attempts is 1 to {ATTEMPTS_MAX}, not {attempts}', file=sys.stderr)

        return 2

    if not 0 < port <= PORT_MAX:
        print(f'{USAGE}; port is 1 to {PORT_MAX}, not {port}', file=sys.stderr)

        return 2

    for _ in range(attempts):
        if _reachable(host, port):
            return 0

        time.sleep(WAIT_INTERVAL)

    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
