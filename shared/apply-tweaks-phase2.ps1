<#
  apply-tweaks-phase2.ps1 - second-pass efficiency tweaks for a Windows 10 guest (dockur / QEMU).
  Run AFTER apply-tweaks.ps1. Every change logs "old -> new" so it can be reversed by hand.

  Deliberately NOT done here (higher risk, do manually and one at a time):
    full Defender disable, VDOT debloat, removing Windows features, touching NI services beyond delayed start.

  Usage (from an elevated or normal PowerShell; it self-elevates):
    powershell -ExecutionPolicy Bypass -File apply-tweaks-phase2.ps1
  Optional switches:
    -ProjectPath "C:\Users\youruser\Documents\LabVIEW Projects"   (Defender exclusion)
    -PagefileMB 3072     fixed pagefile size on C:
    -SkipPagefile        leave the pagefile alone
    -RestorePoint        create a System Restore point first (shadow storage capped at 2 GB)
    -Cleanup             DISM component cleanup + temp / update-cache deletion (slow on 2 vCPUs)

  Note: an elevated process often cannot see mapped drives such as Z:. If the script fails to start
  from Z:, copy it to C:\ and run it from there (or run it from the \\host.lan UNC path).
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = "$env:USERPROFILE\Documents",
    [int]$PagefileMB = 3072,
    [switch]$SkipPagefile,
    [switch]$RestorePoint,
    [switch]$Cleanup
)

# ---------- self-elevate ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# ---------- logging ----------
$LogDir = if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) { $PSScriptRoot } else { $env:TEMP }
$LogFile = Join-Path $LogDir 'tweaks2-log.txt'
try { Add-Content -Path $LogFile -Value '' -ErrorAction Stop }
catch { $LogFile = Join-Path $env:TEMP 'tweaks2-log.txt' }

function Say($m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Step($name, [scriptblock]$body) {
    Say "== $name"
    try { & $body; Say '   ok' }
    catch { Say "   FAILED: $($_.Exception.Message)" }
}

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    $old = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Say "   reg $Path\$Name : [$old] -> [$Value]"
}

