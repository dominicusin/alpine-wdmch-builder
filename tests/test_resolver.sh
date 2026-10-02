#!/bin/bash
# test_resolver.sh - does the dependency resolver fail correctly?
#
# image/resolve-deps.py decides what goes on the USB stick. There is no
# hand-maintained package list: the seeds are resolved into a closure, and
# anything missing from that closure is discovered on the WDMCH, not on the
# build machine.
#
# That is why the failure modes matter more than the happy path. A resolver
# that quietly returns a short closure produces a stick that installs a system
# which cannot boot. Three real defects came from exactly that:
#   - APKINDEX v2 encodes shared libraries as p:so:* providers inside D:,
#     with no separate So: line, so the libraries were dropped
#   - virtual providers were not consulted, so a package provided by another
#     looked like it had an unsatisfiable dependency
#   - conflicts are encoded as a leading '!' in D: and were parsed as a
#     dependency, so the package was fetched when it should have been refused
#
# These build real APKINDEX.tar.gz files and run the real resolver. Nothing
# here re-implements resolution.

set -u
cd "$(dirname "$0")/.." || exit 1
RESOLVER=image/resolve-deps.py
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
# The accumulator is named _cond_rc, not rc, on purpose. cond is always called
# inside $( ), so it runs in a subshell: a plain `rc=0` here would overwrite a
# caller's `rc` that an assertion is about to test, and the assertion would
# silently evaluate the accumulator instead of the value it was given. That
# happened here - every exit-code assertion was checking [ 0 -ne 0 ].
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$RESOLVER" ] || { echo "FAIL: $RESOLVER missing" >&2; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: python3 unavailable" >&2; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# mkindex <outfile> <record>...   (one record per argument, blank-line separated)
# The APKINDEX inside the tar is PLAIN text; only the tar is gzipped. Gzipping
# the member as well - which this did at first - yields a tar of gzip bytes
# that parses to an empty index and every assertion below fails for the wrong
# reason. The real main/community indexes are tar.gz with a plain member.
mkindex() {
    local out=$1; shift
    local body="" rec
    for rec in "$@"; do body="$body$rec"$'\n\n'; done
    printf '%s' "$body" > "$W/APKINDEX"
    tar -czf "$out" -C "$W" APKINDEX
}

resolve() { # resolve <main> <community> <seed...>  -> closure on stdout
    python3 "$RESOLVER" --tsv --main "$1" --community "$2" "${@:3}" 2>"$W/err"
}

echo "=== dependency resolver ==="

# --- 1. a plain chain ---------------------------------------------------------
mkindex "$W/main.tar.gz" \
"C:1
P:app
V:1.0-r0
A:x86_64
D:libfoo=1.0-r0
F:lib

" \
"C:1
P:libfoo
V:1.0-r0
A:x86_64
F:lib
"
mkindex "$W/comm.tar.gz" "C:1
P:other
V:1.0-r0
A:x86_64
F:lib
"
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" app)
check "a two-level chain resolves" \
      "$(cond '[ "$(echo "$out" | grep -c .)" -eq 2 ]'; echo $?)"
check "  ...and includes the transitive library" \
      "$(cond 'echo "$out" | grep -q libfoo'; echo $?)"

# --- 2. a dependency that does not exist must be an error --------------------
# This is the important one. Returning a partial closure is how a broken stick
# gets built; the resolver must fail instead.
mkindex "$W/main.tar.gz" \
"C:1
P:app
V:1.0-r0
A:x86_64
D:libmissing=1.0-r0
F:lib
"
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" app); rc=$?
check "an unsatisfiable dependency is a non-zero exit" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...and the missing package is named" \
      "$(cond 'grep -qi libmissing "$W/err"'; echo $?)"
check "  ...and the partial closure is labelled incomplete, not silently short" \
      "$(cond 'grep -q INCOMPLETE "$W/err"'; echo $?)"
check "  ...and the missing name is written where a human will look" \
      "$(cond '[ -s .work/apk-cache-offline/closure-fail.txt ] 2>/dev/null || [ -s closure-fail.txt ] 2>/dev/null'; echo $?)"

# --- 3. a seed that does not exist -------------------------------------------
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" nosuchpackage); rc=$?
check "an unknown seed package is a non-zero exit" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"

