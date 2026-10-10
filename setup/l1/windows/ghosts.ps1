<#
  qemu-ad-pve setup: remove stale (ghost) device instance keys that earlier VM identities left in the L2
  (run as SYSTEM through a one-shot scheduled task by `qad-l1.sh ghosts`). Only devices that are NOT present are
  considered, and only these classes/patterns:
    * CD-ROM class devices (SCSI\CDROM..., IDE\CDROM...)             - old optical drive instances (install CDs, old model)
    * disk drives named ... PROD_HARDDISK / QEMU_HARDDISK            - the install-time 'ASUS HARDDISK' / QEMU disk
    * display adapter PCI\VEN_1234&DEV_1111                          - the emulated Standard VGA after l2.vga = none
  Never touched: anything present, NVIDIA (VEN_10DE), the Samsung disk, the present CD instance, volumes, buses.
  The Enum keys are exported with reg.exe to -Backup first. -Apply 0 only lists.
#>
param([int]$Apply = 1, [string]$Backup = 'C:\Windows\Temp\qad-ghost-backup', [string]$Log = 'C:\Windows\Temp\qad-ghosts.log')
$ErrorActionPreference = 'Continue'
Start-Transcript -Path $Log -Force | Out-Null
$present = @((Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue).InstanceId)
$ghost = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
  $id = $_.InstanceId
  ($present -notcontains $id) -and ($id -notmatch 'VEN_10DE|SAMSUNG|^ROOT\\|^STORAGE\\') -and (
    ($_.Class -eq 'CDROM' -and $id -match '^(SCSI|IDE)\\CDROM') -or
    ($_.Class -eq 'DiskDrive' -and $id -match 'PROD_HARDDISK|QEMU_HARDDISK') -or
    ($_.Class -eq 'Display' -and $id -match '^PCI\\VEN_1234&DEV_1111'))
}
Write-Output "GHOST_FOUND $(@($ghost).Count)"
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
$n = 0; $bad = 0
foreach ($g in $ghost) {
  $id = $g.InstanceId
  $key = 'HKLM\SYSTEM\CurrentControlSet\Enum\' + $id
  Write-Output "GHOST $($g.Class) $id ($($g.FriendlyName))"
  if (-not $Apply) { continue }
  $f = Join-Path $Backup (($id -replace '[\\&{}#]', '_') + '.reg')
  & reg.exe export $key $f /y 2>&1 | Out-Null
  & pnputil.exe /remove-device $id 2>&1 | Out-Null
  if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $id)) {
    Remove-Item -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $id) -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $id)) { Write-Output "GHOST_FAILED $id"; $bad++ } else { $n++ }
}
# empty parent keys (e.g. SCSI\CDROM&VEN_..&PROD_..) left behind
if ($Apply) {
  foreach ($p in 'SCSI', 'IDE', 'PCI') {
    Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\$p" -ErrorAction SilentlyContinue | Where-Object { $_.SubKeyCount -eq 0 -and $_.Name -match 'CDROM&VEN_|DISK&VEN_ASUS|VEN_1234&DEV_1111' } |
      ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Force -ErrorAction SilentlyContinue }
  }
}
Write-Output "GHOST_REMOVED $n failed=$bad"
Write-Output 'GHOST_DONE'
Stop-Transcript | Out-Null
