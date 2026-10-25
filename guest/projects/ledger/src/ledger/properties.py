BALANCED = "every balance equals its opening balance plus the transfers that touched it"
CONSERVED = "the money in all accounts is conserved"
EVENTUALLY = "every fresh transfer completes once the faults stop"
LEASE_LOST = "a transfer lost its account lease before it committed"
REJECTED = "a transfer is rejected for insufficient funds"
REPEATED = "a repeated transfer request is recognised as a duplicate"
SOLVENT = "no account balance is negative"

PROPERTIES = (
    ("always", BALANCED),
    ("always", CONSERVED),
    ("always", SOLVENT),
    ("reachable", REPEATED),
    ("sometimes", REJECTED),
    ("unreachable", LEASE_LOST),
)
