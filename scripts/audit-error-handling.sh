#!/usr/bin/env bash
# scripts/audit-error-handling.sh — fails when new code drops an error silently
# (#607): an unexplained try?, a catch that neither logs nor rethrows, print
# logging, a blocking sleep or wait in the app, localizedDescription shown to the
# listener, or a Core Audio status thrown away. Today's sites are listed in
# scripts/error-handling-baseline.json; the rules and options are documented in
# scripts/audit_error_handling.py.
#
# Run from the repository root. Wired into `make test` and CI "Static audits".
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/audit_error_handling.py "$@"
