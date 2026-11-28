# Shared helpers for the Hyper-V test farm. Dot source it:
#     . "$PSScriptRoot\FarmCommon.ps1"
# Everything talks to the guests over PowerShell Direct (VMBus), so the VMs
# need no network configuration and no WinRM. Requires an elevated host shell.

$script:FarmRoot     = if ($env:PSMUX_VMFARM_ROOT) { $env:PSMUX_VMFARM_ROOT } else { 'C:\vmfarm' }
$script:FarmDataDir  = Join-Path $env:USERPROFILE '.psmux-test-data\vmfarm'
$script:FarmCredFile = Join-Path $script:FarmDataDir 'guest-cred.xml'
$script:FarmSwitch   = 'Default Switch'

function Get-FarmCredential {
    if (-not (Test-Path $script:FarmCredFile)) { throw "no farm credential at $script:FarmCredFile (New-FarmCredential creates it)" }
    Import-Clixml $script:FarmCredFile
}

# A random password for the guest admin account, stored DPAPI protected for the
# current host user only.
function New-FarmCredential {
    param([string]$UserName = 'psmuxtest')
    New-Item -ItemType Directory -Force $script:FarmDataDir | Out-Null
    if (Test-Path $script:FarmCredFile) { return (Import-Clixml $script:FarmCredFile) }
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = [byte[]]::new(20); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $pw = 'Pm9!' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
    $cred = [pscredential]::new($UserName, (ConvertTo-SecureString $pw -AsPlainText -Force))
    $cred | Export-Clixml $script:FarmCredFile
    return $cred
}

# Create a Gen2 VM on a differencing disk off $ParentVhd.
function New-FarmVM {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ParentVhd,
        [int]$Cpu = 4,
        [int64]$MemoryBytes = 6GB,
        [switch]$Tpm
    )
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM $Name already exists" }
    $vhd = Join-Path $script:FarmRoot "vhd\$Name.vhdx"
    if (Test-Path $vhd) { throw "$vhd already exists" }
    New-VHD -Path $vhd -ParentPath $ParentVhd -Differencing | Out-Null
    $vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes -VHDPath $vhd -SwitchName $script:FarmSwitch -Path (Join-Path $script:FarmRoot 'vms')
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes
    Set-VMProcessor -VM $vm -Count $Cpu
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    if ($Tpm) {
        Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
        Enable-VMTPM -VM $vm
    }
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStopAction ShutDown -AutomaticStartAction Nothing
    Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface'
    try { Set-VMVideo -VM $vm -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single -ErrorAction Stop } catch { }
    return $vm
}

# Wait until PowerShell Direct answers and the first logon script has finished.
function Wait-FarmGuest {
    param([Parameter(Mandatory)] [string]$Name, [int]$TimeoutSec = 1800, [string]$Marker = 'C:\vmfarm-firstlogon.done')
    $cred = Get-FarmCredential
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $ok = Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock { param($m) Test-Path $m } -ArgumentList $Marker
            if ($ok) { return $true }
        } catch { }
        Start-Sleep -Seconds 10
    }
    throw "guest $Name not ready after $TimeoutSec s"
}

function New-FarmSession {
    param([Parameter(Mandatory)] [string]$Name)
    New-PSSession -VMName $Name -Credential (Get-FarmCredential) -ErrorAction Stop
}

# Copy the verified installers and the OpenConsole fixture in, then install.
function Install-FarmGuest {
    param([Parameter(Mandatory)] [string]$Name, [switch]$SkipSshServer)
    $s = New-FarmSession $Name
    try {
        Invoke-Command -Session $s -ArgumentList (Get-TimeZone).Id {
            param($tz)
            Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
            # Same zone as the host, so guest and host log timestamps line up.
            try { Set-TimeZone -Id $tz } catch { }
            New-Item -ItemType Directory -Force C:\vmfarm-installers | Out-Null
        }
        foreach ($f in Get-ChildItem (Join-Path $script:FarmRoot 'installers') -File) {
            Copy-Item $f.FullName -Destination "C:\vmfarm-installers\$($f.Name)" -ToSession $s -Force
        }
        Copy-Item (Join-Path $PSScriptRoot 'guest\Install-Tools.ps1') -Destination 'C:\vmfarm-installers\Install-Tools.ps1' -ToSession $s -Force
        Invoke-Command -Session $s -ScriptBlock { param($skip) & C:\vmfarm-installers\Install-Tools.ps1 -SkipSshServer:$skip } -ArgumentList ([bool]$SkipSshServer)
        # The OpenConsole fixture some suites use, at the path they expect.
        $occ = Join-Path $env:TEMP 'occ-conpty\nugetstable'
        if (Test-Path $occ) {
            $gtemp = Invoke-Command -Session $s { $d = Join-Path $env:TEMP 'occ-conpty\nugetstable'; New-Item -ItemType Directory -Force $d | Out-Null; $d }
            foreach ($f in Get-ChildItem $occ -File) { Copy-Item $f.FullName -Destination (Join-Path $gtemp $f.Name) -ToSession $s -Force }
        }
        Invoke-Command -Session $s { Remove-Item C:\vmfarm-installers -Recurse -Force }
    } finally { Remove-PSSession $s }
}

