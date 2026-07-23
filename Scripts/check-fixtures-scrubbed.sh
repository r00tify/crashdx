#!/bin/bash
# Verify every tracked fixture and dSYM is scrubbed. Run by CI; safe to run locally from
# any directory.
#
# Thin wrapper so the documented entrypoint stays stable. The real check lives in
# check_fixtures.py, which walks PARSED JSON rather than grepping file text — a
# grep-based version was bypassable by tabs, newlines, \uXXXX escapes, nesting, and
# ISO-8601 offsets, and (worse) a `grep -q` inside a pipeline under `set -o pipefail`
# reported SIGPIPE as "no match", so it passed exactly the large leaks that mattered.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec /usr/bin/env python3 Scripts/check_fixtures.py "$@"
