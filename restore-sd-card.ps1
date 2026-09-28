<#
.SYNOPSIS
    Restores the USB SD card reader back to Windows from usbipd.
.DESCRIPTION
    Releases all usbipd device locks, unbinds the SD card reader,
    and brings the disk back online so drive D: appears in File Explorer.
#>

# Self-elevate if not admin
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $scriptPath = $MyInvocation.MyCommand.Definition
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList (
        "-NoExit -NoProfile -ExecutionPolicy Bypass -File ""$scriptPath"""
    )
    exit
}

Write-Host ""
Write-Host "  -- Restoring USB SD Card to Windows --" -ForegroundColor Cyan
Write-Host ""

# 1. Unbind any stuck devices from usbipd
$rawList = usbipd list 2>&1
$unboundCount = 0

foreach ($rawLine in $rawList) {
    if ($rawLine -match '^(\d+-[\d.]+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+)$') {
        $busid = $Matches[1]
        $vidpid = $Matches[2]
        $state = $Matches[3]

        if ($state -match 'Shared|Attached|forced') {
            Write-Host "  Releasing Bus $busid ($vidpid)..." -ForegroundColor Yellow
            usbipd detach --busid $busid 2>$null | Out-Null
            usbipd unbind --busid $busid 2>$null | Out-Null
            $unboundCount++
        }
    }
}

if ($unboundCount -eq 0) {
    Write-Host "  No devices were locked by usbipd." -ForegroundColor White
} else {
    Write-Host "  Released $unboundCount device(s) from usbipd." -ForegroundColor Green
}

# 2. Bring any offline USB disks back online
$offlineDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'USB' -and $_.OperationalStatus -match 'Offline' })
foreach ($d in $offlineDisks) {
    Write-Host "  Bringing Disk $($d.Number) ($($d.FriendlyName)) online..." -ForegroundColor Yellow
    Set-Disk -Number $d.Number -IsOffline $false -ErrorAction SilentlyContinue
}

# 3. Wait for Windows to enumerate
Write-Host "  Waiting for Windows to re-detect drive letters..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

# 4. Check for drive letters
$volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
Write-Host ""
Write-Host "  Currently available drive letters:" -ForegroundColor Green
foreach ($v in $volumes) {
    $label = if ($v.FileSystemLabel) { "'$($v.FileSystemLabel)'" } else { "(no label)" }
    Write-Host "    $($v.DriveLetter): $label ($($v.FileSystem), $([math]::Round($v.Size / 1GB, 1)) GB)" -ForegroundColor White
}

Write-Host ""
Write-Host "  Done! If drive D: is not visible, simply unplug and re-insert the USB-C adapter." -ForegroundColor Cyan
Write-Host ""
Read-Host "  Press Enter to exit"
