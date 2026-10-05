#!/bin/bash
# stop-l2.sh: clean ACPI shutdown of the Windows L2 (inside L1). Used as ExecStop of
# qemu-ad-l2.service, so `qm shutdown <L1>` -> L1 poweroff -> this -> Windows shuts down first.
#   STOP_TIMEOUT (default 240 s): powerdown is re-sent every 30 s; after the timeout QMP quit.
set -uo pipefail
W=${W10_DIR:-/root/w10}
PIDF=${PIDF:-$W/w10.pid}
QMP=${QMP:-$W/qmp}
QMPCLI=${QMPCLI:-$W/qad-qmp.py}
STOP_TIMEOUT=${STOP_TIMEOUT:-240}

pid=$(cat "$PIDF" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "L2 not running"
  rm -f "$PIDF"
  exit 0
fi
echo "L2 pid=$pid: ACPI powerdown"
start=$(date +%s)
last=0
while kill -0 "$pid" 2>/dev/null; do
  now=$(date +%s)
  if [ $((now - start)) -ge "$STOP_TIMEOUT" ]; then
    echo "L2 did not shut down within ${STOP_TIMEOUT}s: QMP quit" >&2
    python3 "$QMPCLI" "$QMP" quit || kill "$pid" 2>/dev/null || true
    sleep 5
    break
  fi
  if [ $((now - last)) -ge 30 ]; then
    python3 "$QMPCLI" "$QMP" powerdown || true
    last=$now
  fi
  sleep 2
done
if kill -0 "$pid" 2>/dev/null; then
  kill -9 "$pid" 2>/dev/null || true
fi
echo "L2 stopped after $(( $(date +%s) - start ))s"
