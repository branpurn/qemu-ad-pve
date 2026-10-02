#!/bin/bash
# tier15-common.sh: sourced by tier15-*.sh (not run directly). Safety guard, dummy-deb builder, small helpers.
#
# The tier-1.5 scripts run REAL dpkg / dpkg-divert and rewrite /usr/bin/kvm. They must only ever run as root inside a
# disposable private root filesystem (container, throwaway chroot, or an overlay/tmpfs sandbox discarded on exit).
# The guard below is a best-effort tripwire, not a sandbox: the caller still has to provide the disposable root.

# t15_guard: exit 2 unless it looks safe. Test hook: T15_FS_ROOT prefixes the filesystem probes (default: empty).
t15_guard() {
  local r="${T15_FS_ROOT:-}" f
  [[ ${QAD_T15_SANDBOX:-} == 1 ]] || { echo "refusing: set QAD_T15_SANDBOX=1 to confirm you are inside a disposable root (see tests/README.md)" >&2; exit 2; }
  for f in /usr/sbin/qm /usr/bin/qm /sbin/qm /bin/qm /usr/local/bin/qm /usr/local/sbin/qm; do
    [[ -e $r$f ]] && { echo "refusing: $f exists, this looks like a PVE node" >&2; exit 2; }
  done
  command -v qm >/dev/null 2>&1 && { echo "refusing: 'qm' found on PATH, this looks like a PVE node" >&2; exit 2; }
  [[ -e $r/etc/pve ]] && { echo "refusing: /etc/pve exists, this looks like a PVE node" >&2; exit 2; }
  if command -v dpkg-query >/dev/null 2>&1 && [[ $(dpkg-query -W -f '${Status}' pve-qemu-kvm 2>/dev/null) == *"install ok installed"* ]]; then
    echo "refusing: a real pve-qemu-kvm package is installed here" >&2; exit 2
  fi
  [[ $(id -u) -eq 0 ]] || { echo "refusing: must run as root inside the sandbox" >&2; exit 2; }
}

# t15_init: private temp dir (no fixed /tmp names), script under test, counters
t15_init() {
  HERE=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)
  QAD_SCRIPT=${QAD_SCRIPT:-$HERE/../qemu-ad-pve.sh}
  [[ -r $QAD_SCRIPT ]] || { echo "cannot read $QAD_SCRIPT (set QAD_SCRIPT)" >&2; exit 2; }
  TMPD=$(mktemp -d /tmp/qad-t15.XXXXXX) || exit 2
  trap 'rm -rf "$TMPD"' EXIT
  DEBDIR="$TMPD/debs"; mkdir -p "$DEBDIR"
  NFAIL=0; NPASS=0; NINFO=0
}

# mkdeb <version>: dummy pve-qemu-kvm that ships /usr/bin/kvm -> qemu-system-x86_64, like the real package
mkdeb() {
  local v="$1" d="$DEBDIR/pkg$1"
  mkdir -p "$d/DEBIAN" "$d/usr/bin"
  printf 'Package: pve-qemu-kvm\nVersion: %s\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: dummy stand-in\n' "$v" > "$d/DEBIAN/control"
  printf '#!/bin/sh\necho "VENDOR-QEMU %s "$@""\n' "$v" > "$d/usr/bin/qemu-system-x86_64"
  chmod 755 "$d/usr/bin/qemu-system-x86_64"; ln -s qemu-system-x86_64 "$d/usr/bin/kvm"
  dpkg-deb --root-owner-group -b "$d" "$DEBDIR/pve-qemu-kvm_$1.deb" >/dev/null
}

# res <PASS|FAIL|INFO> <text>: print a result line and count it
res() {
  printf '%s  %s\n' "$1" "$2"
  case $1 in PASS) NPASS=$((NPASS+1));; FAIL) NFAIL=$((NFAIL+1));; *) NINFO=$((NINFO+1));; esac
}

# fcntl_hold <file> <seconds>: hold an fcntl (POSIX) lock the way dpkg does (flock(1) would not model it)
fcntl_hold() {
  python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(float(sys.argv[2]))' "$1" "$2"
}

# t15_finish: summary line; exit non-zero if anything FAILed
t15_finish() {
  echo "TIER15 RESULT: pass=$NPASS fail=$NFAIL info=$NINFO"
  [[ $NFAIL -eq 0 ]]
}
