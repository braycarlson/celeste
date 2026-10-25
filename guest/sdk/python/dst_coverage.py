import fcntl
import mmap
import os
import sys
import zlib


COVERAGE_BITS = 1 << 24
COVERAGE_EXCLUDED = ("/opt/sdk/", "<")
COVERAGE_PATH = "/dev/shm/dst-coverage"
COVERAGE_PORT = 0x5F0
PORT_PATH = "/dev/port"


class Coverage:
    def __init__(self, bitmap, lock, port):
        self.bitmap = bitmap
        self.lock = lock
        self.port = port

    def line(self, code, number):
        name = code.co_filename

        if name.startswith(COVERAGE_EXCLUDED):
            return sys.monitoring.DISABLE

        location = f"{name}:{code.co_qualname}:{number}"
        index = zlib.crc32(location.encode()) & (COVERAGE_BITS - 1)
        offset, bit = divmod(index, 8)
        mask = 1 << bit

        if self.bitmap[offset] & mask:
            return sys.monitoring.DISABLE

        fcntl.flock(self.lock, fcntl.LOCK_EX)

        try:
            if not self.bitmap[offset] & mask:
                self.bitmap[offset] |= mask

                os.pwrite(self.port, index.to_bytes(3, "little"), COVERAGE_PORT)
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

        return sys.monitoring.DISABLE

    def start(self, code, offset):
        return self.line(code, code.co_firstlineno)


def install():
    try:
        lock = os.open(COVERAGE_PATH, os.O_RDWR | os.O_CREAT, 0o666)
        port = os.open(PORT_PATH, os.O_WRONLY)
    except OSError:
        return None

    os.ftruncate(lock, COVERAGE_BITS // 8)

    bitmap = mmap.mmap(lock, COVERAGE_BITS // 8, mmap.MAP_SHARED)
    coverage = Coverage(bitmap, lock, port)
    tool = sys.monitoring.COVERAGE_ID
    events = sys.monitoring.events

    sys.monitoring.use_tool_id(tool, "dst")
    sys.monitoring.register_callback(tool, events.LINE, coverage.line)
    sys.monitoring.register_callback(tool, events.PY_START, coverage.start)
    sys.monitoring.set_events(tool, events.LINE | events.PY_START)

    return coverage
