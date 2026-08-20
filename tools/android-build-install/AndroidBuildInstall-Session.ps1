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
$settingsEditor = Join-Path $PSScriptRoot 'Edit-AndroidProjectPreferences.ps1'
$gitUpdater = Join-Path $PSScriptRoot 'Update-AndroidRepo.ps1'
$statusHelper = Join-Path $PSScriptRoot 'Get-AndroidProjectStatus.ps1'
$syncRunner = Join-Path $PSScriptRoot 'Invoke-AndroidSyncAndRun.ps1'

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
        deviceSerial = ''
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
                deviceSerial = "$($item.deviceSerial)"
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

function Get-StatusResults {
    param(
        [string[]]$Projects,
        [switch]$FetchRemote
    )

    if (-not (Test-Path -LiteralPath $statusHelper -PathType Leaf)) {
        throw "Status helper was not found:`n$statusHelper"
    }

    $splat = @{
        Project = @($Projects)
        PreferencesPath = $preferencesPath
    }
    if ($FetchRemote) { $splat.FetchRemote = $true }
    return @(& $statusHelper @splat)
}

function Show-DeviceScan {
    $projects = @(Get-SavedProjects)
    if ($projects.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Add at least one Android project before scanning the device.', 'Android Device Scan') | Out-Null
        return
    }

    try { $results = @(Get-StatusResults -Projects $projects) }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Android Device Scan') | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install - Device Scan'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(1120, 500)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Each project uses its remembered device when configured. Same/Different is an exact SHA-256 APK comparison.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 48)
    $list.Size = New-Object System.Drawing.Size(1088, 378)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    [void]$list.Columns.Add('Project', 180)
    [void]$list.Columns.Add('Device', 190)
    [void]$list.Columns.Add('Status', 130)
    [void]$list.Columns.Add('Detail', 560)
    $form.Controls.Add($list)

    foreach ($result in $results) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$result.Project)
        [void]$item.SubItems.Add([string]$result.Device)
        [void]$item.SubItems.Add([string]$result.DeviceStatus)
        [void]$item.SubItems.Add([string]$result.DeviceDetail)
        [void]$list.Items.Add($item)
    }

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Size = New-Object System.Drawing.Size(100, 32)
    $close.Location = New-Object System.Drawing.Point(1004, 450)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($close)
    $form.CancelButton = $close
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
    if ($pref.deviceSerial) { $arguments += @('-DeviceSerial', $pref.deviceSerial) }
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

