from __future__ import annotations

from celeste.draws import below, boolean, choice, random
from celeste.lifecycle import checked, eventually_ns, power_loss, quiet_wait, ready, seed
from celeste.ports import InterfaceError
from celeste.properties import (
    Kind,
    Property,
    ack,
    always,
    declare,
    eventually,
    maximize,
    note,
    present,
    reachable,
    sometimes,
    step,
    unreachable,
)


INTERFACE_VERSION = 2

__all__ = (
    'INTERFACE_VERSION',
    'InterfaceError',
    'Kind',
    'Property',
    'ack',
    'always',
    'below',
    'boolean',
    'checked',
    'choice',
    'declare',
    'eventually',
    'eventually_ns',
    'maximize',
    'note',
    'power_loss',
    'present',
    'quiet_wait',
    'random',
    'reachable',
    'ready',
    'seed',
    'sometimes',
    'step',
    'unreachable',
)
