[CmdletBinding()]
param(
    [string]$Project,
    [string]$GradleTask = 'assembleDebug',
    [string]$DeviceSerial
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

function Show-Error {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ''
    Write-Host "ERROR: $Message"

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Android Build and Install',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Show-Info {
    param([Parameter(Mandatory = $true)][string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Android Build and Install',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Select-Folder {
    param([Parameter(Mandatory = $true)][string]$Description)

    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = $Description
    $picker.ShowNewFolderButton = $false

    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return $picker.SelectedPath
}

function Select-ItemFromList {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label
    )

    if ($Items.Count -eq 1) {
        return $Items[0]
    }

    Write-Host ''
    Write-Host $Prompt
    Write-Host ''

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "[$($i + 1)] $(& $Label $Items[$i])"
    }

    while ($true) {
        Write-Host ''
        $answer = Read-Host "Choose 1-$($Items.Count)"
        $number = 0

        if ([int]::TryParse($answer, [ref]$number) -and
            $number -ge 1 -and
            $number -le $Items.Count) {
            return $Items[$number - 1]
        }

        Write-Host 'Invalid selection.'
    }
}

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    # Windows PowerShell 5.1 can represent native stderr as PowerShell error
    # records. Temporarily use Continue so normal stderr (for example, adb
    # daemon startup messages) does not become a terminating error.
    $previousPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Invoke-NativeStreaming {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Get-GradleRoots {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$MaxDepth = 2
    )

    $skipNames = @('.git', '.gradle', '.idea', 'build', 'node_modules', 'out')
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $Root; Depth = 0 })
    $results = @()

    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $wrapper = Join-Path $node.Path 'gradlew.bat'

        if (Test-Path -LiteralPath $wrapper -PathType Leaf) {
            $results += [System.IO.Path]::GetFullPath($node.Path)
            continue
        }

        if ($node.Depth -ge $MaxDepth) {
            continue
        }

        foreach ($child in Get-ChildItem -LiteralPath $node.Path -Directory -ErrorAction SilentlyContinue) {
            if ($skipNames -contains $child.Name) {
                continue
            }

            $queue.Enqueue([pscustomobject]@{
                Path = $child.FullName
                Depth = $node.Depth + 1
            })
        }
    }

    return @($results | Select-Object -Unique)
}

