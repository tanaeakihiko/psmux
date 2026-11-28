# Issue #1115: the `cat` placeholder pane dies when SHELL is Git Bash.
#
# Claude Code's agent teams create each teammate pane as
#   split-window -d ... -- cat
# then set remain-on-exit failed and `respawn-pane -k` it with the real
# command. psmux replaces `cat` with a blocker (#580), but the blocker was
# PowerShell code run through the pane shell, so with SHELL=Git Bash the pane
# died at once:
#   /usr/bin/bash: -c: line 1: syntax error near unexpected token `-ge'
# and with SHELL=cmd.exe:
#   '$__psmux_in' is not recognized as an internal or external command
# The respawn then failed with "can't find pane".
#
# Arms, for each shell (SHELL unset = default pwsh, Git bin\bash.exe,
# Git usr\bin\bash.exe, cmd.exe; a Git shell that is not installed is a SKIP):
#   1. split-window -d -- cat: the pane is still alive after it had time to die
#      (polled, Git Bash is slow to start) and shows no shell error
#   2. split-window -d -- cat - : same
#   3. split-window -d cat (string form): same
#   4. typed input does not end the blocker
#   5. respawn-pane -k replaces the placeholder with the real command
#
# Isolation: own -L namespace and PSMUX_DATA_DIR per shell; honours
# PSMUX_TEST_BIN. Kills only its own namespaces.
$ErrorActionPreference = 'Continue'
$env:PSMUX_RUN_NOPAUSE = '1'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skipped++ }

$origShell = $env:SHELL
$origData = $env:PSMUX_DATA_DIR
$errPattern = 'syntax error|not recognized|unexpected token|command not found'

# Watch a placeholder for $seconds; return 'dead <status>' as soon as it dies.
function Watch-Pane([string]$ns, [string]$pane, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $s = (& $PSMUX -L $ns display-message -p -t $pane '#{pane_dead} #{pane_dead_status}' 2>&1 | Out-String).Trim()
        if ($s -match '^1') { return "dead $($s.Substring(1).Trim())" }
        if ($s -notmatch '^0') { return "gone [$s]" }
        Start-Sleep -Milliseconds 300
    }
    return 'alive'
}

function New-Placeholder([string]$ns, [string]$label, [string[]]$splitArgs) {
    $p = (& $PSMUX -L $ns split-window -d -t s1115:0 -P -F '#{pane_id}' @splitArgs 2>&1 | Out-String).Trim()
    if ($p -notmatch '^%\d+$') { Write-Fail "${label}: split-window gave [$p]"; return $null }
    return $p
}

