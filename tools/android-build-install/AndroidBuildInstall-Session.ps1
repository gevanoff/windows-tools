[CmdletBinding()]
param([string]$Project)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$stateRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WindowsTools\android-build-install'
} else {
    Join-Path $env:TEMP 'WindowsTools\android-build-install'
}
$logRoot = Join-Path $stateRoot 'logs'
$projectsPath = Join-Path $stateRoot 'projects.json'
$preferencesPath = Join-Path $stateRoot 'project-preferences.json'
$runner = Join-Path $PSScriptRoot 'Run-AndroidBuildInstall.ps1'
$scanner = Join-Path $PSScriptRoot 'Scan-AndroidDevice.ps1'
$settingsEditor = Join-Path $PSScriptRoot 'Edit-AndroidProjectPreferences.ps1'
$gitUpdater = Join-Path $PSScriptRoot 'Update-AndroidRepo.ps1'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Normalize-ProjectPath {
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

function Get-SavedProjects {
    if (-not (Test-Path -LiteralPath $projectsPath -PathType Leaf)) { return @() }
    try { $config = Get-Content -LiteralPath $projectsPath -Raw | ConvertFrom-Json } catch { return @() }

    $result = @()
    foreach ($item in @($config.projects)) {
        if ([string]::IsNullOrWhiteSpace("$item")) { continue }
        try { $path = Normalize-ProjectPath -Path "$item" } catch { continue }
        if ((Test-Path -LiteralPath $path -PathType Container) -and $result -notcontains $path) {
            $result += $path
        }
    }
    return @($result)
}

function Save-SavedProjects {
    param([string[]]$Projects = @())

    $unique = @()
    foreach ($item in @($Projects)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $path = Normalize-ProjectPath -Path $item
        if ($unique -notcontains $path) { $unique += $path }
    }

    [pscustomobject]@{ projects = @($unique) } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $projectsPath -Encoding UTF8
}

function Remember-Project {
    param([Parameter(Mandatory = $true)][string]$Path)

    $path = Normalize-ProjectPath -Path $Path
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $path }
    $others = @(Get-SavedProjects | Where-Object { $_ -ne $path })
    Save-SavedProjects -Projects (@($path) + $others)
    return $path
}

function Browse-ForProject {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Choose an Android repository or project folder'
    $picker.ShowNewFolderButton = $false
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $picker.SelectedPath
}

function Get-ProjectPreference {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $default = [pscustomobject]@{
        gradleTask = 'assembleDebug'
        preferredApk = ''
        javaHome = ''
        autoLaunch = $false
    }

    if (-not (Test-Path -LiteralPath $preferencesPath -PathType Leaf)) { return $default }
    try { $json = Get-Content -LiteralPath $preferencesPath -Raw | ConvertFrom-Json } catch { return $default }

    $normalized = Normalize-ProjectPath -Path $ProjectPath
    foreach ($item in @($json.projects)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-ProjectPath -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $normalized) {
            return [pscustomobject]@{
                gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
                preferredApk = "$($item.preferredApk)"
                javaHome = "$($item.javaHome)"
                autoLaunch = [bool]$item.autoLaunch
            }
        }
    }
    return $default
}

function Get-LogSummary {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $projectPath = ''
    $exitCode = $null
    try {
        foreach ($line in Get-Content -LiteralPath $File.FullName) {
            if ($line -like 'Selected project argument:*') {
                $projectPath = $line.Substring('Selected project argument:'.Length).Trim()
            }
            elseif ($line -like 'Exit code:*') {
                $raw = $line.Substring('Exit code:'.Length).Trim()
                $parsed = 0
                if ([int]::TryParse($raw, [ref]$parsed)) { $exitCode = $parsed }
            }
        }
    }
    catch { }

    return [pscustomobject]@{
        Time = $File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Status = if ($null -eq $exitCode) { 'Incomplete' } elseif ($exitCode -eq 0) { 'Success' } else { 'Failed' }
        Project = if ($projectPath) { Split-Path -Leaf $projectPath } else { '(unknown)' }
        Path = $File.FullName
    }
}

