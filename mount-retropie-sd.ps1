<#
.SYNOPSIS
    Mount a RetroPie SD card in WSL 2 via usbipd for ROM file transfer.
.DESCRIPTION
    Uses usbipd-win to pass a USB SD card reader directly to the WSL 2 VM,
    mounts the ext4 partition, opens the ROMs folder in Explorer for
    drag-and-drop, and safely unmounts / detaches when done.
.NOTES
    Requires: usbipd-win  (install: winget install usbipd)
    Usage:    powershell -ExecutionPolicy Bypass -File .\mount-retropie-sd.ps1
              or right-click -> Run with PowerShell
#>

# -- Self-elevate if not admin -------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Resolve the script path reliably ($PSCommandPath can be empty in some launch modes)
    $scriptPath = $MyInvocation.MyCommand.Definition
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
        Write-Host ""
        Write-Host "  This script requires Administrator privileges." -ForegroundColor Yellow
        Write-Host "  Could not determine the script path for auto-elevation." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Please run manually from an elevated PowerShell:" -ForegroundColor Yellow
        Write-Host "    1. Right-click PowerShell -> 'Run as Administrator'" -ForegroundColor Yellow
        Write-Host "    2. Run:  powershell -ExecutionPolicy Bypass -File ""$($MyInvocation.MyCommand.Name)""" -ForegroundColor Yellow
        Read-Host "`n  Press Enter to exit"
        exit 1
    }

    Write-Host ""
    Write-Host "  This script requires Administrator privileges." -ForegroundColor Yellow
    Write-Host "  Relaunching elevated - a UAC prompt will appear..." -ForegroundColor Yellow

    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList (
            "-NoExit -NoProfile -ExecutionPolicy Bypass -File ""$scriptPath"""
        )
        Write-Host ""
        Write-Host "  Elevated window launched. You can close this window." -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "  Elevation failed or UAC was declined." -ForegroundColor Red
        Write-Host "  Please right-click PowerShell -> 'Run as Administrator'" -ForegroundColor Red
        Write-Host "  Then run:  .\mount-retropie-sd.ps1" -ForegroundColor Red
    }

    Read-Host "`n  Press Enter to close this window"
    exit
}

# -- Global error trap (keeps window open on unexpected crash) ----------------
trap {
    Write-Host ""
    Write-Host "  UNEXPECTED ERROR: $_" -ForegroundColor Red
    Write-Host "  At line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    Read-Host "`n  Press Enter to exit"
    exit 1
}

# -- Helpers -------------------------------------------------------------------
function Write-Inf  { param($m) Write-Host "  i " -NoNewline -ForegroundColor Cyan;   Write-Host $m }
function Write-Ok   { param($m) Write-Host "  v " -NoNewline -ForegroundColor Green;  Write-Host $m }
function Write-Wrn  { param($m) Write-Host "  ! " -NoNewline -ForegroundColor Yellow; Write-Host $m }
function Write-Err  { param($m) Write-Host "  X " -NoNewline -ForegroundColor Red;    Write-Host $m }

$Host.UI.RawUI.WindowTitle = "RetroPie SD Card Mounter"

# Track state for cleanup
$script:attachedBusId     = $null
$script:mountPoint        = "/mnt/retropie"
$script:distro            = $null
$script:isMounted         = $false
$script:offlineDiskNumber = $null
$script:useNsenter        = $false
$script:keepAlive         = $null

function Invoke-Cleanup {
    if ($script:keepAlive -and -not $script:keepAlive.HasExited) {
        Stop-Process -Id $script:keepAlive.Id -Force -ErrorAction SilentlyContinue
        $script:keepAlive = $null
    }
    if ($script:isMounted -and $script:distro) {
        Write-Wrn "Emergency cleanup - unmounting..."
        if ($script:useNsenter) {
            wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- sync                      2>$null | Out-Null
            wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- umount $script:mountPoint 2>$null | Out-Null
            wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- umount -l $script:mountPoint 2>$null | Out-Null
        } else {
            wsl.exe -d $script:distro -u root -- sync                                         2>$null | Out-Null
            wsl.exe -d $script:distro -u root -- umount $script:mountPoint                    2>$null | Out-Null
            wsl.exe -d $script:distro -u root -- umount -l $script:mountPoint                 2>$null | Out-Null
        }
        $script:isMounted = $false
    }
    if ($script:attachedBusId) {
        Write-Wrn "Detaching USB device $($script:attachedBusId)..."
        usbipd detach --busid $script:attachedBusId                        2>$null | Out-Null
        usbipd unbind --busid $script:attachedBusId                        2>$null | Out-Null
        $script:attachedBusId = $null
    }
    if ($script:offlineDiskNumber -ne $null) {
        Set-Disk -Number $script:offlineDiskNumber -IsOffline $false       2>$null | Out-Null
        $script:offlineDiskNumber = $null
    }
}

# -- Banner --------------------------------------------------------------------
Write-Host ""
Write-Host "  +==========================================================" -ForegroundColor White
Write-Host "  |       RetroPie SD Card Mounter for WSL 2  (usbipd)       |" -ForegroundColor White
Write-Host "  +==========================================================" -ForegroundColor White
Write-Host ""

# -- Pre-flight checks --------------------------------------------------------

# WSL 2
try {
    $null = wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Err "WSL 2 is not available."
    Read-Host "  Press Enter to exit"; exit 1
}

# Default distro
$script:distro = ((wsl.exe -l -q 2>$null) -replace "`0","" |
    Where-Object { $_.Trim() -ne '' } |
    Select-Object -First 1)
