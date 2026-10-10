# qemu-ad-pve setup: run C:\Windows\Temp\qad-ghosts.ps1 (ghosts.ps1) as SYSTEM through a one-shot scheduled task and print its GHOST_* lines
param([int]$Apply = 1)
$s = 'C:\Windows\Temp\qad-ghosts.ps1'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $s -Apply $Apply"
Register-ScheduledTask -TaskName 'qad-ghosts' -Action $a -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'qad-ghosts'
for ($i = 0; $i -lt 90; $i++) { Start-Sleep 2; if ((Get-ScheduledTask -TaskName 'qad-ghosts').State -ne 'Running') { break } }
Unregister-ScheduledTask -TaskName 'qad-ghosts' -Confirm:$false
Get-Content C:\Windows\Temp\qad-ghosts.log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^GHOST' }
