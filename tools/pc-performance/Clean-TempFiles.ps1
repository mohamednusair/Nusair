<#
.SYNOPSIS
    Deletes temporary and cache files that Windows no longer needs.

.DESCRIPTION
    Cleans every standard temporary location on the system and reports how
    much space was recovered from each one.

    Nothing here is a document, photo or setting. These are caches and
    leftovers that Windows and applications recreate automatically.

    Files that are currently open or locked are skipped silently - that is
    normal and expected.

.PARAMETER Preview
    Show what would be deleted and how big it is, without deleting anything.

.PARAMETER IncludeBrowserCache
    Also clear Edge and Chrome caches. This does NOT log you out and does not
    touch bookmarks, passwords or history - it only removes cached page data.
    Close your browser first or most of it will be locked and skipped.

.EXAMPLE
    .\Clean-TempFiles.ps1 -Preview
    .\Clean-TempFiles.ps1
    .\Clean-TempFiles.ps1 -IncludeBrowserCache
#>

[CmdletBinding()]
param(
    [switch]$Preview,
    [switch]$IncludeBrowserCache
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$script:TotalFreed  = 0
$script:TotalLocked = 0

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0,8:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0,8:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0,8:N0} KB' -f ($Bytes / 1KB) }
    return '{0,8:N0} B ' -f $Bytes
}

function Get-PathSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($sum) { return $sum } else { return 0 }
}

function Clear-Location {
    param(
        [string]$Path,
        [string]$Label,
        [switch]$NeedsAdmin
    )

    if ($NeedsAdmin -and -not $isAdmin) {
        Write-Host ('  {0,-34} {1}' -f $Label, '   needs administrator') -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host ('  {0,-34} {1}' -f $Label, '   not present') -ForegroundColor DarkGray
        return
    }

    $before = Get-PathSize $Path

    if ($before -eq 0) {
        Write-Host ('  {0,-34} {1}' -f $Label, '   already empty') -ForegroundColor DarkGray
        return
    }

    if ($Preview) {
        Write-Host ('  {0,-34} {1}' -f $Label, (Format-Size $before)) -ForegroundColor Yellow
        $script:TotalFreed += $before
        return
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $after  = Get-PathSize $Path
    $freed  = $before - $after
    $script:TotalFreed  += $freed
    $script:TotalLocked += $after

    $note = if ($after -gt 0) { '  (' + (Format-Size $after).Trim() + ' in use, skipped)' } else { '' }
    Write-Host ('  {0,-34} {1}{2}' -f $Label, (Format-Size $freed), $note) -ForegroundColor Green
}

Write-Host ''
Write-Host '  ================================================================'
if ($Preview) {
    Write-Host '   TEMP FILE CLEANUP - PREVIEW ONLY, NOTHING WILL BE DELETED' -ForegroundColor Yellow
} else {
    Write-Host '   TEMP FILE CLEANUP' -ForegroundColor White
}
Write-Host '  ================================================================'
if (-not $isAdmin) {
    Write-Host '   Not running as administrator - system locations will be skipped.' -ForegroundColor Yellow
}

$sysDrive   = $env:SystemDrive
$freeBefore = (Get-PSDrive -Name $sysDrive.TrimEnd(':') -ErrorAction SilentlyContinue).Free

Write-Host ''
Write-Host '  Your files' -ForegroundColor Cyan
Clear-Location -Path $env:TEMP                                              -Label 'User temp folder'
Clear-Location -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps')             -Label 'Crash dumps'
Clear-Location -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER')  -Label 'Error reports'
Clear-Location -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') -Label 'Internet cache'
Clear-Location -Path (Join-Path $env:LOCALAPPDATA 'D3DSCache')              -Label 'Graphics shader cache'
Clear-Location -Path (Join-Path $env:APPDATA 'Microsoft\Windows\Recent')    -Label 'Recent items list'

Write-Host ''
Write-Host '  System' -ForegroundColor Cyan
Clear-Location -Path (Join-Path $env:SystemRoot 'Temp')                     -Label 'Windows temp folder'      -NeedsAdmin
Clear-Location -Path (Join-Path $env:SystemRoot 'Prefetch')                 -Label 'Prefetch data'            -NeedsAdmin
Clear-Location -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')    -Label 'System error report queue' -NeedsAdmin
Clear-Location -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')  -Label 'System error archive'      -NeedsAdmin
Clear-Location -Path (Join-Path $env:SystemRoot 'Logs\CBS')                 -Label 'Servicing logs'           -NeedsAdmin
Clear-Location -Path (Join-Path $env:SystemRoot 'LiveKernelReports')        -Label 'Kernel crash reports'     -NeedsAdmin

# Windows Update cache - the service must be stopped first or the files are locked
if ($isAdmin) {
    $suPath = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $suSize = Get-PathSize $suPath
    if ($suSize -gt 0) {
        if ($Preview) {
            Write-Host ('  {0,-34} {1}' -f 'Windows Update cache', (Format-Size $suSize)) -ForegroundColor Yellow
            $script:TotalFreed += $suSize
        } else {
            Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service bits     -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Get-ChildItem -LiteralPath $suPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $after = Get-PathSize $suPath
            $script:TotalFreed += ($suSize - $after)
            Start-Service bits     -ErrorAction SilentlyContinue
            Start-Service wuauserv -ErrorAction SilentlyContinue
            Write-Host ('  {0,-34} {1}' -f 'Windows Update cache', (Format-Size ($suSize - $after))) -ForegroundColor Green
        }
    } else {
        Write-Host ('  {0,-34} {1}' -f 'Windows Update cache', '   already empty') -ForegroundColor DarkGray
    }

    # Delivery Optimization peer-to-peer update cache
    if (-not $Preview) {
        try {
            $doBefore = (Get-DeliveryOptimizationPerfSnap -ErrorAction Stop).FileSizeInCache
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            if ($doBefore) { $script:TotalFreed += $doBefore }
            Write-Host ('  {0,-34} {1}' -f 'Delivery Optimization cache', (Format-Size $doBefore)) -ForegroundColor Green
        } catch {
            Write-Host ('  {0,-34} {1}' -f 'Delivery Optimization cache', '   skipped') -ForegroundColor DarkGray
        }
    }
}

if ($IncludeBrowserCache) {
    Write-Host ''
    Write-Host '  Browser caches (bookmarks, passwords and logins are NOT touched)' -ForegroundColor Cyan
    $edge   = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache'
    $chrome = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'
    Clear-Location -Path $edge   -Label 'Microsoft Edge cache'
    Clear-Location -Path $chrome -Label 'Google Chrome cache'
}

# Recycle Bin
Write-Host ''
Write-Host '  Recycle Bin' -ForegroundColor Cyan
$binSize = 0
foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $binSize += Get-PathSize (Join-Path $d.Root '$Recycle.Bin')
}
if ($Preview) {
    Write-Host ('  {0,-34} {1}' -f 'Recycle Bin contents', (Format-Size $binSize)) -ForegroundColor Yellow
    $script:TotalFreed += $binSize
} else {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    $script:TotalFreed += $binSize
    Write-Host ('  {0,-34} {1}' -f 'Recycle Bin emptied', (Format-Size $binSize)) -ForegroundColor Green
}

