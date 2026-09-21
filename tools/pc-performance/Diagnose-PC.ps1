<#
.SYNOPSIS
    Read-only performance diagnosis for a slow Windows 11 PC.

.DESCRIPTION
    Collects the measurements that actually explain a slow boot, hangs, slow
    app launches and thermal throttling, then prints a prioritised list of
    findings with the fix for each one.

    This script CHANGES NOTHING. It only reads. Run it first, then run
    Optimize-PC.ps1 to apply the safe fixes.

.EXAMPLE
    .\Diagnose-PC.ps1
    .\Diagnose-PC.ps1 -ReportPath C:\Users\Me\Desktop\pc-report.txt
#>

[CmdletBinding()]
param(
    [string]$ReportPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'pc-performance-report.txt')
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# --------------------------------------------------------------------------
# Findings collection
# --------------------------------------------------------------------------
$script:Findings = New-Object System.Collections.ArrayList

function Add-Finding {
    param(
        [ValidateSet('CRITICAL','HIGH','MEDIUM','LOW')][string]$Severity,
        [string]$Area,
        [string]$Issue,
        [string]$Fix
    )
    [void]$script:Findings.Add([pscustomobject]@{
        Severity = $Severity
        Area     = $Area
        Issue    = $Issue
        Fix      = $Fix
    })
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}

function Write-Item {
    param([string]$Label, $Value, [string]$Colour = 'Gray')
    Write-Host ('  {0,-34}' -f ($Label + ':')) -NoNewline
    Write-Host " $Value" -ForegroundColor $Colour
}

function Format-GB { param([double]$Bytes) '{0:N1} GB' -f ($Bytes / 1GB) }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Start-Transcript -Path $ReportPath -Force | Out-Null

Write-Host ''
Write-Host '  WINDOWS PERFORMANCE DIAGNOSIS' -ForegroundColor White
Write-Host ("  Run at {0}" -f (Get-Date)) -ForegroundColor DarkGray
if (-not $isAdmin) {
    Write-Host '  NOTE: not running as Administrator - some checks will be skipped.' -ForegroundColor Yellow
    Write-Host '        Right-click Run-Diagnose.bat and choose "Run as administrator".' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# 1. System summary
# --------------------------------------------------------------------------
Write-Section 'SYSTEM'

$os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs  = Get-CimInstance Win32_ComputerSystem  -ErrorAction SilentlyContinue
$cpu = @(Get-CimInstance Win32_Processor     -ErrorAction SilentlyContinue)[0]

$totalRamGB = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 }

