[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$PreferencesPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ))
    }
    return $full
}

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @Arguments 2>&1
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { "$_" })
    }
}

function Get-AllPreferences {
    if (-not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) { return @() }
    try { $json = Get-Content -LiteralPath $PreferencesPath -Raw | ConvertFrom-Json } catch { return @() }
    return @($json.projects)
}

function Get-Preference {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $normalized = Normalize-Path -Path $ProjectPath
    foreach ($item in @(Get-AllPreferences)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-Path -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $normalized) {
            return [pscustomobject]@{
                path = $normalized
                gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
                preferredApk = "$($item.preferredApk)"
                javaHome = "$($item.javaHome)"
                autoLaunch = [bool]$item.autoLaunch
                deviceSerial = "$($item.deviceSerial)"
            }
        }
    }

    return [pscustomobject]@{
        path = $normalized
        gradleTask = 'assembleDebug'
        preferredApk = ''
        javaHome = ''
        autoLaunch = $false
        deviceSerial = ''
    }
}

function Save-Preference {
    param([Parameter(Mandatory = $true)]$Preference)

    $projectPath = Normalize-Path -Path $Preference.path
    $items = @()
    foreach ($item in @(Get-AllPreferences)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-Path -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $projectPath) { continue }
        $items += [pscustomobject]@{
            path = $candidate
            gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
            preferredApk = "$($item.preferredApk)"
            javaHome = "$($item.javaHome)"
            autoLaunch = [bool]$item.autoLaunch
            deviceSerial = "$($item.deviceSerial)"
        }
    }

    $items = @([pscustomobject]@{
        path = $projectPath
        gradleTask = $Preference.gradleTask
        preferredApk = $Preference.preferredApk
        javaHome = $Preference.javaHome
        autoLaunch = [bool]$Preference.autoLaunch
        deviceSerial = $Preference.deviceSerial
    }) + $items

    $parent = Split-Path -Parent $PreferencesPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [pscustomobject]@{ projects = @($items) } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $PreferencesPath -Encoding UTF8
}

function Make-RelativeIfInsideProject {
    param(
        [Parameter(Mandatory = $true)][string]$SelectedPath,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )

    $selected = [System.IO.Path]::GetFullPath($SelectedPath)
    $root = (Normalize-Path -Path $ProjectPath) + [System.IO.Path]::DirectorySeparatorChar
    if ($selected.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $selected.Substring($root.Length)
    }
    return $selected
}

function Get-GradleRoots {
    param([Parameter(Mandatory = $true)][string]$Root)

    $skipNames = @('.git', '.gradle', '.idea', 'build', 'node_modules', 'out')
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $Root; Depth = 0 })
    $results = @()

    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $node.Path 'gradlew.bat') -PathType Leaf) {
            $results += $node.Path
            continue
        }
        if ($node.Depth -ge 2) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $node.Path -Directory -ErrorAction SilentlyContinue) {
            if ($skipNames -contains $child.Name) { continue }
            $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $node.Depth + 1 })
        }
    }
    return @($results | Select-Object -Unique)
}