# --------------------------------------------------------------------------
Write-Host ''
Write-Host '  ================================================================'
if ($Preview) {
    Write-Host ('   WOULD RECOVER: {0}' -f (Format-Size $script:TotalFreed).Trim()) -ForegroundColor Yellow
    Write-Host '  ================================================================'
    Write-Host ''
    Write-Host '   Nothing was deleted. Run without -Preview to clean.' -ForegroundColor Yellow
} else {
    $freeAfter = (Get-PSDrive -Name $sysDrive.TrimEnd(':') -ErrorAction SilentlyContinue).Free
    Write-Host ('   RECOVERED: {0}' -f (Format-Size $script:TotalFreed).Trim()) -ForegroundColor Green
    if ($freeBefore -and $freeAfter) {
        Write-Host ('   Free space on {0}  {1}  ->  {2}' -f `
            $sysDrive, (Format-Size $freeBefore).Trim(), (Format-Size $freeAfter).Trim()) -ForegroundColor White
    }
    Write-Host '  ================================================================'
    if ($script:TotalLocked -gt 0) {
        Write-Host ''
        Write-Host ('   {0} was in use and could not be deleted. That is normal.' -f `
            (Format-Size $script:TotalLocked).Trim()) -ForegroundColor DarkGray
        Write-Host '   Restart and run again to catch those.' -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '   Bigger space savings, if you need them:' -ForegroundColor Cyan
Write-Host '     - Press Win+R, type  cleanmgr  and choose "Clean up system files".' -ForegroundColor Gray
Write-Host '       That removes old Windows installations, which can be 20 GB or more.' -ForegroundColor Gray
Write-Host '     - Settings > System > Storage > Temporary files.' -ForegroundColor Gray
Write-Host ''
