#!/bin/bash
# One-command Windows L2 start under L1 patched KVM default.
# Uses hardened disk resolve; qemu-ad-pve if present else stock Debian QEMU.
#
# Optional settings file (written by setup.sh; absent = the lab defaults below):
#   QAD_L2_ENV=/etc/qemu-ad-l2.env   GPU_IDS / GPU_BDFS, L2_SMP, L2_MEM, L2_MAC, MMIO64_MB,
#                                    KVM_PATCH_RE, REQUIRE_QEMU_AD, L2_VNC, EXTRA, WIN_DISK_*
set -euo pipefail
cd /root/w10

QAD_L2_ENV=${QAD_L2_ENV:-/etc/qemu-ad-l2.env}
if [ -r "$QAD_L2_ENV" ]; then
  # shellcheck disable=SC1090
  . "$QAD_L2_ENV"
fi

# Require patched kvm (default path). Override with ALLOW_STOCK_KVM=1 only for fallback tests.
# KVM_PATCH_RE: extended regex the /sys/module/kvm/version string must match.
# Canonical package: dkms/ (kvm-l1, "l1-dkms-0.1"); setup.sh writes KVM_PATCH_RE='l1-dkms'.
# "kvmpatch" (the lab's legacy kvm-patched/1.0, "6.12.111-kvmpatch1") stays accepted by default
# until VM 9200 is realigned to dkms/ (docs/SETUP.md).
KVM_PATCH_RE=${KVM_PATCH_RE:-l1-dkms|kvmpatch}
if [ "${ALLOW_STOCK_KVM:-0}" != "1" ]; then
  ver=$(cat /sys/module/kvm/version 2>/dev/null || echo none)
  file=$(modinfo -F filename kvm 2>/dev/null || echo none)
  if ! [[ $ver =~ $KVM_PATCH_RE ]]; then
    echo "REFUSING start: kvm version='$ver' (want /$KVM_PATCH_RE/). file=$file" >&2
    echo "Patched KVM is the permanent default; load it or set ALLOW_STOCK_KVM=1 for temporary stock." >&2
    exit 80
  fi
  [[ $file == */updates/dkms/* ]] || {
    echo "REFUSING start: kvm not from updates/dkms ($file)" >&2
    exit 81
  }
  tag=$(cat /sys/module/kvm_amd/parameters/patch_tag 2>/dev/null || cat /sys/module/kvm/parameters/build_tag 2>/dev/null || true)
  echo "kvm ok: version=$ver file=$file patch_tag=$tag"
fi

if [ -f /root/w10/w10.pid ] && kill -0 "$(cat /root/w10/w10.pid)" 2>/dev/null; then
  echo "L2 already running pid=$(cat /root/w10/w10.pid)" >&2
  exit 0
fi

WD=$(/root/w10/resolve-windows-disk.sh)
echo "using $WD"

# Prefer qemu-ad-pve copy; fall back to stock Debian qemu only if binary missing/unusable
# (REQUIRE_QEMU_AD=1 turns the fallback into a refusal).
QB=${QB:-/opt/qemu-ad/bin/qemu-system-x86_64}
if [ ! -x "$QB" ] || ! "$QB" --version >/dev/null 2>&1; then
  if [ "${REQUIRE_QEMU_AD:-0}" = "1" ]; then
    echo "REFUSING start: $QB missing/unusable and REQUIRE_QEMU_AD=1" >&2
    exit 82
  fi
  QB=$(command -v qemu-system-x86_64)
  echo "WARN: qemu-ad unavailable, using stock $QB" >&2
fi

# GPU functions inside L1. GPU_IDS ("vendor:device ...", one per function, in function order)
# is resolved at every start, because L1's PCI numbering is not something to hard-code;
# GPU_BDFS is the lab default (both functions behind L1's pcie-pci-bridge).
GPU_BDFS=${GPU_BDFS:-0000:02:01.0 0000:02:01.1}
if [ -n "${GPU_IDS:-}" ]; then
  GPU_BDFS=""
  for id in $GPU_IDS; do
    mapfile -t hits < <(lspci -Dn -d "$id" | awk '{print $1}')
    if [ "${#hits[@]}" -ne 1 ]; then
      echo "REFUSING start: GPU function $id matched ${#hits[@]} devices (${hits[*]:-none}) in L1" >&2
      exit 83
    fi
    GPU_BDFS="$GPU_BDFS ${hits[0]}"
  done
fi
GPUDEV=()
n=0
for bdf in $GPU_BDFS; do
  if [ "$n" -eq 0 ]; then
    GPUDEV+=(-device "vfio-pci,host=$bdf,bus=rpg,addr=0x0.0x0,multifunction=on")
  else
    GPUDEV+=(-device "vfio-pci,host=$bdf,bus=rpg,addr=0x0.0x$n")
  fi
  n=$((n + 1))
done

/root/w10/l2net-up.sh

CPU=${CPU:-host}
VGA=${VGA:-std}
L2_SMP=${L2_SMP:-4}
L2_MEM=${L2_MEM:-6144}
L2_MAC=${L2_MAC:-52:54:00:aa:bb:01}
MMIO64_MB=${MMIO64_MB:-65536}
VNC=()
if [ -n "${L2_VNC:-}" ] && [ "${L2_VNC}" != "none" ]; then
  VNC=(-vnc "$L2_VNC")
fi
# Intentional split of EXTRA env into argv words
# shellcheck disable=SC2206
EXTRA=(${EXTRA:-})

# shellcheck disable=SC2086
exec "$QB" -name w10-l2-ad -machine q35,accel=kvm -cpu "$CPU" -smp "$L2_SMP" -m "$L2_MEM" -rtc base=localtime \
  -drive if=pflash,format=raw,readonly=on,file=/root/l2/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/root/w10/VARS.fd \
  -drive file="$WD",format=raw,if=none,id=wdisk,cache=none,aio=native,discard=unmap \
  -device ide-hd,drive=wdisk,bus=ide.1,rotation_rate=1 \
  -netdev tap,id=n0,ifname=tapl2,script=no,downscript=no -device e1000e,netdev=n0,mac="$L2_MAC" \
  -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string="$MMIO64_MB" \
  -monitor unix:/root/w10/mon,server,nowait -qmp unix:/root/w10/qmp,server,nowait \
  -debugcon file:/root/w10/ovmf-debug.log -global isa-debugcon.iobase=0x402 \
  -vga "$VGA" -display none "${VNC[@]}" -usb -device usb-tablet -serial none \
  -device pcie-root-port,id=rpg,chassis=11,slot=1 \
  "${GPUDEV[@]}" \
  "${EXTRA[@]}" -pidfile /root/w10/w10.pid -daemonize
