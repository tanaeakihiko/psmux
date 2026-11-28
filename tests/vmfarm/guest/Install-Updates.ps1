# Runs INSIDE a farm VM as SYSTEM (a scheduled task: the Windows Update agent
# refuses to download for a remote or PowerShell Direct logon). Installs every
# pending software update through the Windows Update agent, then writes
# C:\vmfarm-wu.done with "reboot" or "done". The caller reboots and runs it
# again until it says "done".
#
# Why the farm patches at all: the RTM Windows 10 22H2 image (19045.2006) is
# too old for .NET 11, and PowerShell 7.7 dies at start with "Your Windows
# doesn't fully support CET. Please install all available Windows updates."
$ErrorActionPreference = 'Stop'
$log = 'C:\vmfarm-wu.log'
function Note($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format s), $m) }
Remove-Item C:\vmfarm-wu.done -ErrorAction SilentlyContinue
try {
    Set-Service wuauserv -StartupType Manual
    Start-Service wuauserv
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Note 'searching'
    $res = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    $todo = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $res.Updates) {
        # Feature updates (a new Windows version) would leave 22H2; skip them.
        if ($u.Title -match 'Feature update|Upgrade to Windows') { Note "skip $($u.Title)"; continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$todo.Add($u)
        Note "queue $($u.Title)"
    }
    if ($todo.Count -eq 0) { Note 'nothing to install'; Set-Content C:\vmfarm-wu.done 'done'; return }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $todo
    Note 'downloading'; $r = $dl.Download(); Note "download result $($r.ResultCode)"
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $todo
    Note 'installing'; $r = $inst.Install(); Note "install result $($r.ResultCode) reboot $($r.RebootRequired)"
    Set-Content C:\vmfarm-wu.done $(if ($r.RebootRequired) { 'reboot' } else { 'again' })
} catch {
    Note "error: $_"
    Set-Content C:\vmfarm-wu.done "error: $_"
} finally {
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
}
