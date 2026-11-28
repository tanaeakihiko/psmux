# Builds a never booted "golden" Windows VHDX straight from an installation ISO.
#
# The image is applied with DISM (Expand-WindowsImage), made bootable with
# bcdboot and given an unattend.xml, so no Windows Setup UI runs. Each VM later
# boots its own DIFFERENCING disk off this golden; the first boot of that child
# runs specialize and OOBE from the unattend, so every VM gets its own SID and
# computer name without sysprep. The golden itself is never booted and is made
# read only once built.
#
# Requires: elevated PowerShell on a Hyper-V host (Mount-VHD), an ISO that holds
# sources\install.wim or install.esd.
#
#   .\New-GoldenVhd.ps1 -IsoPath C:\vmfarm\iso\w10.iso -VhdPath C:\vmfarm\vhd\golden-w10.vhdx `
#       -Credential (Get-Credential psmuxtest)

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$IsoPath,
    [Parameter(Mandatory)] [string]$VhdPath,
    [Parameter(Mandatory)] [pscredential]$Credential,
    [string]$ImageName,                     # default: first image whose name contains "Enterprise"
    [uint64]$SizeBytes = 127GB,
    [string]$TimeZone = 'UTC'
)

$ErrorActionPreference = 'Stop'

if (Test-Path $VhdPath) { throw "$VhdPath already exists; delete it first (it may be the parent of differencing disks)" }

$user = $Credential.UserName
$pass = $Credential.GetNetworkCredential().Password

$iso = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $isoLetter = ($iso | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    if (-not (Test-Path $wim)) { $wim = "${isoLetter}:\sources\install.esd" }
    $images = Get-WindowsImage -ImagePath $wim
    $img = if ($ImageName) { $images | Where-Object ImageName -eq $ImageName } else { $images | Where-Object ImageName -match 'Enterprise' | Select-Object -First 1 }
    if (-not $img) { throw "no matching image in $wim. Available: $($images.ImageName -join '; ')" }
    Write-Host "Applying '$($img.ImageName)' (index $($img.ImageIndex)) from $wim"

    New-VHD -Path $VhdPath -SizeBytes $SizeBytes -Dynamic | Out-Null
    $disk = Mount-VHD -Path $VhdPath -PassThru | Get-Disk
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        # New disks get an empty MSR on GPT init on some builds; remove anything there.
        Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue
        $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        $efi | Add-PartitionAccessPath -AssignDriveLetter
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
        $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
        $os | Add-PartitionAccessPath -AssignDriveLetter
        $sysL = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter
        $osL  = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber).DriveLetter

        Expand-WindowsImage -ImagePath $wim -Index $img.ImageIndex -ApplyPath "${osL}:\" | Out-Null
        & "${osL}:\Windows\System32\bcdboot.exe" "${osL}:\Windows" /s "${sysL}:" /f UEFI | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "bcdboot failed ($LASTEXITCODE)" }

        $panther = "${osL}:\Windows\Panther"
        New-Item -ItemType Directory -Force $panther | Out-Null
        $xml = (Get-Content (Join-Path $PSScriptRoot 'unattend.template.xml') -Raw).
            Replace('@@USER@@', [Security.SecurityElement]::Escape($user)).
            Replace('@@PASSWORD@@', [Security.SecurityElement]::Escape($pass)).
            Replace('@@TIMEZONE@@', $TimeZone)
        [IO.File]::WriteAllText("$panther\unattend.xml", $xml, [Text.UTF8Encoding]::new($false))

        # First logon tweaks that must run inside the user's own session.
        $scripts = "${osL}:\Windows\Setup\Scripts"
        New-Item -ItemType Directory -Force $scripts | Out-Null
        Copy-Item (Join-Path $PSScriptRoot 'firstlogon.ps1') "$scripts\firstlogon.ps1"

        # The ACL on the copied unattend must not let ordinary users read the password.
        & icacls "$panther\unattend.xml" /inheritance:r /grant:r 'SYSTEM:F' 'Administrators:F' | Out-Null
    } finally {
        Dismount-VHD -Path $VhdPath
    }
} finally {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
}
Set-ItemProperty -Path $VhdPath -Name IsReadOnly -Value $true
Write-Host "Golden image ready: $VhdPath"
