# qemu-ad-pve setup: after l2.vga_after_verify = none. Prints VGA_* lines; exit 0 only when the NVIDIA GPU is the only
# display adapter, its problem code is 0 and the interactive session is up on it (dwm.exe running in a console session:
# the login screen or, with autologon, the desktop; explorer.exe is reported for information).
$v = @(Get-CimInstance Win32_VideoController)
Write-Output ("VGA_ADAPTERS " + (($v | ForEach-Object { "$($_.Name):$($_.ConfigManagerErrorCode)" }) -join ';'))
$other = @($v | Where-Object { $_.Name -notmatch 'NVIDIA' })
$nv = @($v | Where-Object { $_.Name -match 'NVIDIA' -and $_.ConfigManagerErrorCode -eq 0 })
$dwm = @(Get-Process dwm -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ge 1 }).Count
$ex = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
Write-Output "VGA_SESSION dwm=$dwm explorer=$ex"
$ok = ($other.Count -eq 0) -and ($nv.Count -ge 1) -and ($dwm -ge 1)
Write-Output ("VGA_CHECK " + $(if ($ok) { 'PASS' } else { 'FAIL' }))
if (-not $ok) { exit 1 }
