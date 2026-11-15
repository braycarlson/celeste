from __future__ import annotations

import mmap
import os
import sys

import celeste_coverage

from typing_extensions import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path


def _body() -> None:
    return None


def test_a_line_zero_and_an_empty_filename_count_once_as_fresh_coverage(tmp_path: Path) -> None:
    assert tmp_path.is_dir()

    bitmap_path = tmp_path / 'celeste-coverage'
    port_path = tmp_path / 'port'

    bitmap_path.write_bytes(bytes(celeste_coverage.COVERAGE_BITS // 8))
    port_path.write_bytes(b'')

    lock = os.open(bitmap_path, os.O_RDWR)
    port = os.open(port_path, os.O_WRONLY)

    try:
        bitmap = mmap.mmap(lock, celeste_coverage.COVERAGE_BITS // 8, mmap.MAP_SHARED)
        coverage = celeste_coverage.Coverage(bitmap, lock, port)
        empty = _body.__code__
        unnamed = _body.__code__.replace(co_filename='')

        assert coverage.line(empty, 0) is sys.monitoring.DISABLE
        assert coverage.line(unnamed, 1) is sys.monitoring.DISABLE

        written = port_path.read_bytes()[celeste_coverage.COVERAGE_PORT :]

        assert coverage.line(empty, 0) is sys.monitoring.DISABLE
        assert port_path.read_bytes()[celeste_coverage.COVERAGE_PORT :] == written
        assert len(written) == celeste_coverage.INDEX_BYTES
        assert sum(byte.bit_count() for byte in bitmap[:]) == 2

        bitmap.close()
    finally:
        os.close(port)
        os.close(lock)
