<#
.SYNOPSIS
    Reports NVIDIA display-adapter health (with focus on Code 43) as ONE JSON document on stdout.

.DESCRIPTION
    Run INSIDE a Windows 10 guest (Windows PowerShell 5.1 or pwsh 7). Read-only; changes nothing.

    Devices reported (array 'nvidia_devices'):
      * Win32_PnPEntity with PNPClass 'Display' AND (PNPDeviceID contains VEN_10DE OR Manufacturer
        matches NVIDIA)                                           -> match = 'nvidia_display'
    Any OTHER device with ConfigManagerErrorCode 43 is listed in 'other_code43'
    (same fields, match = 'other_code43'); it does not count as an NVIDIA device but does
    make 'result' = 'code43' when at least one NVIDIA display device exists.

    Per device: InstanceId, FriendlyName, PnP Status (Get-PnpDevice), Present,
    ConfigManagerErrorCode (Win32_PnPEntity) + meaning text, driver version/date/provider
    (Win32_PnPSignedDriver and DEVPKEY_Device_Driver*), 'code43' boolean.

    Also: host info (computer name, OS caption/build, ISO 8601 UTC timestamp,
    Win32_ComputerSystem.HypervisorPresent), nvidia-smi summary (never fails if absent),
    and the last 5 relevant Kernel-PnP / nvlddmkm System events ('recent_events').

    'result':
      no_nvidia_device  no NVIDIA display device found (nvidia_devices = [])   exit 3
      code43            any reported device has ConfigManagerErrorCode 43      exit 43
      ok                every NVIDIA device has ConfigManagerErrorCode 0       exit 0
      error_other       otherwise (some other non-zero error code)             exit 2
    'exit_code' is also included in the JSON, because Invoke-Command (PSRemoting) does not
    propagate remote exit codes.

.PARAMETER Pretty
    Indented JSON (default is compact, single line).

.PARAMETER OutFile
    Additionally write the JSON (UTF-8, no BOM) to this path on the machine running the script.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\w10-code43-check.ps1 -Pretty
    echo $LASTEXITCODE
#>
[CmdletBinding()]
param(
    [switch]$Pretty,
    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function ConvertTo-IsoUtc {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $dt = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)
        return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } catch {
        return [string]$Value
    }
}

$ErrorText = @{
    0  = 'This device is working properly.'
    1  = 'This device is not configured correctly.'
    3  = 'The driver for this device might be corrupted, or your system may be running low on memory or other resources.'
    10 = 'This device cannot start.'
    12 = 'This device cannot find enough free resources that it can use.'
    14 = 'This device cannot work properly until you restart your computer.'
    18 = 'Reinstall the drivers for this device.'
    19 = 'Windows cannot start this hardware device because its configuration information (in the registry) is incomplete or damaged.'
    21 = 'Windows is removing this device.'
    22 = 'This device is disabled.'
    24 = 'This device is not present, is not working properly, or does not have all its drivers installed.'
    28 = 'The drivers for this device are not installed.'
    29 = 'This device is disabled because the firmware of the device did not give it the required resources.'
    31 = 'This device is not working properly because Windows cannot load the drivers required for this device.'
    32 = 'A driver (service) for this device has been disabled.'
    33 = 'Windows cannot determine which resources are required for this device.'
    34 = 'Windows cannot determine the settings for this device.'
    35 = 'Your computer''s system firmware does not include enough information to properly configure and use this device.'
    36 = 'This device is requesting a PCI interrupt but is configured for an ISA interrupt (or vice versa).'
    37 = 'Windows cannot initialize the device driver for this hardware.'
    38 = 'Windows cannot load the device driver for this hardware because a previous instance of the device driver is still in memory.'
    39 = 'Windows cannot load the device driver for this hardware. The driver may be corrupted or missing.'
    40 = 'Windows cannot access this hardware because its service key information in the registry is missing or recorded incorrectly.'
    41 = 'Windows successfully loaded the device driver for this hardware but cannot find the hardware device.'
    42 = 'Windows cannot load the device driver for this hardware because there is a duplicate device already running in the system.'
    43 = 'Windows has stopped this device because it has reported problems. (Code 43)'
    44 = 'An application or service has shut down this hardware device.'
    45 = 'Currently, this hardware device is not connected to the computer.'
    46 = 'Windows cannot gain access to this hardware device because the operating system is in the process of shutting down.'
    47 = 'Windows cannot use this hardware device because it has been prepared for safe removal.'
    48 = 'The software for this device has been blocked from starting because it is known to have problems with Windows.'
    49 = 'Windows cannot start new hardware devices because the system hive is too large.'
    50 = 'Windows cannot apply all of the properties for this device.'
    51 = 'This device is currently waiting on another device or set of devices to start.'
    52 = 'Windows cannot verify the digital signature for the drivers required for this device.'
}

