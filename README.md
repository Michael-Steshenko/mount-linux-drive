# Mount Linux / RetroPie SD Card in Windows

> Mount, browse, and edit Linux `ext4`, `ext3`, and `ext2` SD cards and USB drives directly in **Windows File Explorer** using WSL 2 and `usbipd-win`.

---

## The Problem

Windows natively only supports FAT32, exFAT, and NTFS. When you plug a Raspberry Pi SD card (RetroPie, Raspberry Pi OS, Ubuntu, Armbian, etc.) into a Windows PC:

- Windows only sees the tiny FAT32 `boot` partition (usually ~256 MB) as drive `D:`.
- The main Linux partition (`ext4`), which holds your ROMs, configurations, and user data, is invisible.
- Windows often pops up a dangerous prompt: *"You need to format the disk before you can use it"*.
- Built-in `wsl --mount` frequently fails or is unsupported on removable USB SD card readers.
- Outdated third-party Windows ext4 filesystem drivers (like Ext2Fsd) are notoriously unstable and can cause blue screens or data corruption.

## The Solution

This tool bridges Windows and Linux safely:

1. Uses [**`usbipd-win`**](https://github.com/dorssel/usbipd-win) to pass the physical USB card reader directly into **WSL 2**.
2. The real Linux kernel inside WSL 2 mounts the ext4 partition with full read/write support and native filesystem safety.
3. Automatically opens **Windows File Explorer** via `\\wsl.localhost` directly to your files so you can drag-and-drop ROMs or edit configuration files.
4. When you're done, pressing **Enter** cleanly flushes write caches (`sync`), unmounts the filesystem, and returns the SD card reader back to Windows.

---

## RetroPie & General Linux Support

While optimized out-of-the-box for **RetroPie**, this tool works with **any Linux SD card or USB storage device**:

- **RetroPie SD Cards**:
  - Automatically identifies the `home/pi/RetroPie/roms` folder.
  - Opens File Explorer directly inside your ROM folder.
  - Automatically fixes Linux folder permissions (`chmod 777` & `chown 1000:1000`) so you never hit *"Access is denied"* when copying ROMs into emulator subfolders (`snes`, `gba`, `psx`, `nes`, etc.).
- **Raspberry Pi OS / Ubuntu / Debian / Other Linux Images**:
  - If a RetroPie ROMs directory is not detected, it automatically opens the root of the mounted filesystem in File Explorer.
  - Allows full access to `/etc`, `/home`, `/var`, etc., for manual configuration, backups, and file management from Windows.
  - Supports partitioned disks (Partition 2 or 1) as well as whole-disk filesystems.

---

## Key Features

- **Interactive Menu with Storage Classification**: Categorizes USB devices, identifies disk sizes and drive labels, and automatically recommends your SD card reader.
- **Systemd & Mount Namespace Aware**: Automatically detects if your WSL 2 distro runs systemd and mounts into PID 1's namespace (`nsenter`) so `\\wsl.localhost` in Windows Explorer has immediate access.
- **WSL 2 Keep-Alive Daemon**: Modern WSL 2 automatically powers down after ~8 seconds of inactivity. This script runs a background keep-alive process while you browse, preventing WSL from idle-sleeping and disconnecting the USB device mid-transfer.
- **Safe Windows Handle Release**: Automatically handles drive-locking issues by unbinding stuck devices and managing Windows volume handles to prevent USB error states.
- **Safe Unmount & Cache Flushing**: Guarantees all data is written to disk (`sync`) before unmounting, with a lazy unmount (`umount -l`) fallback if Explorer still holds a folder open.
- **Emergency Recovery Utility Included**: Comes with `restore-sd-card.ps1` to instantly restore drive letters in Windows if a session is ever aborted unexpectedly.

---

## Prerequisites

1. **Windows 10 (version 2004+)** or **Windows 11**
2. **WSL 2** installed with any Linux distribution (e.g., Ubuntu, Debian, Arch Linux):
   ```powershell
   wsl --install
   ```
3. **`usbipd-win`** (version 4.0 or newer, the script will auto install it if it's missing):
   Install via Windows Package Manager (`winget`):
   ```powershell
   winget install dorssel.usbipd-win
   ```
   *(A one-time Windows restart is recommended after installing `usbipd-win`)*.

---

## How to Use

1. **Plug in your SD card reader** containing the Linux or RetroPie card.
2. Open PowerShell as **Administrator**.
3. Run the mounter script:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\mount-retropie-sd.ps1
   ```
4. Select your SD card reader from the list (it will usually be option `1` with `<-- RECOMMENDED`).
5. File Explorer will automatically open to your files:
   - For **RetroPie**: Drag and drop your ROMs into the appropriate emulator folders (`snes/`, `gba/`, `psx/`, etc.).
   - For **General Linux**: Browse and manage your filesystem directly in Explorer.
6. When finished copying, return to the PowerShell window and press **Enter**.
7. The script will safely flush write caches, unmount the drive, and return it to Windows. You can now safely remove the SD card.

---

## Emergency Recovery: `restore-sd-card.ps1`

If you ever close your PowerShell terminal abruptly, disconnect the USB cable mid-session, or notice that Windows is not showing drive `D:` after using WSL:

Run the recovery script in PowerShell as Administrator:
```powershell
.\restore-sd-card.ps1
```

This utility will:
- Release any device locks held by `usbipd`.
- Unbind any captured USB devices.
- Bring any offline USB disks back online in Windows.
- Force Windows to re-enumerate drive letters so drive `D:` (`boot`) reappears in File Explorer.

---

## Troubleshooting

### "Device in error state" or "Device is busy"
Windows may be holding an active file handle on the FAT32 `boot` partition (drive `D:`).
- Close any File Explorer windows or text editors looking at drive `D:`.
- Unplug the USB card reader and plug it back in.
- Run `.\restore-sd-card.ps1` if needed, then re-run `.\mount-retropie-sd.ps1`.

### "Access is denied" when opening subfolders in Windows Explorer
- This occurs when folders on the Linux filesystem have restrictive Linux file permissions (`700` or `750`).
- The script automatically runs `chmod -R 777` on the target directory upon mounting. If you encounter permission errors on non-RetroPie filesystems, you can adjust permissions from within WSL:
  ```bash
  wsl -u root -- chmod -R 777 /mnt/retropie/<subfolder>
  ```

---

## License

MIT License. Feel free to modify and adapt for your own workflows.