function Get-LocalSdkPath {
    param([string]$GradleRoot)

    if (-not $GradleRoot) { return $null }
    $localProperties = Join-Path $GradleRoot 'local.properties'
    if (-not (Test-Path -LiteralPath $localProperties -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $localProperties) {
        if ($line -match '^\s*sdk\.dir\s*=\s*(.+)\s*$') {
            return [Environment]::ExpandEnvironmentVariables($matches[1].Trim().Replace('\:', ':').Replace('\\', '\'))
        }
    }
    return $null
}

function Resolve-Adb {
    param([string]$ProjectPath)

    $roots = @(Get-GradleRoots -Root $ProjectPath)
    $sdkRoots = @()
    if ($roots.Count -gt 0) {
        $localSdk = Get-LocalSdkPath -GradleRoot $roots[0]
        if ($localSdk) { $sdkRoots += $localSdk }
    }
    if ($env:ANDROID_SDK_ROOT) { $sdkRoots += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $sdkRoots += $env:ANDROID_HOME }
    if ($env:LOCALAPPDATA) { $sdkRoots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }

    foreach ($sdkRoot in @($sdkRoots | Select-Object -Unique)) {
        $candidate = Join-Path $sdkRoot 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-ConnectedDevices {
    param([Parameter(Mandatory = $true)][string]$Adb)

    $result = Invoke-NativeCaptured -FilePath $Adb -Arguments @('devices', '-l')
    if ($result.ExitCode -ne 0) { throw "adb failed while listing devices: $($result.Output -join ' ')" }

    $devices = @()
    foreach ($line in $result.Output) {
        if ($line -match '^(\S+)\s+device\b\s*(.*)$') {
            $serial = $matches[1]
            $details = $matches[2]
            $model = $serial
            if ($details -match '(?:^|\s)model:([^\s]+)') { $model = $matches[1].Replace('_', ' ') }
            $devices += [pscustomobject]@{ Serial = $serial; Model = $model }
        }
    }
    return @($devices)
}

function Select-Device {
    param([Parameter(Mandatory = $true)][object[]]$Devices)

    if ($Devices.Count -eq 0) { return $null }
    if ($Devices.Count -eq 1) { return $Devices[0] }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Choose Preferred Android Device'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 300)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 16)
    $list.Size = New-Object System.Drawing.Size(488, 210)
    foreach ($entry in $Devices) { [void]$list.Items.Add("$($entry.Model) [$($entry.Serial)]") }
    $dialog.Controls.Add($list)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use Device'
    $ok.Size = New-Object System.Drawing.Size(110, 32)
    $ok.Location = New-Object System.Drawing.Point(286, 248)
    $ok.Enabled = $false
    $dialog.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $cancel.Location = New-Object System.Drawing.Point(404, 248)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    $list.Add_SelectedIndexChanged({ $ok.Enabled = ($list.SelectedIndex -ge 0) })
    $ok.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $dialog.Tag = $Devices[$list.SelectedIndex]
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $list.Add_DoubleClick({ if ($list.SelectedIndex -ge 0) { $ok.PerformClick() } })
    $list.SelectedIndex = 0

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dialog.Tag
}

$projectPath = Normalize-Path -Path $Project
$preference = Get-Preference -ProjectPath $projectPath

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Android Project Settings'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(760, 390)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Text = "Project: $projectPath"
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(16, 16)
$form.Controls.Add($title)

$taskLabel = New-Object System.Windows.Forms.Label
$taskLabel.Text = 'Gradle task:'
$taskLabel.AutoSize = $true
$taskLabel.Location = New-Object System.Drawing.Point(16, 58)
$form.Controls.Add($taskLabel)

$task = New-Object System.Windows.Forms.TextBox
$task.Location = New-Object System.Drawing.Point(150, 54)
$task.Size = New-Object System.Drawing.Size(570, 24)
$task.Text = $preference.gradleTask
$form.Controls.Add($task)

$apkLabel = New-Object System.Windows.Forms.Label
$apkLabel.Text = 'Preferred APK:'
$apkLabel.AutoSize = $true
$apkLabel.Location = New-Object System.Drawing.Point(16, 100)
$form.Controls.Add($apkLabel)

$apk = New-Object System.Windows.Forms.TextBox
$apk.Location = New-Object System.Drawing.Point(150, 96)
$apk.Size = New-Object System.Drawing.Size(470, 24)
$apk.Text = $preference.preferredApk
$form.Controls.Add($apk)

$apkBrowse = New-Object System.Windows.Forms.Button
$apkBrowse.Text = 'Browse...'
$apkBrowse.Size = New-Object System.Drawing.Size(92, 28)
$apkBrowse.Location = New-Object System.Drawing.Point(628, 94)
$form.Controls.Add($apkBrowse)

$javaLabel = New-Object System.Windows.Forms.Label
$javaLabel.Text = 'JAVA_HOME:'
$javaLabel.AutoSize = $true
$javaLabel.Location = New-Object System.Drawing.Point(16, 142)
$form.Controls.Add($javaLabel)

$java = New-Object System.Windows.Forms.TextBox
$java.Location = New-Object System.Drawing.Point(150, 138)
$java.Size = New-Object System.Drawing.Size(470, 24)
$java.Text = $preference.javaHome
$form.Controls.Add($java)

$javaBrowse = New-Object System.Windows.Forms.Button
$javaBrowse.Text = 'Browse...'
$javaBrowse.Size = New-Object System.Drawing.Size(92, 28)
$javaBrowse.Location = New-Object System.Drawing.Point(628, 136)
$form.Controls.Add($javaBrowse)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = 'Preferred device:'
$deviceLabel.AutoSize = $true
$deviceLabel.Location = New-Object System.Drawing.Point(16, 184)
$form.Controls.Add($deviceLabel)

$device = New-Object System.Windows.Forms.TextBox
$device.Location = New-Object System.Drawing.Point(150, 180)
$device.Size = New-Object System.Drawing.Size(470, 24)
$device.Text = $preference.deviceSerial
$form.Controls.Add($device)

$deviceDetect = New-Object System.Windows.Forms.Button
$deviceDetect.Text = 'Detect...'
$deviceDetect.Size = New-Object System.Drawing.Size(92, 28)
$deviceDetect.Location = New-Object System.Drawing.Point(628, 178)
$form.Controls.Add($deviceDetect)

$launch = New-Object System.Windows.Forms.CheckBox
$launch.Text = 'Launch the app automatically after a successful install'
$launch.AutoSize = $true
$launch.Location = New-Object System.Drawing.Point(150, 226)
$launch.Checked = [bool]$preference.autoLaunch
$form.Controls.Add($launch)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Blank fields use normal defaults. Detect stores the adb serial for this project.'
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(150, 258)
$form.Controls.Add($hint)

$reset = New-Object System.Windows.Forms.Button
$reset.Text = 'Reset Defaults'
$reset.Size = New-Object System.Drawing.Size(120, 32)
$reset.Location = New-Object System.Drawing.Point(16, 338)
$form.Controls.Add($reset)

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Size = New-Object System.Drawing.Size(100, 32)
$save.Location = New-Object System.Drawing.Point(512, 338)
$form.Controls.Add($save)

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.Size = New-Object System.Drawing.Size(100, 32)
$cancel.Location = New-Object System.Drawing.Point(620, 338)
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$form.AcceptButton = $save
$form.CancelButton = $cancel

$apkBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose preferred APK'
    $dialog.Filter = 'Android packages (*.apk)|*.apk|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.InitialDirectory = $projectPath
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $apk.Text = Make-RelativeIfInsideProject -SelectedPath $dialog.FileName -ProjectPath $projectPath
    }
})

$javaBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a JDK folder containing bin\java.exe'
    $dialog.ShowNewFolderButton = $false
    if ($java.Text -and (Test-Path -LiteralPath $java.Text -PathType Container)) { $dialog.SelectedPath = $java.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $java.Text = $dialog.SelectedPath }
})

