[CmdletBinding()]
param(
    [string]$Project
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$logRoot = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:LOCALAPPDATA 'WindowsTools\android-build-install\logs'
} else {
    Join-Path $env:TEMP 'WindowsTools\android-build-install\logs'
}

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logRoot "android-build-install-$timestamp.log"
$implementation = Join-Path $PSScriptRoot 'Build-And-Install-Android.ps1'

$childArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $implementation
)

if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $childArguments += @('-Project', $Project)
}

@(
    'Android Build and Install',
    "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "Computer: $env:COMPUTERNAME",
    "User: $env:USERNAME",
    "Launcher: $PSCommandPath",
    "Implementation: $implementation",
    "Selected project argument: $Project",
    ''
) | Set-Content -LiteralPath $logPath -Encoding UTF8

Write-Host "Detailed log: $logPath"
Write-Host ''

$previousPreference = $ErrorActionPreference
$exitCode = 1

try {
    # Run the implementation in a child PowerShell process so all Gradle/adb
    # stdout and stderr arrive as ordinary text. Write every line to both the
    # console and the persistent log without relying on newer Tee-Object flags.
    $ErrorActionPreference = 'Continue'
    & powershell.exe @childArguments 2>&1 |
        ForEach-Object {
            $line = "$_"
            Write-Host $line
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value $line
        }
    $exitCode = $LASTEXITCODE
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