# --- 4. virtual providers, as APKINDEX v2 encodes them ------------------------
# p:so:* lives inside D: on the providing side. Verified against the pinned
# index: all 6411 `so:` entries in main are BARE sonames with no version, so
# the fixture matches that rather than a shape I invented.
mkindex "$W/main.tar.gz" \
"C:1
P:app
V:1.0-r0
A:x86_64
D:so:libc.musl-x86_64.so.1 so:libssl.so.3
" \
"C:1
P:musl
V:1.2.5-r0
A:x86_64
p:so:libc.musl-x86_64.so.1=1
" \
"C:1
P:libssl3
V:3.0-r0
A:x86_64
p:so:libssl.so.3=3.0
"
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" app)
check "a p:so:* virtual provider satisfies the dependency" \
      "$(cond 'echo "$out" | grep -q musl'; echo $?)"
check "  ...and pulls in every provider it needs" \
      "$(cond 'echo "$out" | grep -q libssl3'; echo $?)"

# The lookup indexes bare sonames, and a non-matching key is skipped silently -
# the e2fsprogs truncation shape. If a future index versions these deps, this
# has to keep working rather than quietly truncate again.
mkindex "$W/main.tar.gz" \
"C:1
P:app
V:1.0-r0
A:x86_64
D:so:libc.musl-x86_64.so.1=1
" \
"C:1
P:musl
V:1.2.5-r0
A:x86_64
p:so:libc.musl-x86_64.so.1=1
"
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" app)
check "a VERSIONED so: dependency still resolves to its provider" \
      "$(cond 'echo "$out" | grep -q musl'; echo $?)"

# --- 5. conflicts are a refusal, not a dependency -----------------------------
# v2 encodes conflicts as a leading '!' inside D:.
mkindex "$W/main.tar.gz" \
"C:1
P:app
V:1.0-r0
A:x86_64
D:!badpkg
F:lib
" \
"C:1
P:badpkg
V:1.0-r0
A:x86_64
F:lib
"
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" app); rc=$?
# A conflict is a negative constraint, not an unsatisfiable dependency: it must
# not be fetched, and it must not make resolution fail. Asserting only "badpkg
# is absent" is not enough - when the '!' handling is removed, badpkg is looked
# up as a package, fails to exist, and is reported missing, so it is still
# absent from the output. The exit code is what separates the two.
check "a '!conflict' is not treated as a dependency to fetch" \
      "$(cond '! echo "$out" | grep -q badpkg'; echo $?)"
check "  ...and does NOT make resolution fail" \
      "$(cond '[ $rc -eq 0 ]'; echo $?)"

# --- 6. a seed satisfied only from community ---------------------------------
mkindex "$W/main.tar.gz" "C:1
P:app
V:1.0-r0
A:x86_64
D:only-in-community=1
F:lib
"
mkindex "$W/comm.tar.gz" "C:1
P:only-in-community
V:1-r0
A:x86_64
F:lib
"
out=$(resolve "$W/main.tar.gz" "$W/comm.tar.gz" app)
check "a package is found in the community index" \
      "$(cond 'echo "$out" | grep -q only-in-community'; echo $?)"

# --- 7. a dependency cycle must terminate ------------------------------------
mkindex "$W/main.tar.gz" \
"C:1
P:pinger
V:1-r0
A:x86_64
D:pong=1
F:lib
" \
"C:1
P:pong
V:1-r0
A:x86_64
D:pinger=1
F:lib
"
out=$(timeout 20 sh -c "python3 '$RESOLVER' --tsv --main '$W/main.tar.gz' --community '$W/comm.tar.gz' pinger" 2>/dev/null); rc=$?
check "a dependency cycle terminates rather than looping" \
      "$(cond '[ $rc -ne 124 ]'; echo $?)"

# --- 8. a missing index file is an error, not an empty closure ---------------
out=$(python3 "$RESOLVER" --tsv --main "$W/does-not-exist.tar.gz" --community "$W/comm.tar.gz" app 2>"$W/err"); rc=$?
check "a missing APKINDEX is a non-zero exit" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...and never yields an empty-but-successful closure" \
      "$(cond '[ -z "$out" ]'; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "dependency resolver: PASSED"
else
    echo "dependency resolver: FAILED ($FAILED)" >&2
    exit 1
fi
