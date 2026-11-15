from __future__ import annotations

import types

from typing_extensions import Any


CONTROL = frozenset((*range(0x20), 0x7F))
DEPTH_MAX = 32
ESCAPES = types.MappingProxyType({'\\': '\\\\', '"': '\\"', '\n': '\\n', '\t': '\\t', '\r': '\\r'})
INDENT = '    '
NODES_MAX = 1_000_000

KEYWORDS = frozenset(
    (
        'and',
        'break',
        'const',
        'continue',
        'else',
        'enum',
        'error',
        'false',
        'fn',
        'for',
        'if',
        'null',
        'or',
        'return',
        'struct',
        'true',
        'try',
        'type',
        'undefined',
        'union',
        'var',
        'while',
    )
)


class Literal(str):
    __slots__ = ()


class ZonError(ValueError):
    pass


def _children(value: Any, inner: str) -> list[tuple[Any, str]]:
    assert isinstance(value, (dict, list, tuple))
    assert isinstance(inner, str)

    if not isinstance(value, dict):
        return [(child, inner) for child in value]

    for key in value:
        if not isinstance(key, str):
            message = f'a ZON field name must be a string, not {key!r}'
            raise ZonError(message)

    return [(child, f'{inner}.{_name(key)} = ') for key, child in value.items()]


def _name(name: str) -> str:
    assert isinstance(name, str)

    if name in KEYWORDS:
        return '@' + _string(name)

    if not name.isascii():
        return '@' + _string(name)

    if not name.isidentifier():
        return '@' + _string(name)

    return name


def _scalar(value: Any) -> str:
    assert not isinstance(value, (dict, list, tuple))

    if isinstance(value, Literal):
        return '.' + _name(str(value))

    if isinstance(value, bool):
        return 'true' if value else 'false'

    if value is None:
        return 'null'

    if isinstance(value, int):
        return str(value)

    if isinstance(value, str):
        return _string(value)

    message = f'ZON has no spelling for a {type(value).__name__}: {value!r}'
    raise ZonError(message)


def _string(text: str) -> str:
    assert isinstance(text, str)

    pieces = ['"']

    for character in text:
        code = ord(character)

        if character in ESCAPES:
            pieces.append(ESCAPES[character])
        elif code in CONTROL:
            pieces.append(f'\\x{code:02x}')
        else:
            pieces.append(character)

    pieces.append('"')

    return ''.join(pieces)


def dumps(value: Any) -> str:
    assert not callable(value)

    pieces = []
    stack: list[str | tuple[Any, int, str, str]] = [(value, 0, '', '\n')]

    for _ in range(NODES_MAX):
        if not stack:
            return ''.join(pieces)

        item = stack.pop()

        if isinstance(item, str):
            pieces.append(item)

            continue

        current, depth, prefix, suffix = item

        if depth > DEPTH_MAX:
            message = f'a ZON value nests deeper than {DEPTH_MAX} levels'
            raise ZonError(message)

        pieces.append(prefix)

        if not isinstance(current, (dict, list, tuple)):
            pieces.append(_scalar(current) + suffix)
        elif not current:
            pieces.append('.{}' + suffix)
        else:
            inner = INDENT * (depth + 1)

            pieces.append('.{\n')
            stack.append(f'{INDENT * depth}}}{suffix}')
            stack.extend(
                (child, depth + 1, label, ',\n')
                for child, label in reversed(_children(current, inner))
            )

    message = f'a ZON value holds more than {NODES_MAX} nodes'
    raise ZonError(message)
