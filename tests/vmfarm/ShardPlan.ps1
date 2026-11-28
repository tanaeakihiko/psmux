# Deterministic shard assignment for tests\run_all_tests.ps1 -ShardIndex/-ShardCount.
#
# Greedy longest processing time first: suites are taken in order of recorded
# duration (longest first, name as the tie break), and each goes to the shard
# with the smallest total so far (lowest shard number on a tie). A suite with no
# recorded duration is costed at the median of the recorded ones. The same
# inputs always give the same plan, on any machine, so every shard computes its
# own slice independently and the slices never overlap or miss a suite.

function Read-SuiteDurations {
    param([string]$Path)
    $map = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $map }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($Path -match '\.jsonl$') {
        # A runner results.jsonl: one record per suite with Name and Duration.
        foreach ($line in ($raw -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            try { $r = $line | ConvertFrom-Json; if ($r.Name -and $r.Status -ne 'SKIP') { $map[[string]$r.Name] = [double]$r.Duration } } catch { }
        }
    } else {
        $j = $raw | ConvertFrom-Json
        $src = if ($j.PSObject.Properties['seconds']) { $j.seconds } else { $j }
        foreach ($p in $src.PSObject.Properties) { $map[$p.Name] = [double]$p.Value }
    }
    return $map
}

# Returns one object per shard: Index (1 based), Suites (names, sorted), Seconds (estimate).
function Get-ShardPlan {
    param(
        [Parameter(Mandatory)] [string[]]$Suites,
        [Parameter(Mandatory)] [int]$ShardCount,
        [hashtable]$Durations = @{}
    )
    $known = @($Durations.Values | Sort-Object)
    $median = if ($known.Count) {
        if ($known.Count % 2) { $known[[int][math]::Floor($known.Count / 2)] }
        else { ($known[$known.Count / 2 - 1] + $known[$known.Count / 2]) / 2 }
    } else { 1.0 }

    $items = foreach ($s in ($Suites | Sort-Object -Unique)) {
        [pscustomobject]@{ Name = $s; Cost = $(if ($Durations.ContainsKey($s)) { [double]$Durations[$s] } else { [double]$median }) }
    }
    # Sort-Object is stable; ordinal name order first, then cost descending.
    $ordered = @($items | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })

    $load = [double[]]::new($ShardCount)
    $members = @(for ($i = 0; $i -lt $ShardCount; $i++) { , [System.Collections.Generic.List[string]]::new() })
    foreach ($it in $ordered) {
        $best = 0
        for ($i = 1; $i -lt $ShardCount; $i++) { if ($load[$i] -lt $load[$best]) { $best = $i } }
        $load[$best] += $it.Cost
        $members[$best].Add($it.Name)
    }
    for ($i = 0; $i -lt $ShardCount; $i++) {
        [pscustomobject]@{
            Index   = $i + 1
            Suites  = @($members[$i] | Sort-Object)
            Seconds = [math]::Round($load[$i], 1)
        }
    }
}