function Get-LocalSdkPath {
    param([Parameter(Mandatory = $true)][string]$GradleRoot)

    $localProperties = Join-Path $GradleRoot 'local.properties'

    if (-not (Test-Path -LiteralPath $localProperties -PathType Leaf)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $localProperties) {
        if ($line -match '^\s*sdk\.dir\s*=\s*(.+)\s*$') {
            $value = $matches[1].Trim()
            $value = $value.Replace('\:', ':').Replace('\\', '\')
            return [Environment]::ExpandEnvironmentVariables($value)
        }
    }

    return $null
}

function Resolve-Adb {
    param([Parameter(Mandatory = $true)][string]$GradleRoot)

    $sdkRoots = @()
    $localSdk = Get-LocalSdkPath -GradleRoot $GradleRoot

    if (-not [string]::IsNullOrWhiteSpace($localSdk)) {
        $sdkRoots += $localSdk
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
        $sdkRoots += $env:ANDROID_SDK_ROOT
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $sdkRoots += $env:ANDROID_HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $sdkRoots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    }

    foreach ($sdkRoot in @($sdkRoots | Select-Object -Unique)) {
        $candidate = Join-Path $sdkRoot 'platform-tools\adb.exe'

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Get-ConnectedDevices {
    param([Parameter(Mandatory = $true)][string]$Adb)

    $result = Invoke-NativeCaptured -FilePath $Adb -Arguments @('devices', '-l')

    if ($result.ExitCode -ne 0) {
        throw "adb failed while listing devices:`n$($result.Output -join [Environment]::NewLine)"
    }

    $devices = @()

    foreach ($rawLine in $result.Output) {
        $line = "$rawLine".Trim()

        if ($line -match '^(\S+)\s+(device|offline|unauthorized|recovery|sideload)\b\s*(.*)$') {
            $serial = $matches[1]
            $state = $matches[2]
            $details = $matches[3]
            $model = $serial

            if ($details -match '(?:^|\s)model:([^\s]+)') {
                $model = $matches[1].Replace('_', ' ')
            }

            $devices += [pscustomobject]@{
                Serial = $serial
                State = $state
                Model = $model
                Details = $details
            }
        }
    }

    return @($devices)
}

function Resolve-Device {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [string]$RequestedSerial
    )

    $devices = @(Get-ConnectedDevices -Adb $Adb)

    if (-not [string]::IsNullOrWhiteSpace($RequestedSerial)) {
        $match = @($devices | Where-Object { $_.Serial -eq $RequestedSerial })

        if ($match.Count -eq 0) {
            throw "Device '$RequestedSerial' was not reported by adb."
        }

        if ($match[0].State -ne 'device') {
            throw "Device '$RequestedSerial' is present but its state is '$($match[0].State)'."
        }

        return $match[0]
    }

    $ready = @($devices | Where-Object { $_.State -eq 'device' })

    if ($ready.Count -eq 0) {
        if (@($devices | Where-Object { $_.State -eq 'unauthorized' }).Count -gt 0) {
            throw 'An Android device is connected but not authorized. Unlock it and accept the USB debugging authorization prompt, then run the tool again.'
        }

        if (@($devices | Where-Object { $_.State -eq 'offline' }).Count -gt 0) {
            throw 'An Android device is connected but adb reports it as offline. Reconnect USB or restart USB debugging, then run the tool again.'
        }

        throw 'No ready Android device was found. Connect a device with USB debugging enabled and confirm that Windows has the required USB driver.'
    }

    return Select-ItemFromList `
        -Prompt 'Multiple Android devices are connected. Choose the install target:' `
        -Items $ready `
        -Label { param($item) "$($item.Model)  [$($item.Serial)]" }
}

function Resolve-Java {
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $javaFromHome = Join-Path $env:JAVA_HOME 'bin\java.exe'

        if (-not (Test-Path -LiteralPath $javaFromHome -PathType Leaf)) {
            throw "JAVA_HOME is set but does not contain bin\java.exe:`n$env:JAVA_HOME"
        }

        return $javaFromHome
    }

    $java = Get-Command java.exe -ErrorAction SilentlyContinue

    if ($null -eq $java) {
        throw 'Java was not found. Set JAVA_HOME to a JDK supported by the Android project, or add that JDK to PATH.'
    }

    return $java.Source
}

function Get-ApkCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$GradleRoot,
        [int]$MaxModuleDepth = 2
    )

    $skipNames = @('.git', '.gradle', '.idea', 'build', 'node_modules', 'out')
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $GradleRoot; Depth = 0 })
    $apks = @()

    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $apkRoot = Join-Path $node.Path 'build\outputs\apk'

        if (Test-Path -LiteralPath $apkRoot -PathType Container) {
            $apks += Get-ChildItem -LiteralPath $apkRoot -Filter '*.apk' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\androidTest\\' }
        }

        if ($node.Depth -ge $MaxModuleDepth) {
            continue
        }

        foreach ($child in Get-ChildItem -LiteralPath $node.Path -Directory -ErrorAction SilentlyContinue) {
            if ($skipNames -contains $child.Name) {
                continue
            }

            $queue.Enqueue([pscustomobject]@{
                Path = $child.FullName
                Depth = $node.Depth + 1
            })
        }
    }

    $unique = @($apks | Sort-Object FullName -Unique)
    $debug = @($unique | Where-Object {
        $_.FullName -match '(?i)\\debug\\' -or $_.Name -match '(?i)debug.*\.apk$'
    })

    if ($debug.Count -gt 0) {
        return @($debug | Sort-Object LastWriteTime -Descending)
    }

    return @($unique | Sort-Object LastWriteTime -Descending)
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = Select-Folder -Description 'Choose an Android project or repository folder'

    if ([string]::IsNullOrWhiteSpace($Project)) {
        Write-Host 'Cancelled.'
        exit 0
    }
}

try {
    $Project = [System.IO.Path]::GetFullPath($Project)
}
catch {
    Show-Error "Invalid project path:`n$Project"
    exit 1
}

