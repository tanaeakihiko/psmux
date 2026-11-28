# perf_dead_registry_startup.ps1 - what dead PID registries cost a new session.
#
# Every psmux invocation sweeps the data dir for stale registries before it
# does anything else (cleanup_stale_port_files). A registry whose `.pid` names
# a process that no longer exists is reaped on the spot, but deciding that used
# to cost one full process snapshot per registry (CreateToolhelp32Snapshot,
# about 30 to 45 ms here): OpenProcess fails for a dead PID, and the #650
# fallback treated every refusal as "maybe it lives in another session" and
# walked the whole table. Six dead registries added roughly 200 ms to the next
# command, the very first thing a user ran after a crash or a hard kill.
#
# This suite plants 0, 1 and 6 dead registries in an isolated data dir right
# before each measured `new-session -d`, then reports two numbers per run:
#   cli_ms     until `new-session -d` returns
#   prompt_ms  until the new pane shows a shell prompt (capture-pane polled)
# for a COLD start (no server in the namespace, so the CLI starts one) and a
# WARM start (a server and its warm spare are up, so the new session is a
# claim). Several builds can be compared in one run; their iterations are
# interleaved so they share the machine's load.
#
# Isolation: its own -L namespace and its own PSMUX_DATA_DIR per scenario,
# cleanup with `-L <ns> kill-server` only, leftovers killed by PID and only
# when their executable is one of the builds under test. Nothing else is
# touched.
#
#   pwsh -File tests\perf_dead_registry_startup.ps1 -BuildSpec 'before=C:\b\psmux.exe;after=C:\a\psmux.exe' -N 12
#
# Each build must be a file named psmux.exe (a renamed copy changes how the
# registry identifies its own servers).

