"""M05 Phase-B tools: symbol selection + hash sizing reports.

These are throw-away analysis scripts used to pick lob_core compile-time
parameters. They MUST NOT be imported by RTL build flows or by any test
that runs in CI — outputs are baked into the design at C-phase parameter
freeze and never re-read at runtime.
"""
