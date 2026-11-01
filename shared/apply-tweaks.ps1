# apply-tweaks.ps1 - Windows 10 VM performance tweaks (run as Administrator in Windows)
$log = Join-Path $PSScriptRoot "tweaks-log.txt"
"=== apply-tweaks started $(Get-Date) ===" | Out-File $log -Encoding utf8
function Log($m) { $m | Out-File $log -Append -Encoding utf8 }
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Not admin - relaunching elevated"
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Log "Running as admin"
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Log "Power plan set to High performance"
New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name VisualFXSetting -Value 3 -Type DWord
Log "Visual effects set to Adjust for best performance (VisualFXSetting=3)"
Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name MenuShowDelay -Value "0"
Set-ItemProperty "HKCU:\Control Panel\Desktop\WindowMetrics" -Name MinAnimate -Value "0"
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name TaskbarAnimations -Value 0 -Type DWord
Log "Menu/ window/ taskbar animations off"
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name EnableTransparency -Value 0 -Type DWord
Log "Transparency off"
Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value ""
Set-ItemProperty "HKCU:\Control Panel\Colors" -Name Background -Value "0 0 0"
Log "Wallpaper cleared to solid black background color"
New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name GlobalUserDisabled -Value 1 -Type DWord
Log "Background apps disabled globally"
Set-ItemProperty "HKCU:\System\GameConfigStore" -Name GameDVR_Enabled -Value 0 -Type DWord
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name AllowGameDVR -Value 0 -Type DWord
Set-ItemProperty "HKCU:\Software\Microsoft\GameBar" -Name AllowAutoGameMode -Value 0 -Type DWord
Set-ItemProperty "HKCU:\Software\Microsoft\GameBar" -Name AutoGameModeEnabled -Value 0 -Type DWord
Log "Game Bar / Game DVR off"
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name StartupBoostEnabled -Value 0 -Type DWord
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name BackgroundModeEnabled -Value 0 -Type DWord
Log "Edge startup boost and background mode off (policy)"
Set-Service -Name SysMain -StartupType Manual
Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
Set-Service -Name WSearch -StartupType Manual
Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
Log "SysMain and Windows Search set to Manual and stopped (NI services untouched)"
foreach ($key in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run")) {
    $props = (Get-ItemProperty $key).PSObject.Properties | Where-Object { $_.Name -match "OneDrive|MicrosoftEdgeAutoLaunch" }
    foreach ($p in $props) { Remove-ItemProperty -Path $key -Name $p.Name; Log "Removed startup entry $($p.Name) from $key" }
}
Log "Startup Run-key cleanup done"
$d = Get-PSDrive C
Log "C: free after tweaks: $([math]::Round($d.Free/1GB,2)) GB"
Log "=== apply-tweaks finished $(Get-Date) ==="
Write-Host "Tweaks applied. Log written to $log"
