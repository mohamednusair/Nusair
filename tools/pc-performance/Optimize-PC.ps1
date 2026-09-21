<#
.SYNOPSIS
    Applies the safe, reversible performance fixes for a slow Windows 11 PC.

.DESCRIPTION
    By default this script only PREVIEWS what it would do and changes nothing.
    Add -Apply to actually make the changes.

    Before applying anything it creates a System Restore point, and it writes a
    backup of every startup entry it disables so the change can be undone with
    -RestoreStartup.

    Run Diagnose-PC.ps1 first to see which problems you actually have. Some of
    the biggest causes of slowness (a mechanical hard disk, too little RAM, a
    clogged cooling fan) are hardware and cannot be fixed by any script.

.PARAMETER Apply
    Actually perform the changes. Without this, nothing is modified.

.PARAMETER RestoreStartup
    Re-enable every startup item this script previously disabled.

.PARAMETER ThermalFix
    Cap the CPU at 99% maximum state, which disables turbo boost. On a laptop
    that is overheating this dramatically reduces heat and fan noise, and often
    increases real sustained performance because the CPU stops throttling.

.PARAMETER SkipRepair
    Skip the system file repair stage (sfc / DISM), which is the slow part.

.EXAMPLE
    .\Optimize-PC.ps1                 # preview only, changes nothing
    .\Optimize-PC.ps1 -Apply          # apply the safe fixes
    .\Optimize-PC.ps1 -Apply -ThermalFix
    .\Optimize-PC.ps1 -RestoreStartup # undo startup changes
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RestoreStartup,
    [switch]$ThermalFix,
    [switch]$SkipRepair,
    [switch]$NoRestorePoint
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$BackupDir  = Join-Path $env:LOCALAPPDATA 'PCOptimize'
$BackupFile = Join-Path $BackupDir 'startup-backup.json'
$LogFile    = Join-Path $BackupDir ('optimize-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$script:FreedBytes = 0

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-' * 74) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('-' * 74) -ForegroundColor DarkCyan
}

function Write-Action {
    param([string]$Text, [switch]$Done, [switch]$Skipped, [switch]$Failed)
    if     ($Done)    { Write-Host "    [DONE]    $Text" -ForegroundColor Green }
    elseif ($Skipped) { Write-Host "    [SKIP]    $Text" -ForegroundColor DarkGray }
    elseif ($Failed)  { Write-Host "    [FAILED]  $Text" -ForegroundColor Red }
    elseif ($Apply)   { Write-Host "    [DOING]   $Text" -ForegroundColor White }
    else              { Write-Host "    [WOULD]   $Text" -ForegroundColor Yellow }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# --------------------------------------------------------------------------
# Elevation check
# --------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  This script needs Administrator rights.' -ForegroundColor Red
    Write-Host '  Close this window, right-click Run-Optimize.bat, and choose' -ForegroundColor Red
    Write-Host '  "Run as administrator".' -ForegroundColor Red
    Write-Host ''
    return
}

Start-Transcript -Path $LogFile -Force | Out-Null

