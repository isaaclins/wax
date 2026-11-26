#!/usr/bin/env bash
# `make format` and `make lint` run this, and so does CI's format check (#365),
# so all three look at the same files with the same configuration.
#
#   scripts/swift-format.sh lint     report every violation and exit non-zero
#   scripts/swift-format.sh format   rewrite the files in place
#
# SWIFT_FORMAT picks the binary. Otherwise a standalone install wins, then the
# copy inside the active Xcode toolchain. CI pins the version through the
# Swift container image in .github/workflows/ci.yml; when a local verdict
# differs from CI's, CI's version is the one that counts.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
case "$mode" in
  lint) args=(lint --strict) ;;
  format) args=(format --in-place) ;;
  *) echo "usage: $0 lint|format" >&2; exit 2 ;;
esac

swift_format="${SWIFT_FORMAT:-}"
if [ -z "$swift_format" ]; then
  swift_format="$(command -v swift-format 2>/dev/null || xcrun --find swift-format 2>/dev/null || true)"
fi
if [ -z "$swift_format" ]; then
  echo "swift-format not found. Install Xcode or run: brew install swift-format" >&2
  exit 1
fi

find Spotiglass SpotiglassTests -name '*.swift' -print0 \
  | xargs -0 "$swift_format" "${args[@]}" --parallel --configuration .swift-format
