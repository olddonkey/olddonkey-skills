"""Shared stdlib-only code for the implementation-loop journal (task-graph-v1).

Modules:
  canonical   canonical JSON encoding and the "sha256:" digest
  vocabulary  the schema-2 journal vocabulary, its digest subjects, and the
              guarded transition table
  reduce      the pure reducer that folds a run's events into node state

Scripts import this package only through the resolved sibling ``lib/``
directory of their own real path, and refuse a symlinked ``lib/``.
"""

VOCABULARY = "tg-v1.0a1"
