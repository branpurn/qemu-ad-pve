#!/bin/bash
# shellcheck disable=SC2015,SC2034  # `cond && ok || bad` is the intended idiom; variables are used inside eval'd checks
# Tests for tools/qemu-ad-breakglass.sh. Needs no root, no PVE, no network, no dpkg state.
#
# SAFE BY CONSTRUCTION: every run of the tool happens under `env -i` with PATH = <temp stub dir>:/usr/bin:/bin, so
# `qm`, `dpkg-divert`, `dpkg` and `apt-get` are stubs that only edit state files in the temp dir. Every path the tool
# knows about (PREFIX, SRC_ROOT, LIST_FILE, WRAPPER_PATH, VENDOR_PATH, LOG_FILE, DPKG_LOCK, state dir, pid dir) is set to
# a path inside a temp "sandbox", and the tool is run with QAD_BREAKGLASS_SANDBOX so that it refuses any path outside it.
# The few runs WITHOUT the sandbox variable are all refusal tests or dry runs that must be refused before doing anything,
# and none uses --apply except the "needs root" check (refused for non-root; skipped when run as root). The refusal
# tests deliberately run WITHOUT --apply too: validation happens before the dry-run/apply split, and a regression in a
# check then still cannot modify anything outside the temp dir.
# All VMIDs (7001, 7002, 7003, ...) are made-up fixtures.
#
# Usage: bash tests/breakglass-test.sh        (exit 0 = all pass; the last line is `BREAKGLASS TEST: pass=N fail=M`)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BG="$HERE/../tools/qemu-ad-breakglass.sh"
[[ -r $BG ]] || { echo "cannot read $BG" >&2; exit 2; }
ROOT=$(mktemp -d /tmp/qad-bg-test.XXXXXX) || exit 2
trap 'rm -rf "$ROOT"' EXIT
STUB="$ROOT/stub"; SB="$ROOT/sb"; mkdir -p "$STUB" "$ROOT/home"
pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1 (rc=${rc:-?} out=$(printf '%s' "${out:-}" | tail -3 | tr '\n' '|' | cut -c1-200))"; fi; }

# the real kvm must be untouched by this whole test (it is never given to the tool; this is a tripwire)
real_kvm_sig() { { ls -l --time-style=+%s /usr/bin/kvm /usr/bin/kvm.pve 2>&1; sha256sum /usr/bin/kvm 2>&1; } | sha256sum; }
SIG0=$(real_kvm_sig)

# ---- stubs (state lives in $STUB_DIR) ----
cat > "$STUB/qm" <<'S'
#!/bin/bash
# stub qm: state in $STUB_DIR/qm.vms, lines "<id> <status> <protection 0|1>"; every call is logged.
# Failure injection (env): STUB_QM_{LIST,CONFIG,STATUS}_FAIL_FROM=N fails the Nth and later call of that subcommand;
# STUB_QM_STATUS_SEQ="a b c" answers successive `status` calls with a, b, c (then c); STUB_QM_STOP_FAIL=1 (stop does nothing, rc 0);
# STUB_QM_STOP_RC=N (stop does nothing, rc N); STUB_QM_DESTROY_FAIL=1 (rc 5, VM kept) | late (VM deleted, then rc 5);
# STUB_QM_DESTROY_NOOP=1 (rc 0 but VM kept); STUB_QM_LIST_HIDE=<id> (`list` omits that VM although `config` still works).
echo "qm $*" >> "$STUB_DIR/qm.calls"
V="$STUB_DIR/qm.vms"; touch "$V"
nth() { grep -c "^qm $1" "$STUB_DIR/qm.calls"; }
failfrom() { [[ -n $1 && $(nth "$2") -ge $1 ]]; }
case "${1:-}" in
  list) failfrom "${STUB_QM_LIST_FAIL_FROM:-}" list && { echo "stub qm: list failed" >&2; exit 1; }
        echo "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
        awk -v h="${STUB_QM_LIST_HIDE:-}" '$1!=h{printf "%10s vm%-18s %-10s 512        8.00 0\n",$1,$1,$2}' "$V" ;;
  status) failfrom "${STUB_QM_STATUS_FAIL_FROM:-}" status && { echo "stub qm: status failed" >&2; exit 1; }
          if [[ -n ${STUB_QM_STATUS_SEQ:-} ]]; then read -ra q <<<"$STUB_QM_STATUS_SEQ"; n=$(nth status); ((n > ${#q[@]})) && n=${#q[@]}; echo "status: ${q[n-1]}"; exit 0; fi
          awk -v i="$2" '$1==i{print "status: "$2; f=1} END{exit !f}' "$V" ;;
  config) failfrom "${STUB_QM_CONFIG_FAIL_FROM:-}" config && { echo "stub qm: config failed" >&2; exit 1; }
          awk -v i="$2" '$1==i{print "name: vm"i; if($3==1)print "protection: 1"; f=1} END{exit !f}' "$V" ;;
  stop) [[ -n ${STUB_QM_STOP_RC:-} ]] && exit "$STUB_QM_STOP_RC"; [[ -n ${STUB_QM_STOP_FAIL:-} ]] && exit 0; sed -i "s/^\($2\) running/\1 stopped/" "$V" ;;
  set) [[ $* == *"--protection 0"* ]] && sed -i "s/^\($2 [a-z]*\) 1$/\1 0/" "$V" ;;
  destroy) [[ ${STUB_QM_DESTROY_FAIL:-} == 1 ]] && exit 5
           [[ -n ${STUB_QM_DESTROY_NOOP:-} ]] && exit 0
           grep -q "^$2 " "$V" || exit 2; [[ $(awk -v i="$2" '$1==i{print $3}' "$V") == 1 ]] && { echo "stub qm: VM is protected" >&2; exit 2; }
           sed -i "/^$2 /d" "$V"; [[ ${STUB_QM_DESTROY_FAIL:-} == late ]] && exit 5; exit 0 ;;
  *) echo "stub qm: refusing '$*'" >&2; exit 99 ;;
esac
S
cat > "$STUB/pvecm" <<'S'
#!/bin/bash
# stub pvecm: "status" fails (node is not in a cluster) unless STUB_PVECM_OK is set
[[ -n ${STUB_PVECM_OK:-} ]]
S
cat > "$STUB/dpkg-divert" <<'S'
#!/bin/bash
# stub dpkg-divert: one record "<path>|<diverted-to>" in $STUB_DIR/divert; calls logged
echo "dpkg-divert $*" >> "$STUB_DIR/divert.calls"
D="$STUB_DIR/divert"; args=("$@"); path="${args[-1]}"
if [[ $* == *--list* ]]; then [[ -f $D ]] && awk -F'|' -v p="$path" '$1==p{print "local diversion of "$1" to "$2}' "$D"; exit 0; fi
if [[ $* == *--remove* ]]; then
  [[ -n ${STUB_DIVERT_FAIL:-} ]] && { echo "dpkg-divert: error: stub failure" >&2; exit 2; }
  rm -f "$D"; exit 0
fi
echo "stub dpkg-divert: refusing '$*'" >&2; exit 99
S
cat > "$STUB/dpkg" <<'S'
#!/bin/bash
echo "dpkg $*" >> "$STUB_DIR/dpkg.calls"
case "${1:-}" in
  -S) if [[ -f $2 ]] && ! grep -q 'Generated by qemu-ad-pve' "$2" 2>/dev/null; then echo "pve-qemu-kvm: $2"; else echo "dpkg-query: no path found matching pattern $2" >&2; exit 1; fi ;;
  --audit) exit 0 ;;
  -l) echo "ii  pve-qemu-kvm 0.0-stub all stub"; exit 0 ;;
  *) echo "stub dpkg: refusing '$*'" >&2; exit 99 ;;
