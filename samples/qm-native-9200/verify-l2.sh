#!/bin/bash
# L1: verify autostarted Windows L2 (unit state, patched kvm, Code 0, nvidia-smi, CuPy), then drop key
install -m 600 /tmp/w10_ed25519 /root/w10/.w10key; rm -f /tmp/w10_ed25519
SSH="ssh -i /root/w10/.w10key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 w10admin@10.99.0.2"
echo "=== TIME $(date -Is) L1 boot=$(uptime -s) ==="
echo "kvm=$(cat /sys/module/kvm/version) kvm_amd=$(cat /sys/module/kvm_amd/version) file=$(modinfo -F filename kvm)"
systemctl is-enabled w10-l2.service; systemctl is-active w10-l2.service
systemctl show w10-l2.service -p ActiveEnterTimestamp -p MainPID -p ExecMainStatus
echo '--- previous L1 boot: shutdown path (journal -b -1)'
journalctl -b -1 --no-pager -o short-iso -u w10-l2.service -u systemd-logind.service | grep -E 'Power key|w10-l2|l2-service|powering|Stopp' | tail -12
tail -4 /root/w10/l2-service.log
journalctl -b -u w10-l2.service --no-pager -o short-iso | tail -12
for i in $(seq 1 60); do $SSH hostname >/dev/null 2>&1 && { echo "L2_SSH_UP (waited ~$((i*5-5))s)"; break; }; sleep 5; done
$SSH '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("s")'
$SSH 'Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match "VEN_10DE" } | ForEach-Object { $_.Name + " | " + $_.Status + " | Code " + $_.ConfigManagerErrorCode }'
$SSH 'nvidia-smi --query-gpu=name,driver_version,memory.total,pcie.link.gen.current --format=csv,noheader; nvidia-smi -q | Select-String -Pattern "BAR1" -Context 0,1 | Select-Object -First 1'
for k in 1 2; do $SSH 'C:\gputest\py\python.exe C:\gputest\cuda-test.py' 2>&1 | grep -E 'TFLOP|RESULT|cupy|device|Error' ; done
$SSH 'Get-WinEvent -FilterHashtable @{LogName="System"; Id=41,6005,6006,6008,1074} -MaxEvents 6 | ForEach-Object { $_.TimeCreated.ToString("s") + " id=" + $_.Id + " " + ($_.Message -split "`n")[0].Trim() }'
dmesg | grep -ciE "DMAR:.*fault|IO_PAGE_FAULT|AER: (Corrected|Uncorrected|Multiple)|BUG:|Oops|Call Trace" | sed "s/^/L1 fault-pattern lines: /"
rm -f /root/w10/.w10key
echo VERIFY_DONE