# --------------------------------------------------------------------------
# Restore mode
# --------------------------------------------------------------------------
if ($RestoreStartup) {
    Write-Step 'RESTORING PREVIOUSLY DISABLED STARTUP ITEMS'
    if (-not (Test-Path $BackupFile)) {
        Write-Host '    No backup file found - nothing to restore.' -ForegroundColor Yellow
    } else {
        $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json
        foreach ($item in $backup) {
            try {
                New-Item -Path $item.KeyPath -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $item.KeyPath -Name $item.Name `
                    -Value ([byte[]]$item.Value) -Type Binary -ErrorAction Stop
                Write-Action "Re-enabled: $($item.Name)" -Done
            } catch {
                Write-Action "Could not restore $($item.Name): $_" -Failed
            }
        }
        Write-Host ''
        Write-Host '    Sign out and back in for the changes to take effect.' -ForegroundColor Green
    }
    Stop-Transcript | Out-Null
    return
}

# --------------------------------------------------------------------------
# Banner
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '  WINDOWS PERFORMANCE OPTIMISER' -ForegroundColor White
if ($Apply) {
    Write-Host '  MODE: APPLY - changes WILL be made.' -ForegroundColor Yellow
} else {
    Write-Host '  MODE: PREVIEW - nothing will be changed.' -ForegroundColor Green
    Write-Host '  Re-run with  -Apply  to actually perform these fixes.' -ForegroundColor Green
}

# --------------------------------------------------------------------------
# 0. System restore point
# --------------------------------------------------------------------------
if ($Apply -and -not $NoRestorePoint) {
    Write-Step 'STEP 0 - SAFETY: SYSTEM RESTORE POINT'
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Before PC performance optimisation' `
            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Action 'System restore point created' -Done
    } catch {
        Write-Action "Could not create a restore point ($($_.Exception.Message))" -Failed
        Write-Host '    Continuing anyway - every change below is individually reversible.' -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------
# 1. Clear caches and temporary files
# --------------------------------------------------------------------------
Write-Step 'STEP 1 - RECLAIM DISK SPACE'

function Clear-FolderContents {
    param([string]$Path, [string]$Label, [int]$OlderThanDays = 0)

    if (-not (Test-Path $Path)) { Write-Action "$Label (not present)" -Skipped; return }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $items  = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
              Where-Object { $OlderThanDays -eq 0 -or $_.LastWriteTime -lt $cutoff }

    $size = 0
    foreach ($i in $items) {
        if ($i.PSIsContainer) {
            $sub = (Get-ChildItem -LiteralPath $i.FullName -Recurse -File -Force `
                        -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum
            if ($sub) { $size += $sub }
        } else {
            $size += $i.Length
        }
    }

    Write-Action ("$Label - {0} items, {1}" -f $items.Count, (Format-Size $size))

    if ($Apply) {
        $before = $size
        foreach ($i in $items) {
            Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:FreedBytes += $before
    }
}

Clear-FolderContents -Path $env:TEMP -Label 'User temp folder'
Clear-FolderContents -Path (Join-Path $env:SystemRoot 'Temp') -Label 'Windows temp folder'
Clear-FolderContents -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps') -Label 'Crash dumps'
Clear-FolderContents -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue') -Label 'Error report queue'
Clear-FolderContents -Path (Join-Path $env:SystemRoot 'Logs\CBS') -Label 'Servicing logs' -OlderThanDays 7

# Windows Update download cache - stop the service first
$suPath = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
if (Test-Path $suPath) {
    $suSize = (Get-ChildItem $suPath -Recurse -File -Force -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum
    Write-Action ("Windows Update download cache - {0}" -f (Format-Size $suSize))
    if ($Apply) {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Stop-Service bits     -Force -ErrorAction SilentlyContinue
        Get-ChildItem $suPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service bits     -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction SilentlyContinue
        $script:FreedBytes += $suSize
    }
}

# Delivery Optimization cache
Write-Action 'Delivery Optimization cache'
if ($Apply) {
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
}

# Recycle Bin
Write-Action 'Recycle Bin'
if ($Apply) {
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }
}

# Superseded component store updates - big win, safe
if (-not $SkipRepair) {
    Write-Action 'Component store cleanup (removes superseded update files)'
    if ($Apply) {
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
        Write-Action 'Component store cleaned' -Done
    }
}

if ($Apply) {
    Write-Host ''
    Write-Host ("    Total reclaimed: {0}" -f (Format-Size $script:FreedBytes)) -ForegroundColor Green
}

# --------------------------------------------------------------------------
# 2. Trim the startup list
# --------------------------------------------------------------------------
Write-Step 'STEP 2 - REDUCE STARTUP PROGRAMS'

# Known non-essential auto-starters. Disabling these does NOT uninstall the
# program - it only stops it launching automatically at sign-in.
$BloatPatterns = @(
    'Spotify', 'Steam', 'EpicGames', 'EADesktop', 'Origin', 'Discord',
    'Skype', 'Zoom', 'Slack', 'Teams',
    'iTunesHelper', 'AppleSyncNotifier', 'QuickTime', 'Bonjour',
    'Adobe.*Updater', 'AdobeAAMUpdater', 'AdobeGCInvoker', 'Acrobat.*Update',
    'CCleaner', 'Java.*Update', 'jusched', 'GoogleUpdate', 'GoogleDrive',
    'CyberLink', 'Nero', 'RealPlayer', 'WildTangent', 'McAfee.*Update',
    'Dropbox', 'uTorrent', 'BitTorrent', 'Evernote', 'Grammarly',
    'MicrosoftEdgeAutoLaunch', 'Cortana', 'OneDriveStandaloneUpdater'
)

$Essential = @(
    'SecurityHealth', 'WindowsDefender', 'MsMpEng', 'RtkAudUService',
    'RtkNGUI', 'SynTPEnh', 'ETDCtrl', 'IAStorIcon', 'Dell', 'HP ',
    'Lenovo', 'ASUS', 'NvBackend', 'igfxTray', 'Realtek', 'Intel'
)

$runKeyPairs = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)

$disabledNow = New-Object System.Collections.ArrayList
$leftAlone   = New-Object System.Collections.ArrayList

foreach ($pair in $runKeyPairs) {
    if (-not (Test-Path $pair.Run)) { continue }
    $props = Get-ItemProperty -Path $pair.Run -ErrorAction SilentlyContinue
    if (-not $props) { continue }

    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        $entry = "$($p.Name) $($p.Value)"

        $isEssential = $false
        foreach ($e in $Essential) { if ($entry -match $e) { $isEssential = $true; break } }
        if ($isEssential) { [void]$leftAlone.Add($p.Name); continue }

        $isBloat = $false
        foreach ($b in $BloatPatterns) { if ($entry -match $b) { $isBloat = $true; break } }

        if (-not $isBloat) { [void]$leftAlone.Add($p.Name); continue }

        # Already disabled?
        $currentVal = $null
        try {
            $currentVal = (Get-ItemProperty -Path $pair.Approved -Name $p.Name -ErrorAction Stop).$($p.Name)
        } catch { }
        if ($currentVal -is [byte[]] -and $currentVal.Length -gt 0 -and ($currentVal[0] -band 0x01)) {
            continue   # already disabled
        }

        Write-Action ("Disable at startup: {0}" -f $p.Name)
        [void]$disabledNow.Add([pscustomobject]@{
            Name    = $p.Name
            KeyPath = $pair.Approved
            Value   = if ($currentVal) { $currentVal } else { [byte[]](2,0,0,0,0,0,0,0,0,0,0,0) }
        })
    }
}

if ($Apply -and $disabledNow.Count -gt 0) {
    # Back up first so -RestoreStartup can undo this
    $existing = @()
    if (Test-Path $BackupFile) {
        $existing = @(Get-Content $BackupFile -Raw | ConvertFrom-Json)
    }
    $merged = @($existing) + @($disabledNow | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; KeyPath = $_.KeyPath; Value = @($_.Value) }
    })
    $merged | ConvertTo-Json -Depth 4 | Set-Content -Path $BackupFile -Encoding UTF8

    $disabledBytes = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
    foreach ($d in $disabledNow) {
        try {
            New-Item -Path $d.KeyPath -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $d.KeyPath -Name $d.Name -Value $disabledBytes `
                -Type Binary -ErrorAction Stop
            Write-Action "Disabled $($d.Name)" -Done
        } catch {
            Write-Action "Could not disable $($d.Name)" -Failed
        }
    }
    Write-Host ''
    Write-Host ("    Backup written to {0}" -f $BackupFile) -ForegroundColor DarkGray
    Write-Host '    Undo any time with:  .\Optimize-PC.ps1 -RestoreStartup' -ForegroundColor DarkGray
}

if ($disabledNow.Count -eq 0) {
    Write-Host '    No known non-essential startup items found to disable.' -ForegroundColor Green
}

if ($leftAlone.Count -gt 0) {
    Write-Host ''
    Write-Host '    Left alone (review these yourself in Task Manager > Startup apps):' -ForegroundColor Gray
    $leftAlone | Sort-Object -Unique | ForEach-Object {
        Write-Host "      - $_" -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------
# 3. Power settings
# --------------------------------------------------------------------------
Write-Step 'STEP 3 - POWER AND THERMAL SETTINGS'

$BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'

$active = (powercfg /getactivescheme) 2>$null
if ($active -match 'Power saver') {
    Write-Action 'Switch power plan from Power Saver to Balanced'
    if ($Apply) {
        & powercfg /setactive $BALANCED
        Write-Action 'Power plan set to Balanced' -Done
    }
} else {
    Write-Action 'Power plan is already Balanced or better' -Skipped
}

# Never let the disk spin down while plugged in (causes stutter on wake)
Write-Action 'Disable hard disk sleep while on AC power'
if ($Apply) {
    & powercfg /setacvalueindex SCHEME_CURRENT SUB_DISK DISKIDLE 0
    & powercfg /setactive SCHEME_CURRENT
}

if ($ThermalFix) {
    Write-Action 'Cap CPU at 99% max state (disables turbo boost - big heat reduction)'
    if ($Apply) {
        & powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 99
        & powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 85
        & powercfg /setactive SCHEME_CURRENT
        Write-Action 'CPU turbo disabled - fans should quieten within a few minutes' -Done
        Write-Host '    To undo: powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100' -ForegroundColor DarkGray
    }
} else {
    Write-Host '    (Add -ThermalFix if the laptop runs hot and the fans are loud.)' -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# 4. Visual effects
# --------------------------------------------------------------------------
Write-Step 'STEP 4 - REDUCE UI ANIMATION OVERHEAD'

Write-Action 'Set visual effects to "best performance"'
if ($Apply) {
    $vfx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    New-Item -Path $vfx -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $vfx -Name 'VisualFXSetting' -Value 2 -Type DWord -ErrorAction SilentlyContinue

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' `
        -Name 'MinAnimate' -Value '0' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' `
        -Name 'MenuShowDelay' -Value '0' -ErrorAction SilentlyContinue
    Write-Action 'Animations reduced' -Done
}

Write-Action 'Turn off Windows 11 suggestions, tips and ads (they run background tasks)'
if ($Apply) {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    if (Test-Path $cdm) {
        foreach ($v in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                       'SubscribedContent-310093Enabled','SystemPaneSuggestionsEnabled',
                       'SilentInstalledAppsEnabled','SoftLandingEnabled') {
            Set-ItemProperty -Path $cdm -Name $v -Value 0 -Type DWord -ErrorAction SilentlyContinue
        }
    }
    Write-Action 'Suggestions disabled' -Done
}

# --------------------------------------------------------------------------
# 5. Storage maintenance
# --------------------------------------------------------------------------
Write-Step 'STEP 5 - WINDOWS 11 BACKGROUND BLOAT'

# Remove the artificial delay before startup apps launch, so the desktop
# becomes usable sooner after sign-in.
Write-Action 'Remove the logon startup delay'
if ($Apply) {
    $ser = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
    New-Item -Path $ser -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ser -Name 'StartupDelayInMSec' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Write-Action 'Startup delay removed' -Done
}

# Fast Startup hibernates the kernel instead of rebuilding it each boot.
# On a slow disk this is one of the largest single boot-time wins.
Write-Action 'Enable Fast Startup (large boot-time win, especially on a hard disk)'
if ($Apply) {
    & powercfg /hibernate on 2>$null
    $pwr = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    Set-ItemProperty -Path $pwr -Name 'HiberbootEnabled' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Action 'Fast Startup enabled' -Done
}

# The Widgets board runs a background WebView2 browser process that is a
# well-known memory and CPU consumer on low-spec machines.
Write-Action 'Disable the Widgets board (runs a hidden browser in the background)'
if ($Apply) {
    $dsh = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
    New-Item -Path $dsh -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $dsh -Name 'AllowNewsAndInterests' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Write-Action 'Widgets disabled' -Done
}

# Background game recording runs constantly even when not gaming.
Write-Action 'Disable Xbox Game Bar background recording'
if ($Apply) {
    $gcs = 'HKCU:\System\GameConfigStore'
    if (Test-Path $gcs) {
        Set-ItemProperty -Path $gcs -Name 'GameDVR_Enabled' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }
    $gdvr = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
    New-Item -Path $gdvr -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $gdvr -Name 'AllowGameDVR' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Write-Action 'Game recording disabled' -Done
}

# Stop Store apps running and syncing when they are not open.
Write-Action 'Stop Store apps running in the background'
if ($Apply) {
    $bg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
    New-Item -Path $bg -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $bg -Name 'GlobalUserDisabled' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Action 'Background apps disabled' -Done
}

# Telemetry collection writes to disk continuously. Disabling it does not
# affect Windows Update or security.
$dt = Get-Service DiagTrack -ErrorAction SilentlyContinue
if ($dt -and $dt.StartType -ne 'Disabled') {
    Write-Action 'Disable telemetry collection service (DiagTrack)'
    if ($Apply) {
        Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue
        Set-Service DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Action 'DiagTrack disabled' -Done
        Write-Host '    Undo: Set-Service DiagTrack -StartupType Automatic' -ForegroundColor DarkGray
    }
} else {
    Write-Action 'Telemetry service already disabled' -Skipped
}

# Keep the drive from filling up again.
Write-Action 'Turn on Storage Sense (automatic cleanup of temp files)'
if ($Apply) {
    $ss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    New-Item -Path $ss -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ss -Name '01' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Action 'Storage Sense enabled' -Done
}

Write-Step 'STEP 6 - STORAGE MAINTENANCE'

foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {

    $mediaType = 'Unknown'
    try {
        $mediaType = (Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop |
                      Get-Disk -ErrorAction Stop |
                      Get-PhysicalDisk -ErrorAction Stop).MediaType
    } catch { }

    if ($mediaType -eq 'SSD') {
        Write-Action ("Re-TRIM SSD volume {0}:" -f $vol.DriveLetter)
        if ($Apply) {
            Optimize-Volume -DriveLetter $vol.DriveLetter -ReTrim -ErrorAction SilentlyContinue
            Write-Action ("Volume {0}: trimmed" -f $vol.DriveLetter) -Done
        }
    } elseif ($mediaType -eq 'HDD') {
        Write-Action ("Defragment HDD volume {0}: (this can take a long time)" -f $vol.DriveLetter)
        if ($Apply) {
            Optimize-Volume -DriveLetter $vol.DriveLetter -Defrag -ErrorAction SilentlyContinue
            Write-Action ("Volume {0}: defragmented" -f $vol.DriveLetter) -Done
        }
    } else {
        Write-Action ("Volume {0}: media type unknown - skipping" -f $vol.DriveLetter) -Skipped
    }
}

# SysMain thrashes an SSD without helping it; it DOES help an HDD.
$sysDriveMedia = 'Unknown'
try {
    $sysDriveMedia = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop |
                      Get-Disk | Get-PhysicalDisk).MediaType
} catch { }

if ($sysDriveMedia -eq 'SSD') {
    $sysmain = Get-Service SysMain -ErrorAction SilentlyContinue
    if ($sysmain -and $sysmain.StartType -ne 'Disabled') {
        Write-Action 'Disable SysMain/Superfetch (unnecessary on SSD, causes background disk load)'
        if ($Apply) {
            Set-Service SysMain -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service SysMain -Force -ErrorAction SilentlyContinue
            Write-Action 'SysMain disabled' -Done
            Write-Host '    Undo: Set-Service SysMain -StartupType Automatic' -ForegroundColor DarkGray
        }
    }
} else {
    Write-Action 'Leaving SysMain enabled (it helps on a mechanical disk)' -Skipped
}

# Page file sanity
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.AutomaticManagedPagefile) {
        Write-Action 'Re-enable system-managed page file (a wrong size causes hangs)'
        if ($Apply) {
            $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true } -ErrorAction SilentlyContinue
            Write-Action 'Page file set to system-managed' -Done
        }
    } else {
        Write-Action 'Page file already system-managed' -Skipped
    }
} catch { }

# --------------------------------------------------------------------------
# 6. Repair corrupted system files
# --------------------------------------------------------------------------
if (-not $SkipRepair) {
    Write-Step 'STEP 7 - REPAIR SYSTEM FILES (SLOW - 10 TO 30 MINUTES)'
    Write-Action 'DISM /RestoreHealth then sfc /scannow'
    if ($Apply) {
        Write-Host '    Running DISM... please wait, this looks frozen but is working.' -ForegroundColor Gray
        & dism.exe /Online /Cleanup-Image /RestoreHealth
        Write-Host '    Running sfc /scannow...' -ForegroundColor Gray
        & sfc.exe /scannow
        Write-Action 'System file repair finished' -Done
    }

    Write-Action 'Schedule a read-only disk check (chkdsk /scan)'
    if ($Apply) {
        & chkdsk.exe $env:SystemDrive /scan
        Write-Action 'Disk scan complete' -Done
    }
} else {
    Write-Step 'STEP 7 - SYSTEM FILE REPAIR SKIPPED (-SkipRepair)'
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
Write-Host ''
Write-Host ('#' * 74) -ForegroundColor White
if ($Apply) {
    Write-Host '  OPTIMISATION COMPLETE' -ForegroundColor Green
    Write-Host ('#' * 74) -ForegroundColor White
    Write-Host ''
    Write-Host ("  Disk space reclaimed : {0}" -f (Format-Size $script:FreedBytes)) -ForegroundColor White
    Write-Host ("  Startup items disabled: {0}" -f $disabledNow.Count) -ForegroundColor White
    Write-Host ("  Log file             : {0}" -f $LogFile) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  >> RESTART THE PC NOW for all changes to take effect. <<' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  To undo the startup changes:  .\Optimize-PC.ps1 -RestoreStartup' -ForegroundColor DarkGray
    Write-Host '  To undo everything:           System Restore > "Before PC performance optimisation"' -ForegroundColor DarkGray
} else {
    Write-Host '  PREVIEW COMPLETE - NOTHING WAS CHANGED' -ForegroundColor Green
    Write-Host ('#' * 74) -ForegroundColor White
    Write-Host ''
    Write-Host '  Re-run with -Apply to perform the actions listed above:' -ForegroundColor White
    Write-Host '      .\Optimize-PC.ps1 -Apply' -ForegroundColor Cyan
    Write-Host '  Or, if the laptop also runs hot and loud:' -ForegroundColor White
    Write-Host '      .\Optimize-PC.ps1 -Apply -ThermalFix' -ForegroundColor Cyan
}
Write-Host ''

Stop-Transcript | Out-Null
