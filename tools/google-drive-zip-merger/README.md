# Google Drive ZIP Merger

Google Drive splits large folder downloads into multiple ZIP archives. This utility lets you drag the folder containing those ZIP files onto a launcher, choose the final destination, and extract all archives directly into one merged directory tree.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or later
- No third-party dependencies

## Use

1. Download the large folder from Google Drive.
2. Keep the resulting `.zip` files together in one folder.
3. Drag that folder onto `Merge-GoogleDriveZips.bat`.
4. Choose the final destination folder in the Windows folder picker.
5. Wait for all ZIP files to be processed.
6. After successful extraction, choose whether to delete the original ZIP files.

When complete, the destination opens automatically in File Explorer.

## Behavior

The tool:

- finds `.zip` files directly inside the dropped source folder;
- processes them in filename order;
- extracts every archive directly into the selected destination;
- preserves directory paths stored in the ZIPs;
- creates destination directories as necessary;
- protects against archive paths that try to escape the selected destination;
- reports when an existing destination file is replaced;
- asks before deleting source ZIP files;
- never performs ZIP cleanup when extraction fails.

### Existing files

If a ZIP contains a path that already exists in the destination, the version being extracted replaces the existing file. The console reports each replacement and the final count.

This behavior is suitable for normal partitioned Google Drive downloads, but should be considered when rerunning the utility into a destination that already contains data.

## Files

- `Merge-GoogleDriveZips.bat` — drag-and-drop Windows launcher.
- `Merge-GoogleDriveZips.ps1` — extraction, validation, prompting, and cleanup logic.

## Command-line use

The PowerShell implementation can also be called directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Merge-GoogleDriveZips.ps1 `
    -Source "C:\Users\Example\Downloads\DriveDownload"
```

The destination is still chosen through the graphical folder picker.

## Possible future improvements

- Skip byte-identical duplicate files instead of rewriting them.
- Detect same-path files with different contents as explicit conflicts.
- Add an optional non-interactive destination argument for automation.
- Add recursive ZIP discovery when downloads are spread across subdirectories.
