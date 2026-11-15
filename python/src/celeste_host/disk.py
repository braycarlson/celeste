from __future__ import annotations

import enum
import os
import shutil
import subprocess
import tempfile

from dataclasses import dataclass
from pathlib import Path, PurePosixPath


DEBUGFS_ECHO = 'debugfs: '
DEBUGFS_INFORMATION = ('Allocated inode: ', 'debugfs ')
ENTRIES_MAX = 500_000
EPOCH_DEFAULT = 1_767_225_600
PATH_FORBIDDEN = ('"', '\n', '\r', '\0')
SIZE_BYTES_MAX = 64 << 30
SIZE_BYTES_MIN = 16 << 20


class DiskError(RuntimeError):
    pass


class Existing(enum.Enum):
    DIRECTORY = enum.auto()
    MISSING = enum.auto()
    OTHER = enum.auto()


@dataclass(frozen=True)
class Entry:
    path: str
    gid: int = 0
    link: str | None = None
    mode: int = 0o644
    source: Path | None = None
    uid: int = 0

    @property
    def directory(self) -> bool:
        return self.source is None and self.link is None


def _debugfs(image: Path, script: str, epoch: int) -> list[str]:
    assert image.is_file()
    assert script.endswith('\n')
    assert epoch > 0

    with tempfile.NamedTemporaryFile('w', suffix='.debugfs', delete=False) as handle:
        handle.write(script)

    try:
        completed = _tool(['debugfs', '-w', '-f', handle.name, str(image)], epoch)
    finally:
        Path(handle.name).unlink()

    if completed.returncode != 0:
        message = f'debugfs exited {completed.returncode} on {image}: {completed.stderr.strip()}'
        raise DiskError(message)

    return (completed.stdout + completed.stderr).splitlines()


def _debugfs_errors(lines: list[str]) -> list[str]:
    assert isinstance(lines, list)

    return [line for line in lines if not _debugfs_noise(line)]


def _debugfs_noise(line: str) -> bool:
    assert isinstance(line, str)

    if not line.strip():
        return True

    return line.startswith((DEBUGFS_ECHO, *DEBUGFS_INFORMATION))


def _entries_validate(entries: list[Entry]) -> None:
    assert isinstance(entries, list)

    if len(entries) > ENTRIES_MAX:
        message = f'{len(entries)} disk entries exceed the limit of {ENTRIES_MAX}'
        raise DiskError(message)

    seen = set()

    for entry in entries:
        path = PurePosixPath(entry.path)

        if not path.is_absolute():
            message = f'a disk entry path must be absolute: {entry.path!r}'
            raise DiskError(message)

        if path == PurePosixPath('/'):
            message = 'a disk entry cannot replace the root directory'
            raise DiskError(message)

        if any(character in entry.path for character in PATH_FORBIDDEN):
            message = f'a disk entry path carries a quote or a control character: {entry.path!r}'
            raise DiskError(message)

        if '..' in path.parts:
            message = f'a disk entry path must not climb with ..: {entry.path!r}'
            raise DiskError(message)

        if str(path) != entry.path:
            message = f'a disk entry path must be normalized: {entry.path!r}'
            raise DiskError(message)

        if entry.source is not None:
            if entry.link is not None:
                message = f'a disk entry is a file or a link, not both: {entry.path}'
                raise DiskError(message)

        if entry.path in seen:
            message = f'a disk entry path appears twice: {entry.path}'
            raise DiskError(message)

        if not 0 <= entry.mode <= 0o7777:
            message = f'a disk entry mode is outside 0..0o7777: {entry.path} {entry.mode:o}'
            raise DiskError(message)

        seen.add(entry.path)


def _entry_from_path(path: Path, guest: str, uid: int, gid: int) -> Entry:
    assert os.path.lexists(path)
    assert guest.startswith('/')
    assert uid >= 0
    assert gid >= 0

    if path.is_symlink():
        return Entry(path=guest, gid=gid, link=str(path.readlink()), mode=0o777, uid=uid)

    if path.is_dir():
        return Entry(path=guest, gid=gid, mode=0o755, uid=uid)

    mode = 0o755 if os.access(path, os.X_OK) else 0o644

    return Entry(path=guest, gid=gid, mode=mode, source=path, uid=uid)


def _existing(image: Path, paths: list[str], epoch: int) -> dict[str, Existing]:
    assert image.is_file()
    assert isinstance(paths, list)
    assert epoch > 0

    return {path: _existing_kind(image, path, epoch) for path in paths}


def _existing_kind(image: Path, path: str, epoch: int) -> Existing:
    assert image.is_file()
    assert path.startswith('/')
    assert epoch > 0

    completed = _tool(['debugfs', '-R', f'stat "{path}"', str(image)], epoch)
    text = completed.stdout + completed.stderr

    if 'File not found by ext2_lookup' in text:
        return Existing.MISSING

    if 'Type: directory' in text:
        return Existing.DIRECTORY

    if 'Type: ' in text:
        return Existing.OTHER

    message = f'debugfs reported no type for {path} in {image}: {text.strip()}'
    raise DiskError(message)


