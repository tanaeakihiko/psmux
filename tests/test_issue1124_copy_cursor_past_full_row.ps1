# Issue #1124: copy mode with emacs keys goes one past a full row that does
# not wrap, as tmux does.
#
# A program that writes a full row and then CR LF leaves a row that does not
# wrap (the inbox console host of Windows 10 hands psmux every full row that
# way). With emacs keys tmux 3.8 puts the copy cursor one past such a row, at
# column sx, since window_copy_cursor_limit gives the line's length
# (window-copy.c:6315), and draws a `$` in the last cell. psmux held the
# cursor on the last column, so end-of-line and next-word-end stopped one
# short and a selection to the end of the row lost its last character.
#
# Every value checked is what tmux 3.8 reports for the same rows in a pane of
# the same size, and vi keys are checked to stay as they were. The `$` is
# drawn by the client and is checked by tests-rs/test_copy_cursor_past_end_render.rs.
#
# The suite runs under -L in a PSMUX_DATA_DIR of its own and kills only its own
# namespace. Set PSMUX_TEST_EXE (or PSMUX_TEST_BIN) to test a binary that is
# not on PATH. The user's clipboard is saved and put back.

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0; $script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
. "$PSScriptRoot\isolated_config.ps1" -Lines @("set -g default-shell $POWERSHELL", "set -g mode-keys emacs")

