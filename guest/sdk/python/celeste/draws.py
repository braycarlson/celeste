from __future__ import annotations

from typing import TYPE_CHECKING

from celeste import ports

if TYPE_CHECKING:
    from collections.abc import Sequence


WORD_BITS = 64


def below(limit: int) -> int:
    assert limit > 0, f'a draw below {limit} has no value to return'

    return word_below(random(), limit)


def boolean() -> bool:
    return word_boolean(random())


def choice[Option](options: Sequence[Option]) -> Option:
    assert len(options) > 0, 'a choice needs at least one option'

    return options[below(len(options))]


def random() -> int:
    return ports.draw()


def word_below(word: int, limit: int) -> int:
    assert 0 <= word < 1 << WORD_BITS, f'a word is {WORD_BITS} bits, unlike {word}'
    assert limit > 0, f'a draw below {limit} has no value to return'

    value = (word * limit) >> WORD_BITS

    assert 0 <= value < limit

    return value


def word_boolean(word: int) -> bool:
    assert 0 <= word < 1 << WORD_BITS, f'a word is {WORD_BITS} bits, unlike {word}'

    return word >> (WORD_BITS - 1) == 1
