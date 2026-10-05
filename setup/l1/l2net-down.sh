#!/bin/bash
# l2net-down.sh: undo l2net-up.sh (inside L1). Safe to run when nothing is up.
set -uo pipefail
QAD_L2_ENV=${QAD_L2_ENV:-/etc/qemu-ad-l2.env}
if [ -r "$QAD_L2_ENV" ]; then
  # shellcheck disable=SC1090
  . "$QAD_L2_ENV"
fi
BR=${L2_BRIDGE:-brl2}
TAP=${L2_TAP:-tapl2}
RUN=/run/qemu-ad-l2
if [ -f "$RUN/dnsmasq.pid" ]; then
  kill "$(cat "$RUN/dnsmasq.pid")" 2>/dev/null || true
  rm -f "$RUN/dnsmasq.pid"
fi
ip link del "$TAP" 2>/dev/null || true
ip link del "$BR" 2>/dev/null || true
