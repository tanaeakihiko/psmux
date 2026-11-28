<#
.SYNOPSIS
Create, provision and checkpoint the shard VMs for Invoke-ShardedSweep.ps1.

.DESCRIPTION
Windows 11 shards are psmux-s1..N (vTPM, Secure Boot) off golden-w11.vhdx;
Windows 10 shards are psmux-w10-s1..N off golden-w10.vhdx (patched through
Windows Update first, see README). All VMs are built in parallel, each gets the
same tools as the host (guest\Install-Tools.ps1) and the OpenConsole fixture,
and ends with a running state checkpoint named "clean".
#>
[CmdletBinding()]
param(
    [ValidateSet('w11', 'w10')] [string]$Os = 'w11',
    [int]$Count = 5,
    [int]$Cpu = 4,
    [int64]$MemoryBytes = 6GB,
    [string[]]$Names
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FarmCommon.ps1')
if (-not $Names) { $Names = @(1..$Count | ForEach-Object { if ($Os -eq 'w11') { "psmux-s$_" } else { "psmux-w10-s$_" } }) }
$golden = Join-Path $script:FarmRoot "vhd\golden-$Os.vhdx"
if (-not (Test-Path $golden)) { throw "no golden image $golden (New-GoldenVhd.ps1)" }

foreach ($n in $Names) {
    New-FarmVM -Name $n -ParentVhd $golden -Cpu $Cpu -MemoryBytes $MemoryBytes -Tpm:($Os -eq 'w11') | Out-Null
    Start-VM -Name $n
    Write-Host "created and started $n"
}

$here = $PSScriptRoot
$Names | ForEach-Object -ThrottleLimit $Names.Count -Parallel {
    $ErrorActionPreference = 'Stop'
    . (Join-Path $using:here 'FarmCommon.ps1')
    $n = $_
    $t = Get-Date
    try {
        Wait-FarmGuest -Name $n -TimeoutSec 2400 | Out-Null
        Write-Host ("[{0}] first logon done after {1:N0}s" -f $n, ((Get-Date) - $t).TotalSeconds)
        if ($using:Os -eq 'w10') { Update-FarmGuest -Name $n; Write-Host "[$n] patched" }
        Install-FarmGuest -Name $n
        Write-Host "[$n] tools installed"
        # Let the post logon churn (Defender scan, search indexer, Store) settle a little.
        Start-Sleep -Seconds 60
        Checkpoint-VM -Name $n -SnapshotName 'clean'
        Write-Host ("[{0}] checkpoint clean after {1:N0}s" -f $n, ((Get-Date) - $t).TotalSeconds)
    } catch {
        Write-Host "[$n] FAILED: $_"
    }
}
Get-VM -Name $Names | Format-Table Name, State, ProcessorCount, MemoryAssigned, Uptime