if ($cs)  { Write-Item 'Model'      ("{0} {1}" -f $cs.Manufacturer, $cs.Model) }
if ($os)  { Write-Item 'Windows'    ("{0} (build {1})" -f $os.Caption, $os.BuildNumber) }
if ($cpu) { Write-Item 'CPU'        ("{0} ({1} cores / {2} threads)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors) }
Write-Item 'Installed RAM' ("{0} GB" -f $totalRamGB)

if ($os) {
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Item 'Last boot' ("{0}  ({1:N0}d {2}h {3}m ago)" -f $os.LastBootUpTime, $uptime.Days, $uptime.Hours, $uptime.Minutes)
    if ($uptime.TotalDays -gt 14) {
        Add-Finding -Severity 'MEDIUM' -Area 'Uptime' `
            -Issue  ("The PC has not been restarted in {0:N0} days." -f $uptime.TotalDays) `
            -Fix    'Restart the PC. Long uptime leaks memory and fragments the page file.'
    }
}

if ($totalRamGB -gt 0 -and $totalRamGB -lt 8) {
    Add-Finding -Severity 'CRITICAL' -Area 'RAM' `
        -Issue  ("Only {0} GB of RAM installed. Windows 11 needs 8 GB to be comfortable, 16 GB to be fast." -f $totalRamGB) `
        -Fix    'Add RAM. This is the single biggest cause of hangs and freezing on a machine this size.'
} elseif ($totalRamGB -ge 8 -and $totalRamGB -lt 12) {
    Add-Finding -Severity 'MEDIUM' -Area 'RAM' `
        -Issue  ("{0} GB of RAM. Adequate, but browsers plus Office will push it into swapping." -f $totalRamGB) `
        -Fix    'Consider upgrading to 16 GB if hangs persist after the other fixes.'
}

# --------------------------------------------------------------------------
# 2. Storage - the usual culprit
# --------------------------------------------------------------------------
Write-Section 'STORAGE'

$systemDriveLetter = ($env:SystemDrive).TrimEnd(':')
$hasHDD = $false

try {
    $disks = Get-PhysicalDisk -ErrorAction Stop
    foreach ($d in $disks) {
        $media = $d.MediaType
        if (-not $media -or $media -eq 'Unspecified') {
            $media = switch ($d.SpindleSpeed) {
                0       { 'SSD (inferred)' }
                $null   { 'Unknown' }
                default { 'HDD (inferred)' }
            }
        }
        $colour = if ("$media" -like 'HDD*') { 'Red' } else { 'Green' }
        Write-Item ("Disk {0}" -f $d.DeviceId) ("{0} - {1} - {2} - health: {3}" -f `
            $d.FriendlyName, $media, (Format-GB $d.Size), $d.HealthStatus) $colour

        if ("$media" -like 'HDD*') { $hasHDD = $true }

        if ($d.HealthStatus -ne 'Healthy') {
            Add-Finding -Severity 'CRITICAL' -Area 'Disk health' `
                -Issue  ("Disk '{0}' reports health status '{1}'. A failing drive causes exactly the freezing you describe." -f $d.FriendlyName, $d.HealthStatus) `
                -Fix    'Back up your data NOW, then replace the drive. Do not postpone this.'
        }

        # Wear + reallocated sectors
        try {
            $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($rel.Wear -ne $null -and $rel.Wear -gt 80) {
                Add-Finding -Severity 'HIGH' -Area 'Disk health' `
                    -Issue  ("SSD '{0}' is at {1}% of its rated write life." -f $d.FriendlyName, $rel.Wear) `
                    -Fix    'Plan a replacement; performance degrades sharply near end of life.'
            }
            if ($rel.ReadErrorsTotal -gt 0 -or $rel.WriteErrorsTotal -gt 0) {
                Add-Finding -Severity 'HIGH' -Area 'Disk health' `
                    -Issue  ("Disk '{0}' has logged {1} read and {2} write errors." -f $d.FriendlyName, $rel.ReadErrorsTotal, $rel.WriteErrorsTotal) `
                    -Fix    'Back up immediately and run chkdsk. Recurring errors mean the drive is dying.'
            }
            if ($rel.Temperature -and $rel.Temperature -gt 60) {
                Add-Finding -Severity 'MEDIUM' -Area 'Thermals' `
                    -Issue  ("Disk '{0}' is running at {1} C." -f $d.FriendlyName, $rel.Temperature) `
                    -Fix    'Improve airflow; NVMe drives throttle hard above 70 C.'
            }
        } catch { }
    }
} catch {
    Write-Host '  Could not read physical disk info (needs Administrator).' -ForegroundColor Yellow
}

if ($hasHDD) {
    Add-Finding -Severity 'CRITICAL' -Area 'Storage' `
        -Issue  'This PC boots from a mechanical hard disk (HDD). On Windows 11 an HDD is by far the most common reason for a slow boot, long app launch times and the whole machine freezing while the disk catches up.' `
        -Fix    'Replace it with an SSD (SATA or NVMe). This is the single highest-impact fix available - typically 5-10x faster boot and app launches. Nothing in software fully compensates for it.'
}

foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
    $freePct = if ($vol.Size -gt 0) { [math]::Round(100 * $vol.SizeRemaining / $vol.Size, 1) } else { 0 }
    $colour  = if ($freePct -lt 10) { 'Red' } elseif ($freePct -lt 20) { 'Yellow' } else { 'Green' }
    Write-Item ("Volume {0}:" -f $vol.DriveLetter) `
        ("{0} free of {1}  ({2}%)" -f (Format-GB $vol.SizeRemaining), (Format-GB $vol.Size), $freePct) $colour

    if ($vol.DriveLetter -eq $systemDriveLetter -and $freePct -lt 15) {
        $sev = if ($freePct -lt 7) { 'CRITICAL' } else { 'HIGH' }
        Add-Finding -Severity $sev -Area 'Disk space' `
            -Issue  ("The Windows drive ({0}:) is {1}% free. Below roughly 15% Windows cannot manage the page file or updates properly and the whole system stalls." -f $vol.DriveLetter, $freePct) `
            -Fix    'Run Optimize-PC.ps1 -Apply to clear caches, then uninstall unused programs and move large files off this drive.'
    }
}

# --------------------------------------------------------------------------
# 3. Memory pressure right now
# --------------------------------------------------------------------------
Write-Section 'MEMORY PRESSURE (RIGHT NOW)'

if ($os) {
    $freeGB   = $os.FreePhysicalMemory / 1MB
    $totGB    = $os.TotalVisibleMemorySize / 1MB
    $usedPct  = [math]::Round(100 * ($totGB - $freeGB) / $totGB, 1)
    $colour   = if ($usedPct -gt 90) { 'Red' } elseif ($usedPct -gt 80) { 'Yellow' } else { 'Green' }
    Write-Item 'RAM in use' ("{0}%  ({1:N1} GB free of {2:N1} GB)" -f $usedPct, $freeGB, $totGB) $colour

    $commitUsedGB  = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB
    $commitLimitGB = $os.TotalVirtualMemorySize / 1MB
    Write-Item 'Commit charge' ("{0:N1} GB of {1:N1} GB" -f $commitUsedGB, $commitLimitGB)

    if ($usedPct -gt 85) {
        Add-Finding -Severity 'HIGH' -Area 'RAM' `
            -Issue  ("Memory is {0}% used at idle-ish load. Windows is paging to disk, which is what produces the freezes and beachballing." -f $usedPct) `
            -Fix    'Close background apps, cut the startup list (see below), and add RAM if possible.'
    }
}

Write-Host ''
Write-Host '  Top 8 memory consumers:' -ForegroundColor White
Get-Process -ErrorAction SilentlyContinue |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 8 |
    ForEach-Object {
        Write-Host ('    {0,-32} {1,10}' -f $_.ProcessName, (Format-GB $_.WorkingSet64)) -ForegroundColor Gray
    }

Write-Host ''
Write-Host '  Top 8 CPU consumers (total CPU seconds since start):' -ForegroundColor White
Get-Process -ErrorAction SilentlyContinue |
    Sort-Object CPU -Descending |
    Select-Object -First 8 |
    ForEach-Object {
        Write-Host ('    {0,-32} {1,10:N0} s' -f $_.ProcessName, $_.CPU) -ForegroundColor Gray
    }

# --------------------------------------------------------------------------
# 4. Disk activity - is the disk pinned at 100%?
# --------------------------------------------------------------------------
Write-Section 'DISK ACTIVITY'

try {
    $samples = 1..4 | ForEach-Object {
        $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
                -Filter "Name='_Total'" -ErrorAction Stop
        Start-Sleep -Milliseconds 700
        $d
    }
    $avgBusy  = [math]::Round((($samples | Measure-Object -Property PercentDiskTime  -Average).Average), 0)
    $avgQueue = [math]::Round((($samples | Measure-Object -Property CurrentDiskQueueLength -Average).Average), 2)
    $colour   = if ($avgBusy -gt 80) { 'Red' } elseif ($avgBusy -gt 50) { 'Yellow' } else { 'Green' }
    Write-Item 'Average disk busy' ("{0}%" -f $avgBusy) $colour
    Write-Item 'Average queue length' $avgQueue

    if ($avgBusy -gt 80) {
        Add-Finding -Severity 'HIGH' -Area 'Disk' `
            -Issue  ("The disk is {0}% busy while essentially idle. Everything else waits behind it - this is the direct cause of the hangs." -f $avgBusy) `
            -Fix    'Open Task Manager > Processes > sort by Disk to see the offender. Common culprits: Windows Update, search indexing, OneDrive sync, antivirus scan, a failing drive.'
    }
} catch {
    Write-Host '  Disk performance counters unavailable.' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# 5. Startup programs - the slow-boot cause
# --------------------------------------------------------------------------
Write-Section 'STARTUP PROGRAMS'

function Get-StartupApprovedState {
    param([string]$Name, [string]$Scope)
    $paths = if ($Scope -eq 'HKCU') {
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')
    } else {
        @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
          'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')
    }
    foreach ($p in $paths) {
        try {
            $v = Get-ItemProperty -Path $p -Name $Name -ErrorAction Stop
            $bytes = $v.$Name
            if ($bytes -is [byte[]] -and $bytes.Length -gt 0) {
                # 0x02 / 0x06 = enabled, 0x03 / 0x07 = disabled
                if ($bytes[0] -band 0x01) { return 'Disabled' } else { return 'Enabled' }
            }
        } catch { }
    }
    return 'Enabled'
}

$startupItems = New-Object System.Collections.ArrayList

$runKeys = @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Scope = 'HKCU' },
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Scope = 'HKLM' },
    @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'HKLM' }
)