# Patch a guest through Windows Update (guest\Install-Updates.ps1 as SYSTEM),
# rebooting between rounds until nothing is left. Windows PowerShell runs it,
# since pwsh 7.7 does not start on an unpatched Windows 10.
function Update-FarmGuest {
    param([Parameter(Mandatory)] [string]$Name, [int]$MaxRounds = 5, [int]$RoundTimeoutSec = 5400)
    $cred = Get-FarmCredential
    for ($round = 1; $round -le $MaxRounds; $round++) {
        $s = New-FarmSession $Name
        try {
            Copy-Item (Join-Path $PSScriptRoot 'guest\Install-Updates.ps1') -Destination 'C:\Windows\Temp\vmfarm-Install-Updates.ps1' -ToSession $s -Force
            Invoke-Command -Session $s {
                Remove-Item C:\vmfarm-wu.done -ErrorAction SilentlyContinue
                $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\vmfarm-Install-Updates.ps1'
                $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
                Register-ScheduledTask -TaskName 'vmfarm-wu' -Action $act -Principal $pri -Settings $set -Force | Out-Null
                Start-ScheduledTask -TaskName 'vmfarm-wu'
            }
        } finally { Remove-PSSession $s }
        $deadline = (Get-Date).AddSeconds($RoundTimeoutSec); $state = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 20
            try { $state = Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop { if (Test-Path C:\vmfarm-wu.done) { (Get-Content C:\vmfarm-wu.done -Raw).Trim() } } } catch { }
            if ($state) { break }
        }
        Write-Host "[$Name] update round $round -> $state"
        if (-not $state) { throw "update round $round timed out on $Name" }
        if ($state -like 'error*') { throw "update failed on ${Name}: $state" }
        if ($state -eq 'done') { return }
        if ($state -eq 'reboot') {
            Restart-VM -Name $Name -Force -Wait -For Heartbeat
            Wait-FarmGuest -Name $Name -TimeoutSec 3600 | Out-Null
        }
    }
}

# Run a script in the guest's INTERACTIVE desktop session (the autologon user,
# elevated), wait for it, and return its exit code. PowerShell Direct itself is
# a non interactive service logon, so a scheduled task bound to the logged on
# user is what puts the process on the visible desktop. The wrapper raises the
# priority back to Normal: Task Scheduler starts tasks at BelowNormal, and
# children inherit that, which fails timing suites.
#   -GuestScript : path INSIDE the guest
#   -WorkDir     : guest directory for out.log, err.log, exit.txt
function Start-FarmDesktopJob {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)] [string]$GuestScript,
        [Parameter(Mandatory)] [string]$WorkDir,
        [string]$Arguments = '',
        [string]$TaskName = ('vmfarm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)),
        [hashtable]$Environment = @{},
        # Leave stdout on the console (the sweep runner): its own logs are the output.
        [switch]$NoRedirect
    )
    Invoke-Command -Session $Session -ArgumentList $GuestScript, $WorkDir, $Arguments, $TaskName, $Environment, ([bool]$NoRedirect) -ScriptBlock {
        param($script, $work, $argline, $task, $envs, $noredir)
        $redir = if ($noredir) { '' } else { "> '$work\out.log' 2> '$work\err.log'" }
        New-Item -ItemType Directory -Force $work | Out-Null
        Remove-Item (Join-Path $work 'exit.txt') -Force -ErrorAction SilentlyContinue
        $envLines = ($envs.GetEnumerator() | ForEach-Object { "`$env:{0} = '{1}'" -f $_.Key, ($_.Value -replace "'", "''") }) -join "`r`n"
        $wrap = @"
`$ErrorActionPreference = 'Continue'
try { (Get-Process -Id `$PID).PriorityClass = 'Normal' } catch { }
$envLines
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
if (`$env:PSMUX_VMFARM_PREPEND) { `$env:Path = `$env:PSMUX_VMFARM_PREPEND + ';' + `$env:Path }
Set-Location '$work'
Set-Content -Path '$work\started.txt' -Value (Get-Date -Format o)
`$code = 1
try {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File '$script' $argline $redir
    `$code = `$LASTEXITCODE
} catch { Add-Content '$work\err.log' "`$_"; `$code = 99 }
Set-Content -Path '$work\exit.txt' -Value `$code
"@
        $wrapPath = Join-Path $work 'wrap.ps1'
        Set-Content -Path $wrapPath -Value $wrap -Encoding UTF8
        $user = "$env:COMPUTERNAME\$env:USERNAME"
        $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $act = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapPath`"" -WorkingDirectory $work
        $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel
        Register-ScheduledTask -TaskName $task -Action $act -Principal $pri -Settings $set -Force | Out-Null
        Start-ScheduledTask -TaskName $task
        $task
    }
}

function Wait-FarmDesktopJob {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)] [string]$WorkDir,
        [int]$TimeoutSec = 3600
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Invoke-Command -Session $Session -ArgumentList $WorkDir -ScriptBlock {
            param($w) $f = Join-Path $w 'exit.txt'; if (Test-Path $f) { (Get-Content $f -Raw).Trim() } }
        if ($null -ne $code -and "$code" -ne '') { return [int]$code }
        Start-Sleep -Seconds 3
    }
    return $null
}