# Watch every placeholder over one shared window; a broken blocker dies as
# soon as its shell has parsed it, so the window only has to cover start up.
function Test-Placeholders([string]$ns, [hashtable]$panes, [int]$watch) {
    $deadline = (Get-Date).AddSeconds($watch)
    $state = @{}
    foreach ($k in $panes.Keys) { $state[$k] = 'alive' }
    while ((Get-Date) -lt $deadline -and ($state.Values -contains 'alive')) {
        foreach ($k in @($panes.Keys)) {
            if ($state[$k] -ne 'alive') { continue }
            $s = (& $PSMUX -L $ns display-message -p -t $panes[$k] '#{pane_dead} #{pane_dead_status}' 2>&1 | Out-String).Trim()
            if ($s -match '^1') { $state[$k] = "dead $($s.Substring(1).Trim())" }
            elseif ($s -notmatch '^0') { $state[$k] = "gone [$s]" }
        }
        Start-Sleep -Milliseconds 300
    }
    foreach ($k in ($panes.Keys | Sort-Object)) {
        $text = (& $PSMUX -L $ns capture-pane -p -S - -t $panes[$k] 2>&1 | Out-String)
        if ($state[$k] -eq 'alive' -and $text -notmatch $errPattern) {
            Write-Pass "${k}: placeholder alive after $watch s"
        } else {
            $first = (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' | '
            Write-Fail "${k}: placeholder $($state[$k]); pane says: $first"
        }
    }
}

function Invoke-Shell([string]$name, [string]$shell) {
    Write-Host "`n=== Issue #1115: SHELL = $name ===" -ForegroundColor Cyan
    if ($shell -and -not (Test-Path $shell)) { Write-Skip "$name not installed ($shell)"; return }
    if ($shell) { $env:SHELL = $shell } else { [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process') }
    $ns = 'test1115_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $env:PSMUX_DATA_DIR = Join-Path $env:TEMP ('psmux1115-' + $ns)
    New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
    try {
        & $PSMUX -L $ns new-session -d -s s1115 -x 200 -y 50
        $ok = $false
        for ($i = 0; $i -lt 40; $i++) { & $PSMUX -L $ns has-session -t s1115 2>$null; if ($LASTEXITCODE -eq 0) { $ok = $true; break }; Start-Sleep -Milliseconds 250 }
        if (-not $ok) { Write-Fail "${name}: session did not start"; return }
        & $PSMUX -L $ns set-option -g remain-on-exit on | Out-Null

        # Git Bash takes seconds to start; give it time to fail if it is going to.
        # Under load Git Bash has been seen to need over 8 s.
        $watch = if ($shell -match 'bash') { 20 } else { 6 }
        $panes = @{}
        $p1 = New-Placeholder $ns "$name arm 1 (-- cat)" @('--', 'cat')
        if ($p1) { $panes["$name arm 1 (-- cat)"] = $p1 }
        $p2 = New-Placeholder $ns "$name arm 2 (-- cat -)" @('--', 'cat', '-')
        if ($p2) { $panes["$name arm 2 (-- cat -)"] = $p2 }
        $p3 = New-Placeholder $ns "$name arm 3 (string cat)" @('cat')
        if ($p3) { $panes["$name arm 3 (string cat)"] = $p3 }
        Test-Placeholders $ns $panes $watch
        if (-not $p1) { return }

        # Arm 4: typing into the placeholder does not end it.
        & $PSMUX -L $ns send-keys -t $p1 'hello there' Enter | Out-Null
        $after = Watch-Pane $ns $p1 2
        if ($after -eq 'alive') { Write-Pass "$name arm 4: typed input does not end the blocker" }
        else { Write-Fail "$name arm 4: placeholder $after after input" }

        # Arm 5: the Claude Code sequence exactly. The placeholder is made with
        # the default remain-on-exit (off), so a placeholder that dies is
        # removed and the respawn finds no pane ("can't find pane: %N").
        & $PSMUX -L $ns set-option -g remain-on-exit off | Out-Null
        $p5 = (& $PSMUX -L $ns split-window -d -t s1115:0 -P -F '#{pane_id}' -- cat 2>&1 | Out-String).Trim()
        Start-Sleep -Seconds $watch
        & $PSMUX -L $ns set-option -p -t $p5 remain-on-exit failed 2>&1 | Out-Null
        $r = (& $PSMUX -L $ns respawn-pane -k -t $p5 -- cmd /k echo RESPAWNED-1115 2>&1 | Out-String).Trim()
        $p1 = $p5
        $text = ''
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            $text = (& $PSMUX -L $ns capture-pane -p -S - -t $p1 2>&1 | Out-String)
            if ($text -match 'RESPAWNED-1115') { break }
        }
        if ($r -eq '' -and $text -match 'RESPAWNED-1115') { Write-Pass "$name arm 5: respawn-pane -k replaced the placeholder" }
        else { Write-Fail "$name arm 5: respawn said [$r], pane [$($text.Trim())]" }
    } finally {
        & $PSMUX -L $ns kill-server 2>$null | Out-Null
    }
}

Invoke-Shell 'default (unset)' ''
Invoke-Shell 'Git bin\bash.exe' 'C:\Program Files\Git\bin\bash.exe'
Invoke-Shell 'Git usr\bin\bash.exe' 'C:\Program Files\Git\usr\bin\bash.exe'
Invoke-Shell 'cmd.exe' "$env:SystemRoot\System32\cmd.exe"

if ($null -eq $origShell) { [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process') } else { $env:SHELL = $origShell }
$env:PSMUX_DATA_DIR = $origData

Write-Host "`nResults: $script:Passed passed, $script:Failed failed, $script:Skipped skipped"
if ($script:Failed -gt 0) { exit 1 }
exit 0
