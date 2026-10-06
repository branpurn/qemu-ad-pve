#!/bin/bash
# qad-l2-create.sh: create the Windows L2 inside L1 WITHOUT the GPU (started by
# `qad-l1.sh l2-install` as the transient unit qemu-ad-l2-install).
#
# Why without the GPU: inside L1 with the GPU attached, OVMF in L2 does not create the disk boot
# entry and drops to the EFI shell (docs/gpu-phase-intel-viommu.md, caveat 6). So the install
# (or, for an existing image, one plain boot) runs with a *dummy* pcie-root-port in the GPU's
# slot, and the resulting OVMF VARS become the template for every GPU boot.
#
#   iso   : boot the Windows ISO (found by volume label among L1's CD drives), optional
#           autounattend.iso + stage.iso; Setup partitions the blank disk resolved by serial
#           (WIN_DISK_ALLOW_BLANK=1: exact serial + no signatures, never a mounted/ext4 disk).
#           Done when the guest powers off (autounattend's first logon ends with shutdown;
#           interactively: shut Windows down yourself).
#   image : boot the existing Windows disk once, wait QAD_IMAGE_BOOT_WAIT s, then ACPI
#           powerdown until it exits.
set -euo pipefail
# shellcheck disable=SC1091
. /etc/qemu-ad/setup.env
# shellcheck disable=SC1091
. /etc/qemu-ad-l2.env
W=/root/w10
LOG=/var/log/qemu-ad-setup/l2-create.log
QB=/opt/qemu-ad/bin/qemu-system-x86_64
QMPS=$W/qmp-install
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== qad-l2-create $(date -Is) source=$QAD_L2_SOURCE"
finish() {
  local rc=$?
  if [ $rc -ne 0 ]; then echo FAILED >"$W/install.state"; echo "FAILED rc=$rc"; fi
  "$W/l2net-down.sh" || true
}
trap finish EXIT
fail() { echo "ERROR: $*"; exit 1; }

[ -x "$QB" ] || fail "$QB missing (qemu-ad-pve binary not installed in L1)"

find_win_cd() {
  local d lab hits=()
  for d in $(lsblk -dpno NAME,TYPE | awk '$2=="rom"{print $1}'); do
    lab=$(lsblk -dno LABEL "$d" 2>/dev/null || true)
    if [ -n "$QAD_WIN_ISO_LABEL" ]; then
      if [ "$lab" = "$QAD_WIN_ISO_LABEL" ]; then printf '%s\n' "$d"; return 0; fi
    elif [ -n "$lab" ] && [ "$lab" != cidata ]; then
      hits+=("$d")  # label unknown on the host: accept the single non-seed CD
    fi
  done
  if [ "${#hits[@]}" -eq 1 ]; then printf '%s\n' "${hits[0]}"; return 0; fi
  return 1
}

CDS=()
case "$QAD_L2_SOURCE" in
  iso)
    WINCD=$(find_win_cd) || fail "Windows ISO with label '$QAD_WIN_ISO_LABEL' not found among L1 CD drives"
    WD=$(WIN_DISK_ALLOW_BLANK=1 "$W/resolve-windows-disk.sh") || fail "no safe target disk (see resolver output above)"
    if grep -q . <<<"$(lsblk -no FSTYPE "$WD")"; then  # not `lsblk | grep -q` (SIGPIPE + pipefail)
      fail "$WD is not blank (a previous, unfinished install?). To start over: setup.sh install --redo l2_install --wipe-l2-disk"
    fi
    CDS+=(-drive "file=$WINCD,format=raw,if=none,id=wincd,media=cdrom,readonly=on" -device "ide-cd,drive=wincd,bus=ide.0")
    if [ -f "$W/autounattend.iso" ]; then
      CDS+=(-drive "file=$W/autounattend.iso,format=raw,if=none,id=unat,media=cdrom,readonly=on" -device "ide-cd,drive=unat,bus=ide.2")
    fi
    ;;
  image)
    WD=$("$W/resolve-windows-disk.sh") || fail "no Windows (NTFS) disk with serial drive-scsi1 found"
    ;;
  *) fail "QAD_L2_SOURCE=$QAD_L2_SOURCE" ;;
esac
if [ -f "$W/stage.iso" ]; then
  CDS+=(-drive "file=$W/stage.iso,format=raw,if=none,id=stg,media=cdrom,readonly=on" -device "ide-cd,drive=stg,bus=ide.3")
fi
echo "disk=$WD cds=${CDS[*]}"

install -m 600 /usr/share/OVMF/OVMF_VARS_4M.fd "$W/VARS.install.fd"
"$W/l2net-up.sh"
VNC=()
[ "$QAD_VNC" = none ] || VNC=(-vnc "$QAD_VNC")
rm -f "$QMPS"

"$QB" -name w10-l2-install -machine q35,accel=kvm -cpu "$QAD_L2_CPU" -smp "$QAD_L2_SMP" -m "$QAD_L2_MEM" \
  -rtc base=localtime \
  -drive if=pflash,format=raw,readonly=on,file=/root/l2/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$W/VARS.install.fd" \
  -drive file="$WD",format=raw,if=none,id=wdisk,cache=none,aio=native,discard=unmap \
  -device ide-hd,drive=wdisk,bus=ide.1,rotation_rate=1 \
  "${CDS[@]}" \
  -netdev tap,id=n0,ifname=tapl2,script=no,downscript=no -device e1000e,netdev=n0,mac="$QAD_L2_MAC" \
  -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string="$QAD_MMIO64_MB" \
  -qmp "unix:$QMPS,server,nowait" -vga std -display none "${VNC[@]}" -usb -device usb-tablet -serial none \
  -device pcie-root-port,id=rpg,chassis=11,slot=1 \
  -pidfile "$W/install.pid" &
qpid=$!

if [ "$QAD_L2_SOURCE" = iso ]; then
  # Get past "Press any key to boot from CD or DVD..." (OVMF + Windows ISO), first ~25 s only.
  python3 "$W/qad-qmp.py" "$QMPS" sendkey ret 25 1 || true
else
  wait_s=${QAD_IMAGE_BOOT_WAIT:-240}
  echo "image boot: waiting ${wait_s}s, then ACPI powerdown"
  for _ in $(seq 1 "$wait_s"); do kill -0 "$qpid" 2>/dev/null || break; sleep 1; done
  while kill -0 "$qpid" 2>/dev/null; do
    python3 "$W/qad-qmp.py" "$QMPS" powerdown || true
    for _ in $(seq 1 30); do kill -0 "$qpid" 2>/dev/null || break; sleep 1; done
  done
fi
rc=0
wait "$qpid" || rc=$?
echo "L2 install QEMU exited rc=$rc"
[ "$rc" -eq 0 ] || fail "QEMU exited with $rc"

# The disk must now look like Windows (NTFS, resolver without the blank exception).
"$W/resolve-windows-disk.sh" >/dev/null || fail "after the install the disk does not resolve as a Windows disk"
if cmp -s /usr/share/OVMF/OVMF_VARS_4M.fd "$W/VARS.install.fd"; then
  fail "OVMF VARS unchanged: no boot entry was written (did Windows boot at all?)"
fi
install -m 600 "$W/VARS.install.fd" "$W/VARS.template.fd"
install -m 600 "$W/VARS.install.fd" "$W/VARS.fd"
echo DONE >"$W/install.state"
echo "DONE: VARS template built without the GPU -> $W/VARS.template.fd, $W/VARS.fd"
