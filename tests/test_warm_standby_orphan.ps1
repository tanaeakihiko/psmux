# Warm standby lifetime when the server that spawned it dies.
#
# Every psmux server keeps one unclaimed `server -s __warm__ --spawner <pid>`
# standby per namespace so the next new-session is instant. This suite asks
# what happens to that standby, and the shell it holds, when the namespace's
# last real server goes away:
#
#   S1  kill-server of the namespace                 (the documented way)
#   S2  kill-session of the last session             (server exits by itself)
#   S3  the last session's shell exits               (server exits by itself)
#   S4  taskkill /F of the last server, by PID        (a crash, or a suite that
#                                                      stops what it started)
#   S5  taskkill /F of the server AND its client      (closing a terminal whose
#                                                      server then crashes)
#   S6  S4 with two sessions, killing only one       (the standby must stay:
#                                                      a live server still owns it)
#
# Counting is by IDENTITY, not by command line: a CLAIMED standby keeps
# `-s __warm__` in its argv forever (#459), so a process is the unclaimed
# standby only when `<ns>____warm__.pid` names it, and it is an orphan only
# when no other server registered in that namespace is alive.
#
# Isolation: own -L namespace per scenario, own PSMUX_DATA_DIR that is NOT
# deleted while measuring (a deleted data dir ends a standby by design, which
# would hide the case under test). Every process is ended by PID. Meant for a
# disposable VM; it runs only the binary named by PSMUX_TEST_BIN.
#
# Run: pwsh -NoProfile -File tests\test_warm_standby_orphan.ps1 [-WaitSeconds 60]

param([int]$WaitSeconds = 60, [string]$Only = '.', [switch]$WarmDebug)
$ErrorActionPreference = 'Continue'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$PSMUX = (Resolve-Path $PSMUX).Path
$script:TestsPassed = 0; $script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_SESSION', 'PSMUX_PANE', 'TMUX', 'TMUX_PANE', 'PSMUX_NO_WARM') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$root = Join-Path $env:TEMP "psmux_warmorphan_$(Get-Random)"
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = $root
$env:PSMUX_RUN_NOPAUSE = '1'
$warmLog = Join-Path $env:TEMP 'psmux_warm_debug.log'
if ($WarmDebug) { $env:PSMUX_WARM_DEBUG = '1'; Remove-Item $warmLog -EA SilentlyContinue }
$conf = Join-Path $root 'empty.conf'; [IO.File]::WriteAllText($conf, '')
$script:Started = @()

# Every process of this binary in namespace $ns, with what the registry says it is.
function Get-NsProcs($ns) {
    # $ns '' is the default namespace: bare `<session>.pid` files, no -L.
    $reg = @{}
    foreach ($f in Get-ChildItem $root -Filter "*.pid" -EA SilentlyContinue) {
        $name = $f.BaseName
        if ($ns) { if (-not $name.StartsWith("${ns}__")) { continue }; $name = $name.Substring($ns.Length + 2) }
        elseif ($name -match '__' -and $name -ne '__warm__') { continue }
        $body = (Get-Content $f.FullName -EA SilentlyContinue | Select-Object -First 1)
        if ($body -match '^(\d+)') { $reg[[int]$Matches[1]] = $name }
    }
    @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" | Where-Object {
        $_.ExecutablePath -eq $PSMUX -and $_.CommandLine -match " server " -and
        $(if ($ns) { $_.CommandLine -match "-L $([regex]::Escape($ns))( |$)" } else { $_.CommandLine -notmatch ' -L ' })
    } | ForEach-Object {
        $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($_.ProcessId)" | Where-Object { $_.Name -ne 'conhost.exe' -and $_.Name -ne 'OpenConsole.exe' })
        [pscustomobject]@{ Pid = $_.ProcessId; Session = $reg[[int]$_.ProcessId]; Shells = $kids.Count; ShellPids = @($kids.ProcessId) }
    })
}
function Get-Standby($ns) { @(Get-NsProcs $ns | Where-Object { $_.Session -eq '__warm__' }) }
function Get-RealServers($ns) { @(Get-NsProcs $ns | Where-Object { $_.Session -and $_.Session -ne '__warm__' }) }

