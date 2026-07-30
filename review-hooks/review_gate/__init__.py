"""Deep module behind the aggregate review gate.

The interface accepts a review target and policy, then returns one decision
and an evidence path. Hooks and operator commands are thin adapters over
`review_gate.cli`.
"""

RUNTIME_VERSION = "2.0.0"
RUN_SCHEMA_VERSION = 1
RESULT_SCHEMA_VERSION = 1
CACHE_SCHEMA_VERSION = 1
STATE_SCHEMA_VERSION = 1
ACK_SCHEMA_VERSION = 1
