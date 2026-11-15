from __future__ import annotations

import os
import shutil
import subprocess

import pytest

from typing_extensions import TYPE_CHECKING

from celeste_host.disk import DiskError, Entry, disk_assemble, entries_from_tree

if TYPE_CHECKING:
    from pathlib import Path


DEBUGFS = shutil.which('debugfs') or 'debugfs'
E2FSCK = shutil.which('e2fsck') or 'e2fsck'
EPOCH = 1_767_225_600
MKFS = shutil.which('mkfs.ext4') or 'mkfs.ext4'
SIZE_BYTES = 32 << 20


def _cat(image: Path, path: str) -> str:
    assert image.is_file()
    assert path.startswith('/')

    completed = subprocess.run(
        [DEBUGFS, '-R', f'cat "{path}"', str(image)],
        capture_output=True,
        check=True,
        text=True,
    )

    return completed.stdout


def _stat(image: Path, path: str) -> dict[str, str]:
    assert image.is_file()
    assert path.startswith('/')

    completed = subprocess.run(
        [DEBUGFS, '-R', f'stat "{path}"', str(image)],
        capture_output=True,
        check=True,
        text=True,
    )

    fields = {}

    for line in completed.stdout.splitlines():
        parts = line.replace(':', ' ').split()

        for key in ('Type', 'Mode', 'User', 'Group'):
            if key in parts:
                fields[key] = parts[parts.index(key) + 1]

        if line.strip().startswith('mtime'):
            fields['mtime'] = line.split('--')[1].strip()

        if 'Fast link dest' in line:
            fields['link'] = line.split('"')[1]

    return fields


@pytest.fixture
def base(tmp_path: Path) -> Path:
    assert tmp_path.is_dir()

    tree = tmp_path / 'base'
    image = tmp_path / 'base.ext4'

    (tree / 'opt').mkdir(parents=True)
    (tree / 'etc').mkdir()
    (tree / 'etc/hosts').write_text('127.0.0.1 localhost\n')

    subprocess.run(
        [MKFS, '-q', '-d', str(tree), str(image), '16M'],
        check=True,
        env={**os.environ, 'E2FSPROGS_FAKE_TIME': str(EPOCH)},
    )

    return image


@pytest.fixture
def project(tmp_path: Path) -> Path:
    assert tmp_path.is_dir()

    root = tmp_path / 'project'

    (root / 'harness').mkdir(parents=True)
    (root / 'harness/run').write_text('#!/bin/sh\necho run\n')
    (root / 'harness/run').chmod(0o755)
    (root / 'manage.py').write_text('print("manage")\n')
    (root / 'current').symlink_to('harness/run')

    return root


def test_an_assembled_disk_reads_back_every_byte_owner_mode_and_link(
    base: Path,
    project: Path,
    tmp_path: Path,
) -> None:
    assert base.is_file()
    assert project.is_dir()
    assert tmp_path.is_dir()

    hosts = tmp_path / 'hosts'
    output = tmp_path / 'disk.ext4'

    hosts.write_text('127.0.0.1 localhost\n10.77.0.2 db\n')

    entries = entries_from_tree(project, '/opt/project', uid=1000, gid=1001)
    entries.append(Entry(path='/etc/hosts', mode=0o644, source=hosts))

    disk_assemble(base, output, entries, size_bytes=SIZE_BYTES, epoch=EPOCH)

    run = _stat(output, '/opt/project/harness/run')
    manage = _stat(output, '/opt/project/manage.py')
    directory = _stat(output, '/opt/project')
    link = _stat(output, '/opt/project/current')
    checked = subprocess.run([E2FSCK, '-fn', str(output)], capture_output=True, check=False)

    assert output.stat().st_size == SIZE_BYTES
    assert _cat(output, '/opt/project/harness/run') == '#!/bin/sh\necho run\n'
    assert _cat(output, '/etc/hosts') == '127.0.0.1 localhost\n10.77.0.2 db\n'
    assert (run['Type'], run['Mode'], run['User'], run['Group']) == (
        'regular',
        '0755',
        '1000',
        '1001',
    )
    assert (manage['Type'], manage['Mode']) == ('regular', '0644')
    assert (directory['Type'], directory['Mode'], directory['User']) == (
        'directory',
        '0755',
        '1000',
    )
    assert (link['Type'], link['link']) == ('symlink', 'harness/run')
    assert '2025' in run['mtime']
    assert checked.returncode == 0, checked.stdout


