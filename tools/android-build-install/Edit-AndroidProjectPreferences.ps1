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

function Get-AllPreferences {
    if (-not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) {
        return @()
    }

    try {
        $json = Get-Content -LiteralPath $PreferencesPath -Raw | ConvertFrom-Json
    }
    catch {
        return @()
    }

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
            }
        }
    }

    return [pscustomobject]@{
        path = $normalized
        gradleTask = 'assembleDebug'
        preferredApk = ''
        javaHome = ''
        autoLaunch = $false
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
        }
    }

    $items = @([pscustomobject]@{
        path = $projectPath
        gradleTask = $Preference.gradleTask
        preferredApk = $Preference.preferredApk
        javaHome = $Preference.javaHome
        autoLaunch = [bool]$Preference.autoLaunch
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

$projectPath = Normalize-Path -Path $Project
$preference = Get-Preference -ProjectPath $projectPath

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Android Project Settings'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(760, 330)
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
$task.Location = New-Object System.Drawing.Point(130, 54)
$task.Size = New-Object System.Drawing.Size(590, 24)
$task.Text = $preference.gradleTask
$form.Controls.Add($task)

$apkLabel = New-Object System.Windows.Forms.Label
$apkLabel.Text = 'Preferred APK:'
$apkLabel.AutoSize = $true
$apkLabel.Location = New-Object System.Drawing.Point(16, 100)
$form.Controls.Add($apkLabel)

$apk = New-Object System.Windows.Forms.TextBox
$apk.Location = New-Object System.Drawing.Point(130, 96)
$apk.Size = New-Object System.Drawing.Size(490, 24)
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
$java.Location = New-Object System.Drawing.Point(130, 138)
$java.Size = New-Object System.Drawing.Size(490, 24)
$java.Text = $preference.javaHome
$form.Controls.Add($java)

$javaBrowse = New-Object System.Windows.Forms.Button
$javaBrowse.Text = 'Browse...'
$javaBrowse.Size = New-Object System.Drawing.Size(92, 28)
$javaBrowse.Location = New-Object System.Drawing.Point(628, 136)
$form.Controls.Add($javaBrowse)

$launch = New-Object System.Windows.Forms.CheckBox
$launch.Text = 'Launch the app automatically after a successful install'
$launch.AutoSize = $true
$launch.Location = New-Object System.Drawing.Point(130, 184)
$launch.Checked = [bool]$preference.autoLaunch
$form.Controls.Add($launch)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Blank fields use the normal defaults. Preferred APK can be relative to the saved repo path.'
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(130, 216)
$form.Controls.Add($hint)

$reset = New-Object System.Windows.Forms.Button
$reset.Text = 'Reset Defaults'
$reset.Size = New-Object System.Drawing.Size(120, 32)
$reset.Location = New-Object System.Drawing.Point(16, 278)
$form.Controls.Add($reset)

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Size = New-Object System.Drawing.Size(100, 32)
$save.Location = New-Object System.Drawing.Point(512, 278)
$form.Controls.Add($save)

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.Size = New-Object System.Drawing.Size(100, 32)
$cancel.Location = New-Object System.Drawing.Point(620, 278)
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
    if ($java.Text -and (Test-Path -LiteralPath $java.Text -PathType Container)) {
        $dialog.SelectedPath = $java.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $java.Text = $dialog.SelectedPath
    }
})

$reset.Add_Click({
    $task.Text = 'assembleDebug'
    $apk.Text = ''
    $java.Text = ''
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
    })

    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

[void]$form.ShowDialog()
