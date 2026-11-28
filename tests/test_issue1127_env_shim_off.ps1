# Issue #1127: env-shim off reaches the first window, a claimed standby and a set at run time.
#
# env-shim decides whether a PowerShell pane's init script defines the Unix
# style `env` function. Turning it off did not reach the panes in these cases:
#
#   * `set -g env-shim off` in the config file: the first window still had the
#     function. A starting server spawns its first pane before the config runs,
#     with the default (on), and the post config check
#     (warm_pane_sync::for_post_config) did not count env-shim as a reason to
#     spawn that pane again, so the first window got it. Later windows were
#     right, as the pool refills with the config's value.
#   * The same line put in the config after a standby server (__warm__) was
#     spawned: the session that claims the standby reads the config again, but
#     its first window and its pool were spawned before, and the claim only
#     respawned them when default-shell had changed.
#   * `set -g env-shim off` at run time: no pane ever changed. The runtime
#     setter had no arm for the name and kept it as text, so `show` said off
#     while app.env_shim stayed on, and the spare pool was not respawned.
#   * The line read by `source-file`: the config parser set app.env_shim, but
#     the check that respawns the pool after a sourced file did not look at it.
#
# Every check asks a pane whether the function exists once its prompt is up.
# The spare pool stays on (no PSMUX_NO_WARM), since that is where the stale
# panes came from.
#
# The suite runs under -L in a PSMUX_DATA_DIR of its own and stops only the
# servers of its own namespace. Set PSMUX_TEST_EXE (or PSMUX_TEST_BIN) to test a
# binary that is not on PATH.

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0; $script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

. "$PSScriptRoot\isolated_config.ps1"