def _resize(image: Path, size_bytes: int, epoch: int) -> None:
    assert image.is_file()
    assert size_bytes > 0
    assert epoch > 0

    current = image.stat().st_size

    if size_bytes < current:
        message = f'a disk size of {size_bytes} bytes is below the base disk size of {current}'
        raise DiskError(message)

    checked = _tool(['e2fsck', '-fy', str(image)], epoch)

    if checked.returncode not in (0, 1):
        message = f'e2fsck exited {checked.returncode} on {image}: {checked.stdout.strip()}'
        raise DiskError(message)

    if size_bytes == current:
        return

    resized = _tool(['resize2fs', str(image), f'{size_bytes // 1024}K'], epoch)

    if resized.returncode != 0:
        message = f'resize2fs exited {resized.returncode} on {image}: {resized.stderr.strip()}'
        raise DiskError(message)


def _script(entries: list[Entry], existing: dict[str, Existing]) -> str:
    assert isinstance(entries, list)
    assert isinstance(existing, dict)

    commands = []

    for entry in entries:
        kind = existing.get(entry.path, Existing.MISSING)
        quoted = f'"{entry.path}"'

        if entry.directory:
            if kind is Existing.OTHER:
                message = f'{entry.path} is a file in the base disk, not a directory'
                raise DiskError(message)

            if kind is Existing.MISSING:
                commands.append(f'mkdir {quoted}')

            type_bits = 0o040000
        else:
            if kind is Existing.DIRECTORY:
                message = f'{entry.path} is a directory in the base disk, not a file'
                raise DiskError(message)

            if kind is Existing.OTHER:
                commands.append(f'rm {quoted}')

            if entry.link is None:
                commands.append(f'write "{entry.source}" {quoted}')
                type_bits = 0o100000
            else:
                commands.append(f'symlink {quoted} "{entry.link}"')
                type_bits = 0o120000

        commands.append(f'set_inode_field {quoted} mode 0{type_bits | entry.mode:o}')
        commands.append(f'set_inode_field {quoted} uid {entry.uid}')
        commands.append(f'set_inode_field {quoted} gid {entry.gid}')

    return '\n'.join(commands) + '\n'


def _tool(arguments: list[str], epoch: int) -> subprocess.CompletedProcess[str]:
    assert len(arguments) > 0
    assert epoch > 0

    executable = shutil.which(arguments[0])

    if executable is None:
        message = f'{arguments[0]} is not on PATH; celeste builds disks with e2fsprogs'
        raise DiskError(message)

    return subprocess.run(
        [executable, *arguments[1:]],
        capture_output=True,
        check=False,
        env={**os.environ, 'E2FSPROGS_FAKE_TIME': str(epoch)},
        text=True,
    )


def disk_assemble(
    base: Path,
    output: Path,
    entries: list[Entry],
    *,
    size_bytes: int,
    epoch: int = EPOCH_DEFAULT,
) -> None:
    assert isinstance(base, Path)
    assert isinstance(output, Path)
    assert isinstance(entries, list)
    assert isinstance(size_bytes, int)
    assert epoch > 0

    if not SIZE_BYTES_MIN <= size_bytes <= SIZE_BYTES_MAX:
        message = f'a disk size of {size_bytes} bytes is outside {SIZE_BYTES_MIN}..{SIZE_BYTES_MAX}'
        raise DiskError(message)

    if size_bytes % 4096 != 0:
        message = f'a disk size of {size_bytes} bytes is not a multiple of the 4096-byte block'
        raise DiskError(message)

    if not base.is_file():
        message = f'the base disk {base} does not exist'
        raise DiskError(message)

    _entries_validate(entries)

    for entry in entries:
        if entry.source is None:
            continue

        if not entry.source.is_file():
            message = f'the source of {entry.path} is not a file: {entry.source}'
            raise DiskError(message)

    created = {entry.path for entry in entries if entry.directory}
    roots = [
        entry.path for entry in entries if str(PurePosixPath(entry.path).parent) not in created
    ]

    parents = sorted({str(PurePosixPath(path).parent) for path in roots} - {'/'})
    partial = output.with_name(output.name + '.partial')
    copied = _tool(['cp', '--sparse=always', str(base), str(partial)], epoch)

    if copied.returncode != 0:
        message = f'copying the base disk {base} failed: {copied.stderr.strip()}'
        raise DiskError(message)

    try:
        _resize(partial, size_bytes, epoch)

        existing = _existing(partial, roots + parents, epoch)
        absent = [parent for parent in parents if existing[parent] is not Existing.DIRECTORY]

        if absent:
            message = f'the base disk lacks the parent directories {", ".join(absent)}'
            raise DiskError(message)

        errors = _debugfs_errors(_debugfs(partial, _script(entries, existing), epoch))

        if errors:
            message = f'debugfs refused part of the assembly of {output}: {"; ".join(errors[:8])}'
            raise DiskError(message)

        partial.replace(output)
    finally:
        partial.unlink(missing_ok=True)


def entries_from_tree(root: Path, target: str, *, uid: int = 0, gid: int = 0) -> list[Entry]:
    assert isinstance(root, Path)
    assert target.startswith('/')
    assert uid >= 0
    assert gid >= 0

    if not root.is_dir():
        message = f'{root} is not a directory'
        raise DiskError(message)

    entries = [Entry(path=target, gid=gid, mode=0o755, uid=uid)]

    for directory, names, files in os.walk(root):
        names.sort()
        base = PurePosixPath(target) / Path(directory).relative_to(root).as_posix()

        for name in [*names, *sorted(files)]:
            entry = _entry_from_path(Path(directory) / name, str(base / name), uid, gid)
            entries.append(entry)

        if len(entries) > ENTRIES_MAX:
            message = f'{root} holds more than {ENTRIES_MAX} entries'
            raise DiskError(message)

    return entries