if ($script:distro) { $script:distro = $script:distro.Trim() }

if (-not $script:distro) {
    Write-Err "No WSL distribution found.  Install one first (e.g. Ubuntu)."
    Read-Host "  Press Enter to exit"; exit 1
}
Write-Inf "WSL distro: $($script:distro)"

# usbipd
$hasUsbipd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
if (-not $hasUsbipd) {
    Write-Host ""
    Write-Wrn "usbipd-win is not installed."
    Write-Host ""
    $install = Read-Host "  Install it now via winget? [y/N]"
    if ($install -match '^[Yy]$') {
        Write-Inf "Installing usbipd-win..."
        winget install --id dorssel.usbipd-win --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Installation failed.  Install manually: winget install usbipd"
            Read-Host "  Press Enter to exit"; exit 1
        }
        # Refresh PATH so we can find usbipd.exe
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $hasUsbipd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
        if (-not $hasUsbipd) {
            Write-Wrn "usbipd installed but not yet on PATH."
            Write-Wrn "Please close this window, open a new PowerShell, and run the script again."
            Read-Host "  Press Enter to exit"; exit 1
        }
        Write-Ok "usbipd-win installed successfully."
    } else {
        Write-Err "usbipd is required.  Install with:  winget install usbipd"
        Read-Host "  Press Enter to exit"; exit 1
    }
}

function Get-UsbStorageMap {
    $map = @{}
    try {
        # Strictly query USB disks ONLY (excludes NVMe, SATA, PCIe, and Windows OS drives)
        $usbDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
            $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem
        })

        # Query USB storage PnP entities to map parent VID:PID
        $usbEntities = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass = 'USB' or Service = 'USBSTOR' or Service = 'UASPStor'" -ErrorAction SilentlyContinue)

        foreach ($disk in $usbDisks) {
            $diskNum   = $disk.Number
            $diskModel = $disk.FriendlyName
            $rawSize   = $disk.Size

            # Skip empty / offline / 0-byte disks
            if (-not $rawSize -or $rawSize -le 0) { continue }

            # Format size in GB / MB
            $sizeGB = [double]$rawSize / 1GB
            $sizeStr = if ($sizeGB -ge 1) { "$([math]::Round($sizeGB, 1)) GB" } else { "$([math]::Round([double]$rawSize / 1MB, 0)) MB" }

            # Query partitions and volume labels on this USB disk
            $volInfo = @()
            $hasBoot = $false
            try {
                $parts = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue
                foreach ($p in $parts) {
                    if ($p.DriveLetter) {
                        $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
                        $lbl = if ($vol -and $vol.FileSystemLabel) {
                            if ($vol.FileSystemLabel -match '(?i)boot') { $hasBoot = $true }
                            "$($p.DriveLetter): '$($vol.FileSystemLabel)'"
                        } else {
                            "$($p.DriveLetter):"
                        }
                        $volInfo += $lbl
                    }
                }
            } catch {}

            # RetroPie SD card validation:
            # - Must have 'boot' partition, OR be an SD card between 4GB and 550GB
            # - NEVER identify drives > 550 GB (e.g. 1 TB SSDs/HDDs) as an SD card
            $isLikelySd = $false
            if ($hasBoot -and $sizeGB -le 550) {
                $isLikelySd = $true
            } elseif ($sizeGB -ge 4 -and $sizeGB -le 550 -and $diskModel -match '(?i)SD|MMC|Card|Reader|Generic') {
                $isLikelySd = $true
            }

            $diskObj = [PSCustomObject]@{
                Model      = $diskModel
                Size       = $sizeStr
                SizeGB     = $sizeGB
                Volumes    = ($volInfo -join ", ")
                DiskNumber = $diskNum
                HasBoot    = $hasBoot
                IsSdCard   = $isLikelySd
            }

            # Map to USB VID:PID
            $pnpId = $disk.Path
            $vidPid = $null

            # Method A: Path regex
            if ($pnpId -match 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
                $vidPid = ("$($Matches[1]):$($Matches[2])").ToLower()
            }

            # Method B: Match against Win32_DiskDrive to get PNPDeviceID, then find USB parent
            if (-not $vidPid) {
                $wmiDisk = Get-CimInstance Win32_DiskDrive -Filter "Index = $diskNum" -ErrorAction SilentlyContinue
                if ($wmiDisk -and $wmiDisk.PNPDeviceID) {
                    $currId = $wmiDisk.PNPDeviceID
                    for ($step = 0; $step -lt 5; $step++) {
                        if (-not $currId) { break }
                        if ($currId -match 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
                            $vidPid = ("$($Matches[1]):$($Matches[2])").ToLower()
                            break
                        }
                        $parentProp = Get-PnpDeviceProperty -InstanceId $currId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
                        if ($parentProp -and $parentProp.Data) {
                            $currId = $parentProp.Data
                        } else {
                            break
                        }
                    }
                }
            }

            # Method C: Serial number match in PnP entities
            if (-not $vidPid -and $pnpId -match '([0-9a-fA-F]{8,})') {
                $serial = $Matches[1]
                $matchEntity = $usbEntities | Where-Object { $_.DeviceID -match $serial -and $_.DeviceID -match 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})' } | Select-Object -First 1
                if ($matchEntity -and $matchEntity.DeviceID -match 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
                    $vidPid = ("$($Matches[1]):$($Matches[2])").ToLower()
                }
            }

            # ONLY store if a verified USB VID:PID was resolved!
            # Never fallback to a generic catch-all that could grab an internal disk!
            if ($vidPid) {
                $map[$vidPid] = $diskObj
            }
        }
    } catch {}
    return $map
}

