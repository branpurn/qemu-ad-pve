#!/bin/bash
# shellcheck disable=SC2015  # `cond && ok || bad` is the intended idiom here: ok() cannot fail
# Tests for the safety gate of tests/tier2.sh. Needs no root, no PVE and no network.
#
# SAFE BY CONSTRUCTION: every run of tier2.sh happens under `env -i` with PATH = <temp stub dir>:/usr/bin:/bin, so
# `qm`, `hostname` and `pvecm` are stubs that only print canned output (the qm stub logs each call and refuses
# anything except `qm list`). Before any test, the script verifies that `qm` resolves to the stub. tier2.sh is only
# ever invoked with the `gate`, `setup` (REF unset => refuses before doing anything), `teardown` and `table`
# subcommands (the last two only with a gate that refuses, or `table` which only prints a report), and with
# WORK_DIR/HOME pointing into the temp dir. All VMIDs here (100, 101, 300, 500, 900-902, ...) are made-up fixtures.
#
# Usage: bash tests/tier2-gate-test.sh        (exit 0 = all pass; the last line is `GATE TEST: pass=N fail=M`)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T2="$HERE/tier2.sh"
[[ -r $T2 ]] || { echo "cannot read $T2" >&2; exit 2; }
ROOT=$(mktemp -d /tmp/qad-gate-test.XXXXXX) || exit 2
trap 'rm -rf "$ROOT"' EXIT
STUB="$ROOT/stub"; mkdir -p "$STUB" "$ROOT/work" "$ROOT/home"

