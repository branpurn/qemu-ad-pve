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
mkdeb 2.0
export PATH=/usr/sbin:/usr/bin
sed '$d' "$QAD_SCRIPT" > /tmp/lib.sh
R(){ env -u WRAPPER_PATH -u VENDOR_PATH -u SIDE_BIN -u LIST_FILE -u LOG_FILE bash -c "source /tmp/lib.sh; set -euo pipefail; PREFIX=/opt/qemu-ad; $1"; }
dpkg -i "$DEBDIR/pve-qemu-kvm_2.0.deb" >/dev/null 2>&1
mkdir -p /opt/qemu-ad/bin; printf '#!/bin/sh\n' > /opt/qemu-ad/bin/qemu-system-x86_64; chmod +x /opt/qemu-ad/bin/qemu-system-x86_64
cat > /tmp/watch.py <<'P'
import os,time,sys
miss=0;n=0;t0=None
end=time.time()+float(sys.argv[1])
while time.time()<end:
    n+=1
    if not os.path.exists('/usr/bin/kvm'):
        miss+=1
print(f"polls={n} missing_polls={miss}")
P
for round in 1 2 3 4 5 6; do
  python3 /tmp/watch.py 3 > /tmp/w.i & sleep 0.3; R install_wrapper >/dev/null 2>&1; wait; echo "install round $round: $(cat /tmp/w.i)"
  python3 /tmp/watch.py 3 > /tmp/w.u & sleep 0.3; R uninstall >/dev/null 2>&1; wait; echo "uninstall round $round: $(cat /tmp/w.u)"
done
