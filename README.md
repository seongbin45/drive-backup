
Languages: [English](README.md) | [한국어](README.kr.md)

# drive-backup

A Windows automated backup project that automatically detects USB / external HDD/SSD drives when plugged in, backs them up to a local disk, and accumulates backup history via Git commits.

## Overview

- **Automatic detection**: When a removable/fixed drive is connected, it automatically determines whether it is a backup target.
- **Background auto-backup**: Runs unattended on a 5-minute interval via Windows Task Scheduler.
- **Git history management**: Each backup folder is managed as a Git repository, so deletion/change history can be rolled back to a past point in time.
- **Resume after interruption**: Thanks to robocopy's resume capability, if the device is unplugged mid-backup, copying continues where it left off when reconnected.
- **Verification**: Confirms whether backup copies match the originals by comparing metadata (size/modified time) and SHA-256 hashes.
- **Automatic system volume exclusion**: Windows installation volumes, boot partitions, recovery/install media, and Linux root filesystems are detected via actual system file signatures and automatically filtered out of backup targets.

## Directory Structure

```
drive-backup/
├── README.md            <- This file (project overview)
├── Tools/               <- Backup automation PowerShell scripts
│   ├── AutoDriveBackup.ps1        <- Core backup/watch/verify script
│   ├── Register-AutoBackupTask.ps1 <- Task Scheduler registration script
│   └── README.md                  <- Tools operational cautions and known risks
└── docs/                <- Project documentation
    └── WORK-LOG/        <- Development work logs with AI assistants
```

## Requirements

- Windows 10/11, **Windows PowerShell 5.1** or later
- [Git for Windows](https://git-scm.com) (required for the commit history feature)
- Script files must be saved as **UTF-8 with BOM** (without BOM, PowerShell 5.1 misreads them as CP949, causing syntax errors)

## Quick Start

```powershell
# 1. Allow script execution (current user only)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. Scan which drives are backup targets (changes nothing)
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\AutoDriveBackup.ps1 -Mode Scan

# 3. Register with Task Scheduler from an elevated PowerShell (auto-backup every 5 minutes)
.\Tools\Register-AutoBackupTask.ps1

# 4. Check status
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\AutoDriveBackup.ps1 -Mode Status
```

## Backup Output Structure (default: `C:\DriveBackup`)

```
C:\DriveBackup\
├── O_\                  <- O: drive backup (Git repository)
├── E_\                  <- E: drive backup (Git repository)
└── _meta\               <- State/logs/manifests (kept outside backups)
    ├── watcher.log      <- Watch/execution log
    └── O_\
        ├── backup_state.json   <- Resume/state info
        ├── manifest.json       <- File list at last completed backup
        ├── robocopy_*.log      <- Copy logs
        └── verify_*.csv        <- Detailed verification results
```

## ⚠️ Key Known Risks

> Be sure to read `Tools/README.md` for details.

1. **Drive-letter-based folder names**: If you swap between multiple USB devices, they may be assigned the same drive letter and their backups can get mixed together. Migration to volume-serial-based folders is a planned improvement.
2. **Caution with `-Mirror` option**: If deletion propagation is enabled and another device is assigned the same drive letter, the existing backup may be wiped entirely. Using the default (no deletion propagation) is recommended.
3. **Unbounded log growth**: There is no log rotation logic, so `watcher.log` and `robocopy_*.log` keep accumulating.
