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
      [ERROR]  <signal>: <query failed; result unknown, NOT counted as MASKED>
  The script always prints a summary. Exit code is 0 by default. With -Strict it exits 1 if any
  LEAK or ERROR was produced. Some LEAK signals are expected today; this script is for tracking
  them, not a pass/fail gate unless -Strict is given.

.PARAMETER Strict
  Exit 1 if any LEAK or ERROR is found (default: always exit 0 after printing the summary).
#>
param([switch]$Strict)   # must stay the first statement; if run through a wrapper that prepends code, drop -Strict

$ErrorActionPreference = 'Stop'
$script:leaks = 0
$script:errors = 0
function Out-Sig($state, $name, $detail) {
    if ($state -eq 'LEAK')  { $script:leaks++ }
    if ($state -eq 'ERROR') { $script:errors++ }
    '[{0}] {1}: {2}' -f $state.PadRight(6), $name, $detail
}
# Run a query; on failure print [ERROR] and return $null with $script:qok = $false so callers skip MASKED.
function Invoke-Query($name, [scriptblock]$sb) {
    $script:qok = $true
    try { return , @(& $sb) } catch { $script:qok = $false; Out-Sig ERROR $name $_.Exception.Message | Write-Host; return , @() }
}

$vmRx = 'QEMU|Virtio|VirtIO|Red Hat|Hyper-V|VMware|VirtualBox|VBOX|Bochs|BXPC|SeaBIOS|OVMF|EDK II|Proxmox|KVM|Xen|Parallels'

$csA = Invoke-Query 'Win32_ComputerSystem' { Get-CimInstance Win32_ComputerSystem }
$cs = $csA[0] | Select-Object -First 1
if ($script:qok) {
    # 1. Hypervisor-present flag (CPUID.1:ECX[31]); KVM "hidden" does not clear this.
    if ($cs.HypervisorPresent) { Out-Sig LEAK 'HypervisorPresent' 'True' } else { Out-Sig MASKED 'HypervisorPresent' 'False' }
    # 3. System manufacturer / model (SMBIOS type 1)
    $sys = "$($cs.Manufacturer) | $($cs.Model)"
    if ($sys -match $vmRx) { Out-Sig LEAK 'System manufacturer/model' $sys } else { Out-Sig MASKED 'System manufacturer/model' $sys }
}

# 2. Firmware vendor / version strings
$biosA = Invoke-Query 'Win32_BIOS' { Get-CimInstance Win32_BIOS }
if ($script:qok) {
    $bios = $biosA[0] | Select-Object -First 1
    $fw = "$($bios.Manufacturer) | $($bios.SMBIOSBIOSVersion) | $($bios.Version)"
    if ($fw -match $vmRx) { Out-Sig LEAK 'BIOS strings' $fw } else { Out-Sig MASKED 'BIOS strings' $fw }
}

# 4. Baseboard
$bbA = Invoke-Query 'Win32_BaseBoard' { Get-CimInstance Win32_BaseBoard }
$bb = $null
if ($script:qok) {
    $bb = $bbA[0] | Select-Object -First 1
    $bbs = "$($bb.Manufacturer) | $($bb.Product)"
    if ($bbs -match $vmRx) { Out-Sig LEAK 'Baseboard' $bbs } else { Out-Sig MASKED 'Baseboard' $bbs }
}

# 5. PCI / ACPI device IDs and friendly names
$pnpA = Invoke-Query 'Get-PnpDevice' { Get-PnpDevice -PresentOnly }
if ($script:qok) {
    $hits = $pnpA[0] | Where-Object {
        $_.InstanceId -match 'VEN_1AF4|VEN_1B36|VEN_1234|VEN_15AD|VEN_80EE|VMBUS|ACPI\\QEMU|ACPI\\BOCHS|ACPI\\BXPC' -or
        $_.FriendlyName -match 'QEMU|Virtio|Red Hat|VMware|VirtualBox|Bochs|Hyper-V Generation'
    }
    if ($hits) { foreach ($h in $hits) { Out-Sig LEAK 'PnP device' "$($h.FriendlyName) [$($h.InstanceId)]" } }
    else       { Out-Sig MASKED 'PnP devices' 'no known virtual-device IDs' }
}

# 6. Disk model / NIC vendor+MAC OUI
$disks = Invoke-Query 'Win32_DiskDrive' { Get-CimInstance Win32_DiskDrive }
if ($script:qok) {
    foreach ($d in $disks[0]) {
        if ("$($d.Model) $($d.Manufacturer)" -match $vmRx) { Out-Sig LEAK 'Disk model' $d.Model } else { Out-Sig MASKED 'Disk model' $d.Model }
    }
}
$ouiRx = '^(52:54:00|BC:24:11|00:05:69|00:0C:29|00:1C:14|00:50:56|08:00:27|00:15:5D|00:16:3E)'
$nics = Invoke-Query 'Get-NetAdapter' { Get-NetAdapter -Physical }
if ($script:qok) {
    foreach ($n in $nics[0]) {
        $mac = ($n.MacAddress -replace '-', ':').ToUpper()
        if ($mac -match $ouiRx) { Out-Sig LEAK 'NIC MAC OUI' "$($n.InterfaceDescription) $mac" } else { Out-Sig MASKED 'NIC MAC OUI' "$($n.InterfaceDescription) $mac" }
    }
}