function Invoke-Ns($ns) { if ($ns) { & $PSMUX -L $ns @args } else { & $PSMUX @args } }
function Wait-Standby($ns, $ms = 15000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { $s = Get-Standby $ns; if ($s.Count -ge 1 -and $s[0].Shells -ge 1) { return $s[0] }; Start-Sleep -Milliseconds 250 }
    $null
}
function New-Session($ns, $name) {
    Invoke-Ns $ns -f $conf new-session -d -s $name 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 10000) { Invoke-Ns $ns has-session -t $name 2>$null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 100 }
    (Get-RealServers $ns | Where-Object { $_.Session -eq $name } | Select-Object -First 1)
}
# How long the standby (and its shells) outlive the namespace's last server.
function Watch-Standby($ns, $standby, $label) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $gone = $null
    while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds) {
        if (-not (Get-Process -Id $standby.Pid -EA SilentlyContinue)) { $gone = $sw.Elapsed.TotalSeconds; break }
        Start-Sleep -Milliseconds 250
    }
    $shellsLeft = @($standby.ShellPids | Where-Object { Get-Process -Id $_ -EA SilentlyContinue }).Count
    $real = (Get-RealServers $ns).Count
    if ($null -ne $gone -and $shellsLeft -eq 0) { Write-Pass "${label}: the standby (pid $($standby.Pid)) exited after $([Math]::Round($gone, 1)) s, its shells too" }
    else { Write-Fail "${label}: the standby (pid $($standby.Pid)) is $(if ($null -eq $gone) { "still alive after $WaitSeconds s" } else { "gone, but $shellsLeft shell(s) remain" }), live real servers in the namespace: $real, shells it holds: $shellsLeft" }
}
function Stop-Ns($ns) {
    Invoke-Ns $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    foreach ($p in Get-NsProcs $ns) { foreach ($s in $p.ShellPids) { Stop-Process -Id $s -Force -EA SilentlyContinue }; Stop-Process -Id $p.Pid -Force -EA SilentlyContinue }
}

