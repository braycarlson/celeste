from __future__ import annotations

import os


ACTIVE = 'CELESTE_MODE' in os.environ
CONSOLE = '/dev/console'
MESSAGE_BYTES_MAX = 1024
PREFIX = 'CELESTE'


def clean(text: str) -> str:
    assert isinstance(text, str)

    cleaned = ' '.join(text.split()).replace('|', '/')

    assert cleaned, f'a message holds at least one word, unlike {text!r}'
    assert len(cleaned.encode()) <= MESSAGE_BYTES_MAX, (
        f'a message holds at most {MESSAGE_BYTES_MAX} bytes: {cleaned[:60]!r}...'
    )

    return cleaned


def emit(*words: str) -> None:
    assert len(words) > 0

    write(' '.join((PREFIX, *words)))


def write(line: str) -> None:
    assert line
    assert '\n' not in line

    if not ACTIVE:
        return

    descriptor = os.open(CONSOLE, os.O_WRONLY | os.O_NOCTTY)

    try:
        os.write(descriptor, (line + '\n').encode())
    finally:
        os.close(descriptor)
