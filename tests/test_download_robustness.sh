#!/bin/bash
# test_download_robustness.sh - a transient network error must not fail a build.
#
# Proven in CI rather than imagined. Build run 37088825852 (fc45c9b) failed with
# exactly one package - libssl3-3.3.7-r1 - while every other download in the same
# batch succeeded, twice over:
#
#     DL libssl3-3.3.7-r1.apk ... FAIL
#     DL libuuid-2.40.4-r1.apk ... OK (15017 B)
#     DL lzo-2.10-r5.apk ... OK (73878 B)
#     ... 36 more OK
#
# One flaky GET from a CDN discarded ~25 minutes of correct work. dl-packages.sh
# called curl with no --retry at all, so a single refused or reset connection was
# a hard failure.
set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0
check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

SRC=image/dl-packages.sh
[ -f "$SRC" ] || { echo "FAIL: $SRC missing" >&2; exit 1; }

echo "=== every download retries, and none can leave a partial file behind ==="

# --- 1. every curl in the download path retries ------------------------------
# Counted, not assumed: a new download added later without --retry would break
# this, which is the point.
total=$(grep -cE 'curl -fsSL' "$SRC")
with_retry=$(grep -cE 'curl -fsSL --retry' "$SRC")
check "every curl in dl-packages.sh retries ($with_retry/$total)" \
      "$([ "$total" -gt 0 ] && [ "$with_retry" -eq "$total" ] && echo 0 || echo 1)"
check "  ...and retries more than once (a single retry is not a retry)" \
      "$([ "$(grep -oE -- '--retry [0-9]+' "$SRC" | head -1 | awk '{print $2}')" -ge 3 ] && echo 0 || echo 1)"
# --retry does NOT cover connection refused without this, and a CDN edge that
# drops a connection refuses the next one immediately.
check "  ...and retries connection refusals too" \
      "$(grep -q -- '--retry-connrefused' "$SRC" && echo 0 || echo 1)"

# --- 2. nothing is written directly to its final name ------------------------
# A partial file at the real path would satisfy the `[ -s ]` "already present"
# check on the next run, and a truncated APK would be packaged into flash.zip and
# reported as a successful build. Every download therefore targets a temporary
# name and is moved into place only on success.
check "no curl writes straight to a final filename" \
      "$([ "$(grep -cE 'curl -fsSL .* -o "\$(MAIN_DIR|COMM_DIR)/[^"]+"' "$SRC")" -eq 0 ] && echo 0 || echo 1)"
# A temporary that is not derived from $dest is not temporary in any useful
# sense, and the whole point is that a partial file never appears at the final
# path. This checks the assignment, not the later use of the variable: pointing
# tmp straight at the final name satisfies `-o "$tmp"` and defeats the guard.
tmpdef=$(grep -oE 'local tmp="[^"]+"' "$SRC" | head -1)
check "  ...the temporary name is derived from the destination directory" \
      "$(case "$tmpdef" in *'$dest/'*) echo 0 ;; *) echo 1 ;; esac)"
check "  ...and is not the final filename itself" \
      "$(case "$tmpdef" in *'$dest/$file'*) echo 1 ;; *) echo 0 ;; esac)"
check "  ...and each download targets it" \
      "$([ "$(grep -cE -- '-o "\$tmp"' "$SRC")" -ge 1 ] && echo 0 || echo 1)"
check "  ...and is moved into place only after success" \
      "$([ "$(grep -cE 'mv -f "\$tmp"' "$SRC")" -ge 1 ] && echo 0 || echo 1)"
check "  ...and the temporary is removed when the download fails" \
      "$([ "$(grep -cE 'rm -f "\$tmp"' "$SRC")" -ge 1 ] && echo 0 || echo 1)"

# The APKINDEX files are the more dangerous case: a partial index parses as a
# truncated package list and the resolver would then compute a wrong closure.
check "the APKINDEX downloads are hardened the same way" \
      "$([ "$(grep -cE 'APKINDEX.tar.gz" -o "\$(MAIN_INDEX|COMM_INDEX)\.tmp"' "$SRC")" -ge 1 ] && echo 0 || echo 1)"
check "  ...and a failed index download removes its temporary" \
      "$([ "$(grep -cE 'rm -f "\$(MAIN_INDEX|COMM_INDEX)\.tmp"' "$SRC")" -ge 1 ] && echo 0 || echo 1)"

# --- 3. the failure is still reported, not swallowed -------------------------
# Retrying must not turn a genuine failure into a silent pass.
check "a download that exhausts its retries still FAILS the build" \
      "$([ "$(grep -cE 'log "FAIL \(after [0-9]+ retries\)"' "$SRC")" -ge 1 ] && echo 0 || echo 1)"
check "  ...and the resolver still requires every package to be present" \
      "$(grep -qE 'FAIL=[1-9]|OK=.*FAIL=' "$SRC" && echo 0 || echo 1)"

# --- 4. curl is a declared dependency, since it is now load-bearing twice ----
check "curl is still a declared build dependency" \
      "$(grep -q 'curl' tools/check-deps.sh && echo 0 || echo 1)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "download robustness: PASSED"
else
    echo "download robustness: FAILED ($FAILED)" >&2
    exit 1
fi