# -- 1. List USB devices ------------------------------------------------------
Write-Host ""

# Check for any devices stuck in 'Shared (forced)' and release them back to Windows
$initialList = usbipd list 2>&1
$releasedAny = $false
foreach ($rawLine in $initialList) {
    if ($rawLine -match '^(\d+-[\d.]+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4}).*Shared \(forced\)') {
        $stuckBus = $Matches[1]
        Write-Wrn "Bus $stuckBus is locked in 'Shared (forced)'. Releasing back to Windows..."
        usbipd unbind --busid $stuckBus 2>$null | Out-Null
        $releasedAny = $true
    }
}
if ($releasedAny) {
    Write-Inf "Waiting 2 seconds for Windows to re-detect storage..."
    Start-Sleep -Seconds 2
}

Write-Inf "Querying USB devices and attached storage..."

$storageMap = Get-UsbStorageMap

$rawList = usbipd list 2>&1

# Parse the usbipd list output
$parsedDevices = @()
$inConnected = $false

foreach ($rawLine in $rawList) {
    $line = "$rawLine".Trim()
    if ($line -match '^Connected') { $inConnected = $true; continue }
    if ($line -match '^Persisted' -or $line -match '^$') {
        if ($inConnected) { $inConnected = $false }
        continue
    }
    if (-not $inConnected) { continue }
    # Skip header
    if ($line -match '^BUSID') { continue }
    if ($line -match '^-') { continue }

    # Match: BUSID  VID:PID  DEVICE  (2+ spaces)  STATE
    if ($line -match '^(\d+-[\d.]+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+)$') {
        $busid  = $Matches[1].Trim()
        $vidpid = $Matches[2].Trim()
        $rest   = $Matches[3].Trim()

        $device = $rest
        $state  = "Unknown"

        # Split device name from state (separated by 2+ spaces)
        if ($rest -match '^(.+?)\s{2,}(\S.*)$') {
            $device = $Matches[1].Trim()
            $state  = $Matches[2].Trim()
        }

        $parsedDevices += [PSCustomObject]@{
            BusId         = $busid
            VidPid        = $vidpid
            Device        = $device
            State         = $state
            Details       = $device
            IsSdCard      = $false
            IsSystemDrive = $false
        }
    }
}

if ($parsedDevices.Count -eq 0) {
    Write-Err "No USB devices found."
    Write-Err "Make sure your SD card reader is plugged in."
    Read-Host "  Press Enter to exit"; exit 1
}

