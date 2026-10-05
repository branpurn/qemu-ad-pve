<#
  qemu-ad-pve setup: scheduled task (SYSTEM, at startup) registered by firstlogon.ps1.
  Installs the staged NVIDIA driver once the GPU is actually present (first boot under
  qemu-ad-l2.service), reboots once, then removes itself. Log: C:\qad\gpu-driver.log
  Silent flags (-s -noreboot -noeula -clean) are NVIDIA's documented installer switches;
  UNTESTED here.
#>
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\qad\gpu-driver.log -Append | Out-Null
$smi = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
$nv = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' -and $_.Class -eq 'Display' }
if (-not $nv) { Write-Output 'no NVIDIA display device present (yet); retry at next boot'; Stop-Transcript | Out-Null; exit 0 }
if (Test-Path $smi) {
  Write-Output 'NVIDIA driver already installed; removing task'
  Unregister-ScheduledTask -TaskName 'qad-gpu-driver' -Confirm:$false
  Stop-Transcript | Out-Null; exit 0
}
$exe = Get-ChildItem C:\qad\nvidia\*.exe | Select-Object -First 1
Write-Output "installing $($exe.FullName)"
$p = Start-Process -FilePath $exe.FullName -ArgumentList '-s', '-noreboot', '-noeula', '-clean' -Wait -PassThru
Write-Output "installer exit code $($p.ExitCode)"
if (Test-Path $smi) {
  Unregister-ScheduledTask -TaskName 'qad-gpu-driver' -Confirm:$false
  Stop-Transcript | Out-Null
  Restart-Computer -Force
}
Stop-Transcript | Out-Null