param(
    [string]$BuildSpec = '',   # "label=path;label=path"
    [int]$N = 10,
    [string]$Dead = '0,1,6',
    [string]$Mode = 'cold,warm',
    [string]$MetricsDir = ''
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\perf_metrics_common.ps1"

$DeadCounts = @($Dead -split ',' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
$Modes = @($Mode -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
$spec = $BuildSpec
$Builds = @{}
foreach ($pair in ($spec -split ';' | Where-Object { $_ })) { $k, $v = $pair -split '=', 2; $Builds[$k.Trim()] = $v.Trim() }
if ($Builds.Count -eq 0) {
    $exe = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
    if (-not $exe) { $exe = (Get-Command psmux -EA Stop).Source }
    $Builds = @{ current = $exe }
}
foreach ($k in @($Builds.Keys)) {
    $Builds[$k] = (Resolve-Path $Builds[$k]).Path
    if ((Split-Path $Builds[$k] -Leaf) -ne 'psmux.exe') { throw "build '$k' must be named psmux.exe: $($Builds[$k])" }
}
$buildPaths = @($Builds.Values)
$labels = @($Builds.Keys | Sort-Object)

$root = Join-Path $env:TEMP ("psmux-perf-deadreg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $root | Out-Null
$savedDataDir = $env:PSMUX_DATA_DIR

function Get-BuildProcs {
    @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Where-Object { $buildPaths -contains $_.ExecutablePath })
}

function New-DeadPid {
    $p = Start-Process cmd -ArgumentList '/c', 'exit' -WindowStyle Hidden -PassThru
    $p.WaitForExit()
    $id = $p.Id
    # Release the handle: while one is open the process object outlives the
    # process, OpenProcess still succeeds, and the PID is not "gone" the way a
    # hard-killed server's PID is.
    $p.Dispose()
    return $id
}

function Set-DeadRegistries([string]$Dir, [string]$Ns, [int]$Count) {
    for ($i = 0; $i -lt $Count; $i++) {
        $base = Join-Path $Dir ("{0}__dead{1}" -f $Ns, $i)
        Set-Content "$base.port" (40000 + (Get-Random -Maximum 20000)) -NoNewline
        Set-Content "$base.key" 'perf-dead-key' -NoNewline
        Set-Content "$base.sid" '1' -NoNewline
        Set-Content "$base.pid" (New-DeadPid) -NoNewline
    }
    if ($Count -gt 0) {
        # Open every planted file once from another process, untimed. The first
        # open of a file another process has just written waits for the
        # antivirus scan of it, 8 to 10 ms a file here, and that would be
        # charged to psmux. A real dead registry was written when its server
        # started and has been opened by every psmux command since, so its
        # scan is long done.
        cmd /c "type `"$Dir\${Ns}__dead*`" >nul 2>nul"
        Start-Sleep -Milliseconds 200
    }
}

function Wait-Prompt([string]$Exe, [string]$Ns, [string]$Session, [Diagnostics.Stopwatch]$Sw, [int]$TimeoutMs = 20000) {
    while ($Sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = (& $Exe -L $Ns capture-pane -p -t $Session 2>$null | Out-String)
        if ($cap -match '(?m)>\s*$') { return $Sw.Elapsed.TotalMilliseconds }
        Start-Sleep -Milliseconds 15
    }
    return $null
}

function Wait-WarmSpare([string]$Dir, [int]$TimeoutMs = 15000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Get-ChildItem $Dir -Filter '*__warm__*.port' -EA SilentlyContinue) { Start-Sleep -Milliseconds 300; return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Stop-Namespace([string]$Exe, [string]$Ns, [string]$Dir) {
    $env:PSMUX_DATA_DIR = $Dir
    & $Exe -L $Ns kill-server 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        $left = @(Get-BuildProcs | Where-Object { $_.CommandLine -match [regex]::Escape("-L $Ns") -or $_.CommandLine -match [regex]::Escape($Ns) })
        if ($left.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    }
    foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue }
}

$results = [ordered]@{}
foreach ($l in $labels) { foreach ($m in $Modes) { foreach ($d in $DeadCounts) {
    $results["$l|$m|$d"] = [ordered]@{ cli = [System.Collections.Generic.List[double]]::new(); prompt = [System.Collections.Generic.List[double]]::new(); reaped_all = $true; timeouts = 0 }
} } }

# Warm namespaces stay up for the whole run, one per build, so a claim is
# always what is measured.
$warm = @{}
if ($Modes -contains 'warm') {
    foreach ($l in $labels) {
        $dir = Join-Path $root "warm-$l"; New-Item -ItemType Directory -Force $dir | Out-Null
        $ns = "pdrw$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $env:PSMUX_DATA_DIR = $dir
        & $Builds[$l] -L $ns new-session -d -s anchor 2>&1 | Out-Null
        if (-not (Wait-WarmSpare $dir)) { Write-Host "  [WARN] $l warm spare did not appear" -ForegroundColor Yellow }
        $warm[$l] = @{ dir = $dir; ns = $ns }
    }
}

Add-PerfLoadSample 'start' | Out-Null
$serial = 0
try {
    for ($it = 1; $it -le $N; $it++) {
        foreach ($d in $DeadCounts) {
            foreach ($m in $Modes) {
                foreach ($l in $labels) {
                    $exe = $Builds[$l]
                    $serial++
                    $sess = "s$serial"
                    if ($m -eq 'cold') {
                        $dir = Join-Path $root "cold-$serial"; New-Item -ItemType Directory -Force $dir | Out-Null
                        $ns = "pdrc$serial$([guid]::NewGuid().ToString('N').Substring(0,4))"
                    } else {
                        $dir = $warm[$l].dir; $ns = $warm[$l].ns
                        Wait-WarmSpare $dir | Out-Null
                    }
                    $env:PSMUX_DATA_DIR = $dir
                    Set-DeadRegistries $dir $ns $d
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    & $exe -L $ns new-session -d -s $sess 2>&1 | Out-Null
                    $cli = $sw.Elapsed.TotalMilliseconds
                    $prompt = Wait-Prompt $exe $ns $sess $sw
                    $r = $results["$l|$m|$d"]
                    $r.cli.Add([math]::Round($cli, 1))
                    if ($null -ne $prompt) { $r.prompt.Add([math]::Round($prompt, 1)) } else { $r.timeouts++ }
                    if (Get-ChildItem $dir -Filter "${ns}__dead*.port" -EA SilentlyContinue) { $r.reaped_all = $false }
                    if ($m -eq 'cold') {
                        Stop-Namespace $exe $ns $dir
                    } else {
                        & $exe -L $ns kill-session -t $sess 2>&1 | Out-Null
                    }
                }
            }
        }
        if ($it % 3 -eq 0) { Add-PerfLoadSample "iter$it" | Out-Null }
        Write-Host "  iteration $it/$N done"
    }
} finally {
    foreach ($l in $warm.Keys) { Stop-Namespace $Builds[$l] $warm[$l].ns $warm[$l].dir }
    $env:PSMUX_DATA_DIR = $savedDataDir
}

$data = [ordered]@{ n = $N; dead_counts = $DeadCounts; builds = [ordered]@{}; cells = [ordered]@{} }
foreach ($l in $labels) { $data.builds[$l] = [ordered]@{ binary = $Builds[$l]; version = ((& $Builds[$l] -V) -join ' ') } }
Write-Host ""
Write-Host ("{0,-10} {1,-5} {2,4}  {3,22}  {4,22}  {5}" -f 'build', 'mode', 'dead', 'cli p50/p90 ms', 'prompt p50/p90 ms', 'reaped')
foreach ($k in $results.Keys) {
    $l, $m, $d = $k -split '\|'
    $r = $results[$k]
    $c = Get-PerfStats $r.cli.ToArray() 1
    $p = Get-PerfStats $r.prompt.ToArray() 1
    $data.cells[$k] = [ordered]@{ build = $l; mode = $m; dead = [int]$d; cli_ms = $c; prompt_ms = $p; prompt_timeouts = $r.timeouts; reaped_all = $r.reaped_all; cli_raw = $r.cli.ToArray(); prompt_raw = $r.prompt.ToArray() }
    Write-Host ("{0,-10} {1,-5} {2,4}  {3,10} / {4,-10}  {5,10} / {6,-10}  {7}" -f $l, $m, $d, $c.p50, $c.p90, $p.p50, $p.p90, $r.reaped_all)
}
$data.load = Get-PerfLoadSummary
$path = Write-PerfMetrics -Suite 'perf_dead_registry_startup' -Binary ($buildPaths -join ';') -Data $data -MetricsDir $MetricsDir
Write-Host ""
Write-Host "metrics: $path"
$leftover = @(Get-BuildProcs | Where-Object { $_.CommandLine -match 'pdr[cw]' })
Write-Host "leftover processes of the builds under test in this suite's namespaces: $($leftover.Count)"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