# Identify system/boot disks to prevent accidental selection
$systemDiskIds = @{}
try {
    $sysDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsBoot -or $_.IsSystem -or $_.Size -gt 550GB })
    foreach ($sd in $sysDisks) {
        $p = $sd.Path
        if ($p -match 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
            $systemDiskIds[("$($Matches[1]):$($Matches[2])").ToLower()] = $true
        }
        $wmi = Get-CimInstance Win32_DiskDrive -Filter "Index = $($sd.Number)" -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.PNPDeviceID -match 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})') {
            $systemDiskIds[("$($Matches[1]):$($Matches[2])").ToLower()] = $true
        }
    }
} catch {}
$systemDiskIds['0080:a001'] = $true

# Separate storage devices from input/other devices
$storageList = @()
$otherList   = @()

foreach ($d in $parsedDevices) {
    $key = $d.VidPid.ToLower()
    $isStorage = ($storageMap.ContainsKey($key)) -or `
                 ($d.Device -match '(?i)Storage|UAS|SCSI|Card Reader') -or `
                 ($key -eq '05e3:0764' -or $key -eq '0080:a001')

    $details = $d.Device
    $isSd = $false
    $isSys = $systemDiskIds.ContainsKey($key)

    if ($storageMap.ContainsKey($key)) {
        $st = $storageMap[$key]
        $tagParts = @()
        if ($st.Size)    { $tagParts += $st.Size }
        if ($st.Volumes) { $tagParts += $st.Volumes }
        $tag = if ($tagParts.Count -gt 0) { " (" + ($tagParts -join ", ") + ")" } else { "" }
        $details = "$($d.Device)$tag"
        # Only mark as SD card if validated by size and boot label and not system disk
        if ($st.IsSdCard -and -not $isSys) { $isSd = $true }
    } elseif ($key -eq '05e3:0764' -or $d.Device -match '(?i)Card Reader') {
        # Card reader hardware on USB, but no media is mounted in Windows
        $details = "$($d.Device) (SD Reader - No card detected)"
        $isSd = $false
    } elseif ($isSys) {
        $details = "$($d.Device) (Windows System/Boot Drive)"
    }

    if ($details.Length -gt 45) {
        $details = $details.Substring(0, 42) + "..."
    }

    $d.Details       = $details
    $d.IsSdCard      = $isSd
    $d.IsSystemDrive = $isSys

    if ($isStorage) {
        $storageList += $d
    } else {
        $otherList += $d
    }
}

# Sorting priority:
# 0 = Verified SD Card
# 1 = Card Reader hardware (even if no card detected yet)
# 2 = Other non-system storage
# 3 = Windows Boot / System drives (ALWAYS at the bottom!)
$storageList = @($storageList | Sort-Object {
    if ($_.IsSdCard) { 0 }
    elseif ($_.VidPid.ToLower() -eq '05e3:0764' -or $_.Device -match '(?i)Card Reader') { 1 }
    elseif ($_.IsSystemDrive) { 3 }
    else { 2 }
})

# Full list with storage devices first
$usbDevices = @($storageList) + @($otherList)

# Display clean aligned tables
Write-Host ""
Write-Host "  -- Storage Devices -----------------------------------------------------------" -ForegroundColor Cyan
Write-Host ("  {0,-3} {1,-8} {2,-11} {3,-45} {4,-12} {5}" -f "#","Bus ID","VID:PID","Device / Storage Details","State","")
Write-Host ("  {0,-3} {1,-8} {2,-11} {3,-45} {4,-12} {5}" -f "--","-------","---------","---------------------------------------------","------------","")

$suggestedChoice = $null

for ($i = 0; $i -lt $storageList.Count; $i++) {
    $d = $storageList[$i]
    $num = $i + 1

    $stateColor = switch -Wildcard ($d.State) {
        "Attached*" { "Green"  }
        "Shared*"   { "Cyan"   }
        default     { "White"  }
    }

    $line = "  {0,-3} {1,-8} {2,-11} {3,-45} " -f $num, $d.BusId, $d.VidPid, $d.Details
    Write-Host $line -NoNewline
    Write-Host ("{0,-12}" -f $d.State) -NoNewline -ForegroundColor $stateColor

    if ($d.IsSdCard) {
        Write-Host " <-- RECOMMENDED" -ForegroundColor Yellow
        if (-not $suggestedChoice) { $suggestedChoice = $num }
    } else {
        Write-Host ""
    }
}

