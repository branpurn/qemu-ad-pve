<#
.SYNOPSIS
  Guest-side VM-indicator report for qemu-ad-pve test guests (Windows, PowerShell 7 or 5.1).

.DESCRIPTION
  Read-only. Enumerates what a Windows guest can see that reveals it is a virtual machine,
  and classifies each signal as LEAK (still reveals a VM) or MASKED (looks like bare metal).
  It changes nothing in the guest. Output is plain text, one signal per line:
      [LEAK]   <signal>: <detail>
      [MASKED] <signal>: <detail>
      [INFO]   <signal>: <detail>
  Exit code is 0 when no LEAK lines were produced, 1 otherwise.
  Some LEAK signals are expected today (see README); this script is for tracking them,
  not a pass/fail gate unless -Strict is given.

.PARAMETER Strict
  Exit 1 if any LEAK is found (default: always exit 0 after printing the summary).
#>
param([switch]$Strict)   # must stay the first statement; if run through a wrapper that prepends code, drop -Strict handling

$ErrorActionPreference = 'SilentlyContinue'
$script:leaks = 0
function Out-Sig($state, $name, $detail) {
    if ($state -eq 'LEAK') { $script:leaks++ }
    '[{0}] {1}: {2}' -f $state.PadRight(6), $name, $detail
}

$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$vmRx = 'QEMU|Virtio|VirtIO|Red Hat|Hyper-V|VMware|VirtualBox|VBOX|Bochs|BXPC|SeaBIOS|OVMF|EDK II|Proxmox|KVM|Xen|Parallels'

# 1. Hypervisor-present flag (CPUID.1:ECX[31]); KVM "hidden" does not clear this.
if ($cs.HypervisorPresent) { Out-Sig LEAK 'HypervisorPresent' 'True' } else { Out-Sig MASKED 'HypervisorPresent' 'False' }

# 2. Firmware vendor / version strings
$fw = "$($bios.Manufacturer) | $($bios.SMBIOSBIOSVersion) | $($bios.Version)"
if ($fw -match $vmRx) { Out-Sig LEAK 'BIOS strings' $fw } else { Out-Sig MASKED 'BIOS strings' $fw }

# 3. System manufacturer / model (SMBIOS type 1)
$sys = "$($cs.Manufacturer) | $($cs.Model)"
if ($sys -match $vmRx) { Out-Sig LEAK 'System manufacturer/model' $sys } else { Out-Sig MASKED 'System manufacturer/model' $sys }

# 4. Baseboard
$bb = Get-CimInstance Win32_BaseBoard
$bbs = "$($bb.Manufacturer) | $($bb.Product)"
if ($bbs -match $vmRx) { Out-Sig LEAK 'Baseboard' $bbs } else { Out-Sig MASKED 'Baseboard' $bbs }

# 5. PCI / ACPI device IDs and friendly names
$pnp = Get-PnpDevice -PresentOnly
$hits = $pnp | Where-Object {
    $_.InstanceId -match 'VEN_1AF4|VEN_1B36|VEN_1234|VEN_15AD|VEN_80EE|VMBUS|ACPI\\QEMU|ACPI\\BOCHS|ACPI\\BXPC' -or
    $_.FriendlyName -match 'QEMU|Virtio|Red Hat|VMware|VirtualBox|Bochs|Hyper-V Generation'
}
if ($hits) { foreach ($h in $hits) { Out-Sig LEAK 'PnP device' "$($h.FriendlyName) [$($h.InstanceId)]" } }
else       { Out-Sig MASKED 'PnP devices' 'no known virtual-device IDs' }

# 6. Disk model / NIC vendor+MAC OUI
foreach ($d in Get-CimInstance Win32_DiskDrive) {
    if ("$($d.Model) $($d.Manufacturer)" -match $vmRx) { Out-Sig LEAK 'Disk model' $d.Model } else { Out-Sig MASKED 'Disk model' $d.Model }
}
$ouiRx = '^(52:54:00|BC:24:11|00:05:69|00:0C:29|00:1C:14|00:50:56|08:00:27|00:15:5D|00:16:3E)'
foreach ($n in Get-NetAdapter -Physical) {
    $mac = ($n.MacAddress -replace '-', ':').ToUpper()
    if ($mac -match $ouiRx) { Out-Sig LEAK 'NIC MAC OUI' "$($n.InterfaceDescription) $mac" } else { Out-Sig MASKED 'NIC MAC OUI' "$($n.InterfaceDescription) $mac" }
}