$deviceDetect.Add_Click({
    try {
        $adb = Resolve-Adb -ProjectPath $projectPath
        if (-not $adb) { throw 'adb.exe could not be found.' }
        $devices = @(Get-ConnectedDevices -Adb $adb)
        if ($devices.Count -eq 0) { throw 'No authorized Android device is currently connected.' }
        $selected = Select-Device -Devices $devices
        if ($null -ne $selected) { $device.Text = [string]$selected.Serial }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Android Project Settings') | Out-Null
    }
})

$reset.Add_Click({
    $task.Text = 'assembleDebug'
    $apk.Text = ''
    $java.Text = ''
    $device.Text = ''
    $launch.Checked = $false
})

$save.Add_Click({
    $gradleTask = $task.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($gradleTask)) { $gradleTask = 'assembleDebug' }

    $javaHome = $java.Text.Trim()
    if ($javaHome) {
        try { $javaHome = Normalize-Path -Path $javaHome } catch {
            [System.Windows.Forms.MessageBox]::Show('JAVA_HOME is not a valid path.', 'Android Project Settings') | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe') -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('The selected JAVA_HOME does not contain bin\java.exe.', 'Android Project Settings') | Out-Null
            return
        }
    }

    Save-Preference -Preference ([pscustomobject]@{
        path = $projectPath
        gradleTask = $gradleTask
        preferredApk = $apk.Text.Trim()
        javaHome = $javaHome
        autoLaunch = $launch.Checked
        deviceSerial = $device.Text.Trim()
    })

    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

[void]$form.ShowDialog()
