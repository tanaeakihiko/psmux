# Runs INSIDE a farm VM (elevated, through PowerShell Direct). Installs the
# external tools the suites use from installers the host already copied to
# $InstallerDir. Every installer was verified on the host (Authenticode or the
# publisher's SHA256) before it was copied in; nothing here downloads, except
# the optional OpenSSH Server capability, which comes from Windows Update.
param(
    [string]$InstallerDir = 'C:\vmfarm-installers',
    [switch]$SkipSshServer
)
$ErrorActionPreference = 'Stop'
$log = 'C:\vmfarm-install.log'
function Note($m) { $l = "[{0}] {1}" -f (Get-Date -Format s), $m; Add-Content -Path $log -Value $l; Write-Host $l }

trap { Note "tools FAILED: $_"; exit 1 }

function Add-MachinePath([string]$dir) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($p -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', ($dir + ';' + $p), 'Machine')
    }
}
function Run([string]$exe, [string[]]$argv) {
    $p = Start-Process -FilePath $exe -ArgumentList $argv -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "$exe $($argv -join ' ') exited $($p.ExitCode)" }
}
function Find([string]$pattern) {
    $f = Get-ChildItem -Path $InstallerDir -Filter $pattern -File | Select-Object -First 1
    if (-not $f) { Note "SKIP no installer matching $pattern" }
    return $f
}

# PowerShell 7 (zip: the project ships no MSI for 7.7).
if ($f = Find 'PowerShell-*-win-x64.zip') {
    $dest = 'C:\Program Files\PowerShell\7'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $f.FullName -DestinationPath $dest -Force
    Add-MachinePath $dest
    Note "pwsh $((Get-Item "$dest\pwsh.exe").VersionInfo.ProductVersion)"
}
# Git for Windows (Git Bash, ssh, less, perl).
if ((-not (Test-Path 'C:\Program Files\Git\cmd\git.exe')) -and ($f = Find 'Git-*-64-bit.exe')) {
    Run $f.FullName @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES', '/CLOSEAPPLICATIONS')
    Note "git $((Get-Item 'C:\Program Files\Git\cmd\git.exe').VersionInfo.ProductVersion)"
}
# Python, at the same path the dev box uses.
if ($f = Find 'python-*-amd64.exe') {
    $ver = ($f.BaseName -replace '^python-', '' -replace '-amd64$', '').Split('.')
    $target = "C:\Python$($ver[0])$($ver[1])"
    # Re-running the bundle over an existing install fails (1601) under SYSTEM.
    if (Test-Path "$target\python.exe") { Note "python already in $target" } else {
    Run $f.FullName @('/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0', "TargetDir=$target")
    Note "python in $target" }
}
# Visual C++ 2015 to 2022 runtime: nvim and other tools die with
# STATUS_DLL_NOT_FOUND (0xC0000135) without vcruntime140_1.dll, and a fresh
# eval image does not have it. Use the full redistributable from
# aka.ms/vs/17/release/vc_redist.x64.exe; a stripped Package Cache copy fails.
if ($f = Find 'vc_redist.x64.exe') {
    Run $f.FullName @('/install', '/quiet', '/norestart')
    Note "vc runtime $((Get-Item $f.FullName).VersionInfo.ProductVersion)"
}
foreach ($msi in 'nvim-win64.msi', 'node-v*-x64.msi', 'Alacritty-*-installer.msi') {
    if ($f = Find $msi) { Run 'msiexec.exe' @('/i', "`"$($f.FullName)`"", '/qn', '/norestart'); Note "installed $($f.Name)" }
}
Add-MachinePath 'C:\Program Files\Neovim\bin'
Add-MachinePath 'C:\Program Files\Alacritty\'
if ($f = Find 'WezTerm-*-setup.exe') {
    Run $f.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')
    Add-MachinePath 'C:\Program Files\WezTerm'
    Note "installed $($f.Name)"
}

if (-not $SkipSshServer) {
    # Features on Demand come through the Windows Update service, which
    # firstlogon.ps1 disabled; enable it only for this, then disable it again.
    $wu = Get-Service wuauserv
    try {
        Set-Service wuauserv -StartupType Manual; Start-Service wuauserv
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
        Set-Service sshd -StartupType Automatic
        Start-Service sshd
        Note 'sshd installed and running'
    } catch { Note "sshd not installed: $_" }
    finally {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

Note 'tools done'
