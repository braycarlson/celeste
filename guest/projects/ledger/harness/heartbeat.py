import sys
import threading
import time

import dst


BEATS_MAX = 1 << 20
BEAT_INTERVAL = 0.01
CHECKS_MAX = 1 << 20
CHECK_INTERVAL = 0.05
DEADLINE_NS = 500_000_000
RUN_NS = 3_000_000_000
STALLED = "the heartbeat stalled past its deadline"

PROPERTIES = (("sometimes", STALLED),)


class Heart:
    def __init__(self):
        self.beats = 0
        self.stop = threading.Event()


def _beat(heart):
    for _ in range(BEATS_MAX):
        if heart.stop.is_set():
            return

        heart.beats += 1

        time.sleep(BEAT_INTERVAL)

    message = f"the heart beat past {BEATS_MAX} beats"
    raise RuntimeError(message)


def _run():
    dst.declare(PROPERTIES)
    dst.ready()

    heart = Heart()
    beater = threading.Thread(target=_beat, args=(heart,))
    watcher = threading.Thread(target=_watch, args=(heart,))

    beater.start()
    watcher.start()
    time.sleep(RUN_NS / 1e9)
    heart.stop.set()
    beater.join()
    watcher.join()

    dst.console(f"DST WORKLOAD DONE heartbeat beats={heart.beats}")
    dst.power_loss()


def _watch(heart):
    beats = heart.beats
    beat_ns = time.monotonic_ns()

    for _ in range(CHECKS_MAX):
        if heart.stop.is_set():
            return

        time.sleep(CHECK_INTERVAL)

        now_ns = time.monotonic_ns()

        if heart.beats != beats:
            beats = heart.beats
            beat_ns = now_ns

            continue

        dst.sometimes(now_ns - beat_ns > DEADLINE_NS, STALLED)

    message = f"the watcher checked past {CHECKS_MAX} checks"
    raise RuntimeError(message)


def main():
    if sys.argv[1:] == ["check"]:
        dst.console("DST CHECK UP")
        dst.checked()

        return

    _run()


if __name__ == "__main__":
    main()