function Invoke-ProjectSync {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $syncRunner -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Sync & Run helper was not found:`n$syncRunner", 'Android Sync & Run') | Out-Null
        return 1
    }

    $previousPreference = $ErrorActionPreference
    $exitCode = 1
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncRunner -Project $ProjectPath -PreferencesPath $preferencesPath 2>&1 |
            ForEach-Object { Write-Host "$_" }
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return $exitCode
}

function Select-SavedProjectAction {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(1380, 520)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Android project dashboard'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Sync & Run safely updates Git, rebuilds only when needed, compares the APK on-device, installs only when needed, then launches according to project settings.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 42)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 72)
    $list.Size = New-Object System.Drawing.Size(1348, 292)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.ShowItemToolTips = $true
    [void]$list.Columns.Add('Project', 180)
    [void]$list.Columns.Add('Git', 150)
    [void]$list.Columns.Add('Local Build', 150)
    [void]$list.Columns.Add('Device', 150)
    [void]$list.Columns.Add('Path', 690)
    $form.Controls.Add($list)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = 'Select a project to see its settings.'
    $summary.AutoSize = $true
    $summary.Location = New-Object System.Drawing.Point(16, 378)
    $form.Controls.Add($summary)

    $add = New-Object System.Windows.Forms.Button
    $add.Text = 'Add...'
    $add.Size = New-Object System.Drawing.Size(90, 32)
    $add.Location = New-Object System.Drawing.Point(16, 452)
    $form.Controls.Add($add)

    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = 'Remove'
    $remove.Size = New-Object System.Drawing.Size(90, 32)
    $remove.Location = New-Object System.Drawing.Point(112, 452)
    $remove.Enabled = $false
    $form.Controls.Add($remove)

    $reports = New-Object System.Windows.Forms.Button
    $reports.Text = 'Reports...'
    $reports.Size = New-Object System.Drawing.Size(100, 32)
    $reports.Location = New-Object System.Drawing.Point(208, 452)
    $form.Controls.Add($reports)

    $scan = New-Object System.Windows.Forms.Button
    $scan.Text = 'Scan Device...'
    $scan.Size = New-Object System.Drawing.Size(115, 32)
    $scan.Location = New-Object System.Drawing.Point(314, 452)
    $form.Controls.Add($scan)

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Refresh Status'
    $refresh.Size = New-Object System.Drawing.Size(115, 32)
    $refresh.Location = New-Object System.Drawing.Point(435, 452)
    $form.Controls.Add($refresh)

    $gitPull = New-Object System.Windows.Forms.Button
    $gitPull.Text = 'Git Pull'
    $gitPull.Size = New-Object System.Drawing.Size(90, 32)
    $gitPull.Location = New-Object System.Drawing.Point(556, 452)
    $gitPull.Enabled = $false
    $form.Controls.Add($gitPull)

    $settings = New-Object System.Windows.Forms.Button
    $settings.Text = 'Settings...'
    $settings.Size = New-Object System.Drawing.Size(100, 32)
    $settings.Location = New-Object System.Drawing.Point(652, 452)
    $settings.Enabled = $false
    $form.Controls.Add($settings)

    $sync = New-Object System.Windows.Forms.Button
    $sync.Text = 'Sync && Run'
    $sync.Size = New-Object System.Drawing.Size(115, 32)
    $sync.Location = New-Object System.Drawing.Point(864, 452)
    $sync.Enabled = $false
    $form.Controls.Add($sync)

    $build = New-Object System.Windows.Forms.Button
    $build.Text = 'Build'
    $build.Size = New-Object System.Drawing.Size(90, 32)
    $build.Location = New-Object System.Drawing.Point(985, 452)
    $build.Enabled = $false
    $form.Controls.Add($build)

    $exit = New-Object System.Windows.Forms.Button
    $exit.Text = 'Exit'
    $exit.Size = New-Object System.Drawing.Size(90, 32)
    $exit.Location = New-Object System.Drawing.Point(1274, 452)
    $exit.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($exit)
    $form.CancelButton = $exit
    $form.AcceptButton = $sync

    $selectedPath = {
        if ($list.SelectedItems.Count -ne 1) { return $null }
        return [string]$list.SelectedItems[0].Tag
    }

    $refreshSummary = {
        $path = & $selectedPath
        if (-not $path) {
            $summary.Text = 'Select a project to see its settings.'
            return
        }
        $pref = Get-ProjectPreference -ProjectPath $path
        $apkText = if ($pref.preferredApk) { $pref.preferredApk } else { '(prompt/default)' }
        $javaText = if ($pref.javaHome) { $pref.javaHome } else { '(environment default)' }
        $deviceText = if ($pref.deviceSerial) { $pref.deviceSerial } else { '(automatic)' }
        $summary.Text = "Task: $($pref.gradleTask)    APK: $apkText    JDK: $javaText    Device: $deviceText    Auto-launch: $([bool]$pref.autoLaunch)"
    }

    $refreshRows = {
        param([bool]$FetchRemote = $true)

        $projects = @(Get-SavedProjects)
        $selectedBefore = & $selectedPath
        $list.Items.Clear()

        if ($projects.Count -eq 0) {
            & $refreshSummary
            return
        }

        $oldCursor = [System.Windows.Forms.Cursor]::Current
        try {
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
            $form.Text = 'Android Build and Install - Refreshing status...'
            [System.Windows.Forms.Application]::DoEvents()
            $results = if ($FetchRemote) {
                @(Get-StatusResults -Projects $projects -FetchRemote)
            } else {
                @(Get-StatusResults -Projects $projects)
            }

            foreach ($result in $results) {
                $item = New-Object System.Windows.Forms.ListViewItem([string]$result.Project)
                [void]$item.SubItems.Add([string]$result.GitStatus)
                [void]$item.SubItems.Add([string]$result.BuildStatus)
                [void]$item.SubItems.Add([string]$result.DeviceStatus)
                [void]$item.SubItems.Add([string]$result.ProjectPath)
                $item.Tag = [string]$result.ProjectPath
                $item.ToolTipText = "Git: $($result.GitDetail)`nBuild: $($result.BuildDetail)`nDevice: $($result.DeviceDetail)"
                [void]$list.Items.Add($item)
                if ($selectedBefore -and $result.ProjectPath -ieq $selectedBefore) { $item.Selected = $true }
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Android Project Status') | Out-Null
        }
        finally {
            $form.Text = 'Android Build and Install'
            [System.Windows.Forms.Cursor]::Current = $oldCursor
        }

        if ($list.SelectedItems.Count -eq 0 -and $list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
        & $refreshSummary
    }

    $list.Add_SelectedIndexChanged({
        $selected = ($list.SelectedItems.Count -eq 1)
        $remove.Enabled = $selected
        $gitPull.Enabled = $selected
        $settings.Enabled = $selected
        $sync.Enabled = $selected
        $build.Enabled = $selected
        & $refreshSummary
    })

    $chooseAction = {
        param([string]$Action)
        $path = & $selectedPath
        if (-not $path) { return }
        $form.Tag = [pscustomobject]@{ Action = $Action; Project = $path }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    }

    $sync.Add_Click({ & $chooseAction 'Sync' })
    $build.Add_Click({ & $chooseAction 'Build' })
    $list.Add_DoubleClick({ if ($list.SelectedItems.Count -eq 1) { & $chooseAction 'Build' } })

    $add.Add_Click({
        $path = Browse-ForProject
        if (-not $path) { return }
        try { [void](Remember-Project -Path $path) } catch { return }
        & $refreshRows $false
    })

    $remove.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        $remaining = @(Get-SavedProjects | Where-Object { $_ -ine $path })
        Save-SavedProjects -Projects $remaining
        & $refreshRows $false
    })

    $reports.Add_Click({ Show-Reports })
    $scan.Add_Click({ Show-DeviceScan })
    $refresh.Add_Click({ & $refreshRows $true })
    $gitPull.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        Invoke-ProjectGitPull -ProjectPath $path
        & $refreshRows $true
    })
    $settings.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        Invoke-ProjectSettings -ProjectPath $path
        & $refreshRows $false
    })

    $form.Add_Shown({ & $refreshRows $true })

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $form.Tag
}

$lastExitCode = 0
$pending = if ($Project) { [pscustomobject]@{ Action = 'Build'; Project = $Project } } else { $null }

while ($true) {
    if ($null -eq $pending) {
        $pending = Select-SavedProjectAction
        if ($null -eq $pending) { break }
    }

    try { $projectPath = Remember-Project -Path $pending.Project } catch { $projectPath = $pending.Project }

    if ($pending.Action -eq 'Sync') {
        $lastExitCode = Invoke-ProjectSync -ProjectPath $projectPath
    }
    else {
        $lastExitCode = Invoke-ProjectBuild -ProjectPath $projectPath
    }

    $pending = $null
}

exit $lastExitCode