foreach ($k in $runKeys) {
    try {
        $props = Get-ItemProperty -Path $k.Path -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            [void]$startupItems.Add([pscustomobject]@{
                Name    = $p.Name
                Command = "$($p.Value)"
                Source  = $k.Path
                State   = Get-StartupApprovedState -Name $p.Name -Scope $k.Scope
            })
        }
    } catch { }
}

foreach ($folder in @(
    [Environment]::GetFolderPath('Startup'),
    [Environment]::GetFolderPath('CommonStartup')
)) {
    if ($folder -and (Test-Path $folder)) {
        Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$startupItems.Add([pscustomobject]@{
                Name    = $_.BaseName
                Command = $_.FullName
                Source  = 'Startup folder'
                State   = 'Enabled'
            })
        }
    }
}

$enabled = @($startupItems | Where-Object State -eq 'Enabled')
Write-Item 'Startup entries found' ("{0} total, {1} enabled" -f $startupItems.Count, $enabled.Count) `
    $(if ($enabled.Count -gt 10) { 'Red' } elseif ($enabled.Count -gt 6) { 'Yellow' } else { 'Green' })

Write-Host ''
foreach ($i in ($startupItems | Sort-Object State, Name)) {
    $c = if ($i.State -eq 'Enabled') { 'White' } else { 'DarkGray' }
    $cmd = if ($i.Command.Length -gt 70) { $i.Command.Substring(0,67) + '...' } else { $i.Command }
    Write-Host ('    [{0,-8}] {1,-26} {2}' -f $i.State, $i.Name, $cmd) -ForegroundColor $c
}

if ($enabled.Count -gt 8) {
    Add-Finding -Severity 'HIGH' -Area 'Startup' `
        -Issue  ("{0} programs launch at sign-in. Each one competes for disk and CPU during boot, which is why the desktop takes minutes to become usable." -f $enabled.Count) `
        -Fix    'Run Optimize-PC.ps1 -Apply to disable known non-essential auto-starters, or use Task Manager > Startup apps and disable everything you do not need immediately at login.'
}

# Logon scheduled tasks
try {
    $logonTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.State -ne 'Disabled' -and
        $_.TaskPath -notlike '\Microsoft\*' -and
        ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'LogonTrigger|BootTrigger' })
    })
    Write-Host ''
    Write-Item 'Logon/boot scheduled tasks' $logonTasks.Count
    foreach ($t in ($logonTasks | Select-Object -First 15)) {
        Write-Host ('    {0}{1}' -f $t.TaskPath, $t.TaskName) -ForegroundColor Gray
    }
    if ($logonTasks.Count -gt 6) {
        Add-Finding -Severity 'MEDIUM' -Area 'Startup' `
            -Issue  ("{0} third-party scheduled tasks run at logon or boot (updaters, telemetry, launchers)." -f $logonTasks.Count) `
            -Fix    'Open Task Scheduler and disable the ones belonging to software you rarely use (Adobe, Java, Google, browser updaters).'
    }
} catch { }

# --------------------------------------------------------------------------
# 6. Boot timing from the Diagnostics-Performance log
# --------------------------------------------------------------------------
Write-Section 'BOOT PERFORMANCE HISTORY'

try {
    $bootEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        Id      = 100
    } -MaxEvents 5 -ErrorAction Stop

    foreach ($e in $bootEvents) {
        $x = [xml]$e.ToXml()
        $data = @{}
        foreach ($d in $x.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
        $bootMs = [int]$data['BootTime']
        $mainMs = [int]$data['MainPathBootTime']
        $postMs = [int]$data['BootPostBootTime']
        $colour = if ($bootMs -gt 90000) { 'Red' } elseif ($bootMs -gt 45000) { 'Yellow' } else { 'Green' }
        Write-Host ('    {0}   total {1,6:N1}s   (to desktop {2,5:N1}s + post-boot {3,5:N1}s)' -f `
            $e.TimeCreated, ($bootMs/1000), ($mainMs/1000), ($postMs/1000)) -ForegroundColor $colour
    }

    $avgBoot = ($bootEvents | ForEach-Object {
        $x = [xml]$_.ToXml()
        [int]($x.Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text'
    } | Measure-Object -Average).Average

    if ($avgBoot -gt 60000) {
        Add-Finding -Severity 'HIGH' -Area 'Boot' `
            -Issue  ("Average boot time is {0:N0} seconds. A healthy Windows 11 machine with an SSD boots in 15-25 seconds." -f ($avgBoot/1000)) `
            -Fix    'Addressing the storage and startup findings above is what brings this number down.'
    }

    # Events 101-110 name the specific slow component
    $slowEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        Id        = 101,102,103,106,109
        StartTime = (Get-Date).AddDays(-30)
    } -MaxEvents 40 -ErrorAction SilentlyContinue

    if ($slowEvents) {
        Write-Host ''
        Write-Host '  Windows named these as slowing down boot:' -ForegroundColor White
        $slowEvents |
            ForEach-Object {
                $x = [xml]$_.ToXml()
                $d = @{}
                foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
                $label = $d['Name']; if (-not $label) { $label = $d['FriendlyName'] }
                $ms    = $d['TotalTime']; if (-not $ms) { $ms = $d['DegradationTime'] }
                if ($label) {
                    [pscustomobject]@{ Name = $label; Ms = [int]$ms }
                }
            } |
            Group-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    Name  = $_.Name
                    AvgMs = [int](($_.Group | Measure-Object Ms -Average).Average)
                    Hits  = $_.Count
                }
            } |
            Sort-Object AvgMs -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                Write-Host ('    {0,-44} {1,7:N1}s  (x{2})' -f $_.Name, ($_.AvgMs/1000), $_.Hits) -ForegroundColor Yellow
            }
    }
} catch {
    Write-Host '  Boot performance log not available (needs Administrator).' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# 7. Power plan and thermal throttling
# --------------------------------------------------------------------------
Write-Section 'POWER AND THERMALS'

try {
    $scheme = (powercfg /getactivescheme) 2>$null
    Write-Item 'Active power plan' ($scheme -replace '^.*\(' -replace '\)\s*$')
    if ($scheme -match 'Power saver') {
        Add-Finding -Severity 'HIGH' -Area 'Power' `
            -Issue  'The active power plan is Power Saver, which caps CPU speed hard.' `
            -Fix    'Switch to Balanced. Optimize-PC.ps1 -Apply does this automatically.'
    }
} catch { }

if ($cpu) {
    $maxMHz = $cpu.MaxClockSpeed
    $curMHz = $cpu.CurrentClockSpeed
    $pct    = if ($maxMHz) { [math]::Round(100 * $curMHz / $maxMHz, 0) } else { 0 }
    $colour = if ($pct -lt 60) { 'Red' } elseif ($pct -lt 80) { 'Yellow' } else { 'Green' }
    Write-Item 'CPU clock right now' ("{0} MHz of {1} MHz max  ({2}%)" -f $curMHz, $maxMHz, $pct) $colour

    if ($pct -lt 60) {
        Add-Finding -Severity 'HIGH' -Area 'Thermals' `
            -Issue  ("The CPU is running at {0}% of its rated speed. Combined with loud fans, this means thermal throttling: the chip is too hot and is slowing itself down to survive." -f $pct) `
            -Fix    'Clean the fan and heatsink vents with compressed air. If the laptop is more than ~3 years old, have the thermal paste replaced. Also raise the laptop so air can reach the underside intake. This is a hardware fix - no software setting repairs it.'
    }
}

try {
    $tz = Get-CimInstance -Namespace 'root/WMI' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    foreach ($z in $tz) {
        $c = [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1)
        $colour = if ($c -gt 85) { 'Red' } elseif ($c -gt 70) { 'Yellow' } else { 'Green' }
        Write-Item 'Thermal zone' ("{0} C" -f $c) $colour
        if ($c -gt 85) {
            Add-Finding -Severity 'HIGH' -Area 'Thermals' `
                -Issue  ("A thermal sensor reads {0} C. That is throttling territory." -f $c) `
                -Fix    'Clean vents and fans; replace thermal paste; use the laptop on a hard flat surface, never on a bed or cushion.'
        }
    }
} catch {
    Write-Host '  (Motherboard does not expose temperatures to Windows - use HWiNFO64 to read them.)' -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# 8. Security software
# --------------------------------------------------------------------------
Write-Section 'SECURITY SOFTWARE'

try {
    $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    foreach ($a in $av) { Write-Item 'Antivirus' $a.displayName }

    $thirdParty = @($av | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' })
    if ($thirdParty.Count -ge 2) {
        Add-Finding -Severity 'CRITICAL' -Area 'Antivirus' `
            -Issue  ("{0} third-party antivirus products are installed at once ({1}). They scan each other's file access in a loop and can halve disk throughput." -f `
                     $thirdParty.Count, ($thirdParty.displayName -join ', ')) `
            -Fix    'Uninstall all but one. Microsoft Defender alone is sufficient for most users and is the lightest option.'
    } elseif ($thirdParty.Count -eq 1) {
        Add-Finding -Severity 'MEDIUM' -Area 'Antivirus' `
            -Issue  ("Third-party antivirus installed: {0}. These are a common source of slow file access and long boots." -f $thirdParty[0].displayName) `
            -Fix    'Consider removing it and relying on built-in Microsoft Defender, which is significantly lighter.'
    }
} catch { }

# --------------------------------------------------------------------------
# 9. Disconnected network drives - classic Explorer hang
# --------------------------------------------------------------------------
Write-Section 'NETWORK DRIVES'

try {
    $mapped = @(Get-CimInstance Win32_NetworkConnection -ErrorAction SilentlyContinue)
    if ($mapped.Count -eq 0) {
        Write-Host '  None mapped.' -ForegroundColor Green
    }
    foreach ($m in $mapped) {
        $reachable = Test-Path -LiteralPath ($m.LocalName + '\') -ErrorAction SilentlyContinue
        $colour = if ($reachable) { 'Green' } else { 'Red' }
        Write-Item ("{0} -> {1}" -f $m.LocalName, $m.RemoteName) `
            $(if ($reachable) { 'reachable' } else { 'UNREACHABLE' }) $colour
        if (-not $reachable) {
            Add-Finding -Severity 'HIGH' -Area 'Network drives' `
                -Issue  ("Mapped drive {0} ({1}) is unreachable. File Explorer and Open/Save dialogs freeze for 30+ seconds every time they enumerate drives." -f $m.LocalName, $m.RemoteName) `
                -Fix    ("Disconnect it: run  net use {0} /delete  in an elevated prompt, or right-click it in This PC and choose Disconnect." -f $m.LocalName)
        }
    }
} catch { }

# --------------------------------------------------------------------------
# 10. Device errors
# --------------------------------------------------------------------------
Write-Section 'DEVICE AND DRIVER PROBLEMS'

try {
    $bad = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq 'Error' })
    if ($bad.Count -eq 0) {
        Write-Host '  No devices reporting errors.' -ForegroundColor Green
    } else {
        foreach ($b in $bad) {
            Write-Host ('    [ERROR] {0}' -f $b.FriendlyName) -ForegroundColor Red
        }
        Add-Finding -Severity 'MEDIUM' -Area 'Drivers' `
            -Issue  ("{0} device(s) are in an error state. A malfunctioning device driver can stall the system in bursts." -f $bad.Count) `
            -Fix    'Open Device Manager, look for the yellow warning icons, and update or reinstall those drivers from the laptop maker support page.'
    }
} catch { }

