from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


BUNDLED = Path(__file__).parent / '_artifacts'
CHECKOUT = Path(__file__).resolve().parents[3]


class ArtifactError(RuntimeError):
    pass


@dataclass(frozen=True)
class Artifacts:
    base: Path
    binary: Path
    kernel: Path


def _bundled() -> Artifacts:
    return Artifacts(
        base=BUNDLED / 'base.ext4',
        binary=BUNDLED / 'celeste',
        kernel=BUNDLED / 'vmlinux',
    )


def _checkout() -> Artifacts:
    return Artifacts(
        base=CHECKOUT / 'images/base.ext4',
        binary=CHECKOUT / 'zig-out/bin/celeste',
        kernel=CHECKOUT / 'images/vmlinux',
    )


def artifacts() -> Artifacts:
    bundled = _bundled()

    if bundled.binary.is_file():
        candidate = bundled
    elif (CHECKOUT / 'build.zig').is_file():
        candidate = _checkout()
    else:
        message = f'celeste ships no artifacts at {BUNDLED} and runs from no checkout'
        raise ArtifactError(message)

    missing = [
        str(path)
        for path in (candidate.binary, candidate.kernel, candidate.base)
        if not path.is_file()
    ]

    if missing:
        message = (
            f'celeste is missing {", ".join(missing)}; in a checkout, '
            f'`zig build`, `zig build images:kernel`, and `zig build images` produce them'
        )

        raise ArtifactError(message)

    return candidate
