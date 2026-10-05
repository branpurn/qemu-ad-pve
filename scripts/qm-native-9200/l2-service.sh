#!/bin/bash
# L1 (VM 9200, Debian 13) helper for w10-l2.service. Install as /root/w10/l2-service.sh (0755).
#   pre  : wait (<=60 s) until both L1 GPU functions 02:01.0/.1 are bound to vfio-pci
#   stop : graceful ACPI power-down of the Windows L2 via its QMP socket, wait for QEMU to exit;
#          only if Windows ignores it for L2_STOP_WAIT seconds: QMP quit, then kill (logged as NOT graceful)
#   post : tear down the L2 bridge/tap (l2net-down.sh)
# start itself is /root/w10/start-l2.sh (patched-KVM check, hardened disk resolve, -daemonize).
set -uo pipefail
LOG=/root/w10/l2-service.log
PIDF=/root/w10/w10.pid
QMP=/root/w10/qmp
log() { echo "$(date -Is) $*" | tee -a "$LOG"; }
qmp() { { printf '%s\n' '{"execute":"qmp_capabilities"}' "{\"execute\":\"$1\"}"; sleep 1; } |
          timeout 5 socat - "UNIX-CONNECT:$QMP" >/dev/null 2>&1; }

case "${1:-}" in
pre)
  for i in $(seq 1 60); do
    ok=1
    for d in 0000:02:01.0 0000:02:01.1; do
      [ "$(basename "$(readlink "/sys/bus/pci/devices/$d/driver" 2>/dev/null)")" = vfio-pci ] || ok=0
    done
    if [ "$ok" = 1 ]; then log "pre: GPU 02:01.0/.1 on vfio-pci (waited ${i}s); kvm=$(cat /sys/module/kvm/version 2>/dev/null)"; exit 0; fi
    sleep 1
  done
  log "pre: GPU not on vfio-pci after 60s; not starting L2"
  exit 1
  ;;
stop)
  pid=$(cat "$PIDF" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then log "stop: L2 not running"; exit 0; fi
  log "stop: ACPI system_powerdown -> L2 pid=$pid"
  qmp system_powerdown || log "stop: QMP system_powerdown send failed"
  wait_s=${L2_STOP_WAIT:-150}
  for i in $(seq 1 "$wait_s"); do
    if ! kill -0 "$pid" 2>/dev/null; then log "stop: L2 exited cleanly after ${i}s"; exit 0; fi
    sleep 1
  done
  log "stop: L2 still running after ${wait_s}s -> QMP quit (NOT graceful)"
  qmp quit || true
  sleep 5
  if kill -0 "$pid" 2>/dev/null; then log "stop: still alive -> SIGKILL (NOT graceful)"; kill -9 "$pid" 2>/dev/null; fi
  exit 0
  ;;
post)
  /root/w10/l2net-down.sh >/dev/null 2>&1 || true
  log "post: L2 network torn down; qemu=$(pgrep -c -f 'qemu-system.*w10-l2-ad' || true)"
  exit 0
  ;;
*)
  echo "usage: $0 pre|stop|post" >&2
  exit 2
  ;;
esac