function Show-Reports {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install - Reports'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(880, 440)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Recent build/install reports:'
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($label)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 46)
    $list.Size = New-Object System.Drawing.Size(848, 326)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    [void]$list.Columns.Add('Run', 155)
    [void]$list.Columns.Add('Result', 85)
    [void]$list.Columns.Add('Project', 230)
    [void]$list.Columns.Add('Report file', 350)
    $form.Controls.Add($list)

    foreach ($file in @(Get-ChildItem -LiteralPath $logRoot -Filter 'android-build-install-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $summary = Get-LogSummary -File $file
        $item = New-Object System.Windows.Forms.ListViewItem($summary.Time)
        [void]$item.SubItems.Add($summary.Status)
        [void]$item.SubItems.Add($summary.Project)
        [void]$item.SubItems.Add((Split-Path -Leaf $summary.Path))
        $item.Tag = $summary.Path
        [void]$list.Items.Add($item)
    }

    $open = New-Object System.Windows.Forms.Button
    $open.Text = 'Open Report'
    $open.Size = New-Object System.Drawing.Size(120, 32)
    $open.Location = New-Object System.Drawing.Point(16, 392)
    $open.Enabled = $false
    $form.Controls.Add($open)

    $folder = New-Object System.Windows.Forms.Button
    $folder.Text = 'Open Reports Folder'
    $folder.Size = New-Object System.Drawing.Size(150, 32)
    $folder.Location = New-Object System.Drawing.Point(146, 392)
    $form.Controls.Add($folder)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Size = New-Object System.Drawing.Size(100, 32)
    $close.Location = New-Object System.Drawing.Point(764, 392)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($close)
    $form.CancelButton = $close

    $list.Add_SelectedIndexChanged({ $open.Enabled = ($list.SelectedItems.Count -eq 1) })
    $openReport = {
        if ($list.SelectedItems.Count -ne 1) { return }
        $path = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Start-Process notepad.exe -ArgumentList "`"$path`""
        }
    }
    $open.Add_Click($openReport)
    $list.Add_DoubleClick($openReport)
    $folder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$logRoot`"" })

    if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
    [void]$form.ShowDialog()
}

function Show-DeviceScan {
    $projects = @(Get-SavedProjects)
    if ($projects.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Add at least one Android project before scanning the device.', 'Android Device Scan') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Scanner script was not found:`n$scanner", 'Android Device Scan') | Out-Null
        return
    }

    $oldCursor = [System.Windows.Forms.Cursor]::Current
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        $results = @(& $scanner -Project $projects)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Android Device Scan') | Out-Null
        return
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = $oldCursor
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install - Device Scan'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(1120, 500)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $device = if ($results.Count -gt 0) { $results[0].Device } else { '(unknown)' }
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Device: $device    Comparison: installed APK bytes vs latest local debug APK"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($label)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Same/Different is SHA-256 exact. Unknown means an exact comparison was not safe or possible.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 40)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 70)
    $list.Size = New-Object System.Drawing.Size(1088, 356)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    [void]$list.Columns.Add('Status', 115)
    [void]$list.Columns.Add('Project', 170)
    [void]$list.Columns.Add('Package', 215)
    [void]$list.Columns.Add('Local APK', 260)
    [void]$list.Columns.Add('Detail', 320)
    $form.Controls.Add($list)

    foreach ($result in $results) {
        $localApk = if ($result.LocalApk) { Split-Path -Leaf $result.LocalApk } else { '' }
        $item = New-Object System.Windows.Forms.ListViewItem([string]$result.Status)
        [void]$item.SubItems.Add([string]$result.Project)
        [void]$item.SubItems.Add([string]$result.PackageId)
        [void]$item.SubItems.Add($localApk)
        [void]$item.SubItems.Add([string]$result.Detail)
        $item.Tag = $result
        [void]$list.Items.Add($item)
    }

    $details = New-Object System.Windows.Forms.Button
    $details.Text = 'Details...'
    $details.Size = New-Object System.Drawing.Size(110, 32)
    $details.Location = New-Object System.Drawing.Point(16, 450)
    $details.Enabled = $false
    $form.Controls.Add($details)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Size = New-Object System.Drawing.Size(100, 32)
    $close.Location = New-Object System.Drawing.Point(1004, 450)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($close)
    $form.CancelButton = $close

    $list.Add_SelectedIndexChanged({ $details.Enabled = ($list.SelectedItems.Count -eq 1) })
    $showDetails = {
        if ($list.SelectedItems.Count -ne 1) { return }
        $result = $list.SelectedItems[0].Tag
        $text = @(
            "Project: $($result.ProjectPath)",
            "Status: $($result.Status)",
            "Package: $($result.PackageId)",
            "Local APK: $($result.LocalApk)",
            "Local SHA-256: $($result.LocalHash)",
            "Installed SHA-256: $($result.InstalledHash)",
            "Detail: $($result.Detail)"
        ) -join [Environment]::NewLine
        [System.Windows.Forms.MessageBox]::Show($text, 'Android Device Scan Details') | Out-Null
    }
    $details.Add_Click($showDetails)
    $list.Add_DoubleClick($showDetails)

    if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
    [void]$form.ShowDialog()
}

