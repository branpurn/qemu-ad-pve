#!/bin/bash
# qemu-ad-pve setup: PVE hookscript for the L1 VM @QAD_VMID@ (installed into a snippets storage
# by setup.sh and referenced as `hookscript:` in the VM config; removed by `setup.sh uninstall`).
#
# Why: the GPU is passed with raw -device options in args: (pcie-pci-bridge topology, which
# hostpciN cannot express), so qm does not do its usual hostpci work. pre-start does the safe
# part of it:
#   1. refuse to start while another *running* VM references the same GPU (hostpciN or args host=)
#   2. bind GPU functions that have no driver to vfio-pci (driver_override), like qm does
#   3. unbind non-display functions (e.g. the GPU's HDMI audio) from a host driver, like qm does,
#      but REFUSE if the display function itself is on a host driver (the host is using it)
# Nothing persistent is written; host modprobe/kernel config is never touched.
set -euo pipefail
VMID=@QAD_VMID@
GPU_SLOT=@QAD_GPU_SLOT@
GPU_FUNCS="@QAD_GPU_FUNCS@"
vmid=${1:-}
phase=${2:-}
[ "$vmid" = "$VMID" ] || exit 0
[ "$phase" = pre-start ] || exit 0

log() { echo "qad-hook[$VMID]: $*"; }
short=${GPU_SLOT#0000:}

for conf in /etc/pve/qemu-server/*.conf; do
  other=$(basename "$conf" .conf)
  [ "$other" = "$VMID" ] && continue
  # active section only (up to the first [snapshot])
  if sed '/^\[/,$d' "$conf" | grep -Eq "^(hostpci[0-9]+:.*($GPU_SLOT|(^|[ :=;])$short)|args:.*host=(0000:)?$short)"; then
    pidf=/var/run/qemu-server/$other.pid
    if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
      log "REFUSING start: VM $other is running and uses GPU $GPU_SLOT. Shut it down first (qm shutdown $other)."
      exit 1
    fi
  fi
done

modprobe vfio-pci
for f in $GPU_FUNCS; do
  dev=/sys/bus/pci/devices/$f
  [ -e "$dev" ] || { log "REFUSING start: $f does not exist"; exit 1; }
  drv=""
  [ -L "$dev/driver" ] && drv=$(basename "$(readlink "$dev/driver")")
  [ "$drv" = vfio-pci ] && continue
  if [ -n "$drv" ]; then
    cls=$(cat "$dev/class")
    case "$cls" in
      0x03*) log "REFUSING start: display function $f is bound to host driver '$drv'"; exit 1 ;;
    esac
    log "unbinding $f from $drv (non-display function, as qm does for hostpci)"
    echo "$f" >"$dev/driver/unbind"
  fi
  echo vfio-pci >"$dev/driver_override"
  echo "$f" >/sys/bus/pci/drivers_probe
  [ "$(basename "$(readlink "$dev/driver")")" = vfio-pci ] || { log "REFUSING start: $f did not bind to vfio-pci"; exit 1; }
  log "$f bound to vfio-pci"
done
exit 0
