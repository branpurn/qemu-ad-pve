#!/bin/bash
# host: plain qm shutdown 9200 with serial console capture; usage: shut.sh <tag>
cd /root/gpu-phase-l1/qmnative; t=$1
( timeout 300 socat -u UNIX-CONNECT:/var/run/qemu-server/9200.serial0 - > serial-$t.log 2>&1 & )
sleep 1
echo "qm shutdown start $(date -Is)"; t0=$(date +%s)
qm shutdown 9200; rc=$?
echo "qm shutdown rc=$rc after $(($(date +%s)-t0))s at $(date -Is)"
qm status 9200; pgrep -af 'kvm.*-id 9200' || echo 'no 9200 qemu'
lspci -nnk -s 02:00 | grep driver; cat /run/qemu-server/pci-id-reservations
sleep 1; pkill -f 'socat -u UNIX-CONNECT:/var/run/qemu-server/9200.serial0' || true
tr -d '\r' < serial-$t.log | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -iE "w10-l2|Windows L2|power key|Power Button|systemd-poweroff|poweroff.target" | grep -v "stop running" | tail -20; tr -d "\r" < serial-$t.log | grep -o "Job w10-l2.service/stop running ([^)]*)" | tail -1