try {
    Write-Host "`n=== Warm standby lifetime after its namespace's last server ends ===" -ForegroundColor Cyan
    Write-Host "  binary $PSMUX, waiting up to $WaitSeconds s per scenario"

    $scen = @(
        @('S1 kill-server', { param($ns, $srv) Invoke-Ns $ns kill-server 2>&1 | Out-Null }),
        @('S2 kill-session of the last session', { param($ns, $srv) Invoke-Ns $ns kill-session -t a 2>&1 | Out-Null }),
        @('S3 the last shell exits', { param($ns, $srv) Invoke-Ns $ns send-keys -t a 'exit' Enter 2>&1 | Out-Null }),
        @('S4 taskkill /F of the last server', { param($ns, $srv) & taskkill /F /PID $srv.Pid 2>&1 | Out-Null }),
        @('S4d taskkill /F of the last server, default namespace', { param($ns, $srv) & taskkill /F /PID $srv.Pid 2>&1 | Out-Null })
    )
    foreach ($s in $scen) {
        if ($s[0] -notmatch $Only) { continue }
        Write-Host "  t=$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"
        $ns = if ($s[0] -like 'S4d*') { '' } else { "wo$(Get-Random)" }
        Write-Host "`n[$($s[0])]  -L $ns" -ForegroundColor Yellow
        $srv = New-Session $ns 'a'
        $sb = Wait-Standby $ns
        if (-not $srv -or -not $sb) { Write-Fail "$($s[0]): setup (server $([bool]$srv), standby $([bool]$sb))"; Stop-Ns $ns; continue }
        Write-Host "  server pid $($srv.Pid), standby pid $($sb.Pid) holding $($sb.Shells) shell(s)"
        & $s[1] $ns $srv
        Watch-Standby $ns $sb $s[0]
        Stop-Ns $ns
    }

    # S5: an attached client in its own console, then both die abruptly.
    if ('S5' -match $Only) {
    $ns = "wo$(Get-Random)"
    Write-Host "`n[S5 taskkill /F of the client and the server]  -L $ns" -ForegroundColor Yellow
    $client = Start-Process -FilePath $PSMUX -PassThru -ArgumentList @('-L', $ns, '-f', $conf, 'new-session', '-s', 'a')
    $sw = [Diagnostics.Stopwatch]::StartNew(); $srv = $null
    while ($sw.ElapsedMilliseconds -lt 15000 -and -not $srv) { $srv = Get-RealServers $ns | Select-Object -First 1; Start-Sleep -Milliseconds 200 }
    $sb = Wait-Standby $ns
    if (-not $srv -or -not $sb) { Write-Fail "S5: setup (server $([bool]$srv), standby $([bool]$sb))" }
    else {
        & taskkill /F /PID $client.Id 2>&1 | Out-Null
        & taskkill /F /PID $srv.Pid 2>&1 | Out-Null
        Watch-Standby $ns $sb 'S5 client and server killed'
    }
    Stop-Ns $ns

    }
    # S6: two sessions, the spawner dies but another server still lives.
    if ('S6' -match $Only) {
    $ns = "wo$(Get-Random)"
    Write-Host "`n[S6 one of two servers killed]  -L $ns" -ForegroundColor Yellow
    $a = New-Session $ns 'a'
    $null = Wait-Standby $ns
    $b = New-Session $ns 'b'
    Start-Sleep -Seconds 2
    $sb = Wait-Standby $ns
    $spawner = if ($sb) { (Get-CimInstance Win32_Process -Filter "ProcessId=$($sb.Pid)").CommandLine -replace '^.*--spawner (\d+).*$', '$1' }
    $victim = @($a, $b) | Where-Object { $_ -and "$($_.Pid)" -eq "$spawner" } | Select-Object -First 1
    if (-not $sb -or -not $victim) { Write-Fail "S6: setup (standby $([bool]$sb), spawner among the sessions $([bool]$victim))" }
    else {
        & taskkill /F /PID $victim.Pid 2>&1 | Out-Null
        Start-Sleep -Seconds ([Math]::Min(10, $WaitSeconds))
        $still = [bool](Get-Process -Id $sb.Pid -EA SilentlyContinue)
        $standbyNow = Get-Standby $ns
        if ($standbyNow.Count -eq 1) { Write-Pass "S6: the namespace still has exactly one standby while a server lives (pid $($standbyNow[0].Pid), original kept: $still)" }
        else { Write-Fail "S6: want one standby while server '$(if ($victim -eq $a) { 'b' } else { 'a' })' lives, have $($standbyNow.Count)" }
    }
    Stop-Ns $ns
    }
    # S7: kill-session of the last session and an immediate new-session. The
    # standby that is about to retire must either be claimed or step aside so
    # the new session cold starts: the new session must always come up.
    if ('S7' -match $Only) {
    $ns = "wo$(Get-Random)"
    Write-Host "`n[S7 kill the last session, then new-session at once, 10 rounds]  -L $ns" -ForegroundColor Yellow
    $cur = 'r0'
    $null = New-Session $ns $cur
    $null = Wait-Standby $ns
    $ok = 0; $bad = @()
    for ($i = 1; $i -le 10; $i++) {
        $next = "r$i"
        Invoke-Ns $ns kill-session -t $cur 2>&1 | Out-Null
        Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum 400)
        $o = Invoke-Ns $ns -f $conf new-session -d -s $next 2>&1 | Out-String
        Invoke-Ns $ns has-session -t $next 2>$null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $bad += "round ${i}: $($o.Trim())" }
        $cur = $next
        Start-Sleep -Milliseconds 300
    }
    if ($ok -eq 10) { Write-Pass "S7: 10 of 10 new sessions came up right after the last one was killed" }
    else { Write-Fail "S7: $ok of 10 new sessions came up; $($bad -join '; ')" }
    Start-Sleep -Seconds 3
    $sb = Get-Standby $ns
    if ($sb.Count -le 1) { Write-Pass "S7: at most one standby afterwards ($($sb.Count))" } else { Write-Fail "S7: $($sb.Count) standbys afterwards" }
    Stop-Ns $ns
    }

    # S8: exit-empty off keeps the empty server (tmux keeps it running).
    if ('S8' -match $Only) {
    $ns = "wo$(Get-Random)"
    Write-Host "`n[S8 exit-empty off, last session killed]  -L $ns" -ForegroundColor Yellow
    $c8 = Join-Path $root 's8.conf'; [IO.File]::WriteAllText($c8, "set -s exit-empty off`n")
    Invoke-Ns $ns -f $c8 new-session -d -s a 2>&1 | Out-Null
    $sb = Wait-Standby $ns
    if (-not $sb) { Write-Fail "S8: setup (no standby)" }
    else {
        Invoke-Ns $ns kill-session -t a 2>&1 | Out-Null
        Start-Sleep -Seconds ([Math]::Min(10, $WaitSeconds))
        if (Get-Process -Id $sb.Pid -EA SilentlyContinue) { Write-Pass "S8: with exit-empty off the standby stays as the empty server" }
        else { Write-Fail "S8: with exit-empty off the standby exited" }
    }
    Stop-Ns $ns
    }
}
finally {
    if ($WarmDebug -and (Test-Path $warmLog)) { Copy-Item $warmLog (Join-Path $PSScriptRoot 'psmux_warm_debug.log') -Force }
    Start-Sleep -Milliseconds 500
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" | Where-Object { $_.ExecutablePath -eq $PSMUX }) {
        foreach ($k in Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.ProcessId)") { Stop-Process -Id $k.ProcessId -Force -EA SilentlyContinue }
        Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue
    }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
