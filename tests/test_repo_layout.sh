#!/usr/bin/env bash
set -Eeuo pipefail
for p in README.md LICENSE VERSION config/source-lock.env docs/SOURCES.md docs/architecture.md build-image.sh; do
  test -e "$p" || { echo "missing: $p" >&2; exit 1; }
done
