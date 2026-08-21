[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$toolRoot = $PSScriptRoot
$runner = Join-Path $toolRoot 'Run-AndroidBuildInstall.ps1'
$statusHelper = Join-Path $toolRoot 'Get-AndroidProjectStatus.ps1'
$gitUpdater = Join-Path $toolRoot 'Update-AndroidRepo.ps1'
$scanner = Join-Path $toolRoot 'Scan-AndroidDevice.ps1'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("WindowsTools Android Test {0}" -f [Guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA

try {
    foreach ($script in Get-ChildItem -LiteralPath $toolRoot -Filter '*.ps1' -File) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        Assert-True -Condition ($parseErrors.Count -eq 0) -Message "PowerShell parse errors in $($script.Name): $($parseErrors -join '; ')"
    }

    $projectRoot = Join-Path $testRoot 'project with spaces'
    $apkPath = Join-Path $projectRoot 'app\build\outputs\apk\debug\app-debug.apk'
    $sourcePath = Join-Path $projectRoot 'app\src\main\source.txt'
    $fakeJavaHome = Join-Path $testRoot 'fake jdk'

    New-Item -ItemType Directory -Path (Split-Path -Parent $apkPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $sourcePath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fakeJavaHome 'bin') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $projectRoot 'gradlew.bat') -Encoding ASCII -Value @('@echo off', 'exit /b 0')
    Set-Content -LiteralPath $apkPath -Encoding ASCII -Value 'fake apk payload'
    Set-Content -LiteralPath $sourcePath -Encoding ASCII -Value 'newer source input'
    Set-Content -LiteralPath (Join-Path $fakeJavaHome 'bin\java.exe') -Encoding ASCII -Value 'fake java placeholder'

    (Get-Item -LiteralPath $apkPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc = [DateTime]::UtcNow
    $env:LOCALAPPDATA = Join-Path $testRoot 'state with spaces'

    $runOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
        -Project $projectRoot `
        -JavaHome $fakeJavaHome `
        -SkipInstall `
        -SuppressSuccessDialog 2>&1)
    $runExit = [int]$LASTEXITCODE
    Assert-True -Condition ($runExit -eq 0) -Message "Mock build failed with exit code $runExit.`n$($runOutput -join [Environment]::NewLine)"

    $status = @(& $statusHelper -Project @($projectRoot) -SkipDevice)[0]
    Assert-True -Condition ($status.BuildStatus -eq 'Fresh') -Message "Successful build was reported as '$($status.BuildStatus)': $($status.BuildDetail)"
    Assert-True -Condition ((Get-Item -LiteralPath $apkPath).LastWriteTimeUtc -ge (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc) -Message 'Successful build did not advance the deterministic APK freshness timestamp.'

    $missingProject = Join-Path $testRoot 'missing project'
    $failureOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gitUpdater -Project $missingProject -NoUi 2>&1)
    $failureExit = [int]$LASTEXITCODE
    Assert-True -Condition ($failureExit -ne 0) -Message 'Missing-project validation unexpectedly succeeded.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingProject)) -Message 'Failure-path validation created the missing project directory.'

    $scannerFailure = ''
    try { & $scanner -Project @($missingProject) | Out-Null } catch { $scannerFailure = $_.Exception.Message }
    Assert-True -Condition ($scannerFailure -eq 'No valid saved project folders were supplied.') -Message "Normal scanner parameter binding failed unexpectedly: $scannerFailure"

    Write-Host 'PASS: PowerShell parsing, configured JAVA_HOME, paths with spaces, build freshness, scanner binding, and expected failure behavior.'
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -like 'WindowsTools Android Test *' -and
        (Test-Path -LiteralPath $resolvedTestRoot -PathType Container)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
