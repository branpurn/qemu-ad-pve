#!/bin/bash
# l2net-up.sh: isolated L1<->L2 network for the Windows L2 (runs inside L1, idempotent).
# Bridge brl2 + tap tapl2, a private subnet, dnsmasq DHCP with a fixed lease for the L2 MAC.
# No routing / NAT: the L2 has no internet (qemu-ad-pve has no SLIRP anyway); L1 reaches the
# L2's sshd over this bridge. Settings come from /etc/qemu-ad-l2.env (written by setup.sh).
# Reconstructed from the description in docs/gpu-phase-patched-kvm-l1.md (step 9); the lab
# script itself is not in the repo.
set -euo pipefail
QAD_L2_ENV=${QAD_L2_ENV:-/etc/qemu-ad-l2.env}
if [ -r "$QAD_L2_ENV" ]; then
  # shellcheck disable=SC1090
  . "$QAD_L2_ENV"
fi
BR=${L2_BRIDGE:-brl2}
TAP=${L2_TAP:-tapl2}
BRIP=${L2_BRIDGE_IP:-10.254.77.1}
PREFIX=${L2_NET_PREFIX:-24}
L2IP=${L2_IP:-10.254.77.10}
MAC=${L2_MAC:-52:54:00:aa:bb:01}
DSTART=${L2_DHCP_START:-10.254.77.200}
DEND=${L2_DHCP_END:-10.254.77.250}
RUN=/run/qemu-ad-l2

mkdir -p "$RUN"
if ! ip link show "$BR" >/dev/null 2>&1; then
  ip link add "$BR" type bridge
fi
if ! grep -q "inet $BRIP/" <<<"$(ip -4 addr show dev "$BR")"; then
  ip addr add "$BRIP/$PREFIX" dev "$BR"
fi
ip link set "$BR" up
if ! ip link show "$TAP" >/dev/null 2>&1; then
  ip tuntap add dev "$TAP" mode tap
fi
ip link set "$TAP" master "$BR"
ip link set "$TAP" up

if [ -f "$RUN/dnsmasq.pid" ] && kill -0 "$(cat "$RUN/dnsmasq.pid")" 2>/dev/null; then
  exit 0
fi
command -v dnsmasq >/dev/null || { echo "dnsmasq not found (apt-get install dnsmasq-base)" >&2; exit 2; }
dnsmasq --conf-file=/dev/null --interface="$BR" --bind-interfaces --except-interface=lo \
  --port=0 --dhcp-authoritative --dhcp-range="$DSTART,$DEND,12h" \
  --dhcp-host="$MAC,$L2IP" --dhcp-option=option:router --dhcp-option=option:dns-server \
  --dhcp-leasefile="$RUN/dnsmasq.leases" --pid-file="$RUN/dnsmasq.pid"
