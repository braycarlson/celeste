from __future__ import annotations

from dataclasses import dataclass

from typing_extensions import Any


LINKS_MAX = 6
NAME_ALPHABET = frozenset('abcdefghijklmnopqrstuvwxyz0123456789_')
NAME_LENGTH_MAX = 32
TARGETS_MAX = 16


class RosterError(ValueError):
    pass


@dataclass(frozen=True)
class Target:
    name: str
    kill: bool = True
    restart: bool = False

    def __post_init__(self) -> None:
        _name_validate(self.name, 'target')


@dataclass(frozen=True)
class Roster:
    links: tuple[str, ...] = ()
    targets: tuple[Target, ...] = ()

    def __post_init__(self) -> None:
        if len(self.targets) > TARGETS_MAX:
            message = f'a roster names at most {TARGETS_MAX} targets, not {len(self.targets)}'
            raise RosterError(message)

        if len(self.links) > LINKS_MAX:
            message = f'a roster names at most {LINKS_MAX} links, not {len(self.links)}'
            raise RosterError(message)

        for link in self.links:
            _name_validate(link, 'link')

        _unique_validate([target.name for target in self.targets], 'target')
        _unique_validate(list(self.links), 'link')

    def link(self, index: int) -> str:
        assert isinstance(index, int)

        if not 1 <= index <= len(self.links):
            message = f'an event names link {index} of a roster of {len(self.links)}'
            raise RosterError(message)

        return self.links[index - 1]

    def target(self, index: int) -> Target:
        assert isinstance(index, int)

        if not 1 <= index <= len(self.targets):
            message = f'an event names target {index} of a roster of {len(self.targets)}'
            raise RosterError(message)

        return self.targets[index - 1]


def _name_validate(name: str, what: str) -> None:
    assert isinstance(name, str)
    assert what in ('target', 'link')

    if not 1 <= len(name) <= NAME_LENGTH_MAX:
        message = f'a {what} name is 1 to {NAME_LENGTH_MAX} characters, unlike {name!r}'
        raise RosterError(message)

    if not set(name) <= NAME_ALPHABET:
        message = f'a {what} name is made of a-z, 0-9, and _, unlike {name!r}'
        raise RosterError(message)


def _unique_validate(names: list[str], what: str) -> None:
    assert isinstance(names, list)
    assert what in ('target', 'link')

    if len(set(names)) != len(names):
        message = f'a roster names each {what} once, unlike {names}'
        raise RosterError(message)


def roster_fields(roster: Roster) -> dict[str, Any]:
    assert isinstance(roster, Roster)

    targets = [
        {'kill': target.kill, 'name': target.name, 'restart': target.restart}
        for target in roster.targets
    ]

    return {'links': list(roster.links), 'targets': targets}


def roster_from_fields(fields: dict[str, Any]) -> Roster:
    assert isinstance(fields, dict)

    links = fields.get('links')
    targets = fields.get('targets')

    if not isinstance(links, list):
        message = f'a roster lists its links, unlike {fields!r}'
        raise RosterError(message)

    if not isinstance(targets, list):
        message = f'a roster lists its targets, unlike {fields!r}'
        raise RosterError(message)

    named = []

    for target in targets:
        if not isinstance(target, dict):
            message = f'a target is an object with a name, not {target!r}'
            raise RosterError(message)

        named.append(_target_from_fields(target))

    return Roster(links=tuple(str(link) for link in links), targets=tuple(named))


def _target_from_fields(fields: dict[str, Any]) -> Target:
    assert isinstance(fields, dict)

    name = fields.get('name')

    if not isinstance(name, str):
        message = f'a target has a name, unlike {fields!r}'
        raise RosterError(message)

    return Target(
        name=name,
        kill=bool(fields.get('kill', True)),
        restart=bool(fields.get('restart', False)),
    )