function Set-Svc($Name, $Mode) {   # Mode: Disabled | Manual
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    $old = (Get-CimInstance Win32_Service -Filter "Name='$Name'").StartMode
    $scMode = if ($Mode -eq 'Disabled') { 'disabled' } else { 'demand' }
    try { Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop }
    catch { & sc.exe config $Name start= $scMode | Out-Null }
    if ($Mode -eq 'Disabled' -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Say "   svc $Name : $old -> $Mode"
}

Say "---- phase 2 start ($env:COMPUTERNAME, $((Get-CimInstance Win32_OperatingSystem).Caption)) ----"

# ---------- 0. optional restore point ----------
if ($RestorePoint) {
    Step 'System Restore point (shadow storage capped at 2 GB)' {
        Enable-ComputerRestore -Drive "$env:SystemDrive\"
        & vssadmin.exe resize shadowstorage /for=$env:SystemDrive /on=$env:SystemDrive /maxsize=2GB | Out-Null
        Checkpoint-Computer -Description 'before-phase2-tweaks' -RestorePointType MODIFY_SETTINGS
    }
}

# ---------- 1. Defender: keep it on, make it cheap ----------
Step 'Defender: exclusions and CPU throttling (protection stays on)' {
    $paths = @(
        "$env:ProgramFiles\National Instruments",
        "${env:ProgramFiles(x86)}\National Instruments",
        "$env:ProgramData\National Instruments",
        $env:TEMP,
        "$env:SystemRoot\Temp",
        $ProjectPath
    )
    foreach ($p in $paths) { if ($p) { Add-MpPreference -ExclusionPath $p; Say "   exclusion path: $p" } }
    Add-MpPreference -ExclusionProcess 'LabVIEW.exe'
    Set-MpPreference -ScanAvgCPULoadFactor 10 -EnableLowCpuPriority $true -ScanOnlyIfIdleEnabled $true `
                     -DisableCatchupFullScan $true -DisableCatchupQuickScan $true
}

# ---------- 2. power / hibernation ----------
Step 'Hibernation off (frees hiberfil.sys), fast startup off, no display/sleep/disk timeouts' {
    & powercfg.exe -h off
    & powercfg.exe -change -monitor-timeout-ac 0
    & powercfg.exe -change -standby-timeout-ac 0
    & powercfg.exe -change -disk-timeout-ac 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
}

# ---------- 3. fixed pagefile ----------
if (-not $SkipPagefile) {
    Step "Fixed pagefile $PagefileMB MB on C: (needs reboot)" {
        $cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
        if ($cs.AutomaticManagedPagefile) { $cs.AutomaticManagedPagefile = $false; $cs.Put() | Out-Null }
        $pf = Get-WmiObject Win32_PageFileSetting | Where-Object { $_.Name -like 'C:*' }
        if ($pf) { $pf.InitialSize = $PagefileMB; $pf.MaximumSize = $PagefileMB; $pf.Put() | Out-Null }
        else { Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{ Name = 'C:\pagefile.sys'; InitialSize = $PagefileMB; MaximumSize = $PagefileMB } | Out-Null }
    }
}

# ---------- 4. services ----------
Step 'Services: telemetry and unused consumer services -> Disabled' {
    foreach ($s in 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'lfsvc', 'RetailDemo', 'WMPNetworkSvc',
                   'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc', 'Fax', 'RemoteRegistry',
                   'WerSvc', 'WbioSrvc', 'SCardSvr', 'bthserv', 'icssvc', 'PhoneSvc') { Set-Svc $s 'Disabled' }
}
Step 'Services: update plumbing -> Manual (policy below keeps auto-update off)' {
    foreach ($s in 'wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'CDPSvc') { Set-Svc $s 'Manual' }
}

# ---------- 5. scheduled tasks ----------
Step 'Scheduled tasks: defrag, telemetry, error reporting, WinSAT' {
    $tasks = @(
        '\Microsoft\Windows\Defrag\ScheduledDefrag',
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\Maintenance\WinSAT',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
    )
    foreach ($t in $tasks) {
        $tPath = (Split-Path $t -Parent) + '\'
        $tName = Split-Path $t -Leaf
        try { Disable-ScheduledTask -TaskPath $tPath -TaskName $tName -ErrorAction Stop | Out-Null; Say "   disabled: $t" }
        catch { Say "   skipped (not present): $t" }
    }
}

# ---------- 6. machine policies (durable, unlike Set-Service for update/telemetry) ----------
Step 'Machine policies: feeds, telemetry, updates, consumer content, search, activity, lock screen, WER, DO, OneDrive' {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    Set-Reg "$pol\Windows Feeds"          'EnableFeeds' 0
    Set-Reg "$pol\DataCollection"         'AllowTelemetry' 0
    Set-Reg "$pol\WindowsUpdate\AU"       'NoAutoUpdate' 1
    Set-Reg "$pol\CloudContent"           'DisableWindowsConsumerFeatures' 1
    Set-Reg "$pol\CloudContent"           'DisableWindowsSpotlightFeatures' 1
    Set-Reg "$pol\Windows Search"         'AllowCortana' 0
    Set-Reg "$pol\Windows Search"         'DisableWebSearch' 1
    Set-Reg "$pol\Windows Search"         'ConnectedSearchUseWeb' 0
    Set-Reg "$pol\System"                 'EnableActivityFeed' 0
    Set-Reg "$pol\System"                 'PublishUserActivities' 0
    Set-Reg "$pol\Personalization"        'NoLockScreen' 1
    Set-Reg "$pol\Windows Error Reporting" 'Disabled' 1
    Set-Reg "$pol\DeliveryOptimization"   'DODownloadMode' 0
    Set-Reg "$pol\OneDrive"               'DisableFileSyncNGSC' 1
}

# ---------- 7. Edge ----------
Step 'Edge policies: no startup boost / background mode / sidebar, sleeping tabs after 5 min' {
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'StartupBoostEnabled' 0
    Set-Reg $edge 'BackgroundModeEnabled' 0
    Set-Reg $edge 'HubsSidebarEnabled' 0
    Set-Reg $edge 'SleepingTabsEnabled' 1
    Set-Reg $edge 'SleepingTabsTimeout' 300
}

# ---------- 8. per-user: reduce redraws and noise ----------
Step 'Per-user UI: outline drag, no screensaver, no taskbar clutter, no toasts, no Start suggestions' {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'ScreenSaveActive' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'ShowTaskViewButton' 0
    Set-Reg $adv 'ShowCortanaButton' 0
    Set-Reg "$adv\People" 'PeopleBand' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'ContentDeliveryAllowed', 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled',
                   'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'SubscribedContent-338388Enabled',
                   'SubscribedContent-338389Enabled', 'SoftLandingEnabled') { Set-Reg $cdm $n 0 }
}

# ---------- 9. NI services: delayed start only ----------
Step 'NI services -> Automatic (Delayed Start). Nothing is disabled.' {
    Get-CimInstance Win32_Service | Where-Object {
        $_.StartMode -eq 'Auto' -and -not $_.DelayedAutoStart -and
        ($_.DisplayName -match '^(NI |National Instruments)' -or $_.PathName -match 'National Instruments')
    } | ForEach-Object {
        & sc.exe config $_.Name start= delayed-auto | Out-Null
        Say "   delayed: $($_.Name)  [$($_.DisplayName)]"
    }
}

# ---------- 10. VBS / nested virtualization check ----------
Step 'Virtualization-based security check (nested virtualization is costly under QEMU)' {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    Say "   VBS status: $($dg.VirtualizationBasedSecurityStatus)  (0 off, 1 enabled-not-running, 2 running); services running: $($dg.SecurityServicesRunning -join ',')"
    if ($dg.VirtualizationBasedSecurityStatus -ne 0) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
        Say '   VBS/HVCI switched off in registry (effective after reboot)'
    }
    foreach ($f in 'Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Containers-DisposableClientVM') {
        $s = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($s -and $s.State -eq 'Enabled') { Say "   WARNING optional feature enabled: $f (consider disabling)" }
    }
}

# ---------- 11. filesystem ----------
Step 'NTFS: stop last-access timestamp writes' {
    & fsutil.exe behavior set disablelastaccess 1 | Out-Null
}

# ---------- 12. optional cleanup ----------
if ($Cleanup) {
    Step 'Cleanup: component store, update download cache, temp files' {
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $env:TEMP -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'tweaks2-log.txt' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 13. snapshot for before/after comparison ----------
Step 'Snapshot (compare against your baseline)' {
    $os = Get-CimInstance Win32_OperatingSystem
    Say ('   RAM total {0:N0} MB, free {1:N0} MB' -f ($os.TotalVisibleMemorySize / 1KB), ($os.FreePhysicalMemory / 1KB))
    try { Say "   Memory compression: $((Get-MMAgent).MemoryCompression)  (leave this ON on a RAM-starved guest)" } catch { }
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 12 | ForEach-Object {
        Say ('   {0,-28} {1,6:N0} MB' -f $_.ProcessName, ($_.WorkingSet64 / 1MB))
    }
}

Say ("---- phase 2 done. REBOOT to apply pagefile, hibernation, service and VBS changes. Log: {0}" -f $LogFile)
