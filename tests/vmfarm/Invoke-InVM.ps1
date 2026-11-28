<#
.SYNOPSIS
Run a test script inside a farm VM, on its INTERACTIVE desktop, and get the
output back.

.DESCRIPTION
Copies -Script (and any -CopyIn files) into a fresh work folder in the guest,
optionally copies a psmux build (-BinDir holding psmux.exe, tmux.exe, pmux.exe)
and puts it first on PATH, runs the script as the logged on desktop user
(elevated, Normal priority, a visible console), waits, prints its stdout and
stderr, copies the whole work folder back to the host and exits with the
script's exit code.

PowerShell Direct alone is a non interactive logon: windows it opens are not on
the desktop and console input injection does not work, so use this for any
suite that opens a window. Use -NoDesktop for plain CLI checks.

.EXAMPLE
.\Invoke-InVM.ps1 -VMName psmux-w10 -Script ..\test_issue1077_foo.ps1 -BinDir C:\work\mybuild\target\release

.EXAMPLE
# whole folder (a suite plus the helpers it dot sources)
.\Invoke-InVM.ps1 -VMName psmux-w10 -Script C:\x\run.ps1 -CopyIn C:\x\helpers -TimeoutSec 900
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$VMName,
    [Parameter(Mandatory)] [string]$Script,
    [string]$Arguments = '',
    [string[]]$CopyIn = @(),
    [string]$BinDir,
    [int]$TimeoutSec = 1800,
    [switch]$NoDesktop,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FarmCommon.ps1')

if ((Get-VM -Name $VMName).State -ne 'Running') { Start-VM -Name $VMName; Wait-FarmGuest -Name $VMName -TimeoutSec 600 | Out-Null }

$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$gwork = "C:\vmfarm-work\$id"
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "vmfarm-out\$VMName-$id" }

$s = New-FarmSession $VMName
try {
    Invoke-Command -Session $s -ArgumentList $gwork { param($w) New-Item -ItemType Directory -Force $w, "$w\bin" | Out-Null }
    $scriptItem = Get-Item $Script
    Copy-Item $scriptItem.FullName -Destination "$gwork\$($scriptItem.Name)" -ToSession $s
    foreach ($c in $CopyIn) { Copy-Item (Get-Item $c).FullName -Destination $gwork -ToSession $s -Recurse -Force }
    $envs = @{}
    if ($BinDir) {
        foreach ($b in 'psmux.exe', 'tmux.exe', 'pmux.exe') {
            $p = Join-Path $BinDir $b
            if (Test-Path $p) { Copy-Item $p -Destination "$gwork\bin\$b" -ToSession $s }
        }
        $envs['PSMUX_VMFARM_BIN'] = "$gwork\bin"
    }
    $gscript = "$gwork\$($scriptItem.Name)"

    if ($NoDesktop) {
        $code = Invoke-Command -Session $s -ArgumentList $gscript, $gwork, $Arguments, $BinDir -ScriptBlock {
            param($sc, $w, $a, $hasBin)
            if ($hasBin) { $env:Path = "$w\bin;" + $env:Path }
            Set-Location $w
            $cmd = "& pwsh -NoProfile -ExecutionPolicy Bypass -File '$sc' $a > '$w\out.log' 2> '$w\err.log'; `$LASTEXITCODE"
            Invoke-Expression $cmd
        }
    } else {
        if ($BinDir) {
            # Prepend the build dir inside the wrapper, after it resets PATH from the registry.
            $envs['PSMUX_VMFARM_PREPEND'] = "$gwork\bin"
        }
        $task = Start-FarmDesktopJob -Session $s -GuestScript $gscript -WorkDir $gwork -Arguments $Arguments -Environment $envs
        $code = Wait-FarmDesktopJob -Session $s -WorkDir $gwork -TaskName $task -TimeoutSec $TimeoutSec
        Invoke-Command -Session $s -ArgumentList $task { param($t) Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
        if ($null -eq $code) { Write-Warning "timed out after $TimeoutSec s; the guest process may still be running (task folder $gwork)" }
    }

    New-Item -ItemType Directory -Force $OutDir | Out-Null
    Copy-Item -FromSession $s -Path "$gwork\*" -Destination $OutDir -Recurse -Force -Exclude 'bin'
} finally { Remove-PSSession $s }

foreach ($f in 'out.log', 'err.log') {
    $p = Join-Path $OutDir $f
    if ((Test-Path $p) -and (Get-Item $p).Length -gt 0) { Write-Host "----- $f -----"; Get-Content $p }
}
Write-Host "----- exit code $code; files in $OutDir -----"
if ($null -eq $code) { exit 124 }
exit $code
