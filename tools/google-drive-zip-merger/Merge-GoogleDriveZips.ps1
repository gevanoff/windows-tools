[CmdletBinding()]
param(
    [string]$Source
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Show-Error {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Google Drive ZIP Merger',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Select-Folder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = $Description
    $picker.ShowNewFolderButton = $true

    $result = $picker.ShowDialog()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return $picker.SelectedPath
}

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Select-Folder -Description 'Choose the folder containing the Google Drive ZIP files'

    if ([string]::IsNullOrWhiteSpace($Source)) {
        Write-Host 'Cancelled.'
        exit 0
    }
}

try {
    $Source = [System.IO.Path]::GetFullPath($Source)
}
catch {
    Show-Error "Invalid source path:`n$Source"
    exit 1
}

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Show-Error "The source is not a folder:`n$Source"
    exit 1
}

$zipFiles = @(
    Get-ChildItem -LiteralPath $Source -Filter '*.zip' -File |
        Sort-Object Name
)

if ($zipFiles.Count -eq 0) {
    Show-Error "No ZIP files were found in:`n$Source"
    exit 1
}

$Destination = Select-Folder -Description 'Choose where the Google Drive files should be extracted'

if ([string]::IsNullOrWhiteSpace($Destination)) {
    Write-Host 'Cancelled.'
    exit 0
}

$Destination = [System.IO.Path]::GetFullPath($Destination)
$destinationPrefix = $Destination.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

Write-Host ''
Write-Host 'Google Drive ZIP Merger'
Write-Host '======================='
Write-Host ''
Write-Host "Source:      $Source"
Write-Host "Destination: $Destination"
Write-Host "ZIP files:   $($zipFiles.Count)"
Write-Host ''

$totalFiles = 0
$overwrittenFiles = 0
$completedZips = 0

try {
    foreach ($zipFile in $zipFiles) {
        $completedZips++
        Write-Host "[$completedZips/$($zipFiles.Count)] $($zipFile.Name)"

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipFile.FullName)

        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) {
                    continue
                }

                $relativePath = $entry.FullName.Replace(
                    '/',
                    [System.IO.Path]::DirectorySeparatorChar
                )

                $targetPath = Join-Path $Destination $relativePath
                $targetPath = [System.IO.Path]::GetFullPath($targetPath)

                if (-not $targetPath.StartsWith(
                    $destinationPrefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    throw "Unsafe path in archive '$($zipFile.Name)': $($entry.FullName)"
                }

                $targetDirectory = Split-Path -Parent $targetPath

                if (-not (Test-Path -LiteralPath $targetDirectory)) {
                    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
                }

                if (Test-Path -LiteralPath $targetPath) {
                    $overwrittenFiles++
                    Write-Host "    Replacing existing: $relativePath"
                }

                [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                    $entry,
                    $targetPath,
                    $true
                )

                $totalFiles++
            }
        }
        finally {
            $archive.Dispose()
        }
    }
}
catch {
    Show-Error @"
Extraction stopped because of an error:

$($_.Exception.Message)

The original ZIP files have NOT been deleted.
"@
    exit 1
}

Write-Host ''
Write-Host 'Extraction complete.'
Write-Host ''
Write-Host "ZIP files processed: $completedZips"
Write-Host "Files extracted:      $totalFiles"
Write-Host "Files replaced:       $overwrittenFiles"
Write-Host ''

$deleteResult = [System.Windows.Forms.MessageBox]::Show(
    @"
Extraction completed successfully.

Processed $completedZips ZIP files and extracted $totalFiles files.

Do you want to delete the original ZIP files now?
"@,
    'Google Drive ZIP Merger',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)

if ($deleteResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    $deleted = 0

    foreach ($zipFile in $zipFiles) {
        Remove-Item -LiteralPath $zipFile.FullName
        $deleted++
    }

    Write-Host "Deleted $deleted ZIP files."
}

Start-Process explorer.exe -ArgumentList "`"$Destination`""

[System.Windows.Forms.MessageBox]::Show(
    @"
Finished.

ZIP files processed: $completedZips
Files extracted: $totalFiles
Existing files replaced: $overwrittenFiles

The destination folder has been opened.
"@,
    'Google Drive ZIP Merger',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null

exit 0
