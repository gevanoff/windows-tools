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
$runner = Join-Path $PSScriptRoot 'Run-AndroidBuildInstall.ps1'

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
    if (-not (Test-Path -LiteralPath $projectsPath -PathType Leaf)) {
        return @()
    }

    try {
        $config = Get-Content -LiteralPath $projectsPath -Raw | ConvertFrom-Json
    }
    catch {
        return @()
    }

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
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return $path
    }

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

    $status = if ($null -eq $exitCode) { 'Incomplete' } elseif ($exitCode -eq 0) { 'Success' } else { 'Failed' }
    $projectName = if ($projectPath) { Split-Path -Leaf $projectPath } else { '(unknown)' }

    return [pscustomobject]@{
        Time = $File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Status = $status
        Project = $projectName
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

    $files = @(Get-ChildItem -LiteralPath $logRoot -Filter 'android-build-install-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($file in $files) {
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

function Select-SavedProject {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install - Choose Project'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(760, 390)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Choose a saved Android project to build and install:'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Double-click a project, or select it and click Build. This screen returns after every run.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 42)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 72)
    $list.Size = New-Object System.Drawing.Size(728, 238)
    $list.HorizontalScrollbar = $true
    $form.Controls.Add($list)

    foreach ($saved in @(Get-SavedProjects)) { [void]$list.Items.Add($saved) }

    $add = New-Object System.Windows.Forms.Button
    $add.Text = 'Add...'
    $add.Size = New-Object System.Drawing.Size(100, 32)
    $add.Location = New-Object System.Drawing.Point(16, 334)
    $form.Controls.Add($add)

    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = 'Remove'
    $remove.Size = New-Object System.Drawing.Size(100, 32)
    $remove.Location = New-Object System.Drawing.Point(124, 334)
    $remove.Enabled = $false
    $form.Controls.Add($remove)

    $reports = New-Object System.Windows.Forms.Button
    $reports.Text = 'Reports...'
    $reports.Size = New-Object System.Drawing.Size(100, 32)
    $reports.Location = New-Object System.Drawing.Point(232, 334)
    $form.Controls.Add($reports)

    $build = New-Object System.Windows.Forms.Button
    $build.Text = 'Build'
    $build.Size = New-Object System.Drawing.Size(100, 32)
    $build.Location = New-Object System.Drawing.Point(424, 334)
    $build.Enabled = ($list.Items.Count -gt 0)
    $form.Controls.Add($build)

    $exit = New-Object System.Windows.Forms.Button
    $exit.Text = 'Exit'
    $exit.Size = New-Object System.Drawing.Size(100, 32)
    $exit.Location = New-Object System.Drawing.Point(644, 334)
    $exit.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($exit)

    $form.AcceptButton = $build
    $form.CancelButton = $exit

    $list.Add_SelectedIndexChanged({
        $selected = ($list.SelectedIndex -ge 0)
        $build.Enabled = $selected
        $remove.Enabled = $selected
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
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        try { $path = Remember-Project -Path $path } catch { return }
        $list.Items.Clear()
        foreach ($saved in @(Get-SavedProjects)) { [void]$list.Items.Add($saved) }
        $list.SelectedItem = $path
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
        if ($list.Items.Count -gt 0) {
            $list.SelectedIndex = [Math]::Min($index, $list.Items.Count - 1)
        }
    })

    $reports.Add_Click({ Show-Reports })
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

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $runner,
        '-Project', $ProjectPath
    )

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
    if ([string]::IsNullOrWhiteSpace($nextProject)) {
        $nextProject = Select-SavedProject
        if ([string]::IsNullOrWhiteSpace($nextProject)) { break }
    }

    try { $nextProject = Remember-Project -Path $nextProject } catch { }
    $lastExitCode = Invoke-ProjectBuild -ProjectPath $nextProject
    $nextProject = $null
}

exit $lastExitCode
