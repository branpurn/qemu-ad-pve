<#
  qemu-ad-pve setup: runs ONCE at the first logon of the Windows L2 (autounattend
  FirstLogonCommands, elevated, as the admin account). Offline: the L2 has no internet.
  Everything it needs comes from the QADSTAGE CD built inside L1. Log: C:\qad\firstlogon.log
  UNTESTED end to end (written from the lab notes; see docs/SETUP.md "Tested vs untested").

  1. copy \qad from the stage CD to C:\qad
  2. power: never sleep/hibernate, power button = shut down (L1 stops the L2 with ACPI powerdown)
  3. OpenSSH server (Windows capability if available, else the staged OpenSSH-Win64.zip),
     key-only login for L1 (administrators_authorized_keys), firewall rule for the L1 link
  4. Python + offline wheels (if staged) into C:\qad\py and C:\qad\venv
  5. scheduled task that installs the staged NVIDIA driver at the first boot WITH the GPU
  6. shut down (this tells L1 that the L2 is created)
  Interactive installs (autounattend=none) can run this by hand from the CD as Administrator.
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path C:\qad | Out-Null
Start-Transcript -Path C:\qad\firstlogon.log -Append | Out-Null

$vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'QADSTAGE' } | Select-Object -First 1
if (-not $vol) { Write-Output 'QADSTAGE CD not found; nothing to do'; Stop-Transcript | Out-Null; exit 1 }
$S = "$($vol.DriveLetter):"
Write-Output "stage CD at $S"
Copy-Item -Path "$S\qad\*" -Destination C:\qad\ -Recurse -Force

# ---- 2. power
powercfg /hibernate off
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /setactive SCHEME_CURRENT

# ---- 3. OpenSSH
Get-NetConnectionProfile -ErrorAction SilentlyContinue | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
  try { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null }
  catch { Write-Output "OpenSSH capability not installable (offline?): $($_.Exception.Message)" }
  $svc = Get-Service sshd -ErrorAction SilentlyContinue
}
if (-not $svc) {
  $zip = Get-ChildItem C:\qad\openssh\*.zip -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($zip) {
    Expand-Archive -Path $zip.FullName -DestinationPath 'C:\Program Files' -Force
    $dir = Get-ChildItem 'C:\Program Files' -Directory -Filter 'OpenSSH*' | Select-Object -First 1
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir.FullName 'install-sshd.ps1')
    & (Join-Path $dir.FullName 'ssh-keygen.exe') -A
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
  } else {
    Write-Output 'no OpenSSH available (stage.openssh_zip not set): setup.sh verify cannot reach the L2'
  }
}
if ($svc) {
  Set-Service sshd -StartupType Automatic
  Start-Service sshd
  New-NetFirewallRule -Name 'qad-sshd' -DisplayName 'OpenSSH (qemu-ad-pve L1 link)' -Direction Inbound `
    -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
  New-Item -ItemType Directory -Force -Path C:\ProgramData\ssh | Out-Null
  $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
  Copy-Item C:\qad\authorized_keys $ak -Force
  # SIDs, so it works on any display language: Administrators, SYSTEM
  icacls $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
  Write-Output 'sshd running, key-only access for L1'
}

# ---- 4. Python + wheels (offline)
$py = Get-ChildItem C:\qad\python\python-*.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($py) {
  Start-Process -FilePath $py.FullName -Wait -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1',
    'Include_test=0', 'TargetDir=C:\qad\py'
}
$wh = "$S\wheelhouse"
if ((Test-Path C:\qad\py\python.exe) -and (Test-Path $wh)) {
  & C:\qad\py\python.exe -m venv C:\qad\venv
  $vpy = 'C:\qad\venv\Scripts\python.exe'
  if (Test-Path "$wh\requirements.txt") {
    & $vpy -m pip install --no-index --find-links $wh -r "$wh\requirements.txt"
  } elseif (Get-ChildItem "$wh\torch-*.whl" -ErrorAction SilentlyContinue) {
    & $vpy -m pip install --no-index --find-links $wh torch
  } else {
    & $vpy -m pip install --no-index --find-links $wh (Get-ChildItem "$wh\*.whl").FullName
  }
  Write-Output "pip exit $LASTEXITCODE"
}

# ---- 5. NVIDIA driver at the first boot with the GPU (the installer refuses without the device)
if (Get-ChildItem C:\qad\nvidia\*.exe -ErrorAction SilentlyContinue) {
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\qad\gpu-driver.ps1'
  $t = New-ScheduledTaskTrigger -AtStartup
  Register-ScheduledTask -TaskName 'qad-gpu-driver' -Action $a -Trigger $t -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  Write-Output 'scheduled task qad-gpu-driver registered'
}

Set-Content -Path C:\qad\firstlogon.done -Value (Get-Date -Format o)
Stop-Transcript | Out-Null
# ---- 6. power off: L1 treats the QEMU exit as "L2 created"
shutdown.exe /s /t 15 /c "qemu-ad-pve: L2 created; powering off"