# If a card reader is present but no card is detected, warn the user
$unseatedReader = $storageList | Where-Object { ($_.VidPid.ToLower() -eq '05e3:0764' -or $_.Device -match '(?i)Card Reader') -and -not $_.IsSdCard } | Select-Object -First 1
if ($unseatedReader) {
    Write-Host ""
    Write-Wrn "Card reader ($($unseatedReader.BusId)) detected, but NO card is detected in the slot."
    Write-Wrn "If your SD card is plugged into the adapter:"
    Write-Wrn "  1. Unplug the USB-C adapter from your PC."
    Write-Wrn "  2. Pull out the micro-SD card and re-seat it firmly."
    Write-Wrn "  3. Plug the USB-C adapter back in."
}

if ($otherList.Count -gt 0) {
    Write-Host ""
    Write-Host "  -- Other USB Devices (mice, keyboards, adapters) -----------------------------" -ForegroundColor DarkGray
    for ($j = 0; $j -lt $otherList.Count; $j++) {
        $d = $otherList[$j]
        $num = $storageList.Count + $j + 1
        $name = $d.Details
        if ($name.Length -gt 45) { $name = $name.Substring(0, 42) + "..." }
        $line = "  {0,-3} {1,-8} {2,-11} {3,-45} {4}" -f $num, $d.BusId, $d.VidPid, $name, $d.State
        Write-Host $line -ForegroundColor DarkGray
    }
}

Write-Host ""

