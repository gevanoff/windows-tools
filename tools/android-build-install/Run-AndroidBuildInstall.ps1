[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [string]$GradleTask = 'assembleDebug',
    [string]$DeviceSerial,
    [string]$PreferredApk,
    [string]$JavaHome,
    [switch]$AutoLaunch,
    [switch]$SkipBuild,
    [switch]$SkipInstall,
    [switch]$SuppressSuccessDialog
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

function Get-BuildTargetApk {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$Preferred
    )

    if ($Preferred) {
        try {
            $preferredPath = if ([System.IO.Path]::IsPathRooted($Preferred)) {
                [System.IO.Path]::GetFullPath($Preferred)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Preferred))
            }
            if (Test-Path -LiteralPath $preferredPath -PathType Leaf) {
                return Get-Item -LiteralPath $preferredPath
            }
        }
        catch { }
    }

    $candidates = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter '*.apk' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '(?i)\\build\\outputs\\apk\\' -and
            $_.FullName -notmatch '(?i)\\androidTest\\'
        })

    if ($candidates.Count -eq 0) { return $null }

    $debug = @($candidates | Where-Object {
        $_.FullName -match '(?i)\\debug\\' -or $_.Name -match '(?i)debug.*\.apk$'
    })
    if ($debug.Count -gt 0) { $candidates = $debug }

    if ($candidates.Count -eq 1) { return $candidates[0] }

    $conventional = @($candidates | Where-Object {
        $_.FullName -match '(?i)\\app\\build\\outputs\\apk\\debug\\app-debug\.apk$'
    })
    if ($conventional.Count -eq 1) { return $conventional[0] }

    return $null
}

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
if ($SkipBuild) { $childArguments += '-SkipBuild' }
if ($SkipInstall) { $childArguments += '-SkipInstall' }
if ($SuppressSuccessDialog) { $childArguments += '-SuppressSuccessDialog' }

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
    "Device serial: $DeviceSerial",
    "Auto-launch: $([bool]$AutoLaunch)",
    "Skip build: $([bool]$SkipBuild)",
    "Skip install: $([bool]$SkipInstall)",
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

if ($exitCode -eq 0 -and -not $SkipBuild) {
    $builtApk = Get-BuildTargetApk -ProjectRoot $Project -Preferred $PreferredApk
    if ($null -ne $builtApk) {
        $validatedAt = [DateTime]::UtcNow
        $builtApk.LastWriteTimeUtc = $validatedAt
        $freshnessMessage = "Build freshness: validated $($builtApk.FullName) at $($validatedAt.ToString('o'))"
        Write-Host $freshnessMessage
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value $freshnessMessage
    }
    else {
        $freshnessMessage = 'Build freshness: no deterministic APK target could be identified; artifact timestamp was not adjusted.'
        Write-Host $freshnessMessage
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value $freshnessMessage
    }
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
