# Relaunch after the last session is gone: is it still a warm start?
#
# The common way to start psmux is to close the last session and open psmux
# again a little later. The namespace's warm standby is what makes that start
# fast. A standby that outlives an emptied namespace forever is a leak, so it
# retires after a grace (PSMUX_WARM_EMPTY_GRACE_MS, default 15 min); this probe
# measures the relaunch at several delays inside and outside that grace.
#
# For each delay and each binary (interleaved): new-session -d -s a, let the
# standby settle, kill-session -t a, wait the delay, then time
# `new-session -d -s b` to (1) the command returning, (2) a prompt drawn in the
# pane, and record whether b is the old standby (claimed = warm) or a new
# process (cold).
#
# Own -L namespace per sample, own PSMUX_DATA_DIR, processes ended by PID.
# Meant for a VM.
#
#   pwsh -NoProfile -File tests\perf_warm_relaunch_after_empty.ps1 -Bins a\psmux.exe,b\psmux.exe -Delays 2,30,300 -N 3

param(
    [Parameter(Mandatory)][string]$Bins,
    [string]$Delays = "2,30,300",
    [int]$N = 3,
    [string]$Out = ""
)
$ErrorActionPreference = 'Continue'
$binList = @($Bins -split ',' | ForEach-Object { (Resolve-Path $_.Trim()).Path })
$delayList = @($Delays -split ',' | ForEach-Object { [int]$_.Trim() })
foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_SESSION', 'PSMUX_PANE', 'TMUX', 'TMUX_PANE', 'PSMUX_NO_WARM', 'PSMUX_WARM_EMPTY_GRACE_MS') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$root = Join-Path $env:TEMP "psmux_relaunch_$(Get-Random)"
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = $root
$conf = Join-Path $root 'empty.conf'; [IO.File]::WriteAllText($conf, '')
# No -f on new-session: a custom config file turns the warm claim off, and the
# claim is what is under test. So the user's own config is read; a VM has none.
Remove-Item Env:\PSMUX_CONFIG_FILE -EA SilentlyContinue
foreach ($c in "$env:USERPROFILE\.psmux.conf", "$env:USERPROFILE\.psmuxrc", "$env:USERPROFILE\.tmux.conf") { if (Test-Path $c) { Write-Host "  note: $c exists and is read by every session here" -ForegroundColor DarkYellow } }
$rows = @()

function Get-RegPid($ns, $name) {
    $f = Join-Path $root "${ns}__$name.pid"
    $b = Get-Content $f -EA SilentlyContinue | Select-Object -First 1
    if ($b -match '^(\d+)') { [int]$Matches[1] } else { $null }
}
function Stop-Ns($bin, $ns) {
    & $bin -L $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" | Where-Object { $_.ExecutablePath -eq $bin -and $_.CommandLine -match "-L $ns( |$)" }) {
        foreach ($k in Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.ProcessId)") { Stop-Process -Id $k.ProcessId -Force -EA SilentlyContinue }
        Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue
    }
}

try {
    foreach ($d in $delayList) {
        for ($i = 1; $i -le $N; $i++) {
            foreach ($bin in $binList) {
                $ns = "rl$(Get-Random)"
                & $bin -L $ns new-session -d -s a 2>&1 | Out-Null
                $sw = [Diagnostics.Stopwatch]::StartNew(); $sb = $null
                while ($sw.ElapsedMilliseconds -lt 15000 -and -not $sb) { $sb = Get-RegPid $ns '__warm__'; Start-Sleep -Milliseconds 100 }
                Start-Sleep -Seconds 3   # a settled standby, as a real machine has it
                & $bin -L $ns kill-session -t a 2>&1 | Out-Null
                Start-Sleep -Seconds $d
                $alive = [bool]($sb -and (Get-Process -Id $sb -EA SilentlyContinue))
                $sw.Restart()
                & $bin -L $ns new-session -d -s b 2>&1 | Out-Null
                $cmdMs = $sw.Elapsed.TotalMilliseconds
                $promptMs = $null
                while ($sw.ElapsedMilliseconds -lt 15000) {
                    $t = (& $bin -L $ns capture-pane -p -t b 2>$null | Out-String)
                    if ($t -match 'PS [A-Z]:\\.*>') { $promptMs = $sw.Elapsed.TotalMilliseconds; break }
                    Start-Sleep -Milliseconds 10
                }
                $bPid = Get-RegPid $ns 'b'
                $claimed = ($null -ne $sb) -and ($bPid -eq $sb)
                $row = [pscustomobject]@{ bin = (Split-Path (Split-Path $bin -Parent) -Leaf); delay_s = $d; run = $i; standby_alive_before = $alive; claimed = $claimed; cmd_ms = [Math]::Round($cmdMs); prompt_ms = $(if ($promptMs) { [Math]::Round($promptMs) } else { $null }) }
                $rows += $row
                Write-Host ("{0,-10} delay {1,4}s run {2}: standby alive {3,-5} claimed {4,-5} new-session {5,5} ms, prompt {6,5} ms" -f $row.bin, $d, $i, $alive, $claimed, $row.cmd_ms, $row.prompt_ms)
                Stop-Ns $bin $ns
            }
        }
    }
}
finally {
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
Write-Host "`n=== Summary (median) ==="
$rows | Group-Object bin, delay_s | ForEach-Object {
    $c = @($_.Group | ForEach-Object { $_.cmd_ms } | Sort-Object); $p = @($_.Group | Where-Object { $_.prompt_ms } | ForEach-Object { $_.prompt_ms } | Sort-Object)
    "{0,-22} claimed {1}/{2}  new-session p50 {3} ms  prompt p50 {4} ms" -f $_.Name, @($_.Group | Where-Object claimed).Count, $_.Count, $c[[int][Math]::Floor(($c.Count - 1) / 2)], $(if ($p.Count) { $p[[int][Math]::Floor(($p.Count - 1) / 2)] } else { 'n/a' })
}
if ($Out) { $rows | ConvertTo-Json | Set-Content $Out }
