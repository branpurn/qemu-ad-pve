#!/bin/bash
# Tier-2 runner for qemu-ad-pve on a THROWAWAY nested PVE node.
#   !! NEVER RUN THIS ON A PRODUCTION HOST. It installs a QEMU build, diverts /usr/bin/kvm, creates and destroys
#   !! VMs 9001-9003, and runs a real purge. Read tests/README.md first.
# Spec: tests/HARNESS-SPEC.md (P0-P8, safety S1-S4). Outer-host snapshot/rollback is done by whoever
# owns the outer host (see "OUTER HOST" below); this script never touches the outer host.
#
# Usage (as root on the test node):
#   TEST_HOSTNAME=<node> REF=<full 40-hex commit sha> ./tier2.sh all     # full ordered run
#   TEST_HOSTNAME=<node> ./tier2.sh gate|setup|p0|p3|p3b|p4|p6|p8|p1|p2|p7|p5|teardown|table
# Env: TEST_HOSTNAME (required, must equal `hostname`), REF (default: pinned MAIN_SHA below; set it to the commit under test), ISO (default local:iso/alpine-virt.iso),
#      BRIDGE (default vmbr0), OUT (default /root/qad-t2), REPO (default https://github.com/branpurn/qemu-ad-pve),
#      PROTECTED_VMIDS (extra VMIDs to protect, added to the built-in 110 115 200 245: the gate aborts if any exists), SKIP_T1, P0_VERIFY_ONLY
#
# OUTER HOST (before/after, by the person with outer access):
#   qm shutdown <outer_vmid>; qm snapshot <outer_vmid> pre-qemu-ad ; qm start <outer_vmid>   # cold snapshot
#   ... run ...
#   qm stop <outer_vmid>; qm rollback <outer_vmid> pre-qemu-ad; qm start <outer_vmid>
set -uo pipefail
: "${TEST_HOSTNAME:?set TEST_HOSTNAME to the throwaway node hostname}"
# Default REF: FULL SHA of main after PR #3 merged (1cc3181; last commit this runner was validated against).
# Pass REF=<full 40-hex sha> to test something else: setup verifies HEAD == REF when REF is 40 chars.
MAIN_SHA=1cc31815d374fe800fc6dd462aae9963d83d5a68
REF="${REF:-$MAIN_SHA}"; REPO="${REPO:-https://github.com/branpurn/qemu-ad-pve}"
ISO="${ISO:-local:iso/alpine-virt.iso}"; BRIDGE="${BRIDGE:-vmbr0}"
OUT="${OUT:-/root/qad-t2}"; ADPS=/root/qemu-ad-pve/qemu-ad-pve.sh; ADP="bash /root/qemu-ad-pve/qemu-ad-pve.sh"; ADPF=/root/qemu-ad-pve/qemu-ad-pve.sh
SIDE=/opt/qemu-ad/bin/qemu-system-x86_64; WATCHLOG=/root/kvm-watch.log
mkdir -p "$OUT"; RES="$OUT/results.tsv"; touch "$RES"

