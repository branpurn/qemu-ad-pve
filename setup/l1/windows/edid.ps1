<#
  qemu-ad-pve setup: try a registry EDID override for the L2's monitor node (run as SYSTEM through a one-shot scheduled
  task by `qad-l1.sh edid`). With no monitor attached the GPU reports no display target, so only the placeholder
  `DISPLAY\Default_Monitor\...` nodes exist; the EDID and EDID_OVERRIDE\0 values are written to their Device Parameters key.
  Prints EDID_* lines. -Apply 0: list only. -Remove 1: delete the values again (revert). Keys are exported to -Backup first.
#>
param([string]$EdidB64 = '', [int]$Apply = 1, [int]$Remove = 0, [string]$Backup = 'C:\Windows\Temp\qad-edid-backup', [string]$Log = 'C:\Windows\Temp\qad-edid.log')
$ErrorActionPreference = 'Continue'
Start-Transcript -Path $Log -Force | Out-Null
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
$base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
$n = 0
foreach ($mon in Get-ChildItem $base -ErrorAction SilentlyContinue) {
  foreach ($inst in Get-ChildItem $mon.PSPath -ErrorAction SilentlyContinue) {
    $dp = Join-Path $inst.PSPath 'Device Parameters'
    Write-Output "EDID_NODE $($inst.Name)"
    if (-not $Apply) { continue }
    $f = Join-Path $Backup (($inst.Name -replace '[\\&{}#:]', '_') + '.reg')
    & reg.exe export ($inst.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM') $f /y 2>&1 | Out-Null
    if ($Remove) {
      Remove-ItemProperty -LiteralPath $dp -Name EDID -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $dp 'EDID_OVERRIDE') -Recurse -Force -ErrorAction SilentlyContinue
    } else {
      $bytes = [Convert]::FromBase64String($EdidB64)
      New-Item -Path $dp -Force | Out-Null
      New-ItemProperty -LiteralPath $dp -Name EDID -PropertyType Binary -Value $bytes -Force | Out-Null
      New-Item -Path (Join-Path $dp 'EDID_OVERRIDE') -Force | Out-Null
      New-ItemProperty -LiteralPath (Join-Path $dp 'EDID_OVERRIDE') -Name '0' -PropertyType Binary -Value $bytes -Force | Out-Null
    }
    $n++
  }
}
Write-Output "EDID_APPLIED $n remove=$Remove"
Write-Output 'EDID_DONE'
Stop-Transcript | Out-Null
