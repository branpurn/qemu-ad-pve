#!/bin/bash
# Usage: uninstall_after_vendor_removed.sh /path/to/qemu-ad-pve.sh [more scripts...]  (sandbox only: temp dirs, throwaway dpkg admindir)
set -u
W=$(mktemp -d); H=$W/h; mkdir -p $H/bin $H/src $H/etc $W/stub
printf '#!/bin/bash\nexec /usr/bin/dpkg-divert --admindir %s "$@"\n' $W/adm > $W/stub/dpkg-divert; chmod +x $W/stub/dpkg-divert; mkdir -p $W/adm; : > $W/adm/diversions
for LIB in "$@"; do
 sed '$d' $LIB > $W/lib.sh
 : > $W/adm/diversions; printf 'vendor\n' > $H/bin/kvm; rm -f $H/bin/kvm.pve; chmod 755 $H/bin/kvm
 SIDE=$W/side; printf '#!/bin/bash\necho QEMU emulator version 10.2.2\n' > $SIDE; chmod +x $SIDE
 run() { PATH=$W/stub:$PATH bash -c "source $W/lib.sh; set -euo pipefail; need_root(){ :; }; WRAPPER_PATH=$H/bin/kvm VENDOR_PATH=$H/bin/kvm.pve SIDE_BIN=$SIDE LIST_FILE=$H/etc/vms LOG_FILE=$H/log DPKG_LOCK=$H/nolock PREFIX=$H/opt; $1" 2>&1; }
 run install_wrapper >/dev/null; rm -f $H/bin/kvm.pve   # simulates 'apt remove pve-qemu-kvm' (dpkg deletes kvm.pve)
 echo "-- $LIB: uninstall after kvm.pve vanished:"; run uninstall | tail -2; echo "rc=$? divert: $(/usr/bin/dpkg-divert --admindir $W/adm --list $H/bin/kvm)"
 echo "-- reinstall (pve-qemu-kvm reinstalled -> dpkg puts vendor back at kvm.pve):"; printf 'vendor2\n' > $H/bin/kvm.pve; run uninstall | tail -2; cat $H/bin/kvm
done