log()  { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$OUT/run.log"; }
# rec <ID> <PASS|FAIL|INFO|SKIP> <evidence> <notes>
rec()  { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RES"; log "RESULT $1 $2 - $4"; }
# t <ID> <description> <condition-cmd...>: sub-check; sets CASE_FAIL on failure
t()    { local d="$1"; shift; if "$@"; then log "  ok   $d"; else log "  FAIL $d"; CASE_FAIL=1; fi; }
verdict() { if [[ ${CASE_FAIL:-0} -eq 0 ]]; then rec "$1" PASS "$2" "$3"; else rec "$1" FAIL "$2" "$3"; fi; CASE_FAIL=0; }
watch_clean() { [[ ! -s $WATCHLOG ]]; }
# NOTE: this qm has no "qm stop --skiboot"; plain qm stop (Alpine ISO ignores ACPI so no shutdown).
guests_down() { for v in 9001 9002 9003; do qm stop "$v" >/dev/null 2>&1 || true; done; }
pidexe() { readlink "/proc/$(cat "/var/run/qemu-server/$1.pid" 2>/dev/null)/exe" 2>/dev/null; }
live_argv() { tr '\0' '\n' < "/proc/$(cat "/var/run/qemu-server/$1.pid")/cmdline"; }
argv0() { tr '\0' '\n' < "/proc/$(cat "/var/run/qemu-server/$1.pid" 2>/dev/null)/cmdline" 2>/dev/null | head -1; }
# start, wait, and assert: qm status == running AND argv[0] == /usr/bin/kvm (exec -a)
start_wait() { qm start "$1" >>"$OUT/qm.log" 2>&1 && sleep 5 && [[ $(qm status "$1") == *running* ]] && [[ $(argv0 "$1") == /usr/bin/kvm ]]; }
# info <ID> <text>: INFO is recorded but NEVER counts as a pass (verdict ignores it)
info() { printf '%s\tINFO\t-\t%s\n' "$1" "$2" >> "$RES"; log "  INFO $1: $2"; }
export -f pidexe live_argv start_wait argv0

# ---------------- S2 safety gate (ABORT on any failure) ----------------
gate() {
  [[ $(hostname) == "$TEST_HOSTNAME" ]] || { echo "ABORT: wrong host"; exit 99; }
  command -v qm >/dev/null || { echo "ABORT: not a PVE node"; exit 99; }
  # built-in protected VMIDs ALWAYS apply; PROTECTED_VMIDS (space-separated) can only ADD to them, never remove
  local pv="110 115 200 245 ${PROTECTED_VMIDS:-}" v
  for v in $pv; do
    if qm list | awk 'NR>1{print $1}' | grep -Fxq -- "$v"; then echo "ABORT: protected VMID $v present"; exit 99; fi
  done
  if pvecm status >/dev/null 2>&1; then echo "ABORT: node is in a cluster"; exit 99; fi
  [[ -e /dev/kvm ]] || { echo "ABORT: no /dev/kvm (nested virt off)"; exit 99; }
  log "gate ok on $(hostname)"
}

# ---------------- S1 check, S3 baseline, S4 watcher, tier 1 ----------------
setup() {
  gate
  log "S3 baseline"
  { date -Is; pveversion -v; echo; dpkg-divert --list /usr/bin/kvm; readlink -f /usr/bin/kvm; sha256sum "$(readlink -f /usr/bin/kvm)"; dpkg -S /usr/bin/kvm; } > "$OUT/baseline.txt" 2>&1
  pveversion -v > /root/pveversion.before 2>&1
  [[ -z $(dpkg-divert --list /usr/bin/kvm) ]] || { echo "ABORT: divert already present; roll back to pre-qemu-ad first"; exit 99; }
  apt-get install -y git socat strace >>"$OUT/apt.log" 2>&1 || log "warn: tool install failed"
  rm -rf /root/qemu-ad-pve; git clone -q "$REPO" /root/qemu-ad-pve && git -C /root/qemu-ad-pve checkout -q "$REF" || { echo "ABORT: cannot fetch $REF"; exit 98; }
  [[ ${#REF} -ne 40 || $(git -C /root/qemu-ad-pve rev-parse HEAD) == "$REF" ]] || { echo "ABORT: HEAD != pinned REF"; exit 98; }
  { date -Is; echo "REF=$REF commit=$(git -C /root/qemu-ad-pve rev-parse HEAD)"; echo "sha256 $(sha256sum $ADPF)"; } | tee "$OUT/ref.txt"
  # tier 1 must pass on the exact commit
  if [[ -n ${SKIP_T1:-} ]]; then rec T1 SKIP none "skipped: SKIP_T1 set (REF=$REF)"; else
  if [[ -x /root/qemu-ad-pve/tests/tier1.sh ]]; then T1=/root/qemu-ad-pve/tests/tier1.sh; else T1=/root/qemu-ad-pve-tier1.sh; fi
  [[ -x $T1 ]] || { echo "ABORT: tier1.sh missing (copy qemu-ad-pve-tier1.sh to /root)"; exit 98; }
  bash "$T1" $ADPF > "$OUT/tier1.out" 2>&1; local rc=$?
  rec T1 "$([[ $rc -eq 0 ]] && echo PASS || echo FAIL)" tier1.out "$(tail -1 "$OUT/tier1.out")"
  [[ $rc -eq 0 ]] || { echo "ABORT: tier 1 failed"; exit 97; }
  fi
  # S4 watcher
  : > $WATCHLOG
  ( while :; do [[ -x /usr/bin/kvm ]] || echo "MISSING $(date -Is)" >> $WATCHLOG; sleep 0.05; done ) &
  echo $! > /root/kvm-watch.pid; log "watcher pid $(cat /root/kvm-watch.pid)"
  # test guests (spec 3.3)
  pvesm status >/dev/null 2>&1; qm list >/dev/null
  pvesm list local 2>/dev/null | grep -q "${ISO#*:}" || log "warn: ISO ${ISO} not found in local storage; guests will not boot (upload an Alpine virt ISO)"
  for spec in "9001 qad-listed pc-q35-10.1" "9002 qad-unlisted pc-q35-10.1" "9003 qad-unversioned q35"; do
    set -- $spec
    qm status "$1" >/dev/null 2>&1 && qm destroy "$1" --purge >/dev/null 2>&1
    qm create "$1" --name "$2" --memory 512 --cores 1 --machine "$3" --cpu host --ostype l26 --serial0 socket --vga serial0 --cdrom "$ISO" --net0 "virtio,bridge=$BRIDGE" --onboot 0 >>"$OUT/qm.log" 2>&1 || log "warn: qm create $1 failed"
  done
  qm showcmd 9001 --pretty > /root/showcmd.9001.before 2>&1
}

# ---------------- P0 ----------------
p0() {
  gate; CASE_FAIL=0
  # PR3: install builds with --enable-libiscsi. P0_VERIFY_ONLY=1 re-checks an existing install.log instead of rebuilding.
  local rc
  if [[ -n ${P0_VERIFY_ONLY:-} ]]; then grep -q '^INSTALL_RC=0' "$OUT/install.log"; rc=$?; else
  ( time $ADP install; echo "INSTALL_RC=$?" ) > "$OUT/install.log" 2>&1; grep -q '^INSTALL_RC=0' "$OUT/install.log"; rc=$?; fi
  t "install rc=0 (INSTALL_RC from the script itself)" [ $rc -eq 0 ]
  t "second install idempotent rc=0" bash -c "bash $ADPS install >'$OUT/install.second.log' 2>&1"
  t "side binary links libiscsi" bash -c "ldd $SIDE | grep -q libiscsi"
  t "libiscsi-dev installed" bash -c "dpkg -s libiscsi-dev >/dev/null 2>&1"
  t "kvm.pve present, divert in place" bash -c "[[ -e /usr/bin/kvm.pve ]] && dpkg-divert --list /usr/bin/kvm | grep -q kvm.pve"
  $ADP add-vm 9001 >>"$OUT/install.log" 2>&1; $ADP add-vm 9003 >>"$OUT/install.log" 2>&1
  $ADP status > "$OUT/status.p0.txt" 2>&1
  t "side binary reports 10.2.2" bash -c "$SIDE --version | grep -q 'version 10.2.2'"
  t "/usr/bin/kvm is wrapper" grep -q 'Generated by qemu-ad-pve' /usr/bin/kvm
  t "kvm.pve is vendor (resolves to a real qemu)" bash -c "[[ -x \$(readlink -f /usr/bin/kvm.pve) ]] && ! grep -q 'Generated by qemu-ad-pve' /usr/bin/kvm.pve"
  t "list has 9001 and 9003" bash -c "grep -qx 9001 /etc/qemu-ad/vms && grep -qx 9003 /etc/qemu-ad/vms"
  t "libaio+liburing pkgs installed" bash -c "dpkg -s libaio-dev liburing-dev >/dev/null 2>&1"
  ldd $SIDE > "$OUT/ldd.side.txt" 2>&1; t "watcher log empty (P0)" watch_clean; t "side binary links liburing and libaio" bash -c "grep -q uring '$OUT/ldd.side.txt' && grep -q libaio '$OUT/ldd.side.txt'"
  grep -E 'SHA-256 ok|no pinned' "$OUT/install.log" > "$OUT/pins.txt" 2>&1; log "pins: $(tr '\n' ' ' < "$OUT/pins.txt")"
  verdict P0 install.log "build: $(grep -E '^real' "$OUT/install.log" | tr '\t' ' '); pins: $(grep -c 'SHA-256 ok' "$OUT/install.log") verified"
}

# ---------------- P3 ----------------
p3() {
  gate; CASE_FAIL=0; guests_down
  local emits=N; qm showcmd 9001 | tr ' ' '\n' | grep -qx -- -id && emits=Y
  log "P3 step0: qm showcmd emits -id: $emits"
  t "9001 starts" start_wait 9001
  t "9001 exe is side" [ "$(pidexe 9001)" = $SIDE ]
  live_argv 9001 > "$OUT/p3.9001.argv" 2>&1
  t "9001 argv has no -id" bash -c "! grep -qx -- -id '$OUT/p3.9001.argv'"
  t "wrapper log has vmid=9001" grep -q 'vmid=9001' /var/log/qemu-ad-wrapper.log
  t "9001 argv0 == /usr/bin/kvm" [ "$(argv0 9001)" = /usr/bin/kvm ]
  t "9001 argv has -iscsi (PVE-generated line kept)" grep -qx -- -iscsi "$OUT/p3.9001.argv"
  t "9001 machine type has no +pve" bash -c "! grep -q '+pve' <(grep -A1 -x -- -machine '$OUT/p3.9001.argv')"
  t "9001 qm status running" bash -c "[[ \$(qm status 9001) == *running* ]]"
  sleep 12; t "pvestatd/pvesh sees 9001 running with pid" bash -c "pvesh get /nodes/$TEST_HOSTNAME/qemu/9001/status/current --output-format json | grep -q '\"status\":\"running\"'"
  t "9002 starts" start_wait 9002
  live_argv 9002 > "$OUT/p3.9002.argv" 2>&1
  t "9002 exe is vendor" bash -c "[[ \$(pidexe 9002) != '$SIDE' && -n \$(pidexe 9002) ]]"
  [[ $emits == Y ]] && t "9002 argv keeps -id 9002" bash -c "grep -qx -- -id '$OUT/p3.9002.argv' && grep -qx 9002 '$OUT/p3.9002.argv'"
  t "wrapper log has no 9002" bash -c "! grep -q 'vmid=9002' /var/log/qemu-ad-wrapper.log"
  t "9002 argv0 == /usr/bin/kvm" [ "$(argv0 9002)" = /usr/bin/kvm ]
  sleep 12; t "pvestatd/pvesh sees 9002 running" bash -c "pvesh get /nodes/$TEST_HOSTNAME/qemu/9002/status/current --output-format json | grep -q '\"status\":\"running\"'"
  t "qm stop 9001 works under exec -a" bash -c "qm stop 9001 && [[ \$(qm status 9001) == *stopped* ]]"
  t "qm stop 9002 works under exec -a" bash -c "qm stop 9002 && [[ \$(qm status 9002) == *stopped* ]]"
  guests_down
  verdict P3 "p3.*.argv" "qm showcmd emits -id: $emits"
}

# ---------------- P4 ----------------
p4() {
  gate; CASE_FAIL=0; guests_down
  qm showcmd 9002 --pretty | sed 's/ \\$//' > "$OUT/p4.vendor.txt"
  t "9002 starts" start_wait 9002
  live_argv 9002 > "$OUT/p4.live.txt"
  t "exe is vendor" bash -c "[[ \$(pidexe 9002) != '$SIDE' ]]"
  # every token of the live argv (minus pid-ish) should appear in showcmd output
  local miss=0; while IFS= read -r tok; do [[ -z $tok ]] && continue; grep -qF -- "$tok" "$OUT/p4.vendor.txt" || { miss=$((miss+1)); echo "not in showcmd: $tok" >> "$OUT/p4.diff.txt"; }; done < "$OUT/p4.live.txt"
  t "live argv tokens all present in showcmd (missing=$miss)" [ $miss -eq 0 ]
  # strict: parse showcmd with shlex and compare token-for-token with the live argv (argv[0] included)
  qm showcmd 9002 --pretty | python3 -c 'import shlex,sys;print("\n".join(shlex.split(sys.stdin.read().replace("\\\n"," "))))' > "$OUT/p4.showcmd.tok" 2>&1
  t "STRICT: showcmd tokens == live argv (diff empty)" diff "$OUT/p4.showcmd.tok" "$OUT/p4.live.txt"
  # (d) vendor data-dir lookup unaffected by exec -a
  bash -c 'exec -a /usr/bin/kvm /usr/bin/qemu-system-x86_64 -L help' > "$OUT/p4.datadir.exec-a.txt" 2>&1
  /usr/bin/qemu-system-x86_64 -L help > "$OUT/p4.datadir.plain.txt" 2>&1
  t "(d) vendor -L help identical with/without exec -a" diff "$OUT/p4.datadir.exec-a.txt" "$OUT/p4.datadir.plain.txt"
  t "(d) vendor -L help non-empty" test -s "$OUT/p4.datadir.exec-a.txt"
  guests_down
  # qm rejects "+" in VM names (invalid DNS name), so carry +pve5 in a second arg instead
  qm set 9002 --args '-smbios type=1,product=x+pve1 -fw_cfg name=opt/qad+pve5,string=x' >/dev/null
  t "9002 starts with +pve strings" start_wait 9002
  live_argv 9002 > "$OUT/p4.live2.txt"
  t "product=x+pve1 reaches argv" grep -q 'product=x+pve1' "$OUT/p4.live2.txt"
  t "fw_cfg opt/qad+pve5 reaches argv" grep -q 'name=opt/qad+pve5,string=x' "$OUT/p4.live2.txt"
  guests_down
  qm set 9002 --delete args >/dev/null
  # list file removed / empty -> unlisted guest still starts via vendor
  mv /etc/qemu-ad/vms /root/vms.keep; t "9002 starts with list file absent" start_wait 9002; guests_down
  : > /etc/qemu-ad/vms; t "9002 starts with empty list" start_wait 9002; guests_down
  mv -f /root/vms.keep /etc/qemu-ad/vms
  # strace execve comparison (wrapper argv vs vendor argv)
  # strace -f follows the daemonized qemu and never exits: stop it with SIGKILL after 25s (strace -f ignores INT/TERM while the daemonized qemu lives)
  timeout -s KILL 25 strace -f -e trace=execve -s 4000 -o "$OUT/p4.strace.txt" qm start 9002 >/dev/null 2>&1; sleep 2
  grep -E 'execve\("/usr/bin/kvm", \["/usr/bin/kvm", "-id"' "$OUT/p4.strace.txt" | sed -E 's/^[0-9]+ execve\("[^"]*", //; s/, 0x[0-9a-f]+ .*$//' > "$OUT/p4.exec.wrapper.txt"
  grep -E 'execve\("/usr/bin/kvm.pve", \["/usr/bin/kvm", "-id"' "$OUT/p4.strace.txt" | sed -E 's/^[0-9]+ execve\("[^"]*", //; s/, 0x[0-9a-f]+ .*$//' > "$OUT/p4.exec.vendor.txt"
  t "strace: wrapper argv == argv vendor binary receives (non-empty)" bash -c "[[ -s '$OUT/p4.exec.wrapper.txt' ]] && diff '$OUT/p4.exec.wrapper.txt' '$OUT/p4.exec.vendor.txt'"
  grep -c execve "$OUT/p4.strace.txt" > /dev/null 2>&1 && log "strace captured ($(wc -l < "$OUT/p4.strace.txt") lines)"
  guests_down
  verdict P4 "p4.*" "strace in p4.strace.txt for manual argv diff"
}

# ---------------- P3b: (e) showcmd <vmid> matches the wrapper's actual argv ----------------
p3b() {
  gate; CASE_FAIL=0; guests_down
  for v in 9001 9003; do
    $ADP showcmd $v > "$OUT/p3b.showcmd.$v.txt" 2>&1
    start_wait $v || log "  warn: $v failed to start"
    # side-binary view = last line of showcmd (printf %q of SIDE_BIN + SIDE_ARGS)
    tail -1 "$OUT/p3b.showcmd.$v.txt" > "$OUT/p3b.$v.sideline"
    python3 - "$OUT/p3b.$v.sideline" > "$OUT/p3b.$v.expected.tok" <<'PY'
import sys,subprocess
line=open(sys.argv[1]).read().strip()
out=subprocess.check_output(["bash","-c","for a in "+line+"; do printf '%s\\n' \"$a\"; done"]).decode()
sys.stdout.write(out)
PY
    tr '\0' '\n' < "/proc/$(cat "/var/run/qemu-server/$v.pid")/cmdline" | tail -n +2 > "$OUT/p3b.$v.live.tok"
    tail -n +2 "$OUT/p3b.$v.expected.tok" > "$OUT/p3b.$v.expected.noargv0"
    t "(e) showcmd $v side view == live argv[1:]" diff "$OUT/p3b.$v.expected.noargv0" "$OUT/p3b.$v.live.tok"
    t "(e) showcmd $v says IS listed" grep -q 'IS listed' "$OUT/p3b.showcmd.$v.txt"
  done
  guests_down
  verdict P3b "p3b.*" "showcmd vs /proc cmdline"
}

# ---------------- P6 ----------------
p6() {
  gate; CASE_FAIL=0; guests_down
  qm showcmd 9003 | tr ' ' '\n' | grep -n 'pve[0-9]' > "$OUT/p6.showcmd.pve.txt" 2>&1 || true
  log "P6 qemu-server emitted +pveN: $([[ -s $OUT/p6.showcmd.pve.txt ]] && echo yes || echo no)"
  t "9003 starts (machine type accepted)" start_wait 9003
  live_argv 9003 > "$OUT/p6.9003.argv"
  t "9003 live argv has no +pveN in machine type" bash -c "! grep -E 'pc-(q35|i440fx)-[0-9.]+\+pve' '$OUT/p6.9003.argv'"
  guests_down
  qm set 9001 --args '-smbios type=1,product=prod+pve7 -fw_cfg name=opt/qad+pve5,string=x' >/dev/null
  t "9001 starts" start_wait 9001
  live_argv 9001 > "$OUT/p6.9001.argv"
  t "9001 keeps product=prod+pve7" grep -q 'product=prod+pve7' "$OUT/p6.9001.argv"
  t "9001 keeps fw_cfg opt/qad+pve5" grep -q 'name=opt/qad+pve5,string=x' "$OUT/p6.9001.argv"
  guests_down; qm set 9001 --delete args >/dev/null
  verdict P6 "p6.*" "qemu-server emitted +pveN: $([[ -s $OUT/p6.showcmd.pve.txt ]] && echo yes || echo no)"
}

# ---------------- P8 ----------------
p8() {
  gate; CASE_FAIL=0; guests_down
  for round in 1 2; do
    qm start 9001 >>"$OUT/qm.log" 2>&1; qm start 9002 >>"$OUT/qm.log" 2>&1; sleep 60
    for v in 9001 9002; do
      t "r$round $v running" bash -c "[[ \$(qm status $v) == *running* ]]"
      echo '{"execute":"qmp_capabilities"}{"execute":"query-status"}' | timeout 10 socat - UNIX-CONNECT:/var/run/qemu-server/$v.qmp > "$OUT/p8.$v.r$round.qmp" 2>&1
      t "r$round $v QMP status running" grep -q '"status": *"running"' "$OUT/p8.$v.r$round.qmp"
      timeout 20 socat - UNIX-CONNECT:/var/run/qemu-server/$v.serial0 > "$OUT/p8.$v.r$round.serial" 2>&1 || true
      [[ -s $OUT/p8.$v.r$round.serial ]] && log "  serial output captured for $v r$round" || log "  note: no serial output for $v r$round (INFO)"
    done
    t "r$round 9001 exe side" [ "$(pidexe 9001)" = $SIDE ]
    t "r$round 9002 exe vendor" bash -c "[[ \$(pidexe 9002) != '$SIDE' && -n \$(pidexe 9002) ]]"
    for v in 9001 9002; do qm shutdown $v --timeout 30 >/dev/null 2>&1 || qm stop $v >/dev/null 2>&1; done; sleep 3
  done
  guests_down
  verdict P8 "p8.*" "both guests booted twice"
}

# ---------------- P1 ----------------
p1() {
  gate; CASE_FAIL=0; guests_down
  $ADP uninstall >>"$OUT/p1.log" 2>&1
  local h0; h0=$(sha256sum /usr/bin/kvm | awk '{print $1}')
  ln -s /dev/full /usr/bin/kvm.qemu-ad-new; $ADP install >>"$OUT/p1.log" 2>&1; local rc1=$?; rm -f /usr/bin/kvm.qemu-ad-new
  t "ENOSPC injection: rc!=0" [ $rc1 -ne 0 ]
  t "kvm unchanged (sha)" bash -c "[[ \$(sha256sum /usr/bin/kvm | awk '{print \$1}') == $h0 ]]"
  t "no divert" bash -c "[[ -z \$(dpkg-divert --list /usr/bin/kvm) ]]"
  mkdir /usr/bin/kvm.qemu-ad-new; $ADP install >>"$OUT/p1.log" 2>&1; local rc2=$?; rmdir /usr/bin/kvm.qemu-ad-new
  t "dir injection: rc!=0" [ $rc2 -ne 0 ]
  t "kvm unchanged after dir injection" bash -c "[[ \$(sha256sum /usr/bin/kvm | awk '{print \$1}') == $h0 ]]"
  t "no divert after dir injection" bash -c "[[ -z \$(dpkg-divert --list /usr/bin/kvm) ]]"
  t "vendor guest 9002 still starts" start_wait 9002; guests_down
  $ADP install >>"$OUT/p1.log" 2>&1; t "recovery install rc=0" [ $? -eq 0 ]
  t "divert exists after recovery" bash -c "dpkg-divert --list /usr/bin/kvm | grep -q kvm.pve"
  $ADP add-vm 9001 >/dev/null; $ADP add-vm 9003 >/dev/null
  t "watcher log empty" watch_clean
  verdict P1 "p1.log, kvm-watch.log" "sha before=$h0"
}

# ---------------- P2 ----------------
p2() {
  gate; CASE_FAIL=0; guests_down
  local W; W=$(sha256sum /usr/bin/kvm | awk '{print $1}')
  mkdir -p /root/shim; cat > /root/shim/dpkg-divert <<'S'
#!/bin/bash
case "$*" in *--remove*) echo "dpkg: error: dpkg frontend lock held (injected)" >&2; exit 2;; esac
exec /usr/bin/dpkg-divert "$@"
S
  chmod +x /root/shim/dpkg-divert; [[ -x /usr/bin/dpkg-divert ]] || sed -i 's#/usr/bin/dpkg-divert#/usr/sbin/dpkg-divert#' /root/shim/dpkg-divert
  PATH=/root/shim:$PATH $ADP uninstall >>"$OUT/p2.log" 2>&1; local rc=$?
  t "injected remove failure: rc!=0" [ $rc -ne 0 ]
  t "wrapper restored (sha = W)" bash -c "[[ \$(sha256sum /usr/bin/kvm | awk '{print \$1}') == $W ]]"
  t "divert still listed" bash -c "dpkg-divert --list /usr/bin/kvm | grep -q kvm.pve"
  t "kvm.pve exists" test -e /usr/bin/kvm.pve
  t "no .qemu-ad-removed leftover" bash -c "[[ ! -e /usr/bin/kvm.qemu-ad-removed ]]"
  rm -rf /root/shim
  flock /var/lib/dpkg/lock-frontend sleep 30 & local fl=$!; sleep 1
  $ADP uninstall >>"$OUT/p2.lock.log" 2>&1; local rcl=$?; wait $fl 2>/dev/null
  log "P2 real-lock uninstall rc=$rcl (either outcome acceptable; kvm must never be missing)"
  [[ $rcl -eq 0 ]] || $ADP uninstall >>"$OUT/p2.log" 2>&1
  t "final: kvm is vendor, no divert" bash -c "[[ -z \$(dpkg-divert --list /usr/bin/kvm) ]] && ! grep -q 'Generated by qemu-ad-pve' /usr/bin/kvm && [[ ! -e /usr/bin/kvm.pve ]]"
  t "9002 starts" start_wait 9002; guests_down
  $ADP install >>"$OUT/p2.log" 2>&1; $ADP add-vm 9001 >/dev/null; $ADP add-vm 9003 >/dev/null
  t "watcher log empty" watch_clean
  verdict P2 "p2.log, p2.lock.log" "real-lock uninstall rc=$rcl"
}

# ---------------- P7 ----------------
p7() {
  gate; CASE_FAIL=0; guests_down
  local W; W=$(sha256sum /usr/bin/kvm | awk '{print $1}')
  dpkg -l pve-qemu-kvm | tail -1 > "$OUT/p7.before.txt"
  chk7() { t "$1: wrapper hash unchanged" bash -c "[[ \$(sha256sum /usr/bin/kvm | awk '{print \$1}') == $W ]]"
           t "$1: divert listed" bash -c "dpkg-divert --list /usr/bin/kvm | grep -q kvm.pve"
           t "$1: kvm.pve resolves to a real qemu" bash -c "[[ -x \$(readlink -f /usr/bin/kvm.pve) ]]"
           t "$1: dpkg --audit clean" bash -c "[[ -z \$(dpkg --audit) ]]"
           t "$1: unlisted 9002 starts" start_wait 9002; guests_down
           if start_wait 9001; then log "  $1: listed 9001 starts"; else log "  INFO $1: listed 9001 failed to start"; echo "$1: listed 9001 failed" >> "$OUT/p7.info.txt"; fi; guests_down; }
  apt-get install --reinstall -y pve-qemu-kvm >>"$OUT/p7.apt.log" 2>&1; t "reinstall rc=0" [ $? -eq 0 ]; chk7 reinstall
  dpkg --verify pve-qemu-kvm > "$OUT/p7.verify.txt" 2>&1
  apt-cache policy pve-qemu-kvm > "$OUT/p7.policy.txt" 2>&1
  local old; old=$(apt-cache madison pve-qemu-kvm | awk '{print $3}' | sed -n 2p)
  if [[ -n $old ]]; then
    apt-get install -y --allow-downgrades "pve-qemu-kvm=$old" >>"$OUT/p7.apt.log" 2>&1; t "downgrade to $old rc=0" [ $? -eq 0 ]; chk7 downgrade
    apt-get install -y pve-qemu-kvm >>"$OUT/p7.apt.log" 2>&1; t "upgrade to newest rc=0" [ $? -eq 0 ]; chk7 upgrade
  else log "P7: only one pve-qemu-kvm version available; real version change SKIPPED"; fi
  dpkg -l pve-qemu-kvm | tail -1 > "$OUT/p7.after.txt"
  t "watcher log empty" watch_clean
  verdict P7 "p7.*, kvm-watch.log" "from=$(awk '{print $3}' "$OUT/p7.before.txt") via=${old:-none} to=$(awk '{print $3}' "$OUT/p7.after.txt"); info: $(tr '\n' ' ' < "$OUT/p7.info.txt" 2>/dev/null)"
  # extra finding P7r (known): apt remove while diverted
  log "P7r (optional, destructive; run manually if wanted): apt remove pve-qemu-kvm while diverted -> expect dangling wrapper, kvm.pve gone"
}

# ---------------- P5 (last: real purge destroys the build) ----------------
p5() {
  gate; CASE_FAIL=0; guests_down
  mkdir -p /opt/qad-sentinel /usr/local/qad-sentinel /root/shim2
  printf '#!/bin/bash\necho "RM $*" >> /root/rm.log\n' > /root/shim2/rm; chmod +x /root/shim2/rm
  for p in / /usr /etc /opt /opt/ /usr/local /srv /home/x relative/opt /opt/../usr /opt/qemu-ad/../.. /usr/local/bin /usr/local/../../etc; do
    : > /root/rm.log; PATH=/root/shim2:$PATH PREFIX="$p" $ADP uninstall --purge >>"$OUT/p5.log" 2>&1; local rc=$? n; n=$(wc -l < /root/rm.log)
    echo "reject PREFIX='$p' rc=$rc rm=$n" >> "$OUT/p5.table.txt"
    t "reject '$p' (rc!=0, 0 rm)" bash -c "[[ $rc -ne 0 && $n -eq 0 ]]"
  done
  t "refused purges left divert+wrapper" bash -c "dpkg-divert --list /usr/bin/kvm | grep -q kvm.pve && grep -q 'Generated by qemu-ad-pve' /usr/bin/kvm"
  # PREFIX="" is NOT a reject case: the script does PREFIX="${PREFIX:-/opt/qemu-ad}", so empty means the default (an allow case).
  : > /root/rm.log; PATH=/root/shim2:$PATH PREFIX="" $ADP uninstall --purge >>"$OUT/p5.log" 2>&1; local rce=$? ne; ne=$(wc -l < /root/rm.log)
  echo "empty  PREFIX='' rc=$rce rm=$ne line=$(head -1 /root/rm.log) (defaults to /opt/qemu-ad)" >> "$OUT/p5.table.txt"
  t "empty PREFIX == default /opt/qemu-ad (rc=0, one rm)" bash -c "[[ $rce -eq 0 && $ne -eq 1 ]] && grep -qF -- ' /opt/qemu-ad ' /root/rm.log"
  $ADP install >>"$OUT/p5.log" 2>&1 || true
  for p in /opt/qemu-ad /usr/local/qemu-ad /srv/qad; do
    : > /root/rm.log; PATH=/root/shim2:$PATH PREFIX="$p" $ADP uninstall --purge >>"$OUT/p5.log" 2>&1; local rc=$? n; n=$(wc -l < /root/rm.log)
    echo "allow  PREFIX='$p' rc=$rc rm=$n line=$(head -1 /root/rm.log)" >> "$OUT/p5.table.txt"
    t "allow '$p' (rc=0, one rm naming it)" bash -c "[[ $rc -eq 0 && $n -eq 1 ]] && grep -qF -- '$p' /root/rm.log"
    # allow cases uninstalled the divert; restore it for the next iteration
    $ADP install >>"$OUT/p5.log" 2>&1 || true
  done
  # Order: leave the installed state (incl. /opt/qemu-ad build) intact. So the REAL (unshimmed) purge targets a
  # dummy PREFIX + dummy LIST_FILE; the real PREFIX was only purged with rm shimmed (above). Reinstall restores the divert.
  mkdir -p /opt/qad-purgetest/bin; touch /opt/qad-purgetest/bin/x /etc/qemu-ad/vms.purgetest
  PREFIX=/opt/qad-purgetest LIST_FILE=/etc/qemu-ad/vms.purgetest $ADP uninstall --purge >>"$OUT/p5.log" 2>&1; t "real purge (dummy prefix) rc=0" [ $? -eq 0 ]
  t "dummy prefix + list gone" bash -c "[[ ! -e /opt/qad-purgetest && ! -e /etc/qemu-ad/vms.purgetest ]]"
  t "/opt/qemu-ad (real build) untouched" test -x $SIDE
  t "/etc/qemu-ad/vms (real list) untouched" test -s /etc/qemu-ad/vms
  t "sentinel survives" test -d /opt/qad-sentinel
  t "kvm is vendor after real purge's uninstall" bash -c "! grep -q 'Generated by qemu-ad-pve' /usr/bin/kvm"
  $ADP install >>"$OUT/p5.log" 2>&1; t "reinstall after purge rc=0" [ $? -eq 0 ]
  t "wrapper+divert restored" bash -c "dpkg-divert --list /usr/bin/kvm | grep -q kvm.pve && grep -q 'Generated by qemu-ad-pve' /usr/bin/kvm"
  t "watcher log empty (P5)" watch_clean
  rm -rf /opt/qad-sentinel /usr/local/qad-sentinel /root/shim2
  verdict P5 "p5.log, p5.table.txt" "$(wc -l < "$OUT/p5.table.txt") PREFIX cases"
}

teardown() {
  gate
  guests_down
  for v in 9001 9002 9003; do qm destroy "$v" --purge >/dev/null 2>&1 || true; done
  kill "$(cat /root/kvm-watch.pid 2>/dev/null)" 2>/dev/null || true
  cp -f $WATCHLOG /var/log/qemu-ad-wrapper.log /root/pveversion.before "$OUT/" 2>/dev/null || true
  log "teardown done. watcher log: $([[ -s $WATCHLOG ]] && echo 'MISSING entries present!' || echo empty). Now ask the outer-host owner to roll back to pre-qemu-ad."
}

table() {
  { echo "| ID | Result | Evidence | Notes |"; echo "|---|---|---|---|"
    awk -F'\t' '{printf "| %s | %s | %s | %s |\n",$1,$2,$3,$4}' "$RES"; } | tee "$OUT/results.md"
  echo; echo "ref: $(cat "$OUT/ref.txt" 2>/dev/null | tr '\n' ' ')"
  echo "pveversion: $(grep -E 'pve-manager|pve-qemu-kvm' /root/pveversion.before 2>/dev/null | tr '\n' ' ')"
}

all() { setup; p0; p3; p3b; p4; p6; p8; p1; p2; p7; p5; teardown; table; }

case "${1:-}" in
  gate) gate;; setup) setup;; p0) p0;; p1) p1;; p2) p2;; p3) p3;; p3b) p3b;; p4) p4;; p5) p5;; p6) p6;; p7) p7;; p8) p8;;
  teardown) teardown;; table) table;; all) all;;
  *) sed -n '2,18p' "$0"; exit 2;;
esac
