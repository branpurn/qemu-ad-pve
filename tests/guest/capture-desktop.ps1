<#
.SYNOPSIS
  Capture the interactive desktop of a logged-in Windows guest user to a PNG, from a non-interactive
  remote session (e.g. SSH). A plain remote session cannot see the console desktop, so this runs the
  capture as a one-shot scheduled task in the user's interactive session, then removes the task.

.PARAMETER User
  The logged-in console user (DOMAIN\user or COMPUTER\user). Must have an active console session.
.PARAMETER OutDir
  Directory inside the guest to write desktop.png to. Default: $env:TEMP\desktop-capture.
#>
param(
    [Parameter(Mandatory)][string]$User,
    [string]$OutDir = (Join-Path $env:TEMP 'desktop-capture')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$png = Join-Path $OutDir 'desktop.png'
Remove-Item $png -ErrorAction SilentlyContinue

$inner = @"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
`$b=[Windows.Forms.SystemInformation]::VirtualScreen
`$bmp=New-Object Drawing.Bitmap `$b.Width,`$b.Height
`$g=[Drawing.Graphics]::FromImage(`$bmp); `$g.CopyFromScreen(`$b.Left,`$b.Top,0,0,`$bmp.Size)
`$bmp.Save('$png',[Drawing.Imaging.ImageFormat]::Png)
"@
$script = Join-Path $OutDir 'cap.ps1'
Set-Content -Path $script -Value $inner

$name = 'desktop-capture-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$act  = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$pri  = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive
try {
    Register-ScheduledTask -TaskName $name -Action $act -Principal $pri -Force | Out-Null
    Start-ScheduledTask -TaskName $name
    for ($i = 0; $i -lt 20 -and -not (Test-Path $png); $i++) { Start-Sleep -Milliseconds 500 }
} finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
if (Test-Path $png) { Write-Output $png } else { Write-Error 'capture failed (is the user logged in at the console?)'; exit 1 }
