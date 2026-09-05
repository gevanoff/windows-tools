[CmdletBinding()]
param(
    [string]$ShortcutPath,
    [switch]$Remove,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'WindowsTaskbarIdentity.ps1')

if (-not $ShortcutPath) {
    $programsFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $ShortcutPath = Join-Path $programsFolder 'Android Build and Install.lnk'
}
$ShortcutPath = [System.IO.Path]::GetFullPath($ShortcutPath)
if ([System.IO.Path]::GetExtension($ShortcutPath) -ine '.lnk') {
    throw "The shortcut path must end in .lnk: $ShortcutPath"
}

if ($Remove) {
    if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
    if (-not $Quiet) {
        [System.Windows.Forms.MessageBox]::Show(
            "Removed the Start menu shortcut:`n$ShortcutPath",
            'Android Build and Install',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    return
}

$sessionPath = Join-Path $PSScriptRoot 'AndroidBuildInstall-Session.ps1'
$iconPath = Join-Path $PSScriptRoot 'assets\android-build-install.ico'
$powershellPath = Join-Path $PSHOME 'powershell.exe'
foreach ($requiredPath in @($sessionPath, $iconPath, $powershellPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required launcher file was not found: $requiredPath"
    }
}

$shortcutParent = Split-Path -Parent $ShortcutPath
if (-not (Test-Path -LiteralPath $shortcutParent -PathType Container)) {
    New-Item -ItemType Directory -Path $shortcutParent -Force | Out-Null
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $null
try {
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sessionPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = 'Build, install, sync, and launch saved Android projects.'
    $shortcut.WindowStyle = 1
    $shortcut.Save()
}
finally {
    if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
    if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

[WindowsTools.TaskbarIdentity]::SetShortcutAppId($ShortcutPath, (Get-AndroidBuildInstallAppId))

if (-not $Quiet) {
    [System.Windows.Forms.MessageBox]::Show(
        "Installed the Start menu shortcut:`n$ShortcutPath`n`nOpen Start, search for Android Build and Install, then choose Pin to taskbar.",
        'Android Build and Install',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

Write-Output $ShortcutPath
