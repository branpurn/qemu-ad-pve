#!/bin/bash
# Bare-metal audit, L1 part: what the L1 (this VM) reports. Prints key=value lines; read-only.
d=/sys/class/dmi/id
echo "l1.detect_virt=$(systemd-detect-virt 2>/dev/null || true)"
echo "l1.cpuinfo_hypervisor_flag=$(grep -m1 '^flags' /proc/cpuinfo | grep -qw hypervisor && echo 1 || echo 0)"
for f in bios_vendor bios_version sys_vendor product_name board_vendor board_name chassis_type chassis_vendor; do
  echo "l1.dmi.$f=$(cat $d/$f 2>/dev/null || true)"
done
echo "l1.qemu_optpatches=$(sed 's/.*# optional-patches=//p;d' /opt/qemu-ad-optpatch/.qemu-ad-configure-flags 2>/dev/null)"
echo "l1.kvm_dev=$([ -c /dev/kvm ] && echo present || echo missing)"
