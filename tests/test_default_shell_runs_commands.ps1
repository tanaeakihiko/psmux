# A pane command string runs through default-shell, as tmux does.
#
# tmux runs `split-window "<cmd>"` as `default-shell -c "<cmd>"` (spawn.c).
# psmux ran it through the SHELL variable (or the pwsh walk) whatever
# default-shell said: with SHELL unset and `set -g default-shell cmd` the
# interactive pane was cmd, but the command printed PowerShell's version
# table and an unexpanded %OS%.
#
# The probe line reads differently in each shell:
#   echo PROBE $PSVersionTable.PSVersion %OS% $0
#   pwsh: PROBE / version table / %OS% / $0, one argument per line
#   cmd:  PROBE $PSVersionTable.PSVersion Windows_NT $0
#   bash: PROBE .PSVersion %OS% /usr/bin/bash
#
# Cases (default-shell set with `set -g`, or in the config file for E):
#   A  SHELL unset, default-shell unset      -> pwsh (unchanged default)
#   B  SHELL unset, default-shell cmd        -> cmd
#   C  SHELL unset, default-shell Git Bash   -> bash
#   D  SHELL=Git Bash, default-shell pwsh    -> pwsh
#   E  SHELL=cmd, default-shell Git Bash in the config file -> bash
#   F  SHELL=Git Bash, default-shell unset   -> bash (SHELL seeds it, #683)
#   G  SHELL unset, default-shell Git Bash: `-- cat` placeholder is the
#      real cat and respawn-pane -k replaces it (#1115 follows the shell)
# Git Bash cases SKIP when Git for Windows is not installed.
#
# Isolation: own -L namespace, PSMUX_DATA_DIR and -f config per case;
# honours PSMUX_TEST_BIN. Kills only its own namespaces.
$ErrorActionPreference = 'Continue'
$env:PSMUX_RUN_NOPAUSE = '1'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skipped++ }

$origShell = $env:SHELL
$origData = $env:PSMUX_DATA_DIR
$pwsh = (Get-Command pwsh -EA SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -EA Stop).Source }
$cmd = "$env:SystemRoot\System32\cmd.exe"
$bash = 'C:\Program Files\Git\bin\bash.exe'
$haveBash = Test-Path $bash
$probe = 'echo PROBE $PSVersionTable.PSVersion %OS% $0'
$tmp = Join-Path $env:TEMP ('psmux-defshell-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-ShellOf([string]$t) {
    if ($t -match '(?m)^PROBE\s*\r?\n') { return 'pwsh' }
    if ($t -match 'PROBE \S*PSVersion\S* Windows_NT') { return 'cmd' }
    if ($t -match 'PROBE \S*PSVersion %OS% \S*bash') { return 'bash' }
    return 'unknown'
}

function Start-Case([string]$shell, [string]$confLine) {
    if ($shell) { $env:SHELL = $shell } else { [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process') }
    $ns = 'defsh_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $env:PSMUX_DATA_DIR = Join-Path $tmp "data-$ns"
    New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
    $conf = Join-Path $tmp "$ns.conf"
    Set-Content -Path $conf -Value $confLine
    & $PSMUX -L $ns -f $conf new-session -d -s d -x 200 -y 50
    for ($i = 0; $i -lt 40; $i++) { & $PSMUX -L $ns has-session -t d 2>$null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 250 }
    & $PSMUX -L $ns set -g remain-on-exit on | Out-Null
    return $ns
}

function Test-Case([string]$label, [string]$shell, [string]$ds, [string]$how, [string]$want) {
    $confLine = if ($how -eq 'conf') { "set -g default-shell `"$ds`"" } else { '' }
    $ns = Start-Case $shell $confLine
    try {
        if ($how -eq 'set') { & $PSMUX -L $ns set -g default-shell $ds | Out-Null }
        $p = (& $PSMUX -L $ns split-window -d -t d:0 -P -F '#{pane_id}' $probe 2>&1 | Out-String).Trim()
        if ($p -notmatch '^%\d+$') { Write-Fail "${label}: split-window gave [$p]"; return }
        $t = ''
        for ($i = 0; $i -lt 80; $i++) {
            Start-Sleep -Milliseconds 250
            $t = (& $PSMUX -L $ns capture-pane -p -S - -t $p 2>&1 | Out-String)
            if ($t -match 'Pane is dead') { break }
        }
        $got = Get-ShellOf $t
        if ($got -eq $want) { Write-Pass "${label}: the command ran in $got" }
        else {
            $first = (($t -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '
            Write-Fail "${label}: the command ran in $got, want $want; pane: $first"
        }
    } finally { & $PSMUX -L $ns kill-server 2>$null | Out-Null }
}

Write-Host "`n=== a pane command follows default-shell ===" -ForegroundColor Cyan
Test-Case 'A SHELL unset, default-shell unset' '' '' '' 'pwsh'
Test-Case 'B SHELL unset, default-shell cmd' '' $cmd 'set' 'cmd'
if ($haveBash) {
    Test-Case 'C SHELL unset, default-shell Git Bash' '' $bash 'set' 'bash'
    Test-Case 'D SHELL=Git Bash, default-shell pwsh' $bash $pwsh 'set' 'pwsh'
    Test-Case 'E SHELL=cmd, default-shell Git Bash in config' $cmd $bash 'conf' 'bash'
    Test-Case 'F SHELL=Git Bash, default-shell unset' $bash '' '' 'bash'
} else { Write-Skip 'C to F: Git Bash not installed' }

Write-Host "`n=== H: a quoted cmd command reaches cmd unescaped ===" -ForegroundColor Cyan
# cmd reads its own command line; a quote used to arrive as a \" escape and
# the command failed ("The filename, directory name, or volume label syntax
# is incorrect").
$ns = Start-Case '' ''
try {
    & $PSMUX -L $ns set -g default-shell $cmd | Out-Null
    $out = Join-Path $tmp 'quoted out.txt'
    $line = "echo [%OS%] `"two words`" > `"$out`""
    $p = (& $PSMUX -L $ns split-window -d -t d:0 -P -F '#{pane_id}' $line 2>&1 | Out-String).Trim()
    for ($i = 0; $i -lt 40 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 250 }
    $got = if (Test-Path $out) { (Get-Content $out -Raw).Trim() } else { '' }
    if ($got -eq '[Windows_NT] "two words"') { Write-Pass "H: cmd ran the quoted line and expanded %OS%" }
    else {
        $pane = (& $PSMUX -L $ns capture-pane -p -S - -t $p 2>&1 | Out-String).Trim()
        Write-Fail "H: file has [$got]; pane: $pane"
    }
} finally { & $PSMUX -L $ns kill-server 2>$null | Out-Null }

Write-Host "`n=== G: the cat placeholder follows default-shell ===" -ForegroundColor Cyan
if ($haveBash) {
    $ns = Start-Case '' ''
    try {
        & $PSMUX -L $ns set -g default-shell $bash | Out-Null
        & $PSMUX -L $ns set -g remain-on-exit off | Out-Null
        $p = (& $PSMUX -L $ns split-window -d -t d:0 -P -F '#{pane_id}' -- cat 2>&1 | Out-String).Trim()
        $cc = ''
        for ($i = 0; $i -lt 80; $i++) {
            Start-Sleep -Milliseconds 250
            $cc = (& $PSMUX -L $ns display -p -t $p '#{pane_current_command}' 2>&1 | Out-String).Trim()
            if ($cc -eq 'cat' -or $cc -match "can't find") { break }
        }
        if ($cc -eq 'cat') { Write-Pass "G: the placeholder is the real cat under the default-shell bash" }
        else { Write-Fail "G: placeholder pane_current_command [$cc], want cat" }
        & $PSMUX -L $ns set-option -p -t $p remain-on-exit failed 2>&1 | Out-Null
        $r = (& $PSMUX -L $ns respawn-pane -k -t $p -- cmd /k echo RESPAWNED-DEFSH 2>&1 | Out-String).Trim()
        $t = ''
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            $t = (& $PSMUX -L $ns capture-pane -p -S - -t $p 2>&1 | Out-String)
            if ($t -match 'RESPAWNED-DEFSH') { break }
        }
        if ($r -eq '' -and $t -match 'RESPAWNED-DEFSH') { Write-Pass "G: respawn-pane -k replaced the placeholder" }
        else { Write-Fail "G: respawn said [$r], pane [$($t.Trim())]" }
    } finally { & $PSMUX -L $ns kill-server 2>$null | Out-Null }
} else { Write-Skip 'G: Git Bash not installed' }

if ($null -eq $origShell) { [Environment]::SetEnvironmentVariable('SHELL', $null, 'Process') } else { $env:SHELL = $origShell }
$env:PSMUX_DATA_DIR = $origData
Remove-Item -Recurse -Force $tmp -EA SilentlyContinue

Write-Host "`nResults: $script:Passed passed, $script:Failed failed, $script:Skipped skipped"
if ($script:Failed -gt 0) { exit 1 }
exit 0
