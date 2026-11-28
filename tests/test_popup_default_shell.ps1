# display-popup runs its command through default-shell, as tmux does.
#
# tmux runs a popup command as a job through default-shell (popup.c job_run
# with the session's default-shell), and an empty popup opens default-shell.
# psmux hardcoded `pwsh -NoProfile -Command <cmd>` for a popup command string
# and opened the SHELL/pwsh walk for an empty popup, whatever default-shell
# said. With default-shell unset a popup keeps exactly today's pwsh.
#
# The probe writes to a file which shell ran it:
#   echo PROBE $PSVersionTable.PSVersion %OS% $0 > <file>
#   pwsh: PROBE / version table / %OS% / $0 on separate lines
#   cmd:  PROBE $PSVersionTable.PSVersion Windows_NT $0
#   bash: PROBE .PSVersion %OS% /usr/bin/bash
#
# Cases (SHELL unset for A to E):
#   A  default-shell unset    -E probe          -> pwsh   (unchanged)
#   B  default-shell cmd      -E probe          -> cmd
#   C  default-shell Git Bash -E probe          -> bash   (SKIP without Git)
#   D  default-shell cmd      empty popup       -> cmd.exe is the popup's process
#   E  default-shell unset    empty popup       -> pwsh is the popup's process
#   F  SHELL=Git Bash, default-shell unset -E probe -> bash (tmux: default-shell
#      defaults to $SHELL; same as a pane command)
#   G  SHELL=Git Bash, default-shell cmd -E probe   -> cmd (default-shell wins)
#
# Needs a real client: one attached in a conhost window. Safety: unique -L
# namespace and PSMUX_DATA_DIR; cleanup with `-L <ns> kill-server` and by
# recorded PID only. Honours PSMUX_TEST_BIN.
$ErrorActionPreference = 'Continue'
$env:PSMUX_RUN_NOPAUSE = '1'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skipped++ }

foreach ($v in 'PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') { Remove-Item "env:$v" -EA SilentlyContinue }
$origShell = $env:SHELL
[Environment]::SetEnvironmentVariable('SHELL', $null, 'Process')
$origData = $env:PSMUX_DATA_DIR
$work = Join-Path $env:TEMP ('psmux_popsh_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $work 'data'
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$NS = ''
$S = 'ps'
$started = New-Object System.Collections.Generic.List[int]
$cmdExe = "$env:SystemRoot\System32\cmd.exe"
$bash = 'C:\Program Files\Git\bin\bash.exe'

function Get-ShellOf([string]$t) {
    if ($t -match '(?m)^PROBE\s*\r?\n') { return 'pwsh' }
    if ($t -match 'PROBE \S*PSVersion\S* Windows_NT') { return 'cmd' }
    if ($t -match 'PROBE \S*PSVersion %OS% \S*bash') { return 'bash' }
    return "unknown[$($t.Trim())]"
}
function Get-PopupActive { ((& $PSMUX -L $NS dump-state -t $S 2>&1 | Out-String) -match '"popup_active":true') }
function Wait-PopupActive([bool]$Want, [int]$Ms = 8000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) { if ((Get-PopupActive) -eq $Want) { return $true }; Start-Sleep -Milliseconds 100 }
    return $false
}
function Get-Descendants([int]$root) {
    $all = @(Get-CimInstance Win32_Process -EA SilentlyContinue)
    $out = @(); $q = @($root)
    while ($q.Count) {
        $p = $q[0]; $q = @($q | Select-Object -Skip 1)
        foreach ($c in $all | Where-Object { $_.ParentProcessId -eq $p }) { $out += $c; $q += [int]$c.ProcessId }
    }
    return $out
}

