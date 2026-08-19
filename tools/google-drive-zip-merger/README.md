# Google Drive ZIP Merger

Google Drive splits large folder downloads into multiple ZIP archives. This utility lets you select the folder containing those ZIP files, choose the final destination, and extract all archives directly into one merged directory tree.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or later
- No third-party dependencies

## Use

You can start the tool either way:

### Double-click

1. Double-click `Merge-GoogleDriveZips.bat`.
2. Choose the folder containing the Google Drive `.zip` files.
3. Choose the final destination folder.
4. Wait for all ZIP files to be processed.
5. After successful extraction, choose whether to delete the original ZIP files.

### Drag and drop

1. Keep the resulting Google Drive `.zip` files together in one folder.
2. Drag that folder onto `Merge-GoogleDriveZips.bat` in File Explorer.
3. Choose the final destination folder.
4. Wait for all ZIP files to be processed.
5. After successful extraction, choose whether to delete the original ZIP files.

Dragging a folder into an already-open console window is not supported; drag the folder onto the `.bat` file itself.

When complete, the destination opens automatically in File Explorer.

## Behavior

The tool:

- accepts a source folder supplied by drag-and-drop or opens a source-folder picker when launched normally;
- finds `.zip` files directly inside the source folder;
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

- `Merge-GoogleDriveZips.bat` — double-click and drag-and-drop Windows launcher.
- `Merge-GoogleDriveZips.ps1` — source selection, extraction, validation, prompting, and cleanup logic.

## Command-line use

The PowerShell implementation can also be called directly with an explicit source folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Merge-GoogleDriveZips.ps1 `
    -Source "C:\Users\Example\Downloads\DriveDownload"
```

If `-Source` is omitted, the graphical source-folder picker appears. The destination is always chosen through the graphical folder picker.

## Possible future improvements

- Skip byte-identical duplicate files instead of rewriting them.
- Detect same-path files with different contents as explicit conflicts.
- Add an optional non-interactive destination argument for automation.
- Add recursive ZIP discovery when downloads are spread across subdirectories.
