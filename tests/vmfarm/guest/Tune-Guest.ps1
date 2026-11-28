# Runs INSIDE a farm VM (elevated). Removes background work that skews suite
# timings. Measured on the first Windows 11 smoke run: suites took 1.0x to 9.4x
# their host time (3.1x in total) and MsMpEng had 1300 s of CPU, because every
# pwsh start (hundreds per suite) is scanned from Program Files, which the first
# exclusions did not cover.
$ErrorActionPreference = 'Continue'
$paths = @('C:\psmux', 'C:\vmfarm-work', 'C:\Program Files\PowerShell', 'C:\Program Files\Git',
           'C:\Python314', 'C:\Program Files\nodejs', "$env:USERPROFILE\.psmux", "$env:USERPROFILE\.psmux-test-data",
           "$env:LOCALAPPDATA\Temp")
$procs = @('pwsh.exe', 'powershell.exe', 'psmux.exe', 'tmux.exe', 'pmux.exe', 'conhost.exe', 'OpenConsole.exe',
           'cmd.exe', 'bash.exe', 'git.exe', 'python.exe', 'nvim.exe', 'node.exe', 'csc.exe', 'ssh.exe', 'sshd.exe')
foreach ($p in $paths) { try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop } catch { Write-Host "path $p : $_" } }
foreach ($p in $procs) { try { Add-MpPreference -ExclusionProcess $p -ErrorAction Stop } catch { Write-Host "proc $p : $_" } }
# No scheduled or catch up scans during a sweep (8 = never).
try { Set-MpPreference -ScanScheduleDay 8 -DisableCatchupFullScan $true -DisableCatchupQuickScan $true -ErrorAction Stop } catch { Write-Host "scan schedule: $_" }
# Search indexer and SysMain prefetching only add disk and CPU noise here.
foreach ($svc in 'WSearch', 'SysMain') {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue
}
# Finish the pending .NET Framework native image work now instead of mid sweep.
foreach ($ngen in "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\ngen.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\ngen.exe") {
    if (Test-Path $ngen) { & $ngen executeQueuedItems /nologo | Out-Null }
}
Write-Host 'tune done'