cat > "$STUB/qm" <<'S'
#!/bin/bash
# stub qm: logs every call; only `list` is supported (canned output + exit code from files)
echo "qm $*" >> "$STUB_DIR/qm.calls"
[[ ${1:-} == list ]] || { echo "stub qm: refusing '$*'" >&2; exit 99; }
cat "$STUB_DIR/qm.list" 2>/dev/null
exit "$(cat "$STUB_DIR/qm.rc" 2>/dev/null || echo 0)"
S
cat > "$STUB/hostname" <<'S'
#!/bin/bash
echo "gate-test-node"
S
cat > "$STUB/pvecm" <<'S'
#!/bin/bash
exit "$(cat "$STUB_DIR/pvecm.rc" 2>/dev/null || echo 1)"
S
chmod +x "$STUB"/*
export STUB_DIR="$STUB"

pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

# safety: the stub must be what `qm` resolves to under the PATH we use
resolved=$(env -i PATH="$STUB:/usr/bin:/bin" bash -c 'command -v qm')
[[ $resolved == "$STUB/qm" ]] || { echo "ABORT: qm does not resolve to the stub ($resolved)"; exit 2; }

# set_list <rows...>: qm list output (header + rows); set_rc <n>
set_list() { { echo "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"; printf '%s\n' "$@"; } > "$STUB/qm.list"; }
set_rc()   { echo "$1" > "$STUB/qm.rc"; }
row()      { printf '%10s %-20s stopped    512        8.00 0' "$1" "${2:-vm$1}"; }
reset()    { set_rc 0; set_list; echo 1 > "$STUB/pvecm.rc"; : > "$STUB/qm.calls"; }

# gate [VAR=value ...]: run tier2.sh gate hermetically; sets $rc and $out
DEFAULT_ENV=(TEST_HOSTNAME=gate-test-node 'QAD_PROTECTED_VMIDS=100 101 300' KVM_DEV=/dev/null)
gate() { run_t2 gate "${DEFAULT_ENV[@]}" "$@"; }
run_t2() {
  local sub="$1"; shift
  out=$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$ROOT/home" WORK_DIR="$ROOT/work" STUB_DIR="$STUB" "$@" bash "$T2" "$sub" 2>&1); rc=$?
}
# expect <name> abort|pass [pattern]
expect() {
  local name="$1" want="$2" pat="${3:-}"
  if [[ $want == abort ]]; then
    if [[ $rc -ne 0 && $out != *"gate ok"* ]] && { [[ -z $pat ]] || [[ $out == *"$pat"* ]]; }; then ok "$name"; else bad "$name (rc=$rc out=${out:0:160})"; fi
  else
    if [[ $rc -eq 0 && $out == *"gate ok"* ]]; then ok "$name"; else bad "$name (rc=$rc out=${out:0:160})"; fi
  fi
}
no_qm_calls() { [[ ! -s $STUB/qm.calls ]]; }
only_list_calls() { ! grep -qv '^qm list$' "$STUB/qm.calls"; }

# --- unset / empty TEST_HOSTNAME
reset; run_t2 gate KVM_DEV=/dev/null 'QAD_PROTECTED_VMIDS=100'
expect "TEST_HOSTNAME unset: refuses" abort "TEST_HOSTNAME"; no_qm_calls && ok "  ... without calling qm" || bad "  ... qm was called"
reset; run_t2 gate TEST_HOSTNAME= KVM_DEV=/dev/null 'QAD_PROTECTED_VMIDS=100'; expect "TEST_HOSTNAME empty: refuses" abort "TEST_HOSTNAME"
# --- wrong hostname
reset; gate TEST_HOSTNAME=some-other-node; expect "wrong hostname: aborts" abort "wrong host"; no_qm_calls && ok "  ... without calling qm" || bad "  ... qm was called"
# --- QAD_PROTECTED_VMIDS required
reset; run_t2 gate TEST_HOSTNAME=gate-test-node KVM_DEV=/dev/null; expect "QAD_PROTECTED_VMIDS unset: refuses" abort "QAD_PROTECTED_VMIDS"; no_qm_calls && ok "  ... without calling qm" || bad "  ... qm was called"
reset; gate QAD_PROTECTED_VMIDS=; expect "QAD_PROTECTED_VMIDS empty: refuses" abort "QAD_PROTECTED_VMIDS"
reset; gate 'QAD_PROTECTED_VMIDS=   '; expect "QAD_PROTECTED_VMIDS blanks only: refuses" abort "QAD_PROTECTED_VMIDS"
reset; gate 'QAD_PROTECTED_VMIDS=abc'; expect "QAD_PROTECTED_VMIDS non-numeric: refuses" abort "bad QAD_PROTECTED_VMIDS"
reset; gate 'QAD_PROTECTED_VMIDS=100;touch'; expect "QAD_PROTECTED_VMIDS junk: refuses" abort "bad QAD_PROTECTED_VMIDS"
reset; gate PROTECTED_VMIDS=100 QAD_PROTECTED_VMIDS=; expect "old name PROTECTED_VMIDS is not accepted" abort "QAD_PROTECTED_VMIDS"
# --- qm list failures (fail closed)
reset; set_rc 1; gate; expect "qm list fails (no output): aborts" abort "qm list"
reset; set_rc 1; set_list "$(row 100)"; gate; expect "qm list fails but prints a protected VMID: aborts" abort
reset; set_rc 1; set_list "$(row 900)"; gate; expect "qm list fails but prints only a test VMID: aborts" abort "qm list"
# --- protected VMIDs present
for v in 100 101 300; do reset; set_list "$(row $v)"; gate; expect "protected VMID $v present: aborts" abort "protected VMID $v"; done
reset; set_list "$(row 900)" "$(row 300)"; gate; expect "protected VMID last in list: aborts" abort "protected VMID 300"
reset; set_list "$(row 0100)"; gate; expect "zero-padded protected VMID 0100: aborts" abort
# protected VMID first in a long list (500 rows, ~100 KB of output, to exceed the pipe buffer), repeated 50x for flakes
reset; rows=(); name=$(printf 'x%.0s' $(seq 1 180))
rows+=("$(row 100 "$name")"); for i in $(seq 1 499); do rows+=("$(row $((1000+i)) "$name")"); done; set_list "${rows[@]}"
[[ $(wc -c < "$STUB/qm.list") -gt 70000 ]] || bad "fixture too small to exceed a 64 KiB pipe buffer"
flaky=0; for i in $(seq 1 50); do gate; [[ $rc -ne 0 && $out == *"protected VMID 100"* && $out != *"gate ok"* ]] || { flaky=$((flaky+1)); last=$out; }; done
[[ $flaky -eq 0 ]] && ok "protected VMID 100 first in a 500-row list: aborted 50/50 runs" || bad "protected VMID first in long list: $flaky/50 runs did not abort (${last:0:120})"
# --- outside the test range (auto-protected)
reset; set_list "$(row 555)"; gate; expect "VMID outside test range (555) present: aborts" abort "outside the test range"
reset; set_list "$(row 903)"; gate; expect "VMID just above the default range (903): aborts" abort "outside the test range"
reset; set_list "$(row 899)"; gate; expect "VMID just below the default range (899): aborts" abort "outside the test range"
reset; set_list "$(row 500)"; gate 'QAD_PROTECTED_VMIDS=none'; expect "'none' still refuses an outside-range VMID (500)" abort "outside the test range"
# --- unparseable output
reset; set_list "garbage line"; gate; expect "unparseable qm list row: aborts" abort "cannot parse"
# --- passing cases
reset; set_list "$(row 900 qad-a)"; gate; expect "only a test VMID (900) present: passes" pass; only_list_calls && ok "  ... only 'qm list' was called" || bad "  ... other qm calls: $(cat "$STUB/qm.calls")"
reset; set_list "$(row 900)" "$(row 901)" "$(row 902)"; gate; expect "all three test VMIDs present: passes" pass
reset; gate; expect "empty node (header only): passes" pass
reset; : > "$STUB/qm.list"; gate; expect "empty node (no output at all): passes" pass
reset; gate 'QAD_PROTECTED_VMIDS=none'; expect "'none' on an empty node: passes" pass
# --- TEST_VMID_BASE
reset; set_list "$(row 700)" "$(row 702)"; gate TEST_VMID_BASE=700; expect "TEST_VMID_BASE=700: 700/702 are test VMIDs: passes" pass
reset; set_list "$(row 900)"; gate TEST_VMID_BASE=700; expect "TEST_VMID_BASE=700: 900 is now outside the range: aborts" abort "outside the test range"
reset; gate TEST_VMID_BASE=abc; expect "TEST_VMID_BASE non-numeric: aborts" abort "TEST_VMID_BASE"
reset; gate TEST_VMID_BASE=50; expect "TEST_VMID_BASE below 100: aborts" abort "TEST_VMID_BASE"
reset; gate 'QAD_PROTECTED_VMIDS=100 901'; expect "protected VMID inside the test range: config error, aborts" abort "inside the test range"
reset; gate 'ISO=local:iso/x.iso;touch'; expect "ISO with shell metacharacters: aborts" abort "ISO"
reset; gate 'BRIDGE=vmbr0 --x'; expect "BRIDGE with a space: aborts" abort "BRIDGE"
# --- other gate branches
reset; echo 0 > "$STUB/pvecm.rc"; gate; expect "node in a cluster (pvecm status ok): aborts" abort "cluster"
reset; gate KVM_DEV="$ROOT/no-such-dev"; expect "no /dev/kvm: aborts" abort "kvm"
# --- REF is required before setup does anything
reset; run_t2 setup "${DEFAULT_ENV[@]}"; [[ $rc -ne 0 && $out == *"REF"* ]] && ok "setup without REF: refuses" || bad "setup without REF (rc=$rc out=${out:0:160})"
only_list_calls && ok "  ... only 'qm list' was called" || bad "  ... other qm calls: $(cat "$STUB/qm.calls")"
reset; run_t2 setup "${DEFAULT_ENV[@]}" REF=abc123; [[ $rc -ne 0 && $out == *"REF"* ]] && ok "setup with a short REF: refuses" || bad "setup with short REF (rc=$rc out=${out:0:160})"
# --- no mutation before the gate passes: when the gate refuses, no directory or file may be created
# (WORK_DIR, OUT, results.tsv, run.log, ...). Only subcommands that are safe to run hermetically are exercised: with a
# refusing gate each one must stop in gate() (setup also has the unset-REF refusal behind it); `table` is a pure report.
fs_clean() { [[ -z $(ls -A "$ROOT/work" 2>/dev/null) && -z $(ls -A "$ROOT/home" 2>/dev/null) ]]; }
wipe()     { rm -rf "${ROOT:?}/work" "${ROOT:?}/home"; mkdir -p "$ROOT/work" "$ROOT/home"; }
for sub in gate setup teardown table; do
  wipe; reset; run_t2 "$sub" "${DEFAULT_ENV[@]}" TEST_HOSTNAME=some-other-node
  [[ $rc -ne 0 && $out == *"wrong host"* ]] && ok "$sub, gate refuses (wrong host): aborts" || bad "$sub wrong host (rc=$rc out=${out:0:160})"
  fs_clean && ok "  ... and created no files or directories" || bad "  ... $sub created: $(find "$ROOT/work" "$ROOT/home" | head -5 | tr '\n' ' ')"
  wipe; reset; run_t2 "$sub" TEST_HOSTNAME=gate-test-node KVM_DEV=/dev/null    # QAD_PROTECTED_VMIDS unset
  [[ $rc -ne 0 && $out == *"QAD_PROTECTED_VMIDS"* ]] && ok "$sub, QAD_PROTECTED_VMIDS unset: aborts" || bad "$sub unset protected (rc=$rc out=${out:0:160})"
  fs_clean && ok "  ... and created no files or directories" || bad "  ... $sub created: $(find "$ROOT/work" "$ROOT/home" | head -5 | tr '\n' ' ')"
  wipe; reset; set_list "$(row 100)"; run_t2 "$sub" "${DEFAULT_ENV[@]}"        # protected VMID present
  [[ $rc -ne 0 && $out == *"protected VMID 100"* ]] && ok "$sub, protected VMID present: aborts" || bad "$sub protected VMID (rc=$rc out=${out:0:160})"
  fs_clean && ok "  ... and created no files or directories" || bad "  ... $sub created: $(find "$ROOT/work" "$ROOT/home" | head -5 | tr '\n' ' ')"
done
wipe; reset; run_t2 table "${DEFAULT_ENV[@]}" 'WORK_DIR=relative/dir'
[[ $rc -ne 0 && $out == *"absolute path"* ]] && ok "table with a relative WORK_DIR: aborts" || bad "table relative WORK_DIR (rc=$rc out=${out:0:160})"
[[ -z $(ls -A "$ROOT/work") && ! -e "$ROOT/relative" && ! -e relative ]] && ok "  ... and created nothing" || bad "  ... created files"
wipe; reset; set_list "$(row 900)"; run_t2 table "${DEFAULT_ENV[@]}"
[[ $rc -eq 0 && $out == *"gate ok"* && $out == *"| ID | Result |"* ]] && ok "table with a passing gate: prints the table" || bad "table, gate ok (rc=$rc out=${out:0:160})"
[[ -f "$ROOT/work/t2-out/results.md" && -f "$ROOT/work/t2-out/results.tsv" ]] && ok "  ... and creates OUT only now" || bad "  ... results files missing"
only_list_calls && ok "  ... only 'qm list' was called" || bad "  ... other qm calls: $(cat "$STUB/qm.calls")"
wipe
# --- hermetic: nothing outside the temp dir was written
[[ ! -e /tmp/qad-work && ! -e "$HOME/qad-work" ]] && ok "no work dir created outside the temp dir" || bad "stray work dir created"

echo "GATE TEST: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
