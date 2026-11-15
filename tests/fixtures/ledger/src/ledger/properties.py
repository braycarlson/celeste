import celeste


BALANCED = "every balance equals its opening balance plus the transfers that touched it"
CONSERVED = "the money in all accounts is conserved"
EVENTUALLY = "every fresh transfer completes once the faults stop"
LEASE_LOST = "a transfer lost its account lease before it committed"
REJECTED = "a transfer is rejected for insufficient funds"
REPEATED = "a repeated transfer request is recognised as a duplicate"
SOLVENT = "no account balance is negative"

PROPERTIES = (
    celeste.Property(celeste.Kind.ALWAYS, BALANCED),
    celeste.Property(celeste.Kind.ALWAYS, CONSERVED),
    celeste.Property(celeste.Kind.ALWAYS, SOLVENT),
    celeste.Property(celeste.Kind.REACHABLE, REPEATED),
    celeste.Property(celeste.Kind.SOMETIMES, REJECTED),
    celeste.Property(celeste.Kind.UNREACHABLE, LEASE_LOST),
)
