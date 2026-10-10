# Bare-metal audit, L2 part 1 (PowerShell): what Windows reports about the machine. Prints key=value lines.
# Run in the L2 by `qad-l1.sh audit` (setup.sh audit); read-only.
$ErrorActionPreference = 'Continue'
function P($k, $v) { "$k=$v" }
$cs = Get-CimInstance Win32_ComputerSystem
P 'cs.manufacturer' $cs.Manufacturer; P 'cs.model' $cs.Model; P 'cs.hypervisor_present' $cs.HypervisorPresent
$b = Get-CimInstance Win32_BIOS
P 'bios.manufacturer' $b.Manufacturer; P 'bios.version' $b.SMBIOSBIOSVersion; P 'bios.date' ($b.ReleaseDate.ToString('MM/dd/yyyy')); P 'bios.smbios_field_version' $b.Version
$bb = Get-CimInstance Win32_BaseBoard; P 'board.manufacturer' $bb.Manufacturer; P 'board.product' $bb.Product
$en = Get-CimInstance Win32_SystemEnclosure; P 'enclosure.manufacturer' $en.Manufacturer; P 'enclosure.chassis_types' ($en.ChassisTypes -join ',')
$p = Get-CimInstance Win32_Processor | Select-Object -First 1
P 'cpu.name' $p.Name.Trim(); P 'cpu.socket' $p.SocketDesignation; P 'cpu.manufacturer' $p.Manufacturer
$i = 0; Get-CimInstance Win32_PhysicalMemory | ForEach-Object { P "dimm.$i.manufacturer" $_.Manufacturer; P "dimm.$i.part" $_.PartNumber; P "dimm.$i.locator" $_.DeviceLocator; $i++ }
$i = 0; Get-CimInstance Win32_DiskDrive | ForEach-Object { P "disk.$i.model" $_.Model; P "disk.$i.firmware" $_.FirmwareRevision; $i++ }
$i = 0; Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress } | ForEach-Object { P "nic.$i.mac" $_.MACAddress; P "nic.$i.name" $_.Name; $i++ }
$i = 0; Get-CimInstance Win32_VideoController | ForEach-Object { P "video.$i.name" $_.Name; P "video.$i.code" $_.ConfigManagerErrorCode; P "video.$i.driver" $_.DriverVersion; $i++ }
$i = 0; Get-CimInstance Win32_CDROMDrive | ForEach-Object { P "cdrom.$i.name" $_.Name; P "cdrom.$i.media" $_.MediaLoaded; $i++ }
P 'systeminfo.hypervisor_lines' ((systeminfo | Select-String -Pattern 'hypervisor' | Measure-Object).Count)
# install residue (l2.cleanup_unattend / l2.cleanup_staging)
P 'residue.unattend' ((@('C:\unattend.xml', 'C:\autounattend.xml', 'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\actionqueue', 'C:\Windows\System32\Sysprep\unattend.xml') | Where-Object { Test-Path -LiteralPath $_ }) -join ',')
P 'residue.staging' ((@('nvidia', 'python', 'openssh', 'firstlogon.ps1', 'firstlogon.log', 'firstlogon.done', 'gpu-driver.ps1', 'gpu-driver.log') | Where-Object { Test-Path -LiteralPath (Join-Path 'C:\qad' $_) }) -join ',')
$mon = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue)
P 'monitor.pnp' (($mon | ForEach-Object { $_.FriendlyName }) -join ',')
P 'monitor.cim' ((Get-CimInstance Win32_DesktopMonitor | ForEach-Object { $_.Name }) -join ',')
# stale (not present) device instances of earlier VM identities (same filter as setup/l1/windows/ghosts.ps1)
$present = @((Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue).InstanceId)
$ghost = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
  $id = $_.InstanceId
  ($present -notcontains $id) -and ($id -notmatch 'VEN_10DE|SAMSUNG|^ROOT\\|^STORAGE\\') -and (
    ($_.Class -eq 'CDROM' -and $id -match '^(SCSI|IDE)\\CDROM') -or
    ($_.Class -eq 'DiskDrive' -and $id -match 'PROD_HARDDISK|QEMU_HARDDISK') -or
    ($_.Class -eq 'Display' -and $id -match '^PCI\\VEN_1234&DEV_1111')) })
P 'ghost.count' $ghost.Count
P 'ghost.ids' (($ghost | ForEach-Object { $_.InstanceId }) -join ',')
