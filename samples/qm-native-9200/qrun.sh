#!/bin/bash
# host: qrun.sh <script> [extra files]  -> copies to L1 /tmp and runs <script> as root in L1.
# L1 found by its MAC; every neighbour entry for that MAC is tried with ssh (stale DHCP leases are common).
cd /root/gpu-phase-l1/qmnative || exit 1
mac=bc:24:11:0e:69:36
O="-i /root/gpu-phase-l1/l1key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
IP=""
for t in $(seq 1 60); do
  for c in ${L1IP:-} $(ip neigh | awk -v m=$mac 'tolower($5)==m && $6!="FAILED" {print $1}'); do
    if ssh -T $O debian@"$c" true </dev/null 2>/dev/null; then IP=$c; break 2; fi
  done
  for i in $(seq 100 140); do ping -c1 -W1 192.168.1.$i >/dev/null 2>&1 & done; wait
done
[ -z "$IP" ] && { echo L1_SSH_TIMEOUT; exit 9; }
echo "$IP" > l1ip
s=$1; shift
scp -q $O "$s" "$@" debian@"$IP":/tmp/ && ssh -T $O debian@"$IP" "sudo bash /tmp/$(basename "$s")" < /dev/null