# 7. Guest agents / paravirtual services and processes
# Stock Windows ships stopped Hyper-V integration stubs (vmic*), so those only count while Running.
$svc = Get-Service | Where-Object {
    $_.Name -match 'QEMU|qemu-ga|Balloon|vioserial|VirtioFs|VBoxService|VMTools|spice' -or
    ($_.Name -match '^vmic' -and $_.Status -eq 'Running')
}
if ($svc) { foreach ($s in $svc) { Out-Sig LEAK 'Service' "$($s.Name) ($($s.Status))" } } else { Out-Sig MASKED 'Services' 'none' }
$procs = Get-Process | Where-Object { $_.Name -match 'qemu|vbox|vmtools|vmware|spice|vdagent|virtio' }
if ($procs) { foreach ($p in $procs) { Out-Sig LEAK 'Process' $p.Name } } else { Out-Sig MASKED 'Processes' 'none' }

# 8. Paravirtual drivers. Third-party ones (virtio, VBox, VMware) count even when stopped because stock
#    Windows does not contain them; the inbox Hyper-V stubs (vmbus, storvsc, ...) only count while Running.
$drv = Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.Name -match '^(vio|netkvm|balloon|vbox|vmware|vmci|vmhgfs)' -or
    ($_.Name -match '^(vmbus|storvsc|hyperv|HyperVideo|VMBusHID)' -and $_.State -eq 'Running')
}
if ($drv) { foreach ($d in $drv) { Out-Sig LEAK 'Driver registered' "$($d.Name) ($($d.State))" } } else { Out-Sig MASKED 'Drivers' 'none' }

# 9. Physical-hardware plausibility (bare metal normally has these)
$cores = $cpu.NumberOfCores; $threads = $cpu.NumberOfLogicalProcessors
if ($threads -eq $cores) { Out-Sig INFO 'CPU topology' "$cores cores / $threads threads (no SMT; common in VMs)" } else { Out-Sig MASKED 'CPU topology' "$cores cores / $threads threads" }
$dimms = Get-CimInstance Win32_PhysicalMemory
$blank = $dimms | Where-Object { -not $_.PartNumber -or -not $_.Speed }
if ($blank) { Out-Sig LEAK 'Physical memory' "$(@($dimms).Count) DIMM(s), part number/speed blank" } else { Out-Sig MASKED 'Physical memory' "$(@($dimms).Count) DIMM(s) with part number and speed" }
$thermal = @(Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace root/wmi).Count
$fans = @(Get-CimInstance Win32_Fan).Count
if ($thermal -eq 0 -and $fans -eq 0) { Out-Sig INFO 'Thermal/fan sensors' 'none exposed' } else { Out-Sig MASKED 'Thermal/fan sensors' "$thermal zone(s), $fans fan(s)" }
$mon = Get-CimInstance Win32_DesktopMonitor
if ($mon -and ($mon.PNPDeviceID -match 'DISPLAY\\(RHT|QEM|VBX)')) { Out-Sig LEAK 'Monitor ID' ($mon.PNPDeviceID -join ', ') }
elseif ($mon) { Out-Sig INFO 'Monitor ID' ($mon.PNPDeviceID -join ', ') }

# 10. CPU vendor vs. board era consistency (rough heuristic: report both for human review)
Out-Sig INFO 'CPU / board pairing' "$($cpu.Name.Trim()) on $($bb.Manufacturer) $($bb.Product)"

# 11. Timing probe: cost of a tight loop of cheap calls (compare against a bare-metal baseline of the same CPU)
$sw = [Diagnostics.Stopwatch]::StartNew()
1..200000 | ForEach-Object { [void][Environment]::TickCount }
Out-Sig INFO 'Timing loop (200k calls)' "$($sw.ElapsedMilliseconds) ms (needs a bare-metal baseline to interpret)"

''
"Summary: $script:leaks LEAK signal(s)"
if ($Strict -and $script:leaks -gt 0) { exit 1 } else { exit 0 }
