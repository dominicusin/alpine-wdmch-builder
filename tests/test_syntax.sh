#!/bin/bash
# Every tracked shell script must PARSE. bash -n is free and instant.
#
# tools/plan-btrfs-migration.sh did not parse, and had never parsed. It has been
# in the tree since it was written and nothing ran it or checked it, so it sat
# there broken through thirteen releases. Two defects stacked:
#
#   1. info "asymmetric by $(numfmt --to=iec $((SB/SA))x - ..."
#      the command substitution was never closed, so it swallowed the rest of
#      the file
#   2. the heredoc delimiter was PLAN, and the plan text contains a line that is
#      exactly PLAN, so the heredoc closed 60 lines early and the remaining
#      prose was parsed as shell
#
# Neither could have been found by reading it. `bash -n` finds both in
# milliseconds, and nothing in this project ever asked.
set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0
bad=""
for f in $(git ls-files '*.sh' 'rootfs/install-alpine' 'rootfs/init' 'rootfs/init.d/*'); do
    [ -f "$f" ] || continue
    if ! out=$(bash -n "$f" 2>&1); then
        bad="$bad  $f: $(printf '%s' "$out" | head -1)"$'\n'
    fi
done
n=$(git ls-files '*.sh' 'rootfs/install-alpine' 'rootfs/init' 'rootfs/init.d/*' | wc -l)
if [ -n "$bad" ]; then
    echo "FAIL: shell scripts that do not parse:" >&2
    printf '%s' "$bad" >&2
    echo "      A script that cannot parse has never run. Fix or delete it." >&2
    exit 1
fi
echo "  ok    all $n tracked shell scripts parse"