def test_two_assemblies_of_one_tree_are_byte_identical(
    base: Path,
    project: Path,
    tmp_path: Path,
) -> None:
    assert base.is_file()
    assert project.is_dir()
    assert tmp_path.is_dir()

    entries = entries_from_tree(project, '/opt/project')
    first = tmp_path / 'first.ext4'
    second = tmp_path / 'second.ext4'

    disk_assemble(base, first, entries, size_bytes=SIZE_BYTES, epoch=EPOCH)
    disk_assemble(base, second, entries, size_bytes=SIZE_BYTES, epoch=EPOCH)

    assert first.read_bytes() == second.read_bytes()


@pytest.mark.parametrize(
    'entries',
    [
        [Entry(path='/srv/app/manage.py', source=None, link='x')],
        [Entry(path='relative', link='x')],
        [Entry(path='/opt/a"b', link='x')],
        [Entry(path='/opt/../etc/x', link='x')],
        [Entry(path='/opt//x', link='x')],
        [Entry(path='/opt/x', link='x'), Entry(path='/opt/x', link='y')],
        [Entry(path='/etc/hosts')],
        [Entry(path='/opt', link='x')],
        [Entry(path='/opt/x', mode=0o10000, link='x')],
    ],
)
def test_a_missing_parent_or_a_bad_entry_fails_and_leaves_no_disk(
    base: Path,
    entries: list[Entry],
    tmp_path: Path,
) -> None:
    assert base.is_file()
    assert len(entries) > 0
    assert tmp_path.is_dir()

    output = tmp_path / 'disk.ext4'

    with pytest.raises(DiskError):
        disk_assemble(base, output, entries, size_bytes=SIZE_BYTES, epoch=EPOCH)

    assert not output.exists()


def test_a_file_and_a_link_at_once_or_a_missing_source_is_refused(
    base: Path,
    project: Path,
    tmp_path: Path,
) -> None:
    assert base.is_file()
    assert project.is_dir()
    assert tmp_path.is_dir()

    output = tmp_path / 'disk.ext4'
    source = project / 'manage.py'

    refused = [
        [Entry(path='/opt/x', link='y', source=source)],
        [Entry(path='/opt/x', source=tmp_path / 'absent')],
    ]

    for entries in refused:
        with pytest.raises(DiskError):
            disk_assemble(base, output, entries, size_bytes=SIZE_BYTES, epoch=EPOCH)

    assert not output.exists()


@pytest.mark.parametrize('size_bytes', [1 << 20, SIZE_BYTES + 1, 8 << 20])
def test_a_size_outside_the_bounds_or_off_the_block_is_refused(
    base: Path,
    size_bytes: int,
    tmp_path: Path,
) -> None:
    assert base.is_file()
    assert size_bytes > 0
    assert tmp_path.is_dir()

    with pytest.raises(DiskError):
        disk_assemble(base, tmp_path / 'disk.ext4', [], size_bytes=size_bytes, epoch=EPOCH)


def test_a_child_listed_before_its_directory_is_refused(
    base: Path,
    project: Path,
    tmp_path: Path,
) -> None:
    assert base.is_file()
    assert project.is_dir()
    assert tmp_path.is_dir()

    entries = [
        Entry(path='/opt/project/manage.py', source=project / 'manage.py'),
        Entry(path='/opt/project'),
    ]

    with pytest.raises(DiskError):
        disk_assemble(base, tmp_path / 'disk.ext4', entries, size_bytes=SIZE_BYTES, epoch=EPOCH)
