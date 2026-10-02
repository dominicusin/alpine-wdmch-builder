#!/usr/bin/env bash
# test_repo_layout.sh - required files exist, and so does everything the
# documentation tells a reader to run.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

for p in README.md LICENSE VERSION config/source-lock.env docs/SOURCES.md docs/architecture.md build-image.sh; do
  test -e "$p" || { echo "missing: $p" >&2; exit 1; }
done

# Every script or tool path quoted in the documentation must exist.
#
# Documentation is the only interface most operators ever touch, and a renamed
# file turns a working instruction into a dead one - silently, because prose
# never fails anything. This release already found two scripts that nothing
# invoked (one of them never parsed at all); a documented path that no longer
# exists is the same class of absence, and costs nothing to catch.
#
# Scoped to paths under the directories this repo actually uses, so prose about
# /dev/sda or /proc/mounts is not mistaken for a repository reference.
missing=""
while read -r f; do
    [ -n "$f" ] || continue
    [ -e "$f" ] || missing="$missing $f"
done < <(
    grep -rhoE '\b(tools|scripts|tests|image|kernel)/[a-z0-9_.-]+\.(sh|py)' \
        README.md ROADMAP.md STRATEGY.md docs/*.md 2>/dev/null | sort -u
)
if [ -n "$missing" ]; then
    echo "FAIL: documentation references files that do not exist:" >&2
    for m in $missing; do echo "      $m" >&2; done
    exit 1
fi

# A flag shown in the documentation must be a flag the tool accepts. Cheap, and
# it catches the other half of the same problem: the file is still there but the
# instruction using it stopped working.
badflag=""
while read -r m; do
    [ -n "$m" ] || continue
    tool=${m%% *}
    flag=${m##* }
    [ -f "$tool" ] || continue
    grep -q -- "$flag" "$tool" || badflag="$badflag $tool $flag"
done < <(
    grep -rhoE '(tools|scripts)/[a-z0-9_-]+\.sh --[a-z][a-z-]+' \
        README.md ROADMAP.md STRATEGY.md docs/*.md 2>/dev/null | sort -u
)
if [ -n "$badflag" ]; then
    echo "FAIL: documentation shows flags the tool does not accept:" >&2
    for b in $badflag; do echo "      $b" >&2; done
    exit 1
fi

echo "repo layout: OK"