[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [string]$GradleTask = 'assembleDebug',
    [string]$DeviceSerial,
    [string]$PreferredApk,
    [string]$JavaHome,
    [switch]$AutoLaunch
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$stateRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WindowsTools\android-build-install'
} else {
    Join-Path $env:TEMP 'WindowsTools\android-build-install'
}
$logRoot = Join-Path $stateRoot 'logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logRoot "android-build-install-$timestamp.log"
$implementation = Join-Path $PSScriptRoot 'Invoke-AndroidBuildInstall.ps1'

$childArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $implementation,
    '-Project', $Project,
    '-GradleTask', $GradleTask
)
if ($DeviceSerial) { $childArguments += @('-DeviceSerial', $DeviceSerial) }
if ($PreferredApk) { $childArguments += @('-PreferredApk', $PreferredApk) }
if ($JavaHome) { $childArguments += @('-JavaHome', $JavaHome) }
if ($AutoLaunch) { $childArguments += '-AutoLaunch' }

@(
    'Android Build and Install',
    "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "Computer: $env:COMPUTERNAME",
    "User: $env:USERNAME",
    "Launcher: $PSCommandPath",
    "Implementation: $implementation",
    "Selected project argument: $Project",
    "Gradle task: $GradleTask",
    "Preferred APK: $PreferredApk",
    "JAVA_HOME override: $JavaHome",
    "Auto-launch: $([bool]$AutoLaunch)",
    ''
) | Set-Content -LiteralPath $logPath -Encoding UTF8

Write-Host "Detailed log: $logPath"
Write-Host ''

$previousPreference = $ErrorActionPreference
$exitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    & powershell.exe @childArguments 2>&1 |
        ForEach-Object {
            $line = "$_"
            Write-Host $line
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value $line
        }
    $exitCode = [int]$LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousPreference
}

Add-Content -LiteralPath $logPath -Encoding UTF8 -Value @(
    '',
    "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "Exit code: $exitCode"
)

if ($exitCode -ne 0) {
    $message = @"
The Android build/install run failed.

A detailed log has been saved to:
$logPath

The log will now open in Notepad so the actual Gradle or adb error can be copied.
"@

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Android Build and Install',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    Start-Process notepad.exe -ArgumentList "`"$logPath`""
}

exit $exitCode