function Test-Probe([string]$label, [string]$want) {
    $f = Join-Path $work ("probe-" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $cmd = "echo PROBE `$PSVersionTable.PSVersion %OS% `$0 > `"$f`""
    & $PSMUX -L $NS display-popup -t $S -E $cmd 2>&1 | Out-Null
    for ($i = 0; $i -lt 60 -and -not (Test-Path $f); $i++) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 300
    $t = if (Test-Path $f) { Get-Content $f -Raw } else { '' }
    $got = Get-ShellOf $t
    if ($got -eq $want) { Write-Pass "${label}: the popup command ran in $got" }
    else { Write-Fail "${label}: the popup command ran in $got, want $want" }
    if (-not (Wait-PopupActive $false 3000)) { & $PSMUX -L $NS display-popup -t $S -C 2>&1 | Out-Null }
}

function Test-Empty([string]$label, [string]$wantImage) {
    # A default-shell change makes the warm pool start a spare of the new
    # shell; let that settle, then count only processes that appear once the
    # popup opens.
    Start-Sleep -Seconds 4
    $known = @{}
    foreach ($d in Get-Descendants $script:serverPid) { $known[[int]$d.ProcessId] = $true }
    $p = Start-Process -FilePath $PSMUX -ArgumentList "-L $NS display-popup -t $S" -WindowStyle Hidden -PassThru
    $started.Add($p.Id)
    if (-not (Wait-PopupActive $true)) { Write-Fail "${label}: the popup did not open"; return }
    Start-Sleep -Seconds 2
    $names = @(Get-Descendants $script:serverPid | Where-Object { -not $known.ContainsKey([int]$_.ProcessId) } | ForEach-Object { $_.Name.ToLower() })
    & $PSMUX -L $NS display-popup -t $S -C 2>&1 | Out-Null
    [void](Wait-PopupActive $false 3000)
    if ($names -contains $wantImage) { Write-Pass "${label}: the empty popup runs $wantImage" }
    else { Write-Fail "${label}: the empty popup runs [$($names -join ', ')], want $wantImage" }
}

$namespaces = New-Object System.Collections.Generic.List[string]
# Start a server (SHELL as given, read at server start), attach a client.
function Start-Server([string]$shellVar) {
    if ($shellVar) { $env:SHELL = $shellVar } else { [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process') }
    $script:NS = 'popsh_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $namespaces.Add($script:NS)
    & $PSMUX -L $NS new-session -d -s $S -x 140 -y 40 2>&1 | Out-Null
    for ($i = 0; $i -lt 40; $i++) { & $PSMUX -L $NS has-session -t $S 2>$null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 250 }
    $script:serverPid = [int](Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" | Where-Object { $_.CommandLine -match "server -s $S -L $($script:NS)" } | Select-Object -First 1).ProcessId
    [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process')
    $con = Start-Process conhost.exe -ArgumentList "`"$PSMUX`" -L $($script:NS) attach -t $S" -PassThru
    $started.Add($con.Id)
    $attached = $false
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        if ((& $PSMUX -L $NS display-message -t $S -p '#{session_attached}' 2>&1 | Out-String).Trim() -eq '1') { $attached = $true; break }
    }
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($con.Id)" -EA SilentlyContinue)) { $started.Add([int]$c.ProcessId) }
    return $attached
}

try {
    if (-not (Start-Server '')) { Write-Fail 'no client attached'; return }

    Write-Host "`n=== popup commands follow default-shell (SHELL unset) ===" -ForegroundColor Cyan
    Test-Probe 'A SHELL and default-shell unset' 'pwsh'
    & $PSMUX -L $NS set -g default-shell $cmdExe | Out-Null
    Test-Probe 'B default-shell cmd' 'cmd'
    if (Test-Path $bash) {
        & $PSMUX -L $NS set -g default-shell $bash | Out-Null
        Test-Probe 'C default-shell Git Bash' 'bash'
    } else { Write-Skip 'C: Git Bash not installed' }

    Write-Host "`n=== an empty popup opens default-shell ===" -ForegroundColor Cyan
    & $PSMUX -L $NS set -g default-shell $cmdExe | Out-Null
    Test-Empty 'D default-shell cmd' 'cmd.exe'
    & $PSMUX -L $NS set -gu default-shell | Out-Null
    $shown = (& $PSMUX -L $NS show -gv default-shell 2>&1 | Out-String).Trim()
    $wantImg = ([IO.Path]::GetFileName($shown)).ToLower()
    if (-not $wantImg.EndsWith('.exe')) { $wantImg += '.exe' }
    Test-Empty "E default-shell unset (shows $shown)" $wantImg

    # tmux's default-shell defaults to $SHELL: with SHELL set and no
    # default-shell a popup command runs through SHELL, like a pane command.
    Write-Host "`n=== F: SHELL set, default-shell unset ===" -ForegroundColor Cyan
    if (Test-Path $bash) {
        & $PSMUX -L $NS kill-server 2>&1 | Out-Null
        if (-not (Start-Server $bash)) { Write-Fail 'F: no client attached' }
        else {
            Test-Probe 'F SHELL=Git Bash, default-shell unset' 'bash'
            & $PSMUX -L $NS set -g default-shell $cmdExe | Out-Null
            Test-Probe 'G SHELL=Git Bash, default-shell cmd wins' 'cmd'
        }
    } else { Write-Skip 'F and G: Git Bash not installed' }
} finally {
    foreach ($n in $namespaces) { & $PSMUX -L $n kill-server 2>&1 | Out-Null }
    foreach ($p in $started) { Stop-Process -Id $p -Force -EA SilentlyContinue }
    if ($null -eq $origShell) { [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process') } else { $env:SHELL = $origShell }
    $env:PSMUX_DATA_DIR = $origData
    Remove-Item -Recurse -Force $work -EA SilentlyContinue
}
Write-Host "`nResults: $script:Passed passed, $script:Failed failed, $script:Skipped skipped"
if ($script:Failed -gt 0) { exit 1 }
exit 0
