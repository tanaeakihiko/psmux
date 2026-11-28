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
# Windows 11 restarts Windows Update through WaaSMedic even with the service
# disabled, and Store app updates run beside it (measured after smoke run 3:
# wuauserv, DoSvc, InstallService and AppXSvc held 3 of 4 vCPUs on an idle
# shard). Point WU at a dead local server and stop Store auto updates.
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-Item "$wu\AU" -Force | Out-Null
Set-ItemProperty $wu -Name WUServer -Value 'http://127.0.0.1:9'
Set-ItemProperty $wu -Name WUStatusServer -Value 'http://127.0.0.1:9'
Set-ItemProperty $wu -Name DoNotConnectToWindowsUpdateInternetLocations -Value 1 -Type DWord
Set-ItemProperty "$wu\AU" -Name UseWUServer -Value 1 -Type DWord
Set-ItemProperty "$wu\AU" -Name NoAutoUpdate -Value 1 -Type DWord
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload -Value 2 -Type DWord
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name DODownloadMode -Value 99 -Type DWord
foreach ($svc in 'wuauserv', 'UsoSvc', 'DoSvc') { Stop-Service $svc -Force -ErrorAction SilentlyContinue }

# Finish the pending .NET Framework native image work now instead of mid sweep.
foreach ($ngen in "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\ngen.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\ngen.exe") {
    if (Test-Path $ngen) { & $ngen executeQueuedItems /nologo | Out-Null }
}
Write-Host 'tune done'
