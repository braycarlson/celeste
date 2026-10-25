import socket
import sys
import time


WAIT_INTERVAL = 0.1


def main():
    host = sys.argv[1]
    port = int(sys.argv[2])
    attempts = int(sys.argv[3])

    for _ in range(attempts):
        try:
            connection = socket.create_connection((host, port), timeout=1)
        except OSError:
            time.sleep(WAIT_INTERVAL)
        else:
            connection.close()

            return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
