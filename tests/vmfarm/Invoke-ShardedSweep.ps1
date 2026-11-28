<#
.SYNOPSIS
Run tests\run_all_tests.ps1 sharded across the farm VMs and merge the results.

.DESCRIPTION
For each shard VM: restore its "clean" checkpoint, copy in the psmux, tmux and
pmux binaries currently installed on the host (~\.cargo\bin) and this tests
tree, then start run_all_tests.ps1 -ShardIndex i -ShardCount n on the VM's
interactive desktop (Normal priority, PSMUX_TEST_SANDBOX=1, which is only ever
set inside the VM). While the shards run, each shard's progress.log is mirrored
to the host and its result lines are echoed; a shard whose progress.log has not
changed for -StallMinutes prints a STALL line. A shard past its deadline is
asked to stop through the runner's stop flag, then turned off. Finally every
shard's run folder and metrics are copied to
%USERPROFILE%\.psmux-test-data\vmfarm\<run id>\ and one merged summary is
printed and written there (merged_summary.txt, merged_results.jsonl).

Suites listed in host_only_suites.txt (timing gates, WSL) are excluded from the
shards unless -IncludeHostOnly; -ListHostOnly prints the -Only regex to run
them on the host.

.EXAMPLE
.\Invoke-ShardedSweep.ps1                          # full sweep, 5 Windows 11 shards
.\Invoke-ShardedSweep.ps1 -Os w10                  # same on the Windows 10 shard set
.\Invoke-ShardedSweep.ps1 -Only '^test_(all|tmux_compat)$' -ShardCount 2
#>
[CmdletBinding()]
param(
    [ValidateSet('w11', 'w10')] [string]$Os = 'w11',
    [int]$ShardCount = 5,
    [string[]]$VMNames,                 # default: psmux-s1..N (w11) or psmux-w10-s1..N (w10)
    [string]$Only,
    [string]$Exclude,                   # extra exclusions, OR'd with the host only list
    [switch]$IncludeHostOnly,
    [string]$BinDir = (Join-Path $env:USERPROFILE '.cargo\bin'),
    [string]$TestsDir = (Join-Path $PSScriptRoot '..'),
    [string]$RunnerArgs = '',           # extra arguments for run_all_tests.ps1
    [double]$DeadlineFactor = 1.6,      # deadline = estimate * factor + DeadlineSlackMinutes
    [int]$DeadlineSlackMinutes = 30,
    [int]$DeadlineMinutes = 0,          # fixed per shard deadline (overrides the estimate)
    [int]$StallMinutes = 20,
    [int]$PollSeconds = 30,
    [string]$RunId = (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'),
    [switch]$ListHostOnly,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FarmCommon.ps1')
. (Join-Path $PSScriptRoot 'ShardPlan.ps1')

$TestsDir = (Resolve-Path $TestsDir).Path
$hostOnly = @(Get-Content (Join-Path $PSScriptRoot 'host_only_suites.txt') | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
$hostOnlyRegex = '^(' + (($hostOnly | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
if ($ListHostOnly) { $hostOnlyRegex; return }

$excludeParts = @()
if (-not $IncludeHostOnly) { $excludeParts += $hostOnlyRegex }
if ($Exclude) { $excludeParts += "(?:$Exclude)" }
$excludeRegex = ($excludeParts | ForEach-Object { "(?:$_)" }) -join '|'

if (-not $VMNames) {
    $VMNames = @(1..$ShardCount | ForEach-Object { if ($Os -eq 'w11') { "psmux-s$_" } else { "psmux-w10-s$_" } })
}
if ($VMNames.Count -ne $ShardCount) { throw "-VMNames has $($VMNames.Count) names for $ShardCount shards" }

# The same plan the runner computes inside each VM, for the estimates and deadlines.
$suites = @(Get-ChildItem (Join-Path $TestsDir 'test_*.ps1') | ForEach-Object BaseName | Sort-Object)
if ($Only) { $suites = @($suites | Where-Object { $_ -match $Only }) }
if ($excludeRegex) { $suites = @($suites | Where-Object { $_ -notmatch $excludeRegex }) }
$durations = Read-SuiteDurations (Join-Path $TestsDir 'vmfarm\suite_durations.json')
$plan = @(Get-ShardPlan -Suites $suites -ShardCount $ShardCount -Durations $durations)
Write-Host ("Plan: {0} suites over {1} shards ({2}); excluded host only: {3}" -f $suites.Count, $ShardCount, $Os, $(if ($IncludeHostOnly) { 'no' } else { $hostOnly.Count })) -ForegroundColor Cyan
foreach ($p in $plan) { Write-Host ("  shard {0} on {1}: {2} suites, est {3:N1} min" -f $p.Index, $VMNames[$p.Index - 1], $p.Suites.Count, ($p.Seconds / 60)) }
if ($PlanOnly) { return }

$out = Join-Path $script:FarmDataDir $RunId
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out 'orchestrator.log'
function Say([string]$m, [string]$color = 'Gray') {
    $l = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $log -Value $l
    Write-Host $l -ForegroundColor $color
}
Say "run $RunId, results in $out"

foreach ($b in 'psmux.exe', 'tmux.exe', 'pmux.exe') { if (-not (Test-Path (Join-Path $BinDir $b))) { throw "missing $b in $BinDir" } }
$binVer = & (Join-Path $BinDir 'psmux.exe') -V 2>&1
Say "binaries from $BinDir ($binVer)"

# One zip of the tests tree (thousands of small files copy far faster as one).
$zip = Join-Path $out 'tests.zip'
Compress-Archive -Path (Join-Path $TestsDir '*') -DestinationPath $zip -CompressionLevel Fastest -Force
Say ("tests tree zipped: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))

# ---- reset and start every shard VM in parallel ----
foreach ($vm in $VMNames) {
    if (-not (Get-VMSnapshot -VMName $vm -Name 'clean' -ErrorAction SilentlyContinue)) { throw "$vm has no 'clean' checkpoint" }
}
$VMNames | ForEach-Object -Parallel {
    Restore-VMSnapshot -VMName $_ -Name 'clean' -Confirm:$false
    if ((Get-VM -Name $_).State -ne 'Running') { Start-VM -Name $_ }
} -ThrottleLimit $ShardCount
Say "checkpoints restored, VMs running"

$shards = @()
for ($i = 1; $i -le $ShardCount; $i++) {
    $vm = $VMNames[$i - 1]
    Wait-FarmGuest -Name $vm -TimeoutSec 600 | Out-Null
    $s = New-FarmSession $vm
    Invoke-Command -Session $s { Remove-Item C:\psmux -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\psmux\tests, C:\psmux\target\release | Out-Null }
    Copy-Item $zip -Destination 'C:\psmux\tests.zip' -ToSession $s
    foreach ($b in 'psmux.exe', 'tmux.exe', 'pmux.exe') { Copy-Item (Join-Path $BinDir $b) -Destination "C:\psmux\target\release\$b" -ToSession $s }
    Invoke-Command -Session $s { Expand-Archive C:\psmux\tests.zip -DestinationPath C:\psmux\tests -Force; Remove-Item C:\psmux\tests.zip
        Remove-Item (Join-Path $env:TEMP 'psmux-test-logs') -Recurse -Force -ErrorAction SilentlyContinue }
    $argline = "-ShardIndex $i -ShardCount $ShardCount"
    if ($Only) { $argline += " -Only '$($Only -replace "'", "''")'" }
    if ($excludeRegex) { $argline += " -Exclude '$($excludeRegex -replace "'", "''")'" }
    if ($RunnerArgs) { $argline += " $RunnerArgs" }
    $task = Start-FarmDesktopJob -Session $s -GuestScript 'C:\psmux\tests\run_all_tests.ps1' -WorkDir 'C:\vmfarm-shard' -Arguments $argline `
        -Environment @{ PSMUX_TEST_SANDBOX = '1' } -NoRedirect -TaskName 'vmfarm-shard'
    $est = $plan[$i - 1].Seconds
    $deadlineMin = if ($DeadlineMinutes -gt 0) { $DeadlineMinutes } else { [math]::Ceiling($est / 60 * $DeadlineFactor + $DeadlineSlackMinutes) }
    $dir = Join-Path $out "shard$i"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $shards += [pscustomobject]@{
        Index = $i; VM = $vm; Session = $s; Started = Get-Date; Deadline = (Get-Date).AddMinutes($deadlineMin)
        DeadlineMin = $deadlineMin; Dir = $dir; GuestRunDir = $null; ProgressLen = 0; LastChange = Get-Date
        Done = $false; ExitCode = $null; Outcome = 'running'; Finished = $null; StallReported = $false; StopSent = $null
    }
    Say ("shard {0} started on {1} ({2} suites, est {3:N0} min, deadline {4} min)" -f $i, $vm, $plan[$i - 1].Suites.Count, ($est / 60), $deadlineMin) 'Cyan'
}

function Get-GuestState($sh) {
    Invoke-Command -Session $sh.Session -ArgumentList $sh.GuestRunDir, $sh.ProgressLen -ScriptBlock {
        param($runDir, $from)
        $r = @{ RunDir = $runDir; Delta = ''; Len = $from; Exit = $null }
        if (-not $runDir) {
            $lf = Join-Path $env:TEMP 'psmux-test-logs\latest_run.txt'
            if (Test-Path $lf) { $r.RunDir = Join-Path $env:TEMP ('psmux-test-logs\' + (Get-Content $lf -Raw).Trim()) }
        }
        if ($r.RunDir) {
            $p = Join-Path $r.RunDir 'progress.log'
            if (Test-Path $p) {
                $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($fs.Length -gt $from) {
                        $fs.Seek($from, 'Begin') | Out-Null
                        $buf = [byte[]]::new($fs.Length - $from); $n = $fs.Read($buf, 0, $buf.Length)
                        $r.Delta = [Text.Encoding]::UTF8.GetString($buf, 0, $n); $r.Len = $from + $n
                    }
                } finally { $fs.Close() }
            }
        }
        $e = 'C:\vmfarm-shard\exit.txt'
        if (Test-Path $e) { $r.Exit = (Get-Content $e -Raw).Trim() }
        $t = Get-ScheduledTask -TaskName 'vmfarm-shard' -ErrorAction SilentlyContinue
        $r.TaskState = if ($t) { [string]$t.State } else { 'missing' }
        $r
    }
}

function Reopen($sh) {
    try { Remove-PSSession $sh.Session -ErrorAction SilentlyContinue } catch { }
    $sh.Session = New-FarmSession $sh.VM
}

# ---- monitor ----
while (@($shards | Where-Object { -not $_.Done }).Count -gt 0) {
    foreach ($sh in ($shards | Where-Object { -not $_.Done })) {
        $st = $null
        try { $st = Get-GuestState $sh } catch {
            Say ("shard {0}: guest query failed ({1}); reopening session" -f $sh.Index, $_.Exception.Message) 'DarkYellow'
            try { Reopen $sh } catch { }
        }
        $now = Get-Date
        if ($st) {
            if ($st.RunDir -and -not $sh.GuestRunDir) { $sh.GuestRunDir = $st.RunDir }
            if ($st.Delta) {
                [IO.File]::AppendAllText((Join-Path $sh.Dir 'progress.log'), $st.Delta)
                $sh.ProgressLen = $st.Len; $sh.LastChange = $now; $sh.StallReported = $false
                foreach ($line in ($st.Delta -split "`r?`n")) {
                    if ($line -match '\]\s(PASS|FAIL|TIMEOUT|ERROR)\s') {
                        $c = if ($Matches[1] -eq 'PASS') { 'DarkGreen' } else { 'Red' }
                        Write-Host ("[s{0}] {1}" -f $sh.Index, ($line -replace '^\[[^\]]+\]\s*', '')) -ForegroundColor $c
                    }
                }
            }
            if ($null -ne $st.Exit -and "$($st.Exit)" -ne '') {
                $sh.Done = $true; $sh.ExitCode = [int]$st.Exit; $sh.Finished = $now
                $sh.Outcome = if ($sh.StopSent) { 'deadline-stopped' } else { 'finished' }
                Say ("shard {0} {1} (runner exit {2}) after {3:N1} min" -f $sh.Index, $sh.Outcome, $sh.ExitCode, ($now - $sh.Started).TotalMinutes) 'Cyan'
                continue
            }
            if ($st.TaskState -ne 'Running' -and ($now - $sh.Started).TotalSeconds -gt 60) {
                $sh.Done = $true; $sh.Finished = $now; $sh.Outcome = 'runner-died'
                Say ("shard {0}: the desktop task is {1} but wrote no exit code; the runner died" -f $sh.Index, $st.TaskState) 'Red'
                continue
            }
        }
        $idle = ($now - $sh.LastChange).TotalMinutes
        if ($idle -ge $StallMinutes -and -not $sh.StallReported) {
            Say ("STALL shard {0} on {1}: progress.log unchanged for {2:N0} min" -f $sh.Index, $sh.VM, $idle) 'Yellow'
            $sh.StallReported = $true
        }
        if ($now -gt $sh.Deadline) {
            if (-not $sh.StopSent) {
                Say ("DEADLINE shard {0} on {1} after {2} min: asking the runner to stop" -f $sh.Index, $sh.VM, $sh.DeadlineMin) 'Red'
                try { Invoke-Command -Session $sh.Session { Set-Content (Join-Path $env:TEMP 'psmux-teststop.flag') 'vmfarm deadline' } } catch { }
                $sh.StopSent = $now
            } elseif (($now - $sh.StopSent).TotalMinutes -ge 5) {
                Say ("shard {0} did not stop within 5 min of the stop flag; collecting what exists" -f $sh.Index) 'Red'
                $sh.Done = $true; $sh.Outcome = 'deadline-killed'; $sh.Finished = $now
            }
        }
    }
    if (@($shards | Where-Object { -not $_.Done }).Count -gt 0) { Start-Sleep -Seconds $PollSeconds }
}

# ---- collect ----
foreach ($sh in $shards) {
    try {
        try { Invoke-Command -Session $sh.Session { 1 } | Out-Null } catch { Reopen $sh }
        if ($sh.GuestRunDir) {
            Copy-Item -FromSession $sh.Session -Path $sh.GuestRunDir -Destination (Join-Path $sh.Dir 'run') -Recurse -Force
        }
        $hasMetrics = Invoke-Command -Session $sh.Session { Test-Path (Join-Path $env:USERPROFILE '.psmux-test-data\metrics') }
        if ($hasMetrics) {
            $gm = Invoke-Command -Session $sh.Session { Join-Path $env:USERPROFILE '.psmux-test-data\metrics' }
            Copy-Item -FromSession $sh.Session -Path $gm -Destination (Join-Path $sh.Dir 'metrics') -Recurse -Force
        }
        Invoke-Command -Session $sh.Session { Unregister-ScheduledTask -TaskName 'vmfarm-shard' -Confirm:$false -ErrorAction SilentlyContinue }
    } catch { Say ("shard {0}: collect failed: {1}" -f $sh.Index, $_.Exception.Message) 'Red' }
    if ($sh.Outcome -eq 'deadline-killed') { Stop-VM -Name $sh.VM -TurnOff -Force -ErrorAction SilentlyContinue }
    try { Remove-PSSession $sh.Session } catch { }
}

# ---- merge ----
$all = @()
foreach ($sh in $shards) {
    $rj = Join-Path $sh.Dir 'run\results.jsonl'
    $recs = @()
    if (Test-Path $rj) { $recs = @(Get-Content $rj | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
    foreach ($r in $recs) {
        $hostLog = if ($r.Log) { Join-Path (Join-Path $sh.Dir 'run\suites') (Split-Path $r.Log -Leaf) } else { $null }
        $r | Add-Member -NotePropertyName Shard -NotePropertyValue $sh.Index -Force
        $r | Add-Member -NotePropertyName HostLog -NotePropertyValue $hostLog -Force
        $all += $r
    }
    $sh | Add-Member -NotePropertyName Records -NotePropertyValue $recs.Count -Force
    $sh | Add-Member -NotePropertyName Planned -NotePropertyValue $plan[$sh.Index - 1].Suites.Count -Force
}
$all | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $out 'merged_results.jsonl') -Encoding UTF8

$failed = @($all | Where-Object { $_.Status -in 'FAIL', 'TIMEOUT', 'ERROR' })
$passedS = @($all | Where-Object { $_.Status -eq 'PASS' })
$skippedS = @($all | Where-Object { $_.Status -eq 'SKIP' })
$tp = ($all | Measure-Object -Property Passed -Sum).Sum
$tf = ($all | Measure-Object -Property Failed -Sum).Sum
$planned = ($plan | ForEach-Object { $_.Suites.Count } | Measure-Object -Sum).Sum
$missing = @()
foreach ($p in $plan) {
    $got = @{}; foreach ($r in ($all | Where-Object Shard -eq $p.Index)) { $got[$r.Name] = $true }
    $missing += @($p.Suites | Where-Object { -not $got.ContainsKey($_) } | ForEach-Object { "$_ (shard $($p.Index))" })
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add(('=' * 78))
$lines.Add("SHARDED SWEEP $RunId  ($Os, $ShardCount shards, binaries: $binVer)")
$lines.Add(('=' * 78))
$lines.Add(("Suites: {0} planned, {1} with a result: {2} passed, {3} failed, {4} skipped, {5} not run" -f $planned, $all.Count, $passedS.Count, $failed.Count, $skippedS.Count, $missing.Count))
$lines.Add(("Tests:  {0} passed, {1} failed" -f $tp, $tf))
$wall = (($shards | ForEach-Object { if ($_.Finished) { $_.Finished } else { Get-Date } } | Measure-Object -Maximum).Maximum - ($shards | ForEach-Object Started | Measure-Object -Minimum).Minimum)
$lines.Add(("Wall:   {0:hh\:mm\:ss} for the slowest shard" -f $wall))
$lines.Add('')
$lines.Add('Per shard:')
foreach ($sh in $shards) {
    $w = if ($sh.Finished) { $sh.Finished - $sh.Started } else { (Get-Date) - $sh.Started }
    $sf = @($all | Where-Object { $_.Shard -eq $sh.Index -and $_.Status -in 'FAIL', 'TIMEOUT', 'ERROR' }).Count
    $lines.Add(("  shard {0} {1,-12} {2,-17} wall {3:hh\:mm\:ss} (est {4:N0} min)  {5}/{6} suites  {7} failed  runner exit {8}" -f `
        $sh.Index, $sh.VM, $sh.Outcome, $w, ($plan[$sh.Index - 1].Seconds / 60), $sh.Records, $sh.Planned, $sf, $sh.ExitCode))
}
if ($failed.Count) {
    $lines.Add('')
    $lines.Add('Failing suites:')
    foreach ($f in ($failed | Sort-Object Name)) {
        $lines.Add(("  [{0,-7}] {1,-48} {2}P/{3}F {4,7:N1}s  shard {5}" -f $f.Status, $f.Name, $f.Passed, $f.Failed, [double]$f.Duration, $f.Shard))
        foreach ($ff in @($f.FirstFailures | Select-Object -First 2)) { $lines.Add("      $ff") }
        $lines.Add("      log: $($f.HostLog)")
    }
}
if ($missing.Count) {
    $lines.Add('')
    $lines.Add('Planned but no result (shard stopped early or runner died):')
    foreach ($m in $missing) { $lines.Add("  $m") }
}
$lines.Add('')
$lines.Add("Results: $out")
$lines | Set-Content (Join-Path $out 'merged_summary.txt') -Encoding UTF8
$lines | ForEach-Object { Write-Host $_ }
if ($failed.Count -or $missing.Count) { exit 1 } else { exit 0 }