esac
S
cat > "$STUB/apt-get" <<'S'
#!/bin/bash
# stub apt-get: only `install --reinstall pve-qemu-kvm`; puts the vendor file where dpkg would
echo "apt-get $*" >> "$STUB_DIR/apt.calls"
[[ $* == *"--reinstall"*"pve-qemu-kvm"* ]] || { echo "stub apt-get: refusing '$*'" >&2; exit 99; }
[[ -n ${STUB_APT_FAIL:-} ]] && exit 100
if [[ -f $STUB_DIR/divert ]]; then cp "$STUB_VENDOR_SRC" "$(cut -d'|' -f2 "$STUB_DIR/divert")"; else cp "$STUB_VENDOR_SRC" "$STUB_WRAPPER"; fi
S
cat > "$STUB/hostname" <<'S'
#!/bin/bash
echo test-node
S
chmod +x "$STUB"/*
export STUB_DIR="$STUB"

# a vendor "binary": a real ELF (so `--version`-style runs work), made unique by an appended marker
VENDOR_SRC="$ROOT/vendor.bin"; { cat /usr/bin/true; printf 'VENDOR-FIXTURE'; } > "$VENDOR_SRC"; chmod +x "$VENDOR_SRC"
resolved=$(env -i PATH="$STUB:/usr/bin:/bin" bash -c 'command -v qm; command -v dpkg-divert; command -v apt-get; command -v pvecm; command -v hostname')
[[ $resolved == "$STUB/qm"$'\n'"$STUB/dpkg-divert"$'\n'"$STUB/apt-get"$'\n'"$STUB/pvecm"$'\n'"$STUB/hostname" ]] || { echo "ABORT: stubs do not resolve first on PATH ($resolved)"; exit 2; }

P_PREFIX="$SB/opt/qemu-ad"; P_SRC="$SB/opt/src"; P_LIST="$SB/etc/qemu-ad/vms"; P_KVM="$SB/usr/bin/kvm"; P_VEN="$SB/usr/bin/kvm.pve"
P_LOG="$SB/var/log/qemu-ad-wrapper.log"; P_LOCK="$SB/var/lib/dpkg/lock-frontend"; P_STATE="$SB/state"; P_PID="$SB/run/qemu-server"; P_CONF="$SB/etc/pve/qemu-server"

# fresh [vms...]: a host as qemu-ad-pve leaves it: wrapper at kvm, vendor at kvm.pve, divert recorded, prefix/sources/list/log present
fresh() {
  rm -rf "$SB"; mkdir -p "$SB/usr/bin" "$P_PREFIX/bin" "$P_SRC/qemu-10.2.2/sub" "$P_SRC/qemu-anti-detection" "$SB/etc/qemu-ad" "$SB/var/log" "$SB/var/lib/dpkg" "$P_PID" "$P_CONF"
  printf '#!/bin/bash\n# Generated by qemu-ad-pve.sh. Do not edit in place; re-run the installer.\nexit 0\n' > "$P_KVM"; chmod +x "$P_KVM"
  cp "$VENDOR_SRC" "$P_VEN"
  echo "$P_KVM|$P_VEN" > "$STUB/divert"
  echo bin > "$P_PREFIX/bin/qemu-system-x86_64"; echo tar > "$P_SRC/qemu-10.2.2.tar.xz"
  printf '7001\n7002\n' > "$P_LIST"; echo log > "$P_LOG"; echo log1 > "$P_LOG.1"; : > "$P_LOCK"
  : > "$STUB/qm.vms"; : > "$STUB/qm.calls"; : > "$STUB/divert.calls"; : > "$STUB/apt.calls"; : > "$STUB/dpkg.calls"
  for v in "$@"; do echo "$v" >> "$STUB/qm.vms"; done   # "<id> <status> <protection>"
}
snap() { (cd "$SB" && { find . -printf '%p %y %s %m %l\n' | sort; find . -type f -exec sha256sum {} + | sort; }) | sha256sum; }
no_mutating_calls() { ! grep -qE '^qm (destroy|stop|set)|--remove' "$STUB/qm.calls" "$STUB/divert.calls" && [[ ! -s $STUB/apt.calls ]]; }
is_vendor() { cmp -s "$P_KVM" "$VENDOR_SRC"; }

# stdin of the tool is never a terminal in these tests: empty, or an endless stream of "y" lines when BG_YES is set
stdin_src() { if [[ -n ${BG_YES:-} ]]; then yes; else :; fi; }
# bg [ENV=val ...] -- [args]: run the tool hermetically inside the sandbox; sets $rc and $out
bg() {
  local envs=()
  while [[ ${1:-} != -- && $# -gt 0 ]]; do envs+=("$1"); shift; done; shift
  out=$(stdin_src | env -i PATH="$STUB:/usr/bin:/bin" HOME="$ROOT/home" STUB_DIR="$STUB" STUB_WRAPPER="$P_KVM" STUB_VENDOR_SRC="$VENDOR_SRC" \
    QAD_BREAKGLASS_SANDBOX="$SB" PREFIX="$P_PREFIX" SRC_ROOT="$P_SRC" LIST_FILE="$P_LIST" WRAPPER_PATH="$P_KVM" VENDOR_PATH="$P_VEN" \
    LOG_FILE="$P_LOG" DPKG_LOCK="$P_LOCK" QAD_BREAKGLASS_STATE_DIR="$P_STATE" QAD_PID_DIR="$P_PID" PVE_QEMU_CONF_DIR="$P_CONF" \
    "${envs[@]}" bash "$BG" "$@" 2>&1); rc=$?
}
# raw [ENV=val ...] -- [args]: like bg but WITHOUT the sandbox variable and with default paths (refusal/dry-run tests only)
raw() {
  local envs=()
  while [[ ${1:-} != -- && $# -gt 0 ]]; do envs+=("$1"); shift; done; shift
  out=$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$ROOT/home" STUB_DIR="$STUB" "${envs[@]}" bash "$BG" "$@" 2>&1 </dev/null); rc=$?
}
backed_out() { is_vendor && [[ ! -e $P_VEN && ! -e $P_PREFIX && ! -e $P_SRC/qemu-10.2.2 && ! -e $P_SRC/qemu-10.2.2.tar.xz && ! -e $P_SRC/qemu-anti-detection && ! -e $P_LIST && ! -e $P_LOG && ! -e $P_LOG.1 && ! -s $STUB/divert ]]; }

# destroy-mode helpers: DE = the environment of a deliberate test-node run; tty "<text>" is what the "person" types
DE=(QAD_BREAKGLASS_TEST_HOSTNAME=test-node "QAD_BREAKGLASS_TTY=$SB/tty" QAD_BREAKGLASS_NONCE=0a1b2c3d)
tty() { printf '%s\n' "$1" > "$SB/tty"; }
phrase() { printf 'destroy %s on test-node 0a1b2c3d' "$1"; }
no_destroy_calls() { ! grep -qE '^qm (destroy|stop|set)' "$STUB/qm.calls"; }
kvm_untouched() { ! is_vendor && [[ -s $STUB/divert && -d $P_PREFIX ]]; }

echo "== dry run is the default"
fresh; s0=$(snap); bg --; r1=$rc
chk "no options: exit 0 and says DRY-RUN"                  '[[ $r1 -eq 0 && $out == *"DRY-RUN"* && $out == *"--apply"* ]]'
chk "  ... filesystem byte-identical (nothing created, incl. no state dir/log)" '[[ $(snap) == "$s0" && ! -e $P_STATE ]]'
chk "  ... no qm/dpkg-divert/apt mutation was invoked"      'no_mutating_calls'
chk "  ... report is labelled as CURRENT state"             '[[ $out == *"CURRENT state"* ]]'
fresh; s0=$(snap); bg -- --dry-run --keep-build; chk "explicit --dry-run behaves the same" '[[ $rc -eq 0 && $(snap) == "$s0" ]] && no_mutating_calls'
fresh; bg -- --apply --dry-run; chk "--apply with --dry-run: refused (exit 2)"  '[[ $rc -eq 2 && $out == *"mutually exclusive"* ]] && no_mutating_calls'
fresh; bg -- --bogus; chk "unknown option: exit 2"          '[[ $rc -eq 2 ]]'
bg -- --help; chk "--help documents --apply, dry-run default, VMIDS and PROTECTED" '[[ $rc -eq 0 && $out == *"DRY-RUN IS THE DEFAULT"* && $out == *"--apply"* && $out == *QAD_BREAKGLASS_VMIDS* && $out == *QAD_PROTECTED_VMIDS* && $out == *--destroy-vms* && $out == *--clear-vm-protection* && $out == *QAD_BREAKGLASS_TEST_HOSTNAME* && $out == *"typed confirmation"* ]]'
fresh "7001 running 0" "7002 running 0"; tty "x"; s0=$(snap)
bg "${DE[@]}" QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=7002 -- --destroy-vms
chk "dry run with --destroy-vms: prints the qm destroy it would run but runs none, no prompt" '[[ $rc -eq 0 && $out == *"DRY-RUN: qm destroy 7001"* && $out == *"would now ask for a typed confirmation"* ]] && ! grep -q "^qm destroy" "$STUB/qm.calls" && [[ $(snap) == "$s0" ]]'

echo "== --apply: full back-out"
fresh; bg -- --apply; r1=$rc
chk "apply: exit 0, RESULT: PASS"                          '[[ $r1 -eq 0 && $out == *"RESULT: PASS"* ]]'
chk "  ... real kvm back in place; kvm.pve, divert, prefix, sources, list, logs gone" 'backed_out'
chk "  ... the VMID list's now-empty directory was removed, but not its parents" '[[ ! -d $SB/etc/qemu-ad && -d $SB/etc ]]'
chk "  ... run log written in the state dir, mode 600"      '[[ -f $P_STATE/breakglass.log && $(stat -c %a "$P_STATE/breakglass.log") == 600 ]]'
chk "  ... no VM was touched (VMIDS empty => no qm destroy/stop/set)" '! grep -qE "^qm (destroy|stop|set)" "$STUB/qm.calls"'
s1=$(snap); : > "$STUB/divert.calls"; bg -- --apply; r2=$rc
chk "idempotent: second apply exit 0, PASS, state unchanged" '[[ $r2 -eq 0 && $out == *"RESULT: PASS"* ]] && is_vendor'
chk "  ... second run did not call dpkg-divert --remove or apt again" '! grep -q -- --remove "$STUB/divert.calls" && [[ ! -s $STUB/apt.calls ]]'
fresh; bg -- --apply --keep-build
chk "--keep-build: kvm restored, prefix and sources kept, PASS" '[[ $rc -eq 0 && $out == *"RESULT: PASS"* && -d $P_PREFIX && -d $P_SRC/qemu-10.2.2 ]] && is_vendor && [[ ! -e $P_LIST ]]'
fresh; echo "marker" > "$P_SRC/keep-me.txt"; mkdir -p "$SB/opt/other"; bg -- --apply
chk "only qemu-ad artifacts are removed: unrelated files in SRC_ROOT/opt survive" '[[ -f $P_SRC/keep-me.txt && -d $SB/opt/other && $rc -eq 0 ]]'
fresh; bg QEMU_VER=10.2.2 -- --apply; mkdir -p "$P_SRC/qemu-9.9.9"; bg -- --apply
chk "other QEMU_VER source trees are left alone"           '[[ -d $P_SRC/qemu-9.9.9 ]]'

echo "== kvm restore: failure and recovery paths"
fresh; rm -f "$P_VEN"; bg -- --apply
chk "divert recorded but vendor file missing: apt --reinstall pve-qemu-kvm restores it; PASS" '[[ $rc -eq 0 && $out == *"RESULT: PASS"* ]] && grep -q "install --reinstall -y.*pve-qemu-kvm" "$STUB/apt.calls" && backed_out'
fresh; rm -f "$P_VEN"; bg STUB_APT_FAIL=1 -- --apply
chk "vendor missing and apt fails: exit non-zero, wrapper path still not a vendor ELF" '[[ $rc -ne 0 && $out == *"ERROR"* && $out == *"RESULT: FAIL"* ]]'
chk "  ... step 3 skipped: side QEMU prefix, sources and list are left in place" '[[ -d $P_PREFIX && -d $P_SRC/qemu-10.2.2 && -f $P_LIST && $out == *"skipped"* ]]'
fresh; rm -f "$P_VEN"; cp "$VENDOR_SRC" "$SB/usr/bin/qemu-system-x86_64"; bg STUB_APT_FAIL=1 -- --apply
chk "last resort: symlink kvm -> packaged qemu-system-x86_64 when the package cannot be reinstalled" '[[ $rc -eq 0 && -L $P_KVM && $(readlink "$P_KVM") == qemu-system-x86_64 && $out == *"RESULT: PASS"* ]]'
fresh; bg STUB_DIVERT_FAIL=1 -- --apply
chk "dpkg-divert --remove fails: exit non-zero, wrapper and vendor file untouched, prefix kept" '[[ $rc -ne 0 && $out == *"nothing moved"* && -e $P_VEN ]] && cmp -s "$P_VEN" "$VENDOR_SRC" && ! is_vendor && [[ -d $P_PREFIX ]]'
fresh; echo "$P_KVM|$SB/usr/bin/other-tool" > "$STUB/divert"; rm -f "$P_KVM"; cp "$VENDOR_SRC" "$P_KVM"; bg -- --apply
chk "a divert that is not ours is left alone (record kept, no --remove) and reported as FAIL" '[[ $rc -ne 0 && $out == *"not ours"* && -s $STUB/divert ]] && ! grep -q -- --remove "$STUB/divert.calls"'
fresh; rm -f "$P_VEN"; rm -f "$STUB/divert"; bg --  --apply
chk "no divert, wrapper left behind and no vendor file: reinstall repairs it"  '[[ $rc -eq 0 ]] && is_vendor'
fresh; rm -f "$STUB/divert"; bg -- --apply
chk "no divert but wrapper + vendor copy: vendor moved back, no apt"  '[[ $rc -eq 0 && ! -s $STUB/apt.calls ]] && is_vendor && [[ ! -e $P_VEN ]]'
fresh; rm -f "$STUB/divert"; rm -f "$P_KVM"; cp "$VENDOR_SRC" "$P_KVM"; bg -- --apply
chk "already a vendor kvm plus an identical stale kvm.pve: stale copy removed" '[[ $rc -eq 0 && ! -e $P_VEN ]] && is_vendor'
fresh; rm -f "$STUB/divert"; rm -f "$P_KVM"; cp "$VENDOR_SRC" "$P_KVM"; echo different >> "$P_VEN"; bg -- --apply
chk "a differing kvm.pve is kept with a WARNING (and reported)" '[[ $out == *"differs"* && -e $P_VEN ]]'
fresh; touch "$P_KVM.qemu-ad-new" "$P_KVM.bg-new"; bg -- --apply
chk "staged leftovers kvm.qemu-ad-new / kvm.bg-new are removed" '[[ ! -e $P_KVM.qemu-ad-new && ! -e $P_KVM.bg-new && $rc -eq 0 ]]'
if command -v python3 >/dev/null 2>&1; then
  fresh; python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(8)' "$P_LOCK" & lp=$!
  sleep 1; s0=$(snap); bg -- --apply; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  chk "dpkg lock held: refuses to change kvm (exit non-zero), wrapper/divert/prefix untouched" '[[ $rc -ne 0 && $out == *"holds"* ]] && ! is_vendor && [[ -s $STUB/divert && -d $P_PREFIX ]]'
else echo "SKIP  dpkg-lock test (no python3)"; fi

echo "== path validation (all refuse with exit 2 before changing anything)"
refuse() {  # refuse <name> <pattern> <ENV=val ...>
  local name="$1" pat="$2"; shift 2; fresh; local s; s=$(snap); bg "$@" --
  chk "$name" '[[ $rc -eq 2 && $out == *"$pat"* ]] && [[ $(snap) == "$s" ]] && no_mutating_calls'
}
refuse "PREFIX outside the sandbox"                "outside QAD_BREAKGLASS_SANDBOX" PREFIX=/opt/qemu-ad
refuse "WRAPPER_PATH outside the sandbox"          "outside QAD_BREAKGLASS_SANDBOX" WRAPPER_PATH=/usr/bin/kvm VENDOR_PATH=/usr/bin/kvm.pve
refuse "LIST_FILE outside the sandbox"             "outside QAD_BREAKGLASS_SANDBOX" LIST_FILE=/etc/qemu-ad/vms
refuse "SRC_ROOT outside the sandbox"              "outside QAD_BREAKGLASS_SANDBOX" SRC_ROOT=/opt/src
refuse "STATE dir outside the sandbox"             "outside QAD_BREAKGLASS_SANDBOX" QAD_BREAKGLASS_STATE_DIR=/var/lib/qemu-ad-breakglass
refuse "relative PREFIX"                           "not an absolute path" PREFIX=opt/qemu-ad
refuse "PREFIX with .."                            "not a canonical path" "PREFIX=$SB/opt/../etc"
refuse "PREFIX with a trailing slash"              "not a canonical path" "PREFIX=$SB/opt/qemu-ad/"
refuse "PREFIX with whitespace"                    "not a canonical path" "PREFIX=$SB/opt/qemu ad"
refuse "WRAPPER_PATH == VENDOR_PATH"               "same path" "VENDOR_PATH=$P_KVM"
refuse "LIST_FILE is a directory"                  "is a directory" "LIST_FILE=$P_SRC"
refuse "sandbox dir does not exist"                "must be an existing directory" "QAD_BREAKGLASS_SANDBOX=$ROOT/nonexistent"
refuse "sandbox is /"                              "refusing" QAD_BREAKGLASS_SANDBOX=/
refuse "PREFIX equal to the sandbox itself"        "outside QAD_BREAKGLASS_SANDBOX" "PREFIX=$SB"
refuse "bad QEMU_VER"                              "QEMU_VER" "QEMU_VER=../x"
# without a sandbox: the --purge-style allow-lists (dry run, refused before any probe) and the root requirement
for pv in /usr/local/bin /etc /usr /opt /home/x; do
  raw "PREFIX=$pv" -- ; chk "no sandbox: PREFIX=$pv refused (exit 2)" '[[ $rc -eq 2 && $out == *"PREFIX"* ]]'
done
raw PREFIX=/opt/../etc -- ; chk "no sandbox: PREFIX with .. refused"                       '[[ $rc -eq 2 && $out == *"canonical"* ]]'
raw LIST_FILE=/etc/passwd -- ; chk "no sandbox: LIST_FILE outside /etc/qemu-ad,/var/lib/qemu-ad refused" '[[ $rc -eq 2 && $out == *"LIST_FILE"* ]]'
raw LIST_FILE=/etc/qemu-ad -- ; chk "no sandbox: LIST_FILE=/etc/qemu-ad (the directory itself) refused" '[[ $rc -eq 2 ]]'
raw SRC_ROOT=/usr -- ; chk "no sandbox: SRC_ROOT=/usr refused"                         '[[ $rc -eq 2 && $out == *"SRC_ROOT"* ]]'
if [[ $(id -u) -ne 0 ]]; then raw -- --apply; chk "no sandbox: --apply as non-root: refused (needs root)" '[[ $rc -eq 2 && $out == *"needs root"* ]]'; else echo "SKIP  needs-root check (running as root)"; fi

echo "== never write to a block device"
BLK=""; for d in /dev/loop0 /dev/sda /dev/vda /dev/nvme0n1 /dev/mapper/*; do [[ -b $d ]] && { BLK=$d; break; }; done
if [[ -n $BLK ]]; then
  raw "WRAPPER_PATH=$BLK" -- ; chk "no sandbox: WRAPPER_PATH is a block device: refused"  '[[ $rc -eq 2 && $out == *"block device"* ]]'
  raw "VENDOR_PATH=$BLK" -- ; chk "no sandbox: VENDOR_PATH is a block device: refused"   '[[ $rc -eq 2 && $out == *"block device"* ]]'
  raw "LOG_FILE=$BLK" -- ; chk "no sandbox: LOG_FILE is a block device: refused"         '[[ $rc -eq 2 && $out == *"block device"* ]]'
  fresh; rm -f "$P_VEN"; ln -s "$BLK" "$P_VEN"; s=$(snap); bg --
  chk "sandbox: VENDOR_PATH is a symlink to a block device: refused, nothing changed" '[[ $rc -eq 2 && $out == *"block device"* && $(snap) == "$s" ]]'
  fresh; ln -sf "$BLK" "$P_LIST"; s=$(snap); bg --
  chk "sandbox: LIST_FILE is a symlink to a block device: refused, nothing changed"   '[[ $rc -eq 2 && $out == *"block device"* && $(snap) == "$s" ]]'
else echo "SKIP  block-device tests (no block device node visible in /dev here)"; fi

echo "== VMIDs to destroy (opt-in) and the protected list"
refuse "VMIDS set, PROTECTED unset: refused"       "QAD_PROTECTED_VMIDS" QAD_BREAKGLASS_VMIDS=7001
refuse "VMIDS set, PROTECTED empty: refused"       "QAD_PROTECTED_VMIDS" QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=
refuse "VMIDS set, PROTECTED blanks: refused"      "QAD_PROTECTED_VMIDS" QAD_BREAKGLASS_VMIDS=7001 'QAD_PROTECTED_VMIDS=  '
refuse "VMID in both lists: refused"               "in both" QAD_BREAKGLASS_VMIDS=7001 'QAD_PROTECTED_VMIDS=7002 7001'
refuse "zero-padded VMIDS overlap (07001 vs 7001): refused"  "in both" QAD_BREAKGLASS_VMIDS=07001 QAD_PROTECTED_VMIDS=7001
refuse "zero-padded PROTECTED overlap (PROTECTED=07001, VMIDS=7001): refused" "in both" QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=07001
refuse "zero-padded PROTECTED in a list (VMIDS=7001, PROTECTED='7002 0007001'): refused" "in both" QAD_BREAKGLASS_VMIDS=7001 'QAD_PROTECTED_VMIDS=7002 0007001'
refuse "non-numeric VMIDS: refused"                "not a number" QAD_BREAKGLASS_VMIDS=7001\;touch QAD_PROTECTED_VMIDS=none
refuse "glob in VMIDS is not expanded or accepted" "not a number" 'QAD_BREAKGLASS_VMIDS=*' QAD_PROTECTED_VMIDS=none
refuse "glob in PROTECTED is not accepted"         "not a number" QAD_BREAKGLASS_VMIDS=7001 'QAD_PROTECTED_VMIDS=*'
refuse "non-numeric PROTECTED: refused"            "not a number" QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=abc
refuse "overlong VMID: refused"                    "not a number" QAD_BREAKGLASS_VMIDS=12345678901234567890 QAD_PROTECTED_VMIDS=none
fresh; bg QAD_PROTECTED_VMIDS=abc -- ; chk "non-numeric PROTECTED is refused even with no VMIDS" '[[ $rc -eq 2 ]]'
fresh; bg -- --apply; chk "VMIDS empty, PROTECTED unset: fine (no VM actions)" '[[ $rc -eq 0 ]]'

echo "== VM destruction: every gate must be passed (each refusal is exit 2 and changes nothing)"
gate_refuse() {  # gate_refuse <name> <pattern> <ENV...> -- <args>   (VMs 7001 running, 7002 running; 7001 is the target)
  local name=$1 pat=$2; shift 2
  fresh "7001 running 0" "7002 running 0"; tty "$(phrase 7001)"; local s; s=$(snap)
  bg "$@"
  chk "$name" '[[ $rc -eq 2 && $out == *"$pat"* ]] && [[ $(snap) == "$s" ]] && no_mutating_calls'
}
V1=(QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=7002)
gate_refuse "VMIDS in the environment alone (no --destroy-vms), --apply: refused" "--destroy-vms was not given" "${DE[@]}" "${V1[@]}" -- --apply
gate_refuse "VMIDS in the environment alone, dry run: refused too" "--destroy-vms was not given" "${DE[@]}" "${V1[@]}" --
gate_refuse "--destroy-vms with no VMIDS: refused" "QAD_BREAKGLASS_VMIDS is empty" "${DE[@]}" -- --apply --destroy-vms
gate_refuse "--clear-vm-protection without --destroy-vms: refused" "only makes sense together with --destroy-vms" "${DE[@]}" "${V1[@]}" -- --apply --clear-vm-protection
gate_refuse "no QAD_BREAKGLASS_TEST_HOSTNAME: refused" "QAD_BREAKGLASS_TEST_HOSTNAME is not set" "QAD_BREAKGLASS_TTY=$SB/tty" QAD_BREAKGLASS_NONCE=0a1b2c3d "${V1[@]}" -- --apply --destroy-vms
gate_refuse "empty QAD_BREAKGLASS_TEST_HOSTNAME: refused" "is not set" "QAD_BREAKGLASS_TEST_HOSTNAME=" "QAD_BREAKGLASS_TTY=$SB/tty" QAD_BREAKGLASS_NONCE=0a1b2c3d "${V1[@]}" -- --apply --destroy-vms
gate_refuse "test hostname does not match this node: refused" "not the declared test node" QAD_BREAKGLASS_TEST_HOSTNAME=other-node "QAD_BREAKGLASS_TTY=$SB/tty" QAD_BREAKGLASS_NONCE=0a1b2c3d "${V1[@]}" -- --apply --destroy-vms
gate_refuse "dry run also refuses a wrong test hostname" "not the declared test node" QAD_BREAKGLASS_TEST_HOSTNAME=other-node "${V1[@]}" -- --destroy-vms
gate_refuse "a VM on the node that is in neither list: refused" "neither" "${DE[@]}" QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=7003 -- --apply --destroy-vms
gate_refuse "qm list fails during the gate: refused" "qm list" "${DE[@]}" "${V1[@]}" STUB_QM_LIST_FAIL_FROM=1 -- --apply --destroy-vms
gate_refuse "node is in a cluster: refused" "cluster" "${DE[@]}" "${V1[@]}" STUB_PVECM_OK=1 -- --apply --destroy-vms
gate_refuse "typed confirmation: stdin is not a terminal (empty stdin / </dev/null): refused" "interactive terminal" QAD_BREAKGLASS_TEST_HOSTNAME=test-node "${V1[@]}" -- --apply --destroy-vms
BG_YES=1 gate_refuse "typed confirmation: stdin from \`yes\` cannot confirm: refused" "interactive terminal" QAD_BREAKGLASS_TEST_HOSTNAME=test-node "${V1[@]}" -- --apply --destroy-vms
gate_refuse "typed confirmation: wrong token: refused" "did not match" QAD_BREAKGLASS_TEST_HOSTNAME=test-node "QAD_BREAKGLASS_TTY=$SB/tty" QAD_BREAKGLASS_NONCE=ffffffff "${V1[@]}" -- --apply --destroy-vms
fresh "7001 running 0" "7002 running 0"; tty "yes"; s=$(snap); bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "typed confirmation: the answer \`yes\` is refused" '[[ $rc -eq 2 && $out == *"did not match"* && $(snap) == "$s" ]] && no_mutating_calls'
fresh "7001 running 0" "7002 running 0"; tty "$(phrase 7002)"; s=$(snap); bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "typed confirmation: the phrase for a different VM is refused" '[[ $rc -eq 2 && $out == *"did not match"* && $(snap) == "$s" ]] && no_mutating_calls'
fresh "7001 running 0" "7002 running 0"; : > "$SB/tty"; s=$(snap); bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "typed confirmation: an empty answer (EOF) is refused" '[[ $rc -eq 2 && $out == *"no typed confirmation"* && $(snap) == "$s" ]] && no_mutating_calls'
fresh "7001 running 0" "7002 running 0"; tty "$(phrase 7001) "; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "typed confirmation: the phrase with trailing junk is refused" '[[ $rc -eq 2 ]] && no_mutating_calls'
fresh "7001 running 0" "7002 running 0"; printf '%s\n' "$(phrase 7001)" > "$ROOT/outside-tty"; bg QAD_BREAKGLASS_TEST_HOSTNAME=test-node "QAD_BREAKGLASS_TTY=$ROOT/outside-tty" QAD_BREAKGLASS_NONCE=0a1b2c3d "${V1[@]}" -- --apply --destroy-vms
chk "the confirmation-file test hook must itself lie inside the sandbox" '[[ $rc -eq 2 && $out == *"outside QAD_BREAKGLASS_SANDBOX"* ]] && no_mutating_calls'
fresh "7001 running 0" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" QAD_BREAKGLASS_NONCE=NOTHEX "${V1[@]}" -- --apply --destroy-vms
chk "a malformed test nonce is refused" '[[ $rc -eq 2 ]] && no_mutating_calls'

echo "== VM destruction: the full, correctly confirmed path"
fresh "7001 running 0" "7002 running 0" "7003 stopped 0"
printf '7001\n7002\n7003\n' > "$P_LIST"; echo 4242 > "$P_PID/7002.pid"
bg -- --apply --capture-prestate; : > "$STUB/qm.calls"
tty "$(phrase 7001)"; bg "${DE[@]}" QAD_BREAKGLASS_VMIDS=07001 'QAD_PROTECTED_VMIDS=07002 7003' -- --apply --destroy-vms
chk "destroys only the listed VM: stop, destroy 7001; exit 0; PASS (zero-padded ids normalised)" '[[ $rc -eq 0 && $out == *"RESULT: PASS"* && $out == *"typed confirmation accepted"* ]] && grep -q "^qm stop 7001" "$STUB/qm.calls" && grep -q "^qm destroy 7001 " "$STUB/qm.calls"'
chk "  ... no --skiplock anywhere, and no qm set (the VM had no protection flag)" '! grep -q -- --skiplock "$STUB/qm.calls" && ! grep -q "^qm set" "$STUB/qm.calls"'
chk "  ... no qm stop/set/destroy was ever aimed at the protected VMs" '! grep -E "^qm (stop|set|destroy)" "$STUB/qm.calls" | grep -qE "700[23]"'
chk "  ... 7001 removed from the list (logged) before it was destroyed" '[[ $out == *"removed 7001 from"* ]]'
chk "  ... VM config saved first, mode 700 dir"            'ls "$P_STATE"/saved/7001-config-*.txt >/dev/null 2>&1 && [[ $(stat -c %a "$P_STATE/saved") == 700 ]]'
chk "  ... protected VMs still running/stopped as in the pre-state; PIDs compared" '[[ $out == *"same status as in the pre-state"* && $out == *"same PIDs"* && $out != *"FAIL"* ]] && grep -q "^7002 running" "$STUB/qm.vms" && grep -q "^7003 stopped" "$STUB/qm.vms"'
chk "  ... VM 7001 gone in the final report"               '[[ $out == *"VM 7001 gone"* ]] && ! grep -q "^7001 " "$STUB/qm.vms"'
chk "  ... the kvm back-out also happened" 'backed_out'
fresh "7001 stopped 0" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "an already stopped VM is destroyed without a qm stop" '[[ $rc -eq 0 ]] && ! grep -q "^qm stop" "$STUB/qm.calls" && grep -q "^qm destroy 7001" "$STUB/qm.calls"'
fresh "7001 running 0" "7002 running 0" "7003 stopped 0"; tty "$(phrase 7001,7003)"; bg "${DE[@]}" QAD_BREAKGLASS_VMIDS="7003 7001" QAD_PROTECTED_VMIDS=7002 -- --apply --destroy-vms
chk "two targets: the phrase lists both ids (sorted, comma separated); both destroyed" '[[ $rc -eq 0 ]] && ! grep -qE "^700[13] " "$STUB/qm.vms" && grep -q "^7002 running" "$STUB/qm.vms"'
fresh "7001 running 0" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms; : > "$STUB/qm.calls"
tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "idempotent: a second run (VM already gone) exits 0 and issues no destroy" '[[ $rc -eq 0 && $out == *"does not exist"* ]] && no_destroy_calls'

fresh "7001 running 0" "7002 running 0"; echo 4242 > "$P_PID/7002.pid"; bg -- --apply --capture-prestate; sed -i 's/^7002 running/7002 stopped/' "$STUB/qm.vms"
tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "the verifier FAILs (exit 1) if a protected VM's status differs from the pre-state" '[[ $rc -eq 1 && $out == *"FAIL  protected VMs have the same status"* ]]'
fresh "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" QAD_BREAKGLASS_VMIDS=7001 QAD_PROTECTED_VMIDS=7002 -- --apply --destroy-vms
chk "VMID that does not exist: nothing to do, back-out continues; exit 0" '[[ $rc -eq 0 && $out == *"does not exist"* ]] && ! grep -q "^qm destroy" "$STUB/qm.calls"'

echo "== PVE's own VM protection flag is a separate switch"
fresh "7001 running 1" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "protected-by-PVE target without --clear-vm-protection: not destroyed, exit 1, kvm untouched" '[[ $rc -eq 1 && $out == *"--clear-vm-protection"* && $out == *"stopping before touching the kvm wrapper"* ]] && ! grep -qE "^qm (set|destroy)" "$STUB/qm.calls" && kvm_untouched'
fresh "7001 running 1" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms --clear-vm-protection
chk "with --clear-vm-protection: qm set --protection 0 then destroy; exit 0" '[[ $rc -eq 0 ]] && grep -q "^qm set 7001 --protection 0" "$STUB/qm.calls" && grep -q "^qm destroy 7001 " "$STUB/qm.calls" && backed_out'
chk "  ... the protection flag of the other VM was never touched" '! grep -E "^qm set" "$STUB/qm.calls" | grep -q 7002'
fresh "7001 running 1" "7002 running 0"; tty "x"; s=$(snap); bg "${DE[@]}" "${V1[@]}" -- --destroy-vms --clear-vm-protection
chk "dry run with both flags: says it would clear protection and destroy; changes nothing" '[[ $rc -eq 0 && $out == *"DRY-RUN: qm set 7001 --protection 0"* && $out == *"DRY-RUN: qm destroy 7001"* && $(snap) == "$s" ]] && no_mutating_calls'
fresh "7001 running 1" "7002 running 0"; tty "x"; s=$(snap); bg "${DE[@]}" "${V1[@]}" -- --destroy-vms
chk "dry run without --clear-vm-protection: reports it would refuse (exit 1); changes nothing" '[[ $rc -eq 1 && $out == *"--clear-vm-protection"* && $(snap) == "$s" ]] && no_mutating_calls'

echo "== every qm failure fails closed (exit 1, no destroy, kvm wrapper untouched)"
qmfail() {  # qmfail <name> <pattern> <vm lines...> -- <ENV...>
  local name=$1 pat=$2; shift 2; local vms=()
  while [[ $1 != -- ]]; do vms+=("$1"); shift; done; shift
  fresh "${vms[@]}"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" QAD_BREAKGLASS_POLL_SECS=0 "$@" -- --apply --destroy-vms
  chk "$name" '[[ $rc -eq 1 && $out == *"$pat"* && $out == *"RESULT: FAIL"* ]] && ! grep -q "^qm destroy" "$STUB/qm.calls" && kvm_untouched'
}
qmfail "qm list fails after the gate: VM state unknown, not touched, verifier FAILs 'VM gone'" "cannot tell whether VM 7001 exists" "7001 running 0" "7002 running 0" -- STUB_QM_LIST_FAIL_FROM=2
chk "  ... and no stop/set was issued either, and the report does not claim the VM is gone" 'no_destroy_calls && [[ $out == *"FAIL  VM 7001 gone"* && $out != *"PASS  VM 7001 gone"* ]]'
qmfail "VM missing from qm list but qm config still works (inconsistent): treated as unknown, not as absent" "cannot tell whether VM 7001 exists" "7001 running 0" "7002 running 0" -- STUB_QM_LIST_HIDE=7001
qmfail "qm status fails: not stopped, not destroyed" "qm status 7001 failed" "7001 running 0" "7002 running 0" -- STUB_QM_STATUS_FAIL_FROM=1
chk "  ... a failing status probe never leads to qm stop/destroy" 'no_destroy_calls'
qmfail "qm config fails (save step): not destroyed" "qm config 7001 failed" "7001 running 0" "7002 running 0" -- STUB_QM_CONFIG_FAIL_FROM=1
chk "  ... a failing config probe is not read as 'VM absent' (verifier FAILs 'VM gone', no stop)" 'no_destroy_calls && [[ $out == *"FAIL  VM 7001 gone"* ]]'
qmfail "qm config fails when reading the protection flag: not destroyed" "cannot read the protection flag" "7001 stopped 0" "7002 running 0" -- STUB_QM_CONFIG_FAIL_FROM=2
qmfail "qm stop fails (rc != 0): not destroyed" "qm stop 7001 failed" "7001 running 0" "7002 running 0" -- STUB_QM_STOP_RC=3
qmfail "qm stop does nothing (VM stays running): not destroyed" "did not reach 'stopped'" "7001 running 0" "7002 running 0" -- STUB_QM_STOP_FAIL=1
qmfail "status flips back to running right before destroy: not destroyed" "not confirmed stopped right before destroy" "7001 running 0" "7002 running 0" -- "STUB_QM_STATUS_SEQ=running stopped running"
qmfail "status 'paused'/unknown after stop is not 'stopped': not destroyed" "did not reach 'stopped'" "7001 running 0" "7002 running 0" -- "STUB_QM_STATUS_SEQ=running paused"
fresh "7001 stopped 0" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" STUB_QM_DESTROY_FAIL=1 -- --apply --destroy-vms
chk "qm destroy fails: exit 1, 'qm destroy ... failed', verifier FAIL, kvm wrapper untouched" '[[ $rc -eq 1 && $out == *"qm destroy 7001 failed"* && $out == *"RESULT: FAIL"* && $out == *"FAIL  VM 7001 gone"* ]] && kvm_untouched'
fresh "7001 stopped 0" "7002 running 0"; tty "$(phrase 7001)"; mkdir -p "$P_STATE"; echo "not a dir" > "$P_STATE/saved"; bg "${DE[@]}" "${V1[@]}" -- --apply --destroy-vms
chk "the VM config cannot be saved (state dir not writable): not destroyed, exit 1" '[[ $rc -eq 1 && $out == *"cannot save the config of VM 7001"* ]] && ! grep -q "^qm destroy" "$STUB/qm.calls" && kvm_untouched'
fresh "7001 stopped 0" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" STUB_QM_DESTROY_FAIL=late -- --apply --destroy-vms
chk "qm destroy returns non-zero even though the VM vanished: still exit 1 (return code is checked)" '[[ $rc -eq 1 && $out == *"qm destroy 7001 failed"* ]] && kvm_untouched'
fresh "7001 stopped 0" "7002 running 0"; tty "$(phrase 7001)"; bg "${DE[@]}" "${V1[@]}" STUB_QM_DESTROY_NOOP=1 -- --apply --destroy-vms
chk "qm destroy claims success but the VM is still listed: exit 1 ('not confirmed gone')" '[[ $rc -eq 1 && $out == *"not confirmed gone"* ]] && kvm_untouched'
fresh "7001 running 0" "7002 running 0"; bg "${V1[@]}" STUB_QM_LIST_FAIL_FROM=1 -- --verify
chk "--verify with qm list failing: 'VM 7001 gone' is FAIL, not PASS" '[[ $rc -eq 1 && $out == *"FAIL  VM 7001 gone"* && $out != *"PASS  VM 7001 gone"* ]]'

echo "== pre-state capture and --verify"
fresh "7002 running 0"; echo 4242 > "$P_PID/7002.pid"; : > "$P_CONF/7002.conf"; s0=$(snap); bg -- --capture-prestate
chk "--capture-prestate without --apply: only says what it would do, writes nothing" '[[ $rc -eq 0 && $out == *"DRY-RUN"* && $(snap) == "$s0" ]]'
bg -- --apply --capture-prestate
chk "--capture-prestate --apply: pre-state dir (mode 700) with qm list, config, pids, divert, package info" '[[ $rc -eq 0 && $(stat -c %a "$P_STATE/pre-state") == 700 && -s $P_STATE/pre-state/qm-list.txt && -f $P_STATE/pre-state/qm-config-7002.txt && $(cat "$P_STATE/pre-state/pids.txt") == "7002 4242" && -s $P_STATE/pre-state/divert-kvm.txt && -s $P_STATE/pre-state/dpkg-l.txt ]]'
chk "  ... and it did not change kvm (capture only)"          '! is_vendor && [[ -s $STUB/divert ]] && no_mutating_calls'
echo marker > "$P_STATE/pre-state/captured-at.txt"; bg -- --apply --capture-prestate
chk "  ... a second capture refuses to overwrite"              '[[ $out == *"not overwriting"* && $(cat "$P_STATE/pre-state/captured-at.txt") == marker ]]'
bg -- --apply --capture-prestate --force-prestate; chk "  ... --force-prestate overwrites" '[[ $(cat "$P_STATE/pre-state/captured-at.txt") != marker ]]'
fresh; s0=$(snap); bg -- --verify
chk "--verify on an installed host: read-only, exit 1, FAIL lines"  '[[ $rc -eq 1 && $out == *"FAIL"* && $(snap) == "$s0" ]] && no_mutating_calls'
bg -- --apply; s1=$(snap); bg -- --verify
chk "--verify after back-out: read-only, exit 0, PASS"              '[[ $rc -eq 0 && $out == *"RESULT: PASS"* && $(snap) == "$s1" ]]'
bg -- --verify --apply; chk "--verify with --apply: refused"         '[[ $rc -eq 2 ]]'

echo "== pre-state capture must fail when qm fails; the comparison must not pass empty-vs-empty"
fresh "7002 running 0"; bg STUB_QM_LIST_FAIL_FROM=1 -- --apply --capture-prestate
chk "--capture-prestate with qm list failing: exit 1, no pre-state, no temp dir left" '[[ $rc -eq 1 && $out == *"qm list failed"* && ! -e $P_STATE/pre-state ]] && ! ls -A "$P_STATE" | grep -q "pre-state"'
fresh "7002 running 0" "7003 running 0"; bg STUB_QM_CONFIG_FAIL_FROM=2 -- --apply --capture-prestate
chk "--capture-prestate with one qm config failing: exit 1, nothing half-written" '[[ $rc -eq 1 && $out == *"qm config 7003 failed"* ]] && ! ls -A "$P_STATE" | grep -q "pre-state"'
fresh "7002 running 0"; PATH_NOQM=$(PATH=/usr/bin:/bin command -v qm || true)
if [[ -z $PATH_NOQM ]]; then bg PATH=/usr/bin:/bin -- --apply --capture-prestate; chk "--capture-prestate without qm: exit 1, no pre-state" '[[ $rc -eq 1 && $out == *"qm not found"* && ! -e $P_STATE/pre-state ]]'; else echo "SKIP  no-qm capture test (a real qm is on /usr/bin:/bin)"; fi
fresh "7002 running 0"; bg -- --apply --capture-prestate; echo marker > "$P_STATE/pre-state/captured-at.txt"; bg STUB_QM_LIST_FAIL_FROM=1 -- --apply --capture-prestate --force-prestate
chk "a failed --force-prestate keeps the previous good pre-state" '[[ $rc -eq 1 && $(cat "$P_STATE/pre-state/captured-at.txt") == marker ]]'
fresh "7002 running 0"; bg -- --apply --capture-prestate; bg QAD_PROTECTED_VMIDS=7002 STUB_QM_LIST_FAIL_FROM=1 -- --verify
chk "--verify: qm list failing now => the protected-status comparison FAILs (never passes empty vs empty)" '[[ $rc -eq 1 && $out == *"FAIL  protected VMs have the same status"* ]]'
fresh "7002 running 0"; bg -- --apply --capture-prestate; bg QAD_PROTECTED_VMIDS=7009 STUB_QM_LIST_FAIL_FROM=1 -- --verify
chk "--verify: qm list failing now with a protected VMID absent from the pre-state (empty vs empty) still FAILs" '[[ $rc -eq 1 && $out == *"FAIL  protected VMs have the same status"* && $out == *"qm list failed now"* ]]'
fresh "7002 running 0"; bg -- --apply --capture-prestate; : > "$P_STATE/pre-state/qm-list.txt"; bg QAD_PROTECTED_VMIDS=7009 -- --verify
chk "--verify: an empty pre-state qm list with a protected VMID absent from it (empty vs empty) still FAILs" '[[ $rc -eq 1 && $out == *"missing or invalid"* ]]'
fresh "7002 running 0"; bg -- --apply --capture-prestate; : > "$P_STATE/pre-state/qm-list.txt"; bg QAD_PROTECTED_VMIDS=7002 -- --verify
chk "--verify: an empty/invalid pre-state qm list => the comparison FAILs" '[[ $rc -eq 1 && $out == *"FAIL  protected VMs have the same status"* && $out == *"missing or invalid"* ]]'
fresh "7002 running 0"; bg -- --apply --capture-prestate; rm -f "$P_STATE/pre-state/pids.txt"; bg QAD_PROTECTED_VMIDS=7002 -- --verify
chk "--verify: a missing pre-state pids.txt => the PID comparison FAILs" '[[ $rc -eq 1 && $out == *"FAIL  protected VMs have the same PIDs"* ]]'
fresh "7002 running 0"; bg -- --apply --capture-prestate; bg QAD_PROTECTED_VMIDS=07002 -- --verify
chk "--verify: PROTECTED=07002 is normalised and compared as 7002 (status line is PASS)" '[[ $out == *"PASS  protected VMs have the same status"* ]]'

echo "== devices, symlinks, containment, glob handling"
raw WRAPPER_PATH=/dev/null -- ;            chk "no sandbox: WRAPPER_PATH is a character device: refused"  '[[ $rc -eq 2 && $out == *"character device"* ]]'
raw VENDOR_PATH=/dev/zero -- ;             chk "no sandbox: VENDOR_PATH is a character device: refused"   '[[ $rc -eq 2 && $out == *"character device"* ]]'
raw LOG_FILE=/dev/null -- ;                chk "no sandbox: LOG_FILE is a character device: refused"      '[[ $rc -eq 2 && $out == *"character device"* ]]'
raw LOG_FILE=/dev/shm/anything -- ;        chk "no sandbox: LOG_FILE below /dev refused (any /dev subtree)" '[[ $rc -eq 2 && $out == *"/dev"* ]]'
raw LIST_FILE=/proc/self/environ -- ;      chk "no sandbox: a path below /proc refused"                   '[[ $rc -eq 2 ]]'
fresh; rm -f "$P_VEN"; ln -s /dev/null "$P_VEN"; s=$(snap); bg --
chk "sandbox: VENDOR_PATH symlink to a character device: refused, nothing changed" '[[ $rc -eq 2 && $out == *"character device"* && $(snap) == "$s" ]]'
fresh; ln -sf /dev/null "$P_LIST"; s=$(snap); bg --
chk "sandbox: LIST_FILE symlink to a character device: refused, nothing changed"   '[[ $rc -eq 2 && $out == *"character device"* && $(snap) == "$s" ]]'
fresh; mkfifo "$SB/fifo"; s=$(snap); bg "LOG_FILE=$SB/fifo" --
chk "a fifo as LOG_FILE is refused"                                                '[[ $rc -eq 2 && $out == *"fifo"* && $(snap) == "$s" ]]'
mkdir -p "$ROOT/outside/victim"; echo precious > "$ROOT/outside/victim/f"
fresh; rm -rf "$P_PREFIX"; ln -s "$ROOT/outside" "$P_PREFIX"; s=$(snap); bg -- --apply
chk "sandbox escape: PREFIX is a symlink to a directory outside the sandbox: refused, outside tree intact" '[[ $rc -eq 2 && $out == *"resolves to"* && $(snap) == "$s" && -f $ROOT/outside/victim/f ]]'
fresh; ln -s "$ROOT/outside" "$SB/opt/escape"; s=$(snap); bg "SRC_ROOT=$SB/opt/escape" -- --apply
chk "sandbox escape: SRC_ROOT is a symlink out of the sandbox: refused, outside tree intact" '[[ $rc -eq 2 && $out == *"outside QAD_BREAKGLASS_SANDBOX"* && -f $ROOT/outside/victim/f ]]'
fresh; ln -s "$ROOT/outside" "$SB/state"; s=$(snap); bg -- --apply
chk "sandbox escape: the state dir is a symlink out of the sandbox: refused"  '[[ $rc -eq 2 && $out == *"outside QAD_BREAKGLASS_SANDBOX"* && ! -e $ROOT/outside/breakglass.log ]]'
refuse "PREFIX containing WRAPPER_PATH (rm -rf would delete the restored kvm)" "lies inside PREFIX" "PREFIX=$SB/usr"
refuse "PREFIX containing the state dir"           "lies inside PREFIX" "QAD_BREAKGLASS_STATE_DIR=$P_PREFIX/state"
refuse "PREFIX containing LIST_FILE"               "lies inside PREFIX" "LIST_FILE=$P_PREFIX/vms"
refuse "SRC_ROOT inside PREFIX"                    "inside PREFIX" "SRC_ROOT=$P_PREFIX/src"
refuse "PREFIX inside SRC_ROOT"                    "inside (or equal to) SRC_ROOT" "PREFIX=$P_SRC/prefix"
refuse "PREFIX equal to SRC_ROOT"                  "inside (or equal to) SRC_ROOT" "PREFIX=$P_SRC"
refuse "LOG_FILE inside SRC_ROOT"                  "inside SRC_ROOT" "LOG_FILE=$P_SRC/log"
refuse "glob characters in a path are refused"     "not a canonical path" "PREFIX=$SB/opt/qemu*"
refuse "shell metacharacters in a path are refused" 'not a canonical path' 'PREFIX='"$SB"'/opt/a$(id)'
refuse "a newline in a path is refused"            'not a canonical path' "PREFIX=$SB/opt/a"$'\n'"b"
# a lookalike prefix with no qemu-ad content is never deleted; an empty one and a real one are
fresh; rm -rf "$P_PREFIX"; mkdir -p "$P_PREFIX/other"; echo data > "$P_PREFIX/other/file"; bg -- --apply
chk "PREFIX that does not look like ours: NOT deleted, exit 1, kvm back-out still done" '[[ $rc -eq 1 && -f $P_PREFIX/other/file && $out == *"does not look like a qemu-ad prefix"* ]] && is_vendor'
fresh; rm -rf "$P_PREFIX"; mkdir -p "$P_PREFIX"; bg -- --apply
chk "an empty PREFIX directory is removed"      '[[ $rc -eq 0 && ! -e $P_PREFIX ]]'
fresh; rm -rf "$P_PREFIX"; mkdir -p "$P_PREFIX"; : > "$P_PREFIX/.qemu-ad-configure-flags"; bg -- --apply
chk "a PREFIX with only the build stamp is removed" '[[ $rc -eq 0 && ! -e $P_PREFIX ]]'
# .extract.* scratch dirs are looked up in SRC_ROOT, not in the current directory
fresh; mkdir -p "$P_SRC/.extract.AbC123/x"; DECOY=$(mktemp -d "$ROOT/cwd.XXXXXX"); mkdir "$DECOY/.extract.decoy"
pushd "$DECOY" >/dev/null || exit; bg -- --apply; rc2=$rc; popd >/dev/null || exit
chk "SRC_ROOT/.extract.* leftovers are removed (glob anchored in SRC_ROOT)" '[[ $rc2 -eq 0 && ! -e $P_SRC/.extract.AbC123 ]]'
chk "  ... and a .extract.* directory in the current directory is not touched" '[[ -d $DECOY/.extract.decoy ]]'
# set -f: a file named like a VMID glob in the cwd must not change how the lists are read
fresh "7001 running 0" "7002 running 0"; tty "$(phrase 7001)"; touch "$DECOY/7001" "$DECOY/7002"; pushd "$DECOY" >/dev/null || exit
bg "${DE[@]}" 'QAD_BREAKGLASS_VMIDS=7*' QAD_PROTECTED_VMIDS=7002 -- --apply --destroy-vms; popd >/dev/null || exit
chk "a glob in VMIDS with matching files in the cwd is still refused (not expanded)" '[[ $rc -eq 2 && $out == *"not a number"* ]]'

echo "== hermetic"
[[ $(real_kvm_sig) == "$SIG0" ]] && ok "the real /usr/bin/kvm(.pve) were not touched" || bad "real kvm signature changed!"
[[ -z $(ls -A "$ROOT/home") ]] && ok "no files were created in the (fake) HOME" || bad "HOME was written to"

echo "BREAKGLASS TEST: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
