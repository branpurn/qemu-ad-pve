#!/bin/bash
# SAFETY: this script runs REAL dpkg / dpkg-divert and rewrites /usr/bin/kvm. Run it ONLY as root inside a
# disposable private root filesystem (container, chroot copy, or an overlay/tmpfs sandbox that is discarded on
# exit). Never on a real host or a PVE node. See tests/README.md ("Tier 1.5").
[[ ${QAD_T15_SANDBOX:-} == 1 ]] || { echo "refusing: set QAD_T15_SANDBOX=1 to confirm you are inside a disposable root (see tests/README.md)" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "refusing: must run as root inside the sandbox" >&2; exit 2; }
command -v qm >/dev/null 2>&1 && { echo "refusing: 'qm' found, this looks like a PVE node" >&2; exit 2; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Script under test (default: the qemu-ad-pve.sh next to tests/). Dummy pve-qemu-kvm debs are built on the fly.
QAD_SCRIPT=${QAD_SCRIPT:-$HERE/../qemu-ad-pve.sh}
[[ -r $QAD_SCRIPT ]] || { echo "cannot read $QAD_SCRIPT (set QAD_SCRIPT)" >&2; exit 2; }
DEBDIR=$(mktemp -d /tmp/qad-t15-debs.XXXXXX)
# mkdeb <version>: dummy pve-qemu-kvm that ships /usr/bin/kvm -> qemu-system-x86_64, like the real package
mkdeb() {
  local v="$1" d="$DEBDIR/pkg$1"
  mkdir -p "$d/DEBIAN" "$d/usr/bin"
  printf 'Package: pve-qemu-kvm\nVersion: %s\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: dummy stand-in\n' "$v" > "$d/DEBIAN/control"
  printf '#!/bin/sh\necho "VENDOR-QEMU %s "$@""\n' "$v" > "$d/usr/bin/qemu-system-x86_64"
  chmod 755 "$d/usr/bin/qemu-system-x86_64"; ln -s qemu-system-x86_64 "$d/usr/bin/kvm"
  dpkg-deb --root-owner-group -b "$d" "$DEBDIR/pve-qemu-kvm_$1.deb" >/dev/null
}
mkdeb 1.0
mkdeb 2.0
# runs inside bwrap with tmp overlays over /usr /var /etc /opt: everything discarded on exit (or any disposable root)
set -u; export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
S="$QAD_SCRIPT"; H="$DEBDIR"
sed '$d' "$S" > /tmp/lib.sh
R(){ env -u WRAPPER_PATH -u VENDOR_PATH -u SIDE_BIN -u LIST_FILE -u LOG_FILE bash -c "source /tmp/lib.sh; set -euo pipefail; PREFIX=\${PREFIX:-/opt/qemu-ad}; $1"; }
res(){ printf '%s  %s\n' "$1" "$2"; }
dpkg -i "$H"/pve-qemu-kvm_1.0.deb >/dev/null 2>&1 || echo "dpkg -i failed"
mkdir -p /opt/qemu-ad/bin; printf '#!/bin/sh\necho SIDE "$@"\n' > /opt/qemu-ad/bin/qemu-system-x86_64; chmod +x /opt/qemu-ad/bin/qemu-system-x86_64
echo "baseline: kvm -> $(readlink /usr/bin/kvm); divert: [$(dpkg-divert --list /usr/bin/kvm)]"
echo "== P1 real install"
R install_wrapper >/dev/null 2>&1; rc=$?
res "$([[ $rc -eq 0 && -L /usr/bin/kvm.pve && -f /usr/bin/kvm && ! -L /usr/bin/kvm ]] && echo PASS || echo FAIL)" "install: rc=$rc kvm=wrapper(file) kvm.pve=$(readlink /usr/bin/kvm.pve)"
res "$([[ $(/usr/bin/kvm --version 2>&1) == VENDOR* ]] && echo PASS || echo FAIL)" "wrapper -> vendor via kvm.pve symlink resolves (relative symlink): $(/usr/bin/kvm x 2>&1)"
res "$(dpkg-divert --list /usr/bin/kvm | grep -q 'local diversion' && echo PASS || echo FAIL)" "real divert listed: $(dpkg-divert --list /usr/bin/kvm)"
echo "== P7 real upgrade/reinstall via dpkg"
W=$(sha256sum /usr/bin/kvm | cut -c1-12)
dpkg -i "$H"/pve-qemu-kvm_1.0.deb >/dev/null 2>&1; rc=$?
res "$([[ $rc -eq 0 && $(sha256sum /usr/bin/kvm|cut -c1-12) == "$W" && -L /usr/bin/kvm.pve ]] && echo PASS || echo FAIL)" "reinstall same version: rc=$rc wrapper hash unchanged, kvm.pve symlink present"
dpkg -i "$H"/pve-qemu-kvm_2.0.deb >/dev/null 2>&1; rc=$?
res "$([[ $rc -eq 0 && $(sha256sum /usr/bin/kvm|cut -c1-12) == "$W" ]] && echo PASS || echo FAIL)" "upgrade 1.0->2.0: rc=$rc wrapper intact"
res "$([[ $(/usr/bin/kvm -pidfile /var/run/qemu-server/5.pid 2>&1) == 'VENDOR-QEMU 2.0'* ]] && echo PASS || echo FAIL)" "unlisted guest after upgrade runs NEW vendor: $(/usr/bin/kvm -pidfile /var/run/qemu-server/5.pid 2>&1)"
res "$(dpkg -V pve-qemu-kvm >/dev/null 2>&1 && echo PASS || echo FAIL)" "dpkg -V pve-qemu-kvm clean; audit: [$(dpkg --audit)]"
res "$([[ -z $(dpkg -S /usr/bin/kvm 2>&1 | grep -v 'diverted by') || $(dpkg -S /usr/bin/kvm 2>&1) == *diverted* ]] && echo PASS || echo INFO)" "dpkg -S /usr/bin/kvm: $(dpkg -S /usr/bin/kvm 2>&1 | head -2 | tr '\n' ' ')"
dpkg -r pve-qemu-kvm >/dev/null 2>&1; res "INFO" "dpkg -r pve-qemu-kvm while diverted: wrapper present=$([[ -e /usr/bin/kvm ]] && echo y || echo n), kvm.pve present=$([[ -e /usr/bin/kvm.pve || -L /usr/bin/kvm.pve ]] && echo y || echo n)"
dpkg -i "$H"/pve-qemu-kvm_2.0.deb >/dev/null 2>&1
echo "== P2 uninstall: real dpkg lock"
W=$(sha256sum /usr/bin/kvm | cut -c1-12)
( flock /var/lib/dpkg/lock-frontend sleep 8 ) & sleep 1
R uninstall > /tmp/u.out 2>&1; rc=$?
res "INFO" "uninstall while lock-frontend held (flock): rc=$rc; kvm exists=$([[ -e /usr/bin/kvm ]] && echo y || echo n); divert=$(dpkg-divert --list /usr/bin/kvm | wc -l); $(tail -1 /tmp/u.out)"
wait
( flock /var/lib/dpkg/lock sleep 8 ) & sleep 1
if ! dpkg-divert --list /usr/bin/kvm | grep -q .; then R install_wrapper >/dev/null 2>&1; fi
R uninstall > /tmp/u2.out 2>&1; rc=$?
res "INFO" "uninstall while /var/lib/dpkg/lock held: rc=$rc; kvm exists=$([[ -e /usr/bin/kvm ]] && echo y || echo n); divert=$(dpkg-divert --list /usr/bin/kvm | wc -l); $(tail -1 /tmp/u2.out)"
wait
echo "== P2 real failure of dpkg-divert --remove (shim) then clean uninstall"
if ! dpkg-divert --list /usr/bin/kvm | grep -q .; then R install_wrapper >/dev/null 2>&1; fi
W=$(sha256sum /usr/bin/kvm | cut -c1-12)
mkdir -p /tmp/shim; printf '#!/bin/bash\ncase "$*" in *--remove*) echo "dpkg: error: injected lock failure" >&2; exit 2;; esac\nexec /usr/bin/dpkg-divert "$@"\n' > /tmp/shim/dpkg-divert; chmod +x /tmp/shim/dpkg-divert
PATH=/tmp/shim:$PATH R uninstall >/dev/null 2>&1; rc=$?
res "$([[ $rc -ne 0 && $(sha256sum /usr/bin/kvm|cut -c1-12) == "$W" && -n $(dpkg-divert --list /usr/bin/kvm) && ! -e /usr/bin/kvm.qemu-ad-removed ]] && echo PASS || echo FAIL)" "injected remove failure: rc=$rc wrapper restored, divert intact"
R uninstall >/dev/null 2>&1; rc=$?
res "$([[ $rc -eq 0 && -L /usr/bin/kvm && $(readlink /usr/bin/kvm) == qemu-system-x86_64 && -z $(dpkg-divert --list /usr/bin/kvm) && ! -e /usr/bin/kvm.pve ]] && echo PASS || echo FAIL)" "clean uninstall: rc=$rc kvm back to original relative symlink, divert gone, kvm.pve gone"
res "$([[ $(/usr/bin/kvm z 2>&1) == 'VENDOR-QEMU 2.0'* ]] && echo PASS || echo FAIL)" "after uninstall /usr/bin/kvm runs vendor"
echo "== P1b real install failure injection (staged file blocked)"
mkdir /usr/bin/kvm.qemu-ad-new
R install_wrapper >/dev/null 2>&1; rc=$?
res "$([[ $rc -ne 0 && -L /usr/bin/kvm && -z $(dpkg-divert --list /usr/bin/kvm) ]] && echo PASS || echo FAIL)" "staged path is a directory: rc=$rc kvm untouched, no divert"
rmdir /usr/bin/kvm.qemu-ad-new
echo "== P1c real: final mv failure rollback"
mkdir -p /tmp/shim2; printf '#!/bin/bash\nif [[ ${@: -1} == /usr/bin/kvm ]]; then echo "mv: injected" >&2; exit 1; fi\nexec /usr/bin/mv "$@"\n' > /tmp/shim2/mv; chmod +x /tmp/shim2/mv
PATH=/tmp/shim2:$PATH R install_wrapper >/dev/null 2>&1; rc=$?
res "$([[ $rc -ne 0 && -e /usr/bin/kvm && -z $(dpkg-divert --list /usr/bin/kvm) ]] && echo PASS || echo FAIL)" "final mv fails: rc=$rc kvm present=$([[ -e /usr/bin/kvm ]] && echo y || echo n) divert rolled back=$([[ -z $(dpkg-divert --list /usr/bin/kvm) ]] && echo y || echo n)"
echo "== P5 real purge guard + real rm (inside discarded overlay)"
mkdir -p /opt/qad-sentinel /usr/local/qad-sentinel
for p in /usr /opt/../usr /usr/local/bin ""; do PREFIX="$p" R 'uninstall --purge' >/dev/null 2>&1; rc=$?; res "$([[ $rc -ne 0 && -x /usr/bin/dpkg ]] && echo PASS || echo FAIL)" "PREFIX='$p' rejected rc=$rc, /usr/bin/dpkg still present"; done
R "uninstall --purge" >/dev/null 2>&1; rc=$?
res "$([[ $rc -eq 0 && ! -d /opt/qemu-ad && -d /opt/qad-sentinel ]] && echo PASS || echo FAIL)" "real purge /opt/qemu-ad: rc=$rc removed, sentinel kept"
