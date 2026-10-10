<#
  qemu-ad-pve setup: post-install hygiene in the L2 (run by `qad-l1.sh hygiene` over SSH after the first
  successful verify). Removes install residue that is not needed any more. Idempotent, prints HYGIENE_* lines.
    -Unattend 1  delete answer-file copies and Setup/Panther logs (may carry the admin account name and
                 an obfuscated password)
    -Staging 1   delete staged installers and one-shot first-boot scripts/logs from C:\qad
  Kept on purpose: sshd, the admin account + authorized_keys, C:\qad\venv, C:\qad\py, C:\qad\audit,
  C:\qad\pytorch-offline-bench.py (used by `setup.sh verify`).
#>
param([int]$Unattend = 1, [int]$Staging = 1)
$ErrorActionPreference = 'Continue'
function Remove-Hard([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return 0 }
  Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $p) {
    & takeown.exe /f $p /r /d y 2>&1 | Out-Null
    & icacls.exe $p /grant 'Administrators:F' /t /c 2>&1 | Out-Null
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $p) { Write-Output "HYGIENE_FAILED $p"; return 0 }
  return 1
}
$n = 0
if ($Unattend) {
  foreach ($f in 'C:\unattend.xml', 'C:\autounattend.xml', 'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend.xml',
                 'C:\Windows\System32\Sysprep\unattend.xml', 'C:\Windows\System32\sysprep\Panther\unattend.xml',
                 'C:\Windows\Panther\UnattendGC', 'C:\Windows\Panther\actionqueue') { $n += Remove-Hard $f }
  foreach ($d in 'C:\Windows\Panther', 'C:\Windows\System32\Sysprep\Panther') {
    if (Test-Path $d) { Get-ChildItem $d -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $n += Remove-Hard $_.FullName } }
  }
  Get-ChildItem C:\Windows -Recurse -Force -File -Include 'unattend*.xml', 'autounattend*.xml' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\WinSxS\\|\\servicing\\|\\System32\\(oobe|Sysprep\\ActionFiles)' } |
    ForEach-Object { $n += Remove-Hard $_.FullName }
  Write-Output "HYGIENE_UNATTEND removed=$n left=$(@(Get-ChildItem C:\Windows\Panther -Force -Recurse -ErrorAction SilentlyContinue).Count)"
}
if ($Staging) {
  $smi = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
  $task = Get-ScheduledTask -TaskName 'qad-gpu-driver' -ErrorAction SilentlyContinue
  $nvdir = Test-Path C:\qad\nvidia
  if ($task -or ($nvdir -and -not (Test-Path $smi))) {
    Write-Output 'HYGIENE_STAGING skipped (NVIDIA driver not installed yet / qad-gpu-driver task still registered)'
  } else {
    $m = 0
    foreach ($f in 'nvidia', 'python', 'openssh', 'firstlogon.ps1', 'firstlogon.log', 'firstlogon.done', 'gpu-driver.ps1', 'gpu-driver.log',
                   'w10-code43-check.ps1') { $m += Remove-Hard (Join-Path 'C:\qad' $f) }
    Get-ChildItem 'C:\Windows\Temp\dd_vcredist*' -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $m += Remove-Hard $_.FullName }
    Write-Output "HYGIENE_STAGING removed=$m left=$((Get-ChildItem C:\qad -Force -ErrorAction SilentlyContinue | ForEach-Object Name) -join ',')"
  }
}
Write-Output 'HYGIENE_DONE'