function Invoke-ProjectSettings {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $settingsEditor -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Settings editor was not found:`n$settingsEditor", 'Android Project Settings') | Out-Null
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $settingsEditor -Project $ProjectPath -PreferencesPath $preferencesPath
}

function Invoke-ProjectGitPull {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $gitUpdater -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Git update helper was not found:`n$gitUpdater", 'Android Project Git Pull') | Out-Null
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gitUpdater -Project $ProjectPath
}

function Select-SavedProject {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install - Choose Project'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(1120, 430)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Choose a saved Android project:'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Build/install, update from Git, configure project defaults, scan the attached device, or inspect reports.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 42)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 72)
    $list.Size = New-Object System.Drawing.Size(1088, 220)
    $list.HorizontalScrollbar = $true
    $form.Controls.Add($list)
    foreach ($saved in @(Get-SavedProjects)) { [void]$list.Items.Add($saved) }

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = 'Select a project to see its build settings.'
    $summary.AutoSize = $true
    $summary.Location = New-Object System.Drawing.Point(16, 305)
    $form.Controls.Add($summary)

    $add = New-Object System.Windows.Forms.Button
    $add.Text = 'Add...'
    $add.Size = New-Object System.Drawing.Size(100, 32)
    $add.Location = New-Object System.Drawing.Point(16, 362)
    $form.Controls.Add($add)

    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = 'Remove'
    $remove.Size = New-Object System.Drawing.Size(100, 32)
    $remove.Location = New-Object System.Drawing.Point(124, 362)
    $remove.Enabled = $false
    $form.Controls.Add($remove)

    $reports = New-Object System.Windows.Forms.Button
    $reports.Text = 'Reports...'
    $reports.Size = New-Object System.Drawing.Size(100, 32)
    $reports.Location = New-Object System.Drawing.Point(232, 362)
    $form.Controls.Add($reports)

    $scan = New-Object System.Windows.Forms.Button
    $scan.Text = 'Scan Device...'
    $scan.Size = New-Object System.Drawing.Size(120, 32)
    $scan.Location = New-Object System.Drawing.Point(340, 362)
    $scan.Enabled = ($list.Items.Count -gt 0)
    $form.Controls.Add($scan)

    $gitPull = New-Object System.Windows.Forms.Button
    $gitPull.Text = 'Git Pull'
    $gitPull.Size = New-Object System.Drawing.Size(100, 32)
    $gitPull.Location = New-Object System.Drawing.Point(468, 362)
    $gitPull.Enabled = $false
    $form.Controls.Add($gitPull)

    $settings = New-Object System.Windows.Forms.Button
    $settings.Text = 'Settings...'
    $settings.Size = New-Object System.Drawing.Size(100, 32)
    $settings.Location = New-Object System.Drawing.Point(576, 362)
    $settings.Enabled = $false
    $form.Controls.Add($settings)

    $build = New-Object System.Windows.Forms.Button
    $build.Text = 'Build'
    $build.Size = New-Object System.Drawing.Size(100, 32)
    $build.Location = New-Object System.Drawing.Point(792, 362)
    $build.Enabled = $false
    $form.Controls.Add($build)

    $exit = New-Object System.Windows.Forms.Button
    $exit.Text = 'Exit'
    $exit.Size = New-Object System.Drawing.Size(100, 32)
    $exit.Location = New-Object System.Drawing.Point(1004, 362)
    $exit.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($exit)

    $form.AcceptButton = $build
    $form.CancelButton = $exit

    $refreshSummary = {
        if ($list.SelectedIndex -lt 0) {
            $summary.Text = 'Select a project to see its build settings.'
            return
        }
        $path = [string]$list.SelectedItem
        $pref = Get-ProjectPreference -ProjectPath $path
        $apkText = if ($pref.preferredApk) { $pref.preferredApk } else { '(prompt/default)' }
        $javaText = if ($pref.javaHome) { $pref.javaHome } else { '(environment default)' }
        $summary.Text = "Task: $($pref.gradleTask)    APK: $apkText    JDK: $javaText    Auto-launch: $([bool]$pref.autoLaunch)"
    }

    $list.Add_SelectedIndexChanged({
        $selected = ($list.SelectedIndex -ge 0)
        $build.Enabled = $selected
        $remove.Enabled = $selected
        $gitPull.Enabled = $selected
        $settings.Enabled = $selected
        & $refreshSummary
    })

    $build.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $form.Tag = [string]$list.SelectedItem
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $list.Add_DoubleClick({ if ($list.SelectedIndex -ge 0) { $build.PerformClick() } })

    $add.Add_Click({
        $path = Browse-ForProject
        if (-not $path) { return }
        try { $path = Remember-Project -Path $path } catch { return }
        $list.Items.Clear()
        foreach ($saved in @(Get-SavedProjects)) { [void]$list.Items.Add($saved) }
        $list.SelectedItem = $path
        $scan.Enabled = ($list.Items.Count -gt 0)
    })

    $remove.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $index = $list.SelectedIndex
        $remaining = @()
        for ($i = 0; $i -lt $list.Items.Count; $i++) {
            if ($i -ne $index) { $remaining += [string]$list.Items[$i] }
        }
        Save-SavedProjects -Projects $remaining
        $list.Items.RemoveAt($index)
        $scan.Enabled = ($list.Items.Count -gt 0)
        if ($list.Items.Count -gt 0) {
            $list.SelectedIndex = [Math]::Min($index, $list.Items.Count - 1)
        } else {
            $build.Enabled = $false
            $remove.Enabled = $false
            $gitPull.Enabled = $false
            $settings.Enabled = $false
            & $refreshSummary
        }
    })

    $reports.Add_Click({ Show-Reports })
    $scan.Add_Click({ Show-DeviceScan })
    $gitPull.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        Invoke-ProjectGitPull -ProjectPath ([string]$list.SelectedItem)
    })
    $settings.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        Invoke-ProjectSettings -ProjectPath ([string]$list.SelectedItem)
        & $refreshSummary
    })

    $form.Add_Shown({
        if ($list.Items.Count -gt 0) {
            $list.SelectedIndex = 0
            $list.Focus()
        }
    })

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [string]$form.Tag
}

function Invoke-ProjectBuild {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $pref = Get-ProjectPreference -ProjectPath $ProjectPath
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runner,
        '-Project', $ProjectPath,
        '-GradleTask', $pref.gradleTask
    )
    if ($pref.preferredApk) { $arguments += @('-PreferredApk', $pref.preferredApk) }
    if ($pref.javaHome) { $arguments += @('-JavaHome', $pref.javaHome) }
    if ($pref.autoLaunch) { $arguments += '-AutoLaunch' }

    $previousPreference = $ErrorActionPreference
    $exitCode = 1
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe @arguments 2>&1 | ForEach-Object { Write-Host "$_" }
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return $exitCode
}

$lastExitCode = 0
$nextProject = $Project

while ($true) {
    if (-not $nextProject) {
        $nextProject = Select-SavedProject
        if (-not $nextProject) { break }
    }

    try { $nextProject = Remember-Project -Path $nextProject } catch { }
    $lastExitCode = Invoke-ProjectBuild -ProjectPath $nextProject
    $nextProject = $null
}

exit $lastExitCode