# 7. Guest agents / paravirtual services and processes.
#    Stock Windows ships stopped Hyper-V integration stubs (vmic*), so those only count while Running.
# (-ErrorAction SilentlyContinue: some inbox services deny query rights to non-SYSTEM users; that is per-service noise.)
$svc = Invoke-Query 'Get-Service' { Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'QEMU|qemu-ga|Balloon|vioserial|VirtioFs|VBoxService|VMTools|spice' -or
    ($_.Name -match '^vmic' -and $_.Status -eq 'Running') } }
if ($script:qok) {
    if ($svc[0].Count) { foreach ($s in $svc[0]) { Out-Sig LEAK 'Service' "$($s.Name) ($($s.Status))" } } else { Out-Sig MASKED 'Services' 'none' }
}
$procs = Invoke-Query 'Get-Process' { Get-Process | Where-Object { $_.Name -match 'qemu|vbox|vmtools|vmware|spice|vdagent|virtio' } }
if ($script:qok) {
    if ($procs[0].Count) { foreach ($p in $procs[0]) { Out-Sig LEAK 'Process' $p.Name } } else { Out-Sig MASKED 'Processes' 'none' }
}

# 8. Paravirtual drivers. Third-party ones (virtio, VBox, VMware) count even when stopped because stock
#    Windows does not contain them; the inbox Hyper-V stubs (vmbus, storvsc, ...) only count while Running.
$drv = Invoke-Query 'Win32_SystemDriver' { Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.Name -match '^(vio|netkvm|balloon|vbox|vmware|vmci|vmhgfs)' -or
    ($_.Name -match '^(vmbus|storvsc|hyperv|HyperVideo|VMBusHID)' -and $_.State -eq 'Running') } }
if ($script:qok) {
    if ($drv[0].Count) { foreach ($d in $drv[0]) { Out-Sig LEAK 'Driver registered' "$($d.Name) ($($d.State))" } } else { Out-Sig MASKED 'Drivers' 'none' }
}

# 9. Physical-hardware plausibility (bare metal normally has these)
$cpuA = Invoke-Query 'Win32_Processor' { Get-CimInstance Win32_Processor }
$cpu = $null
if ($script:qok) {
    $cpu = $cpuA[0] | Select-Object -First 1
    $cores = $cpu.NumberOfCores; $threads = $cpu.NumberOfLogicalProcessors
    if ($threads -eq $cores) { Out-Sig INFO 'CPU topology' "$cores cores / $threads threads (no SMT; common in VMs)" } else { Out-Sig MASKED 'CPU topology' "$cores cores / $threads threads" }
}
$dimms = Invoke-Query 'Win32_PhysicalMemory' { Get-CimInstance Win32_PhysicalMemory }
if ($script:qok) {
    $blank = $dimms[0] | Where-Object { -not $_.PartNumber -or -not $_.Speed }
    if ($blank) { Out-Sig LEAK 'Physical memory' "$(@($dimms[0]).Count) DIMM(s), part number/speed blank" } else { Out-Sig MASKED 'Physical memory' "$(@($dimms[0]).Count) DIMM(s) with part number and speed" }
}
# Thermal zones and fans: the WMI classes are often unsupported even on bare metal, so a failure is INFO, not ERROR.
try { $thermal = @(Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace root/wmi).Count } catch { $thermal = 0 }
try { $fans = @(Get-CimInstance Win32_Fan).Count } catch { $fans = 0 }
if ($thermal -eq 0 -and $fans -eq 0) { Out-Sig INFO 'Thermal/fan sensors' 'none exposed (or classes unsupported)' } else { Out-Sig MASKED 'Thermal/fan sensors' "$thermal zone(s), $fans fan(s)" }
$mon = Invoke-Query 'Win32_DesktopMonitor' { Get-CimInstance Win32_DesktopMonitor }
if ($script:qok -and $mon[0].Count) {
    if ($mon[0].PNPDeviceID -match 'DISPLAY\\(RHT|QEM|VBX)') { Out-Sig LEAK 'Monitor ID' ($mon[0].PNPDeviceID -join ', ') }
    else { Out-Sig INFO 'Monitor ID' ($mon[0].PNPDeviceID -join ', ') }
}

# 10. CPU vendor vs. board era consistency (rough heuristic: report both for human review)
if ($cpu -and $bb) { Out-Sig INFO 'CPU / board pairing' "$($cpu.Name.Trim()) on $($bb.Manufacturer) $($bb.Product)" }

# 11. Timing probe: cost of a tight loop of cheap calls (compare against a bare-metal baseline of the same CPU)
$sw = [Diagnostics.Stopwatch]::StartNew()
1..200000 | ForEach-Object { [void][Environment]::TickCount }
Out-Sig INFO 'Timing loop (200k calls)' "$($sw.ElapsedMilliseconds) ms (needs a bare-metal baseline to interpret)"

''
"Summary: $script:leaks LEAK signal(s), $script:errors query error(s)"
if ($Strict -and ($script:leaks -gt 0 -or $script:errors -gt 0)) { exit 1 } else { exit 0 }