if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
    Show-Error "The project path is not a directory:`n$Project"
    exit 1
}

try {
    $gradleRoots = @(Get-GradleRoots -Root $Project)

    if ($gradleRoots.Count -eq 0) {
        throw "No gradlew.bat was found in the selected directory or within two directory levels below it.`n`nSelected directory:`n$Project"
    }

    $gradleRoot = Select-ItemFromList `
        -Prompt 'Multiple Gradle projects were found. Choose the Android project to build:' `
        -Items $gradleRoots `
        -Label { param($item) $item }

    $gradlew = Join-Path $gradleRoot 'gradlew.bat'
    $adb = Resolve-Adb -GradleRoot $gradleRoot

    if ([string]::IsNullOrWhiteSpace($adb)) {
        throw "adb.exe could not be found.`n`nThe tool checked local.properties, ANDROID_SDK_ROOT, ANDROID_HOME, the standard Android Studio SDK directory under LOCALAPPDATA, and PATH.`n`nInstall Android SDK Platform-Tools or configure the SDK path and try again."
    }

    $java = Resolve-Java
    $device = Resolve-Device -Adb $adb -RequestedSerial $DeviceSerial

    Write-Host ''
    Write-Host 'Android Build and Install'
    Write-Host '========================='
    Write-Host ''
    Write-Host "Selected folder: $Project"
    Write-Host "Gradle root:     $gradleRoot"
    Write-Host "Gradle task:     $GradleTask"
    Write-Host "Java:            $java"
    Write-Host "adb:             $adb"
    Write-Host "Device:          $($device.Model) [$($device.Serial)]"
    Write-Host ''

    # This environment variable also constrains a custom install* Gradle task if
    # the caller chooses one instead of the default assemble task.
    $env:ANDROID_SERIAL = $device.Serial

    Push-Location $gradleRoot
    try {
        Write-Host "Running: gradlew.bat $GradleTask --stacktrace"
        Write-Host ''
        $gradleExitCode = Invoke-NativeStreaming `
            -FilePath $gradlew `
            -Arguments @($GradleTask, '--stacktrace')
    }
    finally {
        Pop-Location
    }

    if ($gradleExitCode -ne 0) {
        throw "Gradle failed with exit code $gradleExitCode. The APK was not installed."
    }

    $apkCandidates = @(Get-ApkCandidates -GradleRoot $gradleRoot)

    if ($apkCandidates.Count -eq 0) {
        throw "The Gradle build succeeded, but no APK was found under build\outputs\apk.`n`nIf this project uses a custom variant, pass its assemble task with -GradleTask."
    }

    $apk = Select-ItemFromList `
        -Prompt 'Multiple APKs were found. Choose the one to install:' `
        -Items $apkCandidates `
        -Label {
            param($item)
            $relative = $item.FullName.Substring($gradleRoot.Length).TrimStart('\')
            $sizeMb = [Math]::Round($item.Length / 1MB, 1)
            "$relative  ($sizeMb MB)"
        }

    Write-Host ''
    Write-Host "Installing: $($apk.FullName)"
    Write-Host ''

    $install = Invoke-NativeCaptured `
        -FilePath $adb `
        -Arguments @('-s', $device.Serial, 'install', '-r', $apk.FullName)

    foreach ($line in $install.Output) {
        Write-Host $line
    }

    if ($install.ExitCode -ne 0) {
        $combined = $install.Output -join [Environment]::NewLine

        if ($combined -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
            throw "Android rejected the update because the installed app has a different signing key. The tool will not uninstall it automatically because uninstalling would remove its app data.`n`nUninstall the existing app manually only if losing its local data is acceptable."
        }

        throw "adb install failed with exit code $($install.ExitCode).`n`n$combined"
    }

    $successMessage = @"
Build and install completed successfully.

Device: $($device.Model)
Serial: $($device.Serial)
APK: $($apk.Name)

The app was installed with adb install -r, which preserves existing app data when Android permits the update.
"@

    Write-Host ''
    Write-Host 'Success.'
    Show-Info $successMessage
    exit 0
}
catch {
    Show-Error $_.Exception.Message
    exit 1
}