function Get-ErrorCodeText {
    param($Code)
    if ($null -eq $Code) { return $null }
    $c = [int]$Code
    if ($ErrorText.ContainsKey($c)) { return $ErrorText[$c] }
    return ('Unknown ConfigManagerErrorCode {0}.' -f $c)
}

function Get-DeviceReport {
    param($Entity, [string]$Match)

    $instanceId = [string]$Entity.PNPDeviceID
    $code = $null
    if ($null -ne $Entity.ConfigManagerErrorCode) { $code = [int]$Entity.ConfigManagerErrorCode }

    # --- Get-PnpDevice (Status / Present / FriendlyName) ---
    $pnpStatus = $null; $present = $null; $friendly = $null
    try {
        $pd = Get-PnpDevice -InstanceId $instanceId -ErrorAction Stop
        if ($pd) {
            $pd = @($pd)[0]
            $pnpStatus = [string]$pd.Status
            $present   = $pd.Present
            $friendly  = [string]$pd.FriendlyName
        }
    } catch { }
    if (-not $friendly) { $friendly = [string]$Entity.Name }

    # --- Get-PnpDeviceProperty (driver version/date/provider) ---
    $propVersion = $null; $propDate = $null; $propProvider = $null
    try {
        $props = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_DriverProvider' -ErrorAction Stop
        foreach ($p in @($props)) {
            switch ($p.KeyName) {
                'DEVPKEY_Device_DriverVersion'  { if ($null -ne $p.Data) { $propVersion  = [string]$p.Data } }
                'DEVPKEY_Device_DriverDate'     { $propDate     = ConvertTo-IsoUtc $p.Data }
                'DEVPKEY_Device_DriverProvider' { if ($null -ne $p.Data) { $propProvider = [string]$p.Data } }
            }
        }
    } catch { }

    # --- Win32_PnPSignedDriver ---
    $sdVersion = $null; $sdDate = $null; $sdProvider = $null; $sdInf = $null; $sdSigned = $null
    try {
        $esc = $instanceId.Replace('\', '\\').Replace("'", "\'")
        $sd = Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter ("DeviceID = '{0}'" -f $esc) -ErrorAction Stop
        if ($sd) {
            $sd = @($sd)[0]
            $sdVersion  = [string]$sd.DriverVersion
            $sdDate     = ConvertTo-IsoUtc $sd.DriverDate
            $sdProvider = [string]$sd.DriverProviderName
            $sdInf      = [string]$sd.InfName
            $sdSigned   = $sd.IsSigned
        }
    } catch { }

    $driverVersion  = if ($sdVersion)  { $sdVersion }  else { $propVersion }
    $driverDate     = if ($sdDate)     { $sdDate }     else { $propDate }
    $driverProvider = if ($sdProvider) { $sdProvider } else { $propProvider }

    [ordered]@{
        match                        = $Match
        InstanceId                   = $instanceId
        FriendlyName                 = $friendly
        PnpClass                     = [string]$Entity.PNPClass
        Manufacturer                 = [string]$Entity.Manufacturer
        PnpStatus                    = $pnpStatus
        Present                      = $present
        ConfigManagerErrorCode       = $code
        ConfigManagerErrorCodeText   = (Get-ErrorCodeText $code)
        code43                       = ($code -eq 43)
        driver_version               = $driverVersion
        driver_date                  = $driverDate
        driver_provider              = $driverProvider
        driver_inf                   = $sdInf
        driver_is_signed             = $sdSigned
        driver_detail                = [ordered]@{
            win32_pnpsigneddriver = [ordered]@{ version = $sdVersion;   date = $sdDate;   provider = $sdProvider }
            devpkey               = [ordered]@{ version = $propVersion; date = $propDate; provider = $propProvider }
        }
    }
}

# ---------------------------------------------------------------- host info
$hostInfo = [ordered]@{
    computer_name      = $env:COMPUTERNAME
    timestamp_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    os_caption         = $null
    os_version         = $null
    os_build           = $null
    os_architecture    = $null
    hypervisor_present = $null
    manufacturer       = $null
    model              = $null
    powershell_version = $PSVersionTable.PSVersion.ToString()
    powershell_edition = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
}
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $hostInfo.os_caption      = [string]$os.Caption
    $hostInfo.os_version      = [string]$os.Version
    $hostInfo.os_build        = [string]$os.BuildNumber
    $hostInfo.os_architecture = [string]$os.OSArchitecture
} catch { }
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $hostInfo.hypervisor_present = $cs.HypervisorPresent
    $hostInfo.manufacturer       = [string]$cs.Manufacturer
    $hostInfo.model              = [string]$cs.Model
    if ($cs.Name) { $hostInfo.computer_name = [string]$cs.Name }
} catch { }