# -- 2. Selection --------------------------------------------------------------
do {
    $promptText = if ($suggestedChoice) {
        "  Select your SD card reader [1-$($usbDevices.Count), default $suggestedChoice] (q to quit)"
    } else {
        "  Select your SD card reader [1-$($usbDevices.Count)] (q to quit)"
    }
    $choice = Read-Host $promptText
    if ($choice -match '^[Qq]$') { Write-Inf "Cancelled."; exit 0 }
    if ($choice.Trim() -eq '' -and $suggestedChoice) {
        $choice = "$suggestedChoice"
        Write-Inf "Using recommended default: #$choice"
    }
    $ok = [int]::TryParse($choice,[ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $usbDevices.Count
    if (-not $ok) { Write-Wrn "Enter a number between 1 and $($usbDevices.Count)." }
} while (-not $ok)

$sel   = $usbDevices[[int]$choice - 1]
$busid = $sel.BusId

Write-Host ""
Write-Inf "Selected: $($sel.Device) (Bus $busid, $($sel.VidPid))"

# Safety confirm
Write-Host ""
Write-Wrn "This will detach '$($sel.Device)' from Windows and pass it to WSL."
Write-Wrn "The device will be unavailable in Windows until unmounted."
Write-Host ""
$confirm = Read-Host "  Continue? [y/N]"
if ($confirm -notmatch '^[Yy]$') { Write-Inf "Aborted."; exit 0 }
Write-Host ""

# -- 3. Snapshot block devices BEFORE attach ----------------------------------
$beforeRaw = (wsl.exe -d $script:distro -u root -- lsblk -dpno NAME 2>$null)
$before = @($beforeRaw -replace "`0","" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' })

# -- 4. Attach USB device to WSL ----------------------------------------------

# If Windows has this disk mounted, dismount/offline it temporarily to release open handles
$script:offlineDiskNumber = $null
$key = $sel.VidPid.ToLower()
if ($storageMap.ContainsKey($key) -and $storageMap[$key].DiskNumber -ne $null) {
    $script:offlineDiskNumber = $storageMap[$key].DiskNumber
    Write-Inf "Releasing Windows volume handles (taking disk offline temporarily)..."
    Set-Disk -Number $script:offlineDiskNumber -IsOffline $true -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# If not shared, bind it first (requires admin, which the script already has)
if ($sel.State -ne "Shared" -and $sel.State -ne "Attached") {
    Write-Inf "Sharing USB device (binding Bus $busid)..."
    $bindOut = usbipd bind --busid $busid 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Wrn "Standard bind failed, trying with --force..."
        $bindOut = usbipd bind --force --busid $busid 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "usbipd bind failed:"
        $bindOut | ForEach-Object { Write-Err "  $_" }
        Read-Host "  Press Enter to exit"; exit 1
    }
    Write-Ok "USB device shared (bound)."
    Write-Inf "Waiting 3 seconds for USB device to stabilize..."
    Start-Sleep -Seconds 3
}

# If already attached, detach first
if ($sel.State -match "Attached") {
    Write-Inf "Device is already attached - detaching first..."
    usbipd detach --busid $busid 2>$null | Out-Null
    Start-Sleep -Seconds 2
    # Re-snapshot
    $beforeRaw = (wsl.exe -d $script:distro -u root -- lsblk -dpno NAME 2>$null)
    $before = @($beforeRaw -replace "`0","" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' })
}

$attachSuccess = $false
$maxAttempts   = 3

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Inf "Attaching USB device to WSL (Bus $busid, attempt $attempt of $maxAttempts)..."
    $attachOutput = usbipd attach --wsl --busid $busid 2>&1
    if ($LASTEXITCODE -eq 0) {
        $attachSuccess = $true
        break
    }

    $outStr = "$attachOutput"

    # Case 1: Device is not shared
    if ($outStr -match "not shared") {
        Write-Wrn "Device was not shared. Binding with --force..."
        $null = usbipd bind --force --busid $busid 2>&1
        Write-Inf "Waiting 3 seconds for USB device to stabilize..."
        Start-Sleep -Seconds 3
        continue
    }

    # Case 2: Device in error state
    if ($outStr -match "Device in error state") {
        Write-Wrn "Device reported error state. Resetting USB binding..."
        $null = usbipd detach --busid $busid 2>&1
        Start-Sleep -Seconds 1
        $null = usbipd unbind --busid $busid 2>&1
        Start-Sleep -Seconds 2
        $null = usbipd bind --force --busid $busid 2>&1
        Write-Inf "Waiting 3 seconds for re-bind to settle..."
        Start-Sleep -Seconds 3
        continue
    }

    Start-Sleep -Seconds 2
}

if (-not $attachSuccess) {
    Write-Err "usbipd attach failed:"
    $attachOutput | ForEach-Object { Write-Err "  $_" }
    Write-Host ""
    Write-Wrn "If the device remains in 'error state':"
    Write-Wrn "  1. Close any Windows Explorer windows viewing drive D:."
    Write-Wrn "  2. Unplug the USB SD card reader and plug it back in."
    Write-Host ""
    $retryChoice = Read-Host "  Unplug and reconnect the reader, then press 'r' to retry (or Enter to exit)"
    if ($retryChoice -match '^[Rr]$') {
        Write-Inf "Retrying attach..."
        $null = usbipd bind --force --busid $busid 2>&1
        Start-Sleep -Seconds 3
        $attachOutput = usbipd attach --wsl --busid $busid 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Attach still failed:"
            $attachOutput | ForEach-Object { Write-Err "  $_" }
            Read-Host "  Press Enter to exit"; exit 1
        }
    } else {
        exit 1
    }
}

$script:attachedBusId = $busid
Write-Ok "USB device attached to WSL."

# -- 5. Wait for block device to appear ---------------------------------------
Write-Inf "Waiting for block device to appear in WSL..."
Write-Host "  " -NoNewline

$newDev = $null
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    Start-Sleep -Seconds 1
    Write-Host "." -NoNewline

    $afterRaw = (wsl.exe -d $script:distro -u root -- lsblk -dpno NAME 2>$null)
    $after = @($afterRaw -replace "`0","" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' })

    $diff = $after | Where-Object { $_ -notin $before }
    if ($diff) {
        if ($diff -is [array]) { $newDev = $diff[0] }
        else                   { $newDev = $diff }
        break
    }
}

Write-Host ""

if (-not $newDev) {
    Write-Host ""
    Write-Err "No new block device appeared in WSL after 15 seconds."
    Write-Err "Your WSL kernel may not have USB storage support."
    Write-Err "Try:  wsl -d $($script:distro) -u root -- dmesg | tail -20"
    Invoke-Cleanup
    Read-Host "  Press Enter to exit"; exit 1
}

Write-Ok "Block device found: $newDev"

# -- 6. Find the ext4 partition ------------------------------------------------
Write-Inf "Scanning partitions..."

# List partitions on the new device
$lsblkOut = (wsl.exe -d $script:distro -u root -- lsblk -lno NAME,FSTYPE,SIZE,LABEL $newDev 2>$null) -replace "`0",""
if ($lsblkOut) {
    Write-Host ""
    $lsblkOut | ForEach-Object {
        $l = "$_".Trim()
        if ($l -ne '') { Write-Host "    $l" }
    }
    Write-Host ""
}

# Detect if WSL distribution is using systemd (uses mount namespaces)
$script:useNsenter = (wsl.exe -d $script:distro -u root -- sh -c "test -d /run/systemd/system && echo YES" 2>$null) -match "YES"

function Invoke-WslCmd {
    param([string]$cmd)
    $res = if ($script:useNsenter) {
        wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- sh -c $cmd 2>$null
    } else {
        wsl.exe -d $script:distro -u root -- sh -c $cmd 2>$null
    }
    if ($res) {
        $str = ($res -join "`n") -replace "`0",""
        return $str.Trim()
    }
    return ""
}

# Try partition 2 first (standard RetroPie layout: p1=boot/FAT32, p2=rootfs/ext4)
$part = "${newDev}2"
$partExists = Invoke-WslCmd "[ -b '$part' ] && echo YES"

if ($partExists -ne "YES") {
    # Try partition 1 as fallback
    $part = "${newDev}1"
    $partExists = Invoke-WslCmd "[ -b '$part' ] && echo YES"

    if ($partExists -ne "YES") {
        # No standard partitions - try the whole device
        Write-Wrn "No partitions found. Trying to mount the device directly..."
        $part = $newDev
    }
}

Write-Inf "Using partition: $part"

# Verify it's ext4 (or ext2/ext3)
$fstype = Invoke-WslCmd "blkid -s TYPE -o value '$part'"

if ($fstype) {
    Write-Inf "Filesystem: $fstype"
    if ($fstype -notmatch 'ext[234]') {
        Write-Wrn "Expected ext4 but found '$fstype'. Proceeding anyway..."
    }
} else {
    Write-Wrn "Could not detect filesystem type. Proceeding with ext4..."
}

# -- 7. Mount ------------------------------------------------------------------
Write-Host ""

# Check if already mounted
$alreadyMounted = Invoke-WslCmd "mountpoint -q '$($script:mountPoint)' && echo YES"

if ($alreadyMounted -eq "YES") {
    Write-Wrn "$($script:mountPoint) is already mounted - unmounting first..."
    if ($script:useNsenter) {
        wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- umount $script:mountPoint 2>$null | Out-Null
    } else {
        wsl.exe -d $script:distro -u root -- umount $script:mountPoint 2>$null | Out-Null
    }
}

Write-Inf "Mounting $part at $($script:mountPoint)..."
if ($script:useNsenter) {
    wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- mkdir -p $script:mountPoint 2>$null | Out-Null
    $mountErr = (wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- mount -t ext4 -o rw $part $script:mountPoint 2>&1)
} else {
    wsl.exe -d $script:distro -u root -- mkdir -p $script:mountPoint 2>$null | Out-Null
    $mountErr = (wsl.exe -d $script:distro -u root -- mount -t ext4 -o rw $part $script:mountPoint 2>&1)
}
$mountExit = $LASTEXITCODE

if ($mountExit -ne 0) {
    Write-Err "Mount failed:"
    if ($mountErr) { $mountErr | ForEach-Object { Write-Err "  $_" } }
    Invoke-Cleanup
    Read-Host "  Press Enter to exit"; exit 1
}

# Verify it didn't mount read-only
$mountOpts = Invoke-WslCmd "findmnt -no OPTIONS '$($script:mountPoint)'"
if ($mountOpts -match '\bro\b') {
    Write-Wrn "Filesystem mounted read-only (possibly unclean unmount). Remounting read-write..."
    if ($script:useNsenter) {
        wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- mount -o remount,rw $script:mountPoint 2>$null | Out-Null
    } else {
        wsl.exe -d $script:distro -u root -- mount -o remount,rw $script:mountPoint 2>$null | Out-Null
    }
}

$script:isMounted = $true
Write-Ok "Mounted successfully at $($script:mountPoint)"

# -- 8. Find ROMs directory ---------------------------------------------------
$romsRel    = "home/pi/RetroPie/roms"
$romsWsl    = "$($script:mountPoint)/$romsRel"
$romsExists = Invoke-WslCmd "[ -d '$romsWsl' ] && echo YES"

if ($romsExists -eq "YES") {
    $targetWsl = $romsWsl
    Write-Ok "Found RetroPie ROMs directory."
} else {
    Write-Wrn "ROMs dir not found at $romsRel - opening mount root instead."
    $targetWsl = $script:mountPoint
}

# -- 9. Fix permissions -------------------------------------------------------
Write-Inf "Setting write permissions..."
$permCmd = "chmod a+rx /mnt $($script:mountPoint) '$($script:mountPoint)/home' '$($script:mountPoint)/home/pi' '$($script:mountPoint)/home/pi/RetroPie' 2>/dev/null; chmod -R 777 '$targetWsl' 2>/dev/null; chown -R 1000:1000 '$targetWsl' 2>/dev/null"
if ($script:useNsenter) {
    wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- sh -c $permCmd 2>$null | Out-Null
} else {
    wsl.exe -d $script:distro -u root -- sh -c $permCmd 2>$null | Out-Null
}
Write-Ok "Permissions set - drag-and-drop will work."

# -- 10. Open Explorer --------------------------------------------------------
Write-Host ""
$targetWin = "\\wsl.localhost\$($script:distro)" + ($targetWsl -replace '/','\')
Write-Inf "Opening File Explorer..."
Write-Inf "Path: $targetWin"
Start-Process explorer.exe -ArgumentList $targetWin
Write-Ok "Explorer opened."

# -- 11. Directory listing ----------------------------------------------------
Write-Host ""
Write-Inf "Contents:"
Write-Host ""
$listing = if ($script:useNsenter) {
    (wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- ls -1 --color=never $targetWsl 2>$null) -replace "`0",""
} else {
    (wsl.exe -d $script:distro -u root -- ls -1 --color=never $targetWsl 2>$null) -replace "`0",""
}
if ($listing) {
    $items = $listing | Where-Object { "$_".Trim() -ne '' }
    $items | Select-Object -First 30 | ForEach-Object { Write-Host "    $_" }
    if ($items.Count -gt 30) { Write-Host "    ... and $($items.Count - 30) more" }
} else {
    Write-Host "    (empty)"
}

# -- 12. Wait & Keep WSL Alive -------------------------------------------------
# Keep WSL actively running so the VM does not idle-timeout and disconnect the USB device
$script:keepAlive = Start-Process wsl.exe -ArgumentList "-d $script:distro -u root -- sleep infinity" -WindowStyle Hidden -PassThru

Write-Host ""
Write-Host "  +==========================================================" -ForegroundColor White
Write-Host "  |  The SD card is mounted and Explorer is open.            |" -ForegroundColor White
Write-Host "  |  Drag and drop ROM files into the appropriate folder.    |" -ForegroundColor White
Write-Host "  +==========================================================" -ForegroundColor White
Write-Host ""
Read-Host "  Press ENTER when finished copying to safely unmount"

if ($script:keepAlive -and -not $script:keepAlive.HasExited) {
    Stop-Process -Id $script:keepAlive.Id -Force -ErrorAction SilentlyContinue
    $script:keepAlive = $null
}

# -- 13. Unmount & detach -----------------------------------------------------
Write-Host ""
Write-Inf "Flushing caches..."
if ($script:useNsenter) {
    wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- sync 2>$null | Out-Null
} else {
    wsl.exe -d $script:distro -u root -- sync 2>$null | Out-Null
}
Write-Ok "Caches flushed."

Write-Inf "Unmounting $($script:mountPoint)..."
if ($script:useNsenter) {
    wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- umount $script:mountPoint 2>$null | Out-Null
} else {
    wsl.exe -d $script:distro -u root -- umount $script:mountPoint 2>$null | Out-Null
}
if ($LASTEXITCODE -eq 0) {
    $script:isMounted = $false
    Write-Ok "Unmounted."
} else {
    Write-Wrn "Unmount returned an error - the filesystem may still be in use."
    Write-Wrn "Close any Explorer windows accessing the drive and try again."
    Read-Host "  Press Enter to retry"
    if ($script:useNsenter) {
        wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- umount -f $script:mountPoint 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            wsl.exe -d $script:distro -u root -- nsenter -t 1 -m -- umount -l $script:mountPoint 2>$null | Out-Null
        }
    } else {
        wsl.exe -d $script:distro -u root -- umount -f $script:mountPoint 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            wsl.exe -d $script:distro -u root -- umount -l $script:mountPoint 2>$null | Out-Null
        }
    }
    $script:isMounted = $false
}

Write-Inf "Detaching USB device (Bus $($script:attachedBusId))..."
usbipd detach --busid $script:attachedBusId 2>$null | Out-Null
usbipd unbind --busid $script:attachedBusId 2>$null | Out-Null
$script:attachedBusId = $null
if ($script:offlineDiskNumber -ne $null) {
    Set-Disk -Number $script:offlineDiskNumber -IsOffline $false 2>$null | Out-Null
    $script:offlineDiskNumber = $null
}
Write-Ok "USB device detached - returned to Windows."

Write-Host ""
Write-Host "  +==========================================================" -ForegroundColor Green
Write-Host "  |  v  SD card safely unmounted!                            |" -ForegroundColor Green
Write-Host "  |     You may safely remove the SD card.                   |" -ForegroundColor Green
Write-Host "  +==========================================================" -ForegroundColor Green
Write-Host ""
Read-Host "  Press Enter to exit"
exit
