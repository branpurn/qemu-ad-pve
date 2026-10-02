#!/bin/bash
# shellcheck disable=SC2016  # the single-quoted bash -c body is deliberately expanded by the inner shell
# Tests for the safety guard in tier15-common.sh (t15_guard). Runs unprivileged and touches nothing: the guard is only
# CALLED (never the tier-1.5 scripts themselves), against a fake filesystem root (T15_FS_ROOT) and stub binaries.
# Usage: bash tests/tier15-guard-test.sh   (exit 0 = all pass; last line `GUARD TEST: pass=N fail=M`)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(mktemp -d /tmp/qad-guard-test.XXXXXX) || exit 2
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/stub"
pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

# g <name> <pattern> [ENV=val ...]: run t15_guard hermetically; expect exit 2 and the pattern in the message
g() {
  local name="$1" pat="$2"; shift 2
  local out rc
  out=$(env -i PATH="$ROOT/stub:/usr/bin:/bin" T15_FS_ROOT="$ROOT/fs" "$@" bash -c 'source "$1/tier15-common.sh"; t15_guard; echo GUARD-PASSED' _ "$HERE" 2>&1); rc=$?
  if [[ $rc -eq 2 && $out == *"$pat"* && $out != *GUARD-PASSED* ]]; then ok "$name"; else bad "$name (rc=$rc out=${out:0:120})"; fi
}
fresh() { rm -rf "$ROOT/fs" "$ROOT/stub"; mkdir -p "$ROOT/fs/usr/sbin" "$ROOT/fs/etc" "$ROOT/stub"; }

fresh; g "no QAD_T15_SANDBOX: refuses" "QAD_T15_SANDBOX=1"
fresh; g "QAD_T15_SANDBOX=0: refuses" "QAD_T15_SANDBOX=1" QAD_T15_SANDBOX=0
fresh; g "QAD_T15_SANDBOX=true: refuses" "QAD_T15_SANDBOX=1" QAD_T15_SANDBOX=true
fresh; : > "$ROOT/fs/usr/sbin/qm"; g "/usr/sbin/qm exists (not on PATH): refuses" "/usr/sbin/qm" QAD_T15_SANDBOX=1
fresh; printf '#!/bin/sh\n' > "$ROOT/stub/qm"; chmod +x "$ROOT/stub/qm"; g "qm on PATH: refuses" "'qm' found" QAD_T15_SANDBOX=1
fresh; mkdir "$ROOT/fs/etc/pve"; g "/etc/pve exists: refuses" "/etc/pve" QAD_T15_SANDBOX=1
fresh; printf '#!/bin/sh\necho "install ok installed"\n' > "$ROOT/stub/dpkg-query"; chmod +x "$ROOT/stub/dpkg-query"
g "real pve-qemu-kvm installed: refuses" "pve-qemu-kvm package" QAD_T15_SANDBOX=1
if [[ $(id -u) -ne 0 ]]; then fresh; g "all other checks pass but not root: refuses" "must run as root" QAD_T15_SANDBOX=1; else echo "SKIP  not-root check (running as root)"; fi

echo "GUARD TEST: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
