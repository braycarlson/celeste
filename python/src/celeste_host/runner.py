from __future__ import annotations

import subprocess

from dataclasses import dataclass, replace
from pathlib import Path

from typing_extensions import TYPE_CHECKING

from celeste_host.artifacts import Artifacts, artifacts
from celeste_host.configuration import Configuration, configuration_fields
from celeste_host.zon import dumps

if TYPE_CHECKING:
    from typing_extensions import Callable


LINES_MAX = 1_000_000


@dataclass(frozen=True)
class Run:
    config: Path
    lines: list[str]
    returncode: int

    @property
    def passed(self) -> bool:
        return self.returncode == 0


def run(
    configuration: Configuration,
    *,
    directory: Path,
    line_callback: Callable[[str], None] | None = None,
    located: Artifacts | None = None,
) -> Run:
    assert isinstance(configuration, Configuration)
    assert isinstance(directory, Path)
    assert isinstance(located, Artifacts | None)

    found = located or artifacts()
    settings = replace(configuration, kernel=str(found.kernel))
    path = directory / 'celeste.zon'
    lines = []

    directory.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(configuration_fields(settings)))

    with subprocess.Popen(
        [str(found.binary), str(path)],
        cwd=directory,
        stderr=subprocess.STDOUT,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        if process.stdout is None:
            message = 'celeste started without a pipe for its output'
            raise RuntimeError(message)

        for line in process.stdout:
            if len(lines) == LINES_MAX:
                process.kill()

                message = f'celeste printed more than {LINES_MAX} lines; see {directory}'
                raise RuntimeError(message)

            stripped = line.rstrip('\n')
            lines.append(stripped)

            if line_callback is not None:
                line_callback(stripped)

    return Run(config=path, lines=lines, returncode=process.returncode)