$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $PSMUX = $env:PSMUX_TEST_BIN }
if (-not $PSMUX) { $cmd = Get-Command psmux -EA SilentlyContinue; if ($cmd) { $PSMUX = $cmd.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_SESSION', 'PSMUX_PANE', 'PSMUX_TARGET_SESSION', 'PSMUX_TARGET_FULL', 'TMUX', 'TMUX_PANE') {
    Remove-Item "Env:$v" -EA SilentlyContinue
}
$env:PSMUX_NO_WARM = "1"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cfr_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null
$env:PSMUX_DATA_DIR = $TMP
$NS = "cfr" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$S = "fr"

Write-Host "`n=== Copy mode with emacs keys goes one past a full row, as tmux does ===" -ForegroundColor Cyan
Write-Host "  Binary:   $PSMUX"
Write-Host "  Data dir: $TMP"

function P { & $PSMUX -L $NS @args 2>&1 }

# A 20 column pane. Each row ends with CR LF, so none wraps: row 0 is full of
# 'a', row 1 is "one two " and twelve 'z', row 2 is short, and row 3 ends on
# a wide character in its last two columns. The text is built from code
# points so this file stays ASCII.
$WIDE = [string][char]0x4E16
$ROW0 = 'a' * 20
$CONTENT = $ROW0 + "`r`n" + 'one two ' + ('z' * 12) + "`r`nshort`r`n" + ('a' * 18) + $WIDE + "`r`n"
$FILE = Join-Path $TMP "rows.txt"
[IO.File]::WriteAllText($FILE, $CONTENT, [Text.UTF8Encoding]::new($false))

function Pos { ((P display -p -t $S '#{copy_cursor_x},#{copy_cursor_y}') -join '').Trim() }

function Enter-At($row, $col) {
    P send-keys -t $S -X cancel | Out-Null
    P copy-mode -t $S | Out-Null
    P send-keys -t $S -X top-line | Out-Null
    for ($i = 0; $i -lt $row; $i++) { P send-keys -t $S -X cursor-down | Out-Null }
    P send-keys -t $S -X start-of-line | Out-Null
    for ($i = 0; $i -lt $col; $i++) { P send-keys -t $S -X cursor-right | Out-Null }
}

function Copied {
    P send-keys -t $S -X copy-selection | Out-Null
    Start-Sleep -Milliseconds 200
    ((P show-buffer) -join "`n")
}

# What tmux 3.8 reports for each step, by mode-keys.
$EXPECT = @{
    emacs = @{ eol0 = '20,0'; left = '19,0'; eol3 = '20,3'; we1 = '7,1'; we2 = '20,1'; word = '' }
    vi    = @{ eol0 = '19,0'; left = '18,0'; eol3 = '18,3'; we1 = '6,1'; we2 = '19,1'; word = $ROW0 }
}

$savedClipboard = $null
try { $savedClipboard = Get-Clipboard -Raw -EA Stop } catch {}

try {
    $child = "$POWERSHELL -NoProfile -Command `"[Console]::OutputEncoding=[Text.Encoding]::UTF8; " +
        "[Console]::Out.Write([IO.File]::ReadAllText('$FILE')); Start-Sleep 300`""
    P new-session -d -s $S -x 20 -y 8 $child | Out-Null
    $shown = $false
    for ($i = 0; $i -lt 60 -and -not $shown; $i++) {
        Start-Sleep -Milliseconds 200
        $shown = ((P capture-pane -p -t $S) -join "`n") -match '(?m)^short'
    }

    Write-Head "A. the rows reach the pane"
    $cap = @(P capture-pane -p -t $S)
    Check ($shown -and $cap[0] -eq $ROW0 -and $cap[2] -eq 'short' -and $cap[3] -eq (('a' * 18) + $WIDE)) `
        "rows 0 to 3 hold the text" "capture [$($cap[0..3] -join ' | ')]"
    $joined = @(P capture-pane -p -J -t $S)
    Check ($joined[0] -eq $ROW0 -and $joined[1] -like 'one two *') "no row wraps (-J joins nothing)" "capture -J [$($joined[0..1] -join ' | ')]"

    foreach ($mk in 'emacs', 'vi') {
        P set -g mode-keys $mk | Out-Null
        $want = $EXPECT[$mk]

        Write-Head "B. end-of-line and back, mode-keys $mk"
        Enter-At 0 0
        P send-keys -t $S -X end-of-line | Out-Null
        $got = Pos
        Check ($got -eq $want.eol0) "end-of-line on the full row lands on $($want.eol0) (tmux)" "landed on $got, tmux lands on $($want.eol0)"
        P send-keys -t $S -X cursor-left | Out-Null
        $got = Pos
        Check ($got -eq $want.left) "cursor-left from there lands on $($want.left) (tmux)" "landed on $got, tmux lands on $($want.left)"
        Enter-At 3 0
        P send-keys -t $S -X end-of-line | Out-Null
        $got = Pos
        Check ($got -eq $want.eol3) "end-of-line on the row ending on a wide character lands on $($want.eol3) (tmux)" "landed on $got, tmux lands on $($want.eol3)"

        Write-Head "C. next-word-end to the end of the row, mode-keys $mk"
        Enter-At 1 4
        P send-keys -t $S -X next-word-end | Out-Null
        $got = Pos
        Check ($got -eq $want.we1) "next-word-end from 4,1 lands on $($want.we1) (tmux)" "landed on $got, tmux lands on $($want.we1)"
        P send-keys -t $S -X next-word-end | Out-Null
        $got = Pos
        Check ($got -eq $want.we2) "and again on $($want.we2) (tmux)" "landed on $got, tmux lands on $($want.we2)"

        Write-Head "D. a selection to the end of the full row, mode-keys $mk"
        Enter-At 0 0
        P send-keys -t $S -X begin-selection | Out-Null
        P send-keys -t $S -X end-of-line | Out-Null
        $buf = Copied
        Check ($buf -eq $ROW0) "begin-selection, end-of-line, copy-selection copies the whole row (tmux)" "copied [$buf] ($($buf.Length) characters)"
        Enter-At 1 4
        P send-keys -t $S -X begin-selection | Out-Null
        P send-keys -t $S -X next-word-end | Out-Null
        P send-keys -t $S -X next-word-end | Out-Null
        $buf = Copied
        Check ($buf -eq ('two ' + ('z' * 12))) "a selection over next-word-end copies to the end of the row (tmux)" "copied [$buf]"

        Write-Head "E. copy_cursor_word at the end of the full row, mode-keys $mk"
        Enter-At 0 0
        P send-keys -t $S -X end-of-line | Out-Null
        $word = ((P display -p -t $S '#{copy_cursor_word}') -join '')
        Check ($word -eq $want.word) "copy_cursor_word is [$($want.word)] (tmux)" "copy_cursor_word is [$word], tmux gives [$($want.word)]"
    }

    Write-Head "F. the key itself: emacs C-e"
    P set -g mode-keys emacs | Out-Null
    Enter-At 0 0
    P send-keys -t $S C-e | Out-Null
    $got = Pos
    Check ($got -eq '20,0') "emacs C-e lands on 20,0 (tmux)" "landed on $got"

    # tmux holds every cursor move inside window_copy_cursor_limit
    # (window_copy_update_cursor), up and down remember the column a run of
    # them started from and whether it was at the end of its line (lastcx,
    # lastsx), and cursor-right and cursor-left go on to the next and the
    # previous line. psmux kept the column through up, down and the page
    # moves, left history-bottom where it was, and stopped right and left at
    # the pane edge. Each case starts at end-of-line on its row; the values
    # are what tmux 3.8 reports on the same rows, with the status line off so
    # the pane is 8 rows as tmux's was.
    Write-Head "G. up, down, page and wrapping moves from the end of a row"
    P set -g status off | Out-Null
    Start-Sleep -Milliseconds 300
    $MOVES = @(
        @(0, 'cursor-down', '20,1', '19,1'),
        @(0, 'cursor-down cursor-down', '5,2', '4,2'),
        @(0, 'cursor-down cursor-down cursor-down', '20,3', '4,3'),
        @(3, 'cursor-down', '0,4', '0,4'),
        @(1, 'cursor-up', '0,0', '19,0'),
        @(2, 'cursor-down cursor-up', '0,2', '4,2'),
        @(0, 'halfpage-down', '0,4', '0,4'),
        @(0, 'page-down', '0,6', '0,6'),
        @(3, 'halfpage-up', '0,0', '18,0'),
        @(0, 'history-bottom', '0,7', '0,7'),
        @(0, 'cursor-right', '0,1', '0,1'),
        @(2, 'cursor-right', '0,3', '0,3'),
        @(3, 'cursor-right', '0,4', '0,4'),
        @(0, 'cursor-right cursor-right', '1,1', '1,1'),
        @(7, 'cursor-right', '0,7', '0,7'),
        @(3, 'start-of-line cursor-left', '5,2', '4,2'),
        @(4, 'start-of-line cursor-left', '20,3', '18,3'),
        @(0, 'start-of-line cursor-left', '0,0', '0,0'),
        @(0, 'begin-selection cursor-down cursor-down', '5,2', '4,2'),
        @(0, 'rectangle-toggle begin-selection cursor-down cursor-down', '20,2', '19,2'),
        @(0, 'begin-selection rectangle-toggle cursor-right cursor-right', '1,1', '0,1')
    )
    foreach ($mk in 'emacs', 'vi') {
        P set -g mode-keys $mk | Out-Null
        foreach ($m in $MOVES) {
            $want = if ($mk -eq 'emacs') { $m[2] } else { $m[3] }
            P send-keys -t $S -X cancel | Out-Null
            P copy-mode -t $S | Out-Null
            P send-keys -t $S -X top-line | Out-Null
            for ($i = 0; $i -lt $m[0]; $i++) { P send-keys -t $S -X cursor-down | Out-Null }
            P send-keys -t $S -X start-of-line | Out-Null
            P send-keys -t $S -X end-of-line | Out-Null
            foreach ($c in ($m[1] -split ' ')) { P send-keys -t $S -X $c | Out-Null }
            $got = Pos
            Check ($got -eq $want) "$mk, row $($m[0]): $($m[1]) lands on $want (tmux)" "$mk, row $($m[0]): $($m[1]) landed on $got, tmux lands on $want"
        }
    }
} finally {
    P kill-server | Out-Null
    if ($null -ne $savedClipboard) { try { Set-Clipboard -Value $savedClipboard } catch {} }
    Start-Sleep -Milliseconds 500
    Remove-PsmuxIsolatedConfig
    Remove-Item Env:PSMUX_DATA_DIR, Env:PSMUX_NO_WARM -EA SilentlyContinue
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
