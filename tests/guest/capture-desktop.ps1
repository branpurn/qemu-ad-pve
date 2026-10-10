<#
.SYNOPSIS
  Capture the interactive desktop of a logged-in Windows guest user to a PNG, from a non-interactive
  remote session (e.g. SSH). A plain remote session cannot see the console desktop, so this runs the
  capture as a one-shot scheduled task in the user's interactive session, then removes the task.

.DESCRIPTION
  Guest changes made by this script:
    - creates OutDir if missing and writes a helper script (cap.ps1) and the capture (desktop.png) there;
      the helper script is deleted afterwards, the PNG is kept;
    - registers, runs and unregisters a one-shot scheduled task that launches
      powershell.exe with -ExecutionPolicy Bypass for that helper script only.
  Prints the PNG path on success (only once the PNG is fully written and readable), exits 1 otherwise.

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
$tmp = Join-Path $OutDir 'desktop.tmp'
$script = Join-Path $OutDir 'cap.ps1'
Remove-Item $png, $tmp -ErrorAction SilentlyContinue

# Paths are embedded as single-quoted PowerShell literals with any ' doubled, so quotes in -OutDir are safe.
$tmpLit = $tmp.Replace("'", "''")
$pngLit = $png.Replace("'", "''")
$inner = @"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
`$b=[Windows.Forms.SystemInformation]::VirtualScreen
`$bmp=New-Object Drawing.Bitmap `$b.Width,`$b.Height
`$g=[Drawing.Graphics]::FromImage(`$bmp); `$g.CopyFromScreen(`$b.Left,`$b.Top,0,0,`$bmp.Size)
`$g.Dispose()
`$bmp.Save('$tmpLit',[Drawing.Imaging.ImageFormat]::Png)
`$bmp.Dispose()
Move-Item -Force '$tmpLit' '$pngLit'
"@
Set-Content -Path $script -Value $inner

$name = 'desktop-capture-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$scriptArg = $script.Replace('"', '')
$act = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptArg`""
$pri = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive
try {
    Register-ScheduledTask -TaskName $name -Action $act -Principal $pri -Force | Out-Null
    Start-ScheduledTask -TaskName $name
    # The helper writes to a temp name and renames when done, so existence of the PNG means it is complete.
    for ($i = 0; $i -lt 30 -and -not (Test-Path $png); $i++) { Start-Sleep -Milliseconds 500 }
} finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $script, $tmp -ErrorAction SilentlyContinue
}
if (Test-Path $png) { Write-Output $png } else { Write-Error 'capture failed (is the user logged in at the console?)'; exit 1 }
