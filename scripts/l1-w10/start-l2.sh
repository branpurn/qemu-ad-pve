#!/bin/bash
# One-command Windows L2 start under L1 patched KVM default.
# Uses hardened disk resolve; qemu-ad-pve if present else stock Debian QEMU.
set -euo pipefail
cd /root/w10

# Require patched kvm (default path). Override with ALLOW_STOCK_KVM=1 only for fallback tests.
if [ "${ALLOW_STOCK_KVM:-0}" != "1" ]; then
  ver=$(cat /sys/module/kvm/version 2>/dev/null || echo none)
  file=$(modinfo -F filename kvm 2>/dev/null || echo none)
  case "$ver" in
    *kvmpatch*) ;;
    *)
      echo "REFUSING start: kvm version='$ver' (want *kvmpatch*). file=$file" >&2
      echo "Patched KVM is the permanent default; load it or set ALLOW_STOCK_KVM=1 for temporary stock." >&2
      exit 80
      ;;
  esac
  echo "$file" | grep -q "/updates/dkms/" || {
    echo "REFUSING start: kvm not from updates/dkms ($file)" >&2
    exit 81
  }
  echo "kvm ok: version=$ver file=$file patch_tag=$(cat /sys/module/kvm_amd/parameters/patch_tag 2>/dev/null)"
fi

if [ -f /root/w10/w10.pid ] && kill -0 "$(cat /root/w10/w10.pid)" 2>/dev/null; then
  echo "L2 already running pid=$(cat /root/w10/w10.pid)" >&2
  exit 0
fi

WD=$(/root/w10/resolve-windows-disk.sh)
echo "using $WD"

# Prefer qemu-ad-pve copy; fall back to stock Debian qemu only if binary missing/unusable.
QB=${QB:-/opt/qemu-ad/bin/qemu-system-x86_64}
if [ ! -x "$QB" ] || ! "$QB" --version >/dev/null 2>&1; then
  QB=$(command -v qemu-system-x86_64)
  echo "WARN: qemu-ad unavailable, using stock $QB" >&2
fi

/root/w10/l2net-up.sh

CPU=${CPU:-host}
VGA=${VGA:-std}
# Intentional split of EXTRA env into argv words
# shellcheck disable=SC2206
EXTRA=(${EXTRA:-})

# shellcheck disable=SC2086
exec "$QB" -name w10-l2-ad -machine q35,accel=kvm -cpu "$CPU" -smp 4 -m 6144 -rtc base=localtime \
  -drive if=pflash,format=raw,readonly=on,file=/root/l2/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/root/w10/VARS.fd \
  -drive file="$WD",format=raw,if=none,id=wdisk,cache=none,aio=native,discard=unmap \
  -device ide-hd,drive=wdisk,bus=ide.1,rotation_rate=1 \
  -netdev tap,id=n0,ifname=tapl2,script=no,downscript=no -device e1000e,netdev=n0,mac=52:54:00:aa:bb:01 \
  -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 \
  -monitor unix:/root/w10/mon,server,nowait -qmp unix:/root/w10/qmp,server,nowait \
  -debugcon file:/root/w10/ovmf-debug.log -global isa-debugcon.iobase=0x402 \
  -vga "$VGA" -display none -usb -device usb-tablet -serial none \
  -device pcie-root-port,id=rpg,chassis=11,slot=1 \
  -device vfio-pci,host=0000:02:01.0,bus=rpg,addr=0x0.0x0,multifunction=on \
  -device vfio-pci,host=0000:02:01.1,bus=rpg,addr=0x0.0x1 \
  "${EXTRA[@]}" -pidfile /root/w10/w10.pid -daemonize
