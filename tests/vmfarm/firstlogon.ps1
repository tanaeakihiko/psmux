# Runs once, from FirstLogonCommands, in the autologon user's first session
# (Windows PowerShell 5.1). Makes the VM a desktop that never sleeps, locks or
# updates on its own, so a multi hour sweep in its interactive session is not
# interrupted. Leaves C:\vmfarm-firstlogon.done when finished.
$ErrorActionPreference = 'Continue'
$log = 'C:\vmfarm-firstlogon.log'
function Note($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format s), $m) }
Note 'start'

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force

# Keep logging on automatically for ever (Setup set a logon count).
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl -Name AutoAdminLogon -Value '1'
Remove-ItemProperty $wl -Name AutoLogonCount -ErrorAction SilentlyContinue

# Never sleep, never blank, never lock.
foreach ($a in 'standby-timeout-ac', 'monitor-timeout-ac', 'disk-timeout-ac', 'hibernate-timeout-ac') { powercfg /change $a 0 | Out-Null }
powercfg /hibernate off | Out-Null
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveActive -Value '0'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaverIsSecure -Value '0'
Remove-ItemProperty 'HKCU:\Control Panel\Desktop' -Name SCRNSAVE.EXE -ErrorAction SilentlyContinue
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name NoLockScreen -Value 1 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name InactivityTimeoutSecs -Value 0 -Type DWord
# No "require sign in" after the display wakes.
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null
powercfg /SETACTIVE SCHEME_CURRENT | Out-Null

# No Windows Update downloads or restarts mid sweep.
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue

# No "finish setting up your device" or tips screens over the test desktop.
New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Name ScoobeSystemSettingEnabled -Value 0 -Type DWord
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
New-Item $cdm -Force | Out-Null
foreach ($v in 'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled') {
    Set-ItemProperty $cdm -Name $v -Value 0 -Type DWord
}

# Defender: keep it on (the suites watch for its detections) but out of the
# test trees, which compile and run many small harness executables.
foreach ($p in 'C:\psmux', "$env:LOCALAPPDATA\Temp", $env:TEMP, "$env:USERPROFILE\.psmux") {
    try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop } catch { Note "exclusion $p failed: $_" }
}

# Hard error popups off for the whole machine (the runner sets it per process too).
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Windows' -Name ErrorMode -Value 2 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' -Name DontShowUI -Value 1 -Type DWord

Note 'done'
Set-Content -Path 'C:\vmfarm-firstlogon.done' -Value (Get-Date -Format s)