# ---------------------------------------------------------------- devices
$nvidia = New-Object System.Collections.ArrayList
$other  = New-Object System.Collections.ArrayList
$enumError = $null
try {
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)
    foreach ($e in $entities) {
        $id = [string]$e.PNPDeviceID
        $isNvVendor = ($id -match 'VEN_10DE') -or ([string]$e.Manufacturer -match 'NVIDIA')
        $isDisplay  = ([string]$e.PNPClass -eq 'Display')
        if ($isDisplay -and $isNvVendor) {
            [void]$nvidia.Add((Get-DeviceReport -Entity $e -Match 'nvidia_display'))
        }
        elseif ($null -ne $e.ConfigManagerErrorCode -and [int]$e.ConfigManagerErrorCode -eq 43) {
            [void]$other.Add((Get-DeviceReport -Entity $e -Match 'other_code43'))
        }
    }
} catch {
    $enumError = $_.Exception.Message
}

# ---------------------------------------------------------------- nvidia-smi
$smi = [ordered]@{ present = $false; path = $null; exit_code = $null; gpus = @(); error = $null }
try {
    $smiPath = $null
    $cmd = Get-Command -Name 'nvidia-smi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $smiPath = $cmd.Source }
    if (-not $smiPath) {
        $candidates = @()
        if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe') }
        if ($env:SystemRoot)   { $candidates += (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe') }
        foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $smiPath = $c; break } }
    }
    if ($smiPath) {
        $smi.present = $true
        $smi.path    = $smiPath
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $lines = @(& $smiPath '--query-gpu=name,driver_version' '--format=csv,noheader' 2>&1 | ForEach-Object { [string]$_ })
        $smi.exit_code = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($smi.exit_code -eq 0) {
            $gpus = @()
            foreach ($l in $lines) {
                $parts = $l.Split(',')
                if ($parts.Count -ge 2) {
                    $gpus += [ordered]@{ name = $parts[0].Trim(); driver_version = $parts[1].Trim() }
                }
            }
            $smi.gpus = $gpus
        } else {
            $smi.error = (($lines -join ' ').Trim())
            if ($smi.error.Length -gt 500) { $smi.error = $smi.error.Substring(0, 500) }
        }
    }
} catch {
    $smi.error = $_.Exception.Message
}

# ---------------------------------------------------------------- recent events
$events = @()
$eventsError = $null
try {
    $collected = New-Object System.Collections.ArrayList
    foreach ($prov in @('nvlddmkm', 'Microsoft-Windows-Kernel-PnP')) {
        try {
            $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov } -MaxEvents 200 -ErrorAction Stop)
            foreach ($ev in $evs) {
                $msg = [string]$ev.Message
                if ($prov -eq 'nvlddmkm' -or $msg -match 'NVIDIA|VEN_10DE|nvlddmkm') {
                    [void]$collected.Add($ev)
                }
            }
        } catch { }   # provider absent / no events: ignore
    }
    $events = @($collected | Sort-Object -Property TimeCreated -Descending | Select-Object -First 5 | ForEach-Object {
        $m = [string]$_.Message
        if ($m.Length -gt 500) { $m = $m.Substring(0, 500) }
        [ordered]@{
            time_utc = $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            provider = [string]$_.ProviderName
            id       = $_.Id
            level    = [string]$_.LevelDisplayName
            message  = $m
        }
    })
} catch {
    $eventsError = $_.Exception.Message
}

# ---------------------------------------------------------------- result
$nvArr    = @($nvidia.ToArray())
$otherArr = @($other.ToArray())
$anyCode43 = $false
foreach ($d in ($nvArr + $otherArr)) { if ($d.code43) { $anyCode43 = $true } }
$allZero = $true
foreach ($d in $nvArr) { if ($d.ConfigManagerErrorCode -ne 0) { $allZero = $false } }

if ($nvArr.Count -eq 0)  { $result = 'no_nvidia_device'; $exitCode = 3 }
elseif ($anyCode43)      { $result = 'code43';           $exitCode = 43 }
elseif ($allZero)        { $result = 'ok';               $exitCode = 0 }
else                     { $result = 'error_other';      $exitCode = 2 }

$doc = [ordered]@{
    result           = $result
    exit_code        = $exitCode
    host             = $hostInfo
    nvidia_devices   = $nvArr
    other_code43     = $otherArr
    nvidia_smi       = $smi
    recent_events    = $events
    errors           = [ordered]@{ device_enumeration = $enumError; events = $eventsError }
}

if ($Pretty) { $json = ConvertTo-Json -InputObject $doc -Depth 5 }
else         { $json = ConvertTo-Json -InputObject $doc -Depth 5 -Compress }

if ($OutFile) {
    try {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
        [System.IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Warning ("Could not write OutFile '{0}': {1}" -f $OutFile, $_.Exception.Message)
    }
}

Write-Output $json
exit $exitCode
