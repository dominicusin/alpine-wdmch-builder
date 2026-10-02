#!/bin/bash
# test_seams.sh - a declared seam must be honoured at EVERY call site.
#
# The pattern behind four separate defects this release:
#
#   btrfs metadata profile   a comment claimed dup kept two copies; it does not
#   disk selection            /dev/sd? globbed while the test faked /proc/partitions
#   rescue-stick detection   stick_disk() read /proc/mounts while its caller
#                            honoured MOUNTS_FILE
#   installer unmount loop   read /proc/mounts while the same script defined
#                            mounts_file="${PROC_MOUNTS:-/proc/mounts}"
#
# In the last two the script DOCUMENTED a seam and then ignored it in one place.
# A test that set the variable believed it controlled the code; it did not, for
# that call site. The failure mode is invisible from the test, because the test
# is asserting the behaviour it wanted to control rather than the behaviour it
# got.
#
# So: if a script defines an injectable path, no line in that script may read the
# host path directly. This is a static check on purpose - the whole problem is
# that the dynamic tests could not see it.

set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

echo "=== declared seams are honoured everywhere in the script that declares them ==="

# --- rootfs/install-alpine: PROC_MOUNTS ---------------------------------------
INST=rootfs/install-alpine
check "install-alpine declares the PROC_MOUNTS seam" \
      "$(cond "grep -q 'mounts_file=\"\${PROC_MOUNTS:-/proc/mounts}\"' '$INST'"; echo $?)"
# Any line reading /proc/mounts other than the declaration and its comment.
leaks=$(grep -nE '(^|[^_[:alnum:]])/proc/mounts' "$INST" \
        | grep -vE ':\s*#' \
        | grep -v 'mounts_file="${PROC_MOUNTS:-/proc/mounts}"' || true)
check "  ...and no other line reads /proc/mounts directly" \
      "$([ -z "$leaks" ] && echo 0 || echo 1)"
if [ -n "$leaks" ]; then echo "$leaks" | sed 's/^/        /'; fi

# --- tools/backup-fw-table.sh: MOUNTS_FILE -----------------------------------
BF=tools/backup-fw-table.sh
check "backup-fw-table.sh honours MOUNTS_FILE" \
      "$(cond "grep -q 'mounts=\"\${MOUNTS_FILE:-/proc/mounts}\"' '$BF'"; echo $?)"
leaks2=$(grep -nE '(^|[^_[:alnum:]])/proc/mounts' "$BF" \
         | grep -vE ':\s*#' \
         | grep -v 'mounts="${MOUNTS_FILE:-/proc/mounts}"' || true)
check "  ...and no other line reads /proc/mounts directly" \
      "$([ -z "$leaks2" ] && echo 0 || echo 1)"
if [ -n "$leaks2" ]; then echo "$leaks2" | sed 's/^/        /'; fi

# --- scripts/verify-install.sh: PARTS and DEVS -------------------------------
VI=scripts/verify-install.sh
check "verify-install exposes PARTS for the partition table" \
      "$(cond "grep -q 'parts=\${PARTS:-/proc/partitions}' '$VI'"; echo $?)"
check "verify-install exposes DEVS for the disk list" \
      "$(cond "grep -q 'devs=\${DEVS:-}' '$VI'"; echo $?)"

# --- the general sweep, in Python ---------------------------------------------
# In Python because the distinction that matters is lexical and grep cannot make
# it: the path must be a FILE OPERAND, not quoted inside a message. The first
# version of this sweep was grep-based and flagged
#     warn "no sd? device with partitions in /proc/partitions - cannot check"
# which is a diagnostic string, not a read - and a guard that cries wolf about
# correct code trains people to stop reading it.
general=$(python3 - "$PWD" <<'PY'
import re, subprocess, sys

root = sys.argv[1]
files = subprocess.run(
    ["git", "ls-files", "rootfs/install-alpine", "rootfs/init",
     "tools/*.sh", "scripts/*.sh"],
    capture_output=True, text=True, cwd=root).stdout.split()

seam_re = re.compile(r"\$\{([A-Z_]+):-(/proc/[a-z/]+)\}")
found = []
declared = 0

for rel in files:
    try:
        lines = open(f"{root}/{rel}", encoding="utf-8").read().splitlines()
    except OSError:
        continue

    seams = {}
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        for _var, path in seam_re.findall(line):
            seams[path] = n
    if not seams:
        continue
    declared += len(seams)

    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for path, decl in seams.items():
            for m in re.finditer(re.escape(path), line):
                before = line[:m.start()]
                if before.count('"') % 2 == 1 or before.count("'") % 2 == 1:
                    continue                      # inside a message
                if f":-{path}" in line and n == decl:
                    continue                      # the declaration itself
                # Any UNQUOTED occurrence outside the declaration is a read.
                # An earlier version required a redirection or pipe immediately
                # before the path, which missed the commonest shape of all:
                #     awk '...' /proc/mounts
                # where the path is a plain command argument. The explicit
                # per-file checks caught that one, so the sweep agreed by luck
                # rather than by working.
                if not re.match(r"^\s*(#|\*)\s", line):
                    found.append(f"{rel}:{n}  {stripped[:88]}")
                    break

if declared:
    print(f"({declared} declared seam(s) examined)")
for f in found:
    print(f)
PY
)
leaks=$(printf '%s\n' "$general" | grep -v '^(' || true)
check "no script bypasses a seam it declares" \
      "$([ -z "$leaks" ] && echo 0 || echo 1)"
if [ -n "$leaks" ]; then printf '%s\n' "$leaks" | sed 's/^/        /'; fi
[ -n "$general" ] && printf '%s\n' "$general" | grep '^(' | sed 's/^/  /'

echo
if [ "$FAILED" -eq 0 ]; then
    echo "seams: PASSED"
else
    echo "seams: FAILED ($FAILED)" >&2
    exit 1
fi