$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $PSMUX = $env:PSMUX_TEST_BIN }
if (-not $PSMUX) { $cmd = Get-Command psmux -EA SilentlyContinue; if ($cmd) { $PSMUX = $cmd.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_SESSION', 'PSMUX_PANE', 'PSMUX_TARGET_SESSION', 'PSMUX_TARGET_FULL', 'PSMUX_NO_WARM', 'TMUX', 'TMUX_PANE') {
    Remove-Item "Env:$v" -EA SilentlyContinue
}

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_eso_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null
$env:PSMUX_DATA_DIR = $TMP
$NS = "eso" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$S = "es"

Write-Host "`n=== env-shim off reaches the first window and a set at run time ===" -ForegroundColor Cyan
Write-Host "  Binary:   $PSMUX"
Write-Host "  Data dir: $TMP"

function P { & $PSMUX -L $NS @args 2>&1 }

# 'func' when the pane's shell has the env function, 'none' when it has not.
function Ask($target) {
    $up = $false
    for ($i = 0; $i -lt 120; $i++) {
        if (((P capture-pane -p -t $target) -join "`n") -match 'PS [A-Za-z]:\\[^\r\n]*>') { $up = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $up) { return '(no prompt)' }
    $m = 'ESO' + (Get-Random)
    # The typed line never holds the marker and the answer side by side, so a
    # wrapped echo of it cannot match.
    P send-keys -t $target "'$m' + ':' + `$(if (Get-Command env -EA 0 -CommandType Function) { 'func' } else { 'none' })" Enter | Out-Null
    for ($i = 0; $i -lt 80; $i++) {
        $c = ((P capture-pane -p -t $target) -join "`n")
        if ($c -match "(?m)^${m}:(\w+)") { return $Matches[1] }
        Start-Sleep -Milliseconds 250
    }
    return '(no answer)'
}

function Show { ((P show -gv env-shim) -join '').Trim() }

function New-Win {
    # The new window's index, so the check reads that window and no other.
    ((P new-window -P -F '#{window_index}' -t $S) -join '').Trim()
}

function Stop-Ours {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    # A standby server of this namespace that kill-server did not reach.
    Get-CimInstance Win32_Process -Filter "Name = 'psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($NS) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

try {
    Write-Head "A. set -g env-shim off in the config file"
    [IO.File]::WriteAllText($PsmuxIsolatedConfig, "set -g env-shim off`n", [Text.UTF8Encoding]::new($false))
    P new-session -d -s $S | Out-Null
    $got = Show
    Check ($got -eq 'off') "show -gv env-shim is off" "show -gv env-shim is [$got]"
    $got = Ask "${S}:0"
    Check ($got -eq 'none') "the first window has no env function" "the first window: $got"
    $w = New-Win
    $got = Ask "${S}:$w"
    Check ($got -eq 'none') "a new window has no env function" "a new window: $got"
    P split-window -t "${S}:$w" | Out-Null
    $got = Ask "${S}:$w.1"
    Check ($got -eq 'none') "a split has no env function" "a split: $got"
    Stop-Ours

    Write-Head "B. set -g env-shim at run time"
    [IO.File]::WriteAllText($PsmuxIsolatedConfig, '', [Text.UTF8Encoding]::new($false))
    P new-session -d -s $S | Out-Null
    $got = Show
    Check ($got -eq 'on') "show -gv env-shim is on by default" "show -gv env-shim is [$got]"
    $got = Ask "${S}:0"
    Check ($got -eq 'func') "the first window has the env function by default" "the first window: $got"

    P set -g env-shim off | Out-Null
    $got = Show
    Check ($got -eq 'off') "after set -g env-shim off, show is off" "show is [$got]"
    $w = New-Win
    $got = Ask "${S}:$w"
    Check ($got -eq 'none') "the next window has no env function" "the next window: $got"
    $w = New-Win
    $got = Ask "${S}:$w"
    Check ($got -eq 'none') "the window after it has none either" "the window after it: $got"

    P set -g env-shim on | Out-Null
    $w = New-Win
    $got = Ask "${S}:$w"
    Check ($got -eq 'func') "after set -g env-shim on, a new window has it again" "after on: $got"

    # No value toggles, as for the other switches.
    P set -g env-shim | Out-Null
    $got = Show
    Check ($got -eq 'off') "set -g env-shim with no value toggles it off" "after the toggle show is [$got]"
    $w = New-Win
    $got = Ask "${S}:$w"
    Check ($got -eq 'none') "after the toggle a new window has no env function" "after the toggle: $got"

    Write-Head "C. set -g env-shim off from source-file"
    P set -g env-shim on | Out-Null
    $w = New-Win
    $null = Ask "${S}:$w"
    $src = Join-Path $TMP 'off.conf'
    [IO.File]::WriteAllText($src, "set -g env-shim off`n", [Text.UTF8Encoding]::new($false))
    P source-file $src | Out-Null
    $got = Show
    Check ($got -eq 'off') "after source-file, show is off" "after source-file show is [$got]"
    $w = New-Win
    $got = Ask "${S}:$w"
    Check ($got -eq 'none') "after source-file a new window has no env function" "after source-file: $got"
    Stop-Ours

    Write-Head "D. a standby server claimed after the config turned env-shim off"
    # A session leaves a standby server (__warm__) for the next new-session,
    # with the config as it was then; the claim reads the config again. A
    # claim needs the config in its default place: with PSMUX_CONFIG_FILE set,
    # new-session starts a server of its own. So this part uses ~/.psmux.conf
    # in a home of its own.
    $savedProfile = $env:USERPROFILE
    $env:USERPROFILE = $TMP
    Remove-Item Env:PSMUX_CONFIG_FILE -EA SilentlyContinue
    $homeConf = Join-Path $TMP '.psmux.conf'
    [IO.File]::WriteAllText($homeConf, '', [Text.UTF8Encoding]::new($false))
    P new-session -d -s $S | Out-Null
    $null = Ask "${S}:0"
    $standby = @()
    for ($i = 0; $i -lt 120 -and $standby.Count -eq 0; $i++) {
        $standby = @(Get-CimInstance Win32_Process -Filter "Name = 'psmux.exe'" -EA SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($NS) -and $_.CommandLine.Contains('__warm__') } |
            ForEach-Object ProcessId)
        if ($standby.Count -eq 0) { Start-Sleep -Milliseconds 250 }
    }
    [IO.File]::WriteAllText($homeConf, "set -g env-shim off`n", [Text.UTF8Encoding]::new($false))
    P new-session -d -s "${S}2" | Out-Null
    # A claim leaves no server of the new name: the standby became it.
    $own = @(Get-CimInstance Win32_Process -Filter "Name = 'psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($NS) -and $_.CommandLine -match " -s ${S}2( |$)" })
    Check ($standby.Count -gt 0 -and $own.Count -eq 0) "new-session claimed the standby server" "no claim (standby: $($standby.Count), servers of its own: $($own.Count))"
    $got = Ask "${S}2:0"
    Check ($got -eq 'none') "the claimed session's first window has no env function" "the claimed session's first window: $got"
    $w = ((P new-window -P -F '#{window_index}' -t "${S}2") -join '').Trim()
    $got = Ask "${S}2:$w"
    Check ($got -eq 'none') "its next window has no env function" "its next window: $got"
    $env:USERPROFILE = $savedProfile
} finally {
    Stop-Ours
    if ($savedProfile) { $env:USERPROFILE = $savedProfile }
    Remove-PsmuxIsolatedConfig
    Remove-Item Env:PSMUX_DATA_DIR -EA SilentlyContinue
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
