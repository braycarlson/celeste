from __future__ import annotations

import fcntl
import mmap
import os
import sys
import zlib

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from types import CodeType


COVERAGE_BITS = 1 << 24
COVERAGE_EXCLUDED = ('/opt/sdk/', '<')
COVERAGE_PATH = '/dev/shm/celeste-coverage'
COVERAGE_PORT = 0x5F0
INDEX_BYTES = 3
PORT_PATH = '/dev/port'
TOOL_NAME = 'celeste'


class Coverage:
    def __init__(self, bitmap: mmap.mmap, lock: int, port: int) -> None:
        assert len(bitmap) == COVERAGE_BITS // 8
        assert lock >= 0
        assert port >= 0

        self.bitmap = bitmap
        self.lock = lock
        self.port = port

    def line(self, code: CodeType, number: int) -> object:
        assert isinstance(code.co_filename, str)
        assert number >= 0

        name = code.co_filename

        if name.startswith(COVERAGE_EXCLUDED):
            return sys.monitoring.DISABLE

        location = f'{name}:{code.co_qualname}:{number}'
        index = zlib.crc32(location.encode()) & (COVERAGE_BITS - 1)
        offset, bit = divmod(index, 8)
        mask = 1 << bit

        if self.bitmap[offset] & mask:
            return sys.monitoring.DISABLE

        fcntl.flock(self.lock, fcntl.LOCK_EX)

        try:
            if not self.bitmap[offset] & mask:
                self.bitmap[offset] |= mask

                os.pwrite(self.port, index.to_bytes(INDEX_BYTES, 'little'), COVERAGE_PORT)
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

        return sys.monitoring.DISABLE

    def start(self, code: CodeType, _offset: int) -> object:
        assert code.co_firstlineno >= 0
        _ = _offset

        return self.line(code, code.co_firstlineno)


def install() -> Coverage | None:
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

    sys.monitoring.use_tool_id(tool, TOOL_NAME)
    sys.monitoring.register_callback(tool, events.LINE, coverage.line)
    sys.monitoring.register_callback(tool, events.PY_START, coverage.start)
    sys.monitoring.set_events(tool, events.LINE | events.PY_START)

    return coverage
