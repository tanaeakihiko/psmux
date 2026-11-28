# Save a VM's current screen as a PNG (Hyper-V thumbnail API, no vmconnect window).
#   .\Get-VMScreen.ps1 -VMName psmux-s1 -Path $env:TEMP\s1.png
param(
    [Parameter(Mandatory)] [string]$VMName,
    [Parameter(Mandatory)] [string]$Path,
    [int]$Width = 1280,
    [int]$Height = 720
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
$vssd = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData | Where-Object VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
$r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $vssd; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height }
if (-not $r.ImageData) { throw "no image (VM off?)" }
# RGB565, row major.
$bmp = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$rect = [System.Drawing.Rectangle]::new(0, 0, $Width, $Height)
$bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
[System.Runtime.InteropServices.Marshal]::Copy([byte[]]$r.ImageData, 0, $bd.Scan0, $r.ImageData.Length)
$bmp.UnlockBits($bd)
$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "saved $Path"