# --------------------------------------------------------------------------
# 11. Event log - crashes, hangs, disk errors
# --------------------------------------------------------------------------
Write-Section 'EVENT LOG (LAST 14 DAYS)'

$since = (Get-Date).AddDays(-14)

try {
    $diskErrors = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; Level = 1,2; StartTime = $since
    } -ErrorAction SilentlyContinue | Where-Object {
        $_.ProviderName -match 'disk|Ntfs|storahci|stornvme|volmgr'
    })
    Write-Item 'Disk/filesystem errors' $diskErrors.Count `
        $(if ($diskErrors.Count -gt 0) { 'Red' } else { 'Green' })
    if ($diskErrors.Count -gt 0) {
        $diskErrors | Select-Object -First 3 | ForEach-Object {
            Write-Host ('    {0}  [{1}]  {2}' -f $_.TimeCreated, $_.ProviderName,
                (($_.Message -split "`n")[0])) -ForegroundColor Red
        }
        Add-Finding -Severity 'CRITICAL' -Area 'Disk health' `
            -Issue  ("{0} disk or filesystem errors logged in the last 14 days. This is the classic signature of a drive that is failing, and it explains sudden total freezes." -f $diskErrors.Count) `
            -Fix    'Back up your data immediately. Then run chkdsk and check the drive SMART data. Replace the drive if errors recur.'
    }

    $unexpected = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; Id = 41; StartTime = $since
    } -ErrorAction SilentlyContinue)
    Write-Item 'Unexpected shutdowns' $unexpected.Count `
        $(if ($unexpected.Count -gt 2) { 'Red' } elseif ($unexpected.Count -gt 0) { 'Yellow' } else { 'Green' })
    if ($unexpected.Count -gt 2) {
        Add-Finding -Severity 'HIGH' -Area 'Stability' `
            -Issue  ("{0} unexpected shutdowns or hard resets in 14 days (Kernel-Power event 41)." -f $unexpected.Count) `
            -Fix    'Usually overheating, a failing power supply/battery, or unstable RAM. Run Windows Memory Diagnostic (mdsched.exe) and address the thermal findings.'
    }

    $hangs = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Application'; Id = 1002; StartTime = $since
    } -ErrorAction SilentlyContinue)
    Write-Item 'Application hangs' $hangs.Count `
        $(if ($hangs.Count -gt 10) { 'Red' } elseif ($hangs.Count -gt 0) { 'Yellow' } else { 'Green' })
    if ($hangs.Count -gt 0) {
        Write-Host '    Most frequently hanging apps:' -ForegroundColor Yellow
        $hangs | ForEach-Object { ($_.Properties[0].Value) } |
            Group-Object | Sort-Object Count -Descending | Select-Object -First 5 |
            ForEach-Object { Write-Host ('      {0,-32} x{1}' -f $_.Name, $_.Count) -ForegroundColor Yellow }
    }
} catch {
    Write-Host '  Event log queries need Administrator.' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# 12. Pending reboot / update state
# --------------------------------------------------------------------------
Write-Section 'UPDATES AND PENDING WORK'

$pendingReboot = $false
$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
foreach ($k in $rebootKeys) { if (Test-Path $k) { $pendingReboot = $true } }
try {
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
             -Name PendingFileRenameOperations -ErrorAction Stop
    if ($pfro.PendingFileRenameOperations) { $pendingReboot = $true }
} catch { }

Write-Item 'Reboot pending' $(if ($pendingReboot) { 'YES' } else { 'no' }) `
    $(if ($pendingReboot) { 'Yellow' } else { 'Green' })
if ($pendingReboot) {
    Add-Finding -Severity 'MEDIUM' -Area 'Updates' `
        -Issue  'Windows is waiting for a restart to finish installing updates. Until then it keeps update work running in the background, consuming disk and CPU.' `
        -Fix    'Restart the PC and let it complete. Do not power it off mid-update.'
}

# Temp file sizes
function Get-FolderSizeGB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        return [math]::Round(($sum / 1GB), 2)
    } catch { return 0 }
}

$tempGB   = Get-FolderSizeGB $env:TEMP
$winTmpGB = Get-FolderSizeGB (Join-Path $env:SystemRoot 'Temp')
$suGB     = Get-FolderSizeGB (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
$reclaim  = $tempGB + $winTmpGB + $suGB

Write-Item 'User temp files'      ("{0} GB" -f $tempGB)
Write-Item 'Windows temp files'   ("{0} GB" -f $winTmpGB)
Write-Item 'Update download cache'("{0} GB" -f $suGB)
Write-Item 'Reclaimable (approx)' ("{0} GB" -f $reclaim) $(if ($reclaim -gt 5) { 'Yellow' } else { 'Green' })

if ($reclaim -gt 3) {
    Add-Finding -Severity 'LOW' -Area 'Disk space' `
        -Issue  ("About {0} GB of temporary files can be deleted safely." -f $reclaim) `
        -Fix    'Run Optimize-PC.ps1 -Apply.'
}

# --------------------------------------------------------------------------
# VERDICT
# --------------------------------------------------------------------------
Write-Host ''
Write-Host ('#' * 74) -ForegroundColor White
Write-Host '  WHAT TO FIX, IN ORDER' -ForegroundColor White
Write-Host ('#' * 74) -ForegroundColor White

if ($script:Findings.Count -eq 0) {
    Write-Host ''
    Write-Host '  No significant problems detected by this scan.' -ForegroundColor Green
    Write-Host '  If the PC still feels slow, capture it in the act: open Task Manager' -ForegroundColor Gray
    Write-Host '  while it is hanging and note which column (CPU / Memory / Disk) is at 100%.' -ForegroundColor Gray
} else {
    $order = @{ CRITICAL = 0; HIGH = 1; MEDIUM = 2; LOW = 3 }
    $n = 0
    foreach ($f in ($script:Findings | Sort-Object { $order[$_.Severity] })) {
        $n++
        $colour = switch ($f.Severity) {
            'CRITICAL' { 'Red' }
            'HIGH'     { 'Yellow' }
            'MEDIUM'   { 'Cyan' }
            default    { 'Gray' }
        }
        Write-Host ''
        Write-Host ("  {0}. [{1}] {2}" -f $n, $f.Severity, $f.Area) -ForegroundColor $colour
        Write-Host ("     Problem: {0}" -f $f.Issue) -ForegroundColor Gray
        Write-Host ("     Fix:     {0}" -f $f.Fix) -ForegroundColor White
    }
}

Write-Host ''
Write-Host ('-' * 74) -ForegroundColor DarkGray
Write-Host ("  Full report saved to: {0}" -f $ReportPath) -ForegroundColor Green
Write-Host '  Next step: run Run-Optimize.bat as administrator to apply the safe fixes.' -ForegroundColor Green
Write-Host ''

Stop-Transcript | Out-Null
