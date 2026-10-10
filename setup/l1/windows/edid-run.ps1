# qemu-ad-pve setup: run C:\Windows\Temp\qad-edid.ps1 (edid.ps1) as SYSTEM through a one-shot scheduled task and print its EDID_* lines
param([string]$EdidB64 = '', [int]$Apply = 1, [int]$Remove = 0)
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\qad-edid.ps1 -EdidB64 `"$EdidB64`" -Apply $Apply -Remove $Remove"
Register-ScheduledTask -TaskName 'qad-edid' -Action $a -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'qad-edid'
for ($i = 0; $i -lt 60; $i++) { Start-Sleep 2; if ((Get-ScheduledTask -TaskName 'qad-edid').State -ne 'Running') { break } }
Unregister-ScheduledTask -TaskName 'qad-edid' -Confirm:$false
Get-Content C:\Windows\Temp\qad-edid.log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^EDID' }
