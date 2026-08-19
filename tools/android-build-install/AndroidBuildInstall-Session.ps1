[CmdletBinding()]
param(
    [string]$Project
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$stateRoot = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
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

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)

    if ($fullPath.Length -gt $root.Length) {
        $trimChars = [char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $fullPath = $fullPath.TrimEnd($trimChars)
    }

    return $fullPath
}

function Get-SavedProjects {
    if (-not (Test-Path -LiteralPath $projectsPath -PathType Leaf)) {
        return @()
    }

    try {
        $config = Get-Content -LiteralPath $projectsPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Could not read saved project list: $($_.Exception.Message)"
        return @()
    }

    $projects = @()

    foreach ($item in @($config.projects)) {
        $candidate = "$item"

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            $candidate = Normalize-ProjectPath -Path $candidate
        }
        catch {
            continue
        }

        if ((Test-Path -LiteralPath $candidate -PathType Container) -and
            $projects -notcontains $candidate) {
            $projects += $candidate
        }
    }

    return @($projects)
}

function Save-SavedProjects {
    param([string[]]$Projects = @())

    $unique = @()

    foreach ($item in @($Projects)) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        $normalized = Normalize-ProjectPath -Path $item

        if ($unique -notcontains $normalized) {
            $unique += $normalized
        }
    }

    [pscustomobject]@{
        projects = @($unique)
    } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $projectsPath -Encoding UTF8
}

function Remember-Project {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Normalize-ProjectPath -Path $Path

    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        return $normalized
    }

    $existing = @(Get-SavedProjects | Where-Object { $_ -ne $normalized })
    Save-SavedProjects -Projects (@($normalized) + $existing)

    return $normalized
}

function Browse-ForProject {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Choose an Android repository or project folder'
    $picker.ShowNewFolderButton = $false

    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return $picker.SelectedPath
}

function Get-LogSummary {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $projectPath = ''
    $exitCode = $null

    try {
        foreach ($line in Get-Content -LiteralPath $File.FullName -ErrorAction Stop) {
            if ($line -like 'Selected project argument:*') {
                $projectPath = $line.Substring('Selected project argument:'.Length).Trim()
                continue
            }

            if ($line -like 'Exit code:*') {
                $rawExitCode = $line.Substring('Exit code:'.Length).Trim()
                $parsedExitCode = 0

                if ([int]::TryParse($rawExitCode, [ref]$parsedExitCode)) {
                    $exitCode = $parsedExitCode
                }
            }
        }
    }
    catch {
        # A partially written or inaccessible report can still be listed.
    }

    $status = if ($null -eq $exitCode) {
        'Incomplete'
    } elseif ($exitCode -eq 0) {
        'Success'
    } else {
        'Failed'
    }

    $projectName = if ([string]::IsNullOrWhiteSpace($projectPath)) {
        '(unknown)'
    } else {
        Split-Path -Leaf $projectPath
    }

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
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $form.ClientSize = New-Object System.Drawing.Size(880, 440)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Recent build/install reports:'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($title)

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

    $reports = @(
        Get-ChildItem -LiteralPath $logRoot -Filter 'android-build-install-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )

    foreach ($report in $reports) {
        $summary = Get-LogSummary -File $report
        $item = New-Object System.Windows.Forms.ListViewItem($summary.Time)
        [void]$item.SubItems.Add($summary.Status)
        [void]$item.SubItems.Add($summary.Project)
        [void]$item.SubItems.Add((Split-Path -Leaf $summary.Path))
        $item.Tag = $summary.Path
        [void]$list.Items.Add($item)
    }

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = 'Open Report'
    $openButton.Size = New-Object System.Drawing.Size(120, 32)
    $openButton.Location = New-Object System.Drawing.Point(16, 392)
    $openButton.Enabled = $false
    $form.Controls.Add($openButton)

    $folderButton = New-Object System.Windows.Forms.Button
    $folderButton.Text = 'Open Reports Folder'
    $folderButton.Size = New-Object System.Drawing.Size(150, 32)
    $folderButton.Location = New-Object System.Drawing.Point(146, 392)
    $form.Controls.Add($folderButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Size = New-Object System.Drawing.Size(100, 32)
    $closeButton.Location = New-Object System.Drawing.Point(764, 392)
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($closeButton)
    $form.CancelButton = $closeButton

    $list.Add_SelectedIndexChanged({
        $openButton.Enabled = ($list.SelectedItems.Count -eq 1)
    })

    $openSelectedReport = {
        if ($list.SelectedItems.Count -ne 1) {
            return
        }

        $reportPath = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            Start-Process notepad.exe -ArgumentList "`"$reportPath`""
        }
    }

    $openButton.Add_Click($openSelectedReport)
    $list.Add_DoubleClick($openSelectedReport)

    $folderButton.Add_Click({
        Start-Process explorer.exe -ArgumentList "`"$logRoot`""
    })

    if ($list.Items.Count -gt 0) {
        $list.Items[0].Selected = $true
    }

    [void]$form.ShowDialog()
}

function Select-SavedProject {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Android Build and Install - Choose Project'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(760, 390)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Choose a saved Android project to build and install:'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Double-click a project, or select it and click Build. The chooser returns after each run.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 42)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 72)
    $list.Size = New-Object System.Drawing.Size(728, 238)
    $list.HorizontalScrollbar = $true
    $list.SelectionMode = [System.Windows.Forms.SelectionMode]::One
    $form.Controls.Add($list)

    foreach ($saved in @(Get-SavedProjects)) {
        [void]$list.Items.Add($saved)
    }

    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Text = 'Add...'
    $addButton.Size = New-Object System.Drawing.Size(100, 32)
    $addButton.Location = New-Object System.Drawing.Point(16, 334)
    $form.Controls.Add($addButton)

    $removeButton = New-Object System.Windows.Forms.Button
    $removeButton.Text = 'Remove'
    $removeButton.Size = New-Object System.Drawing.Size(100, 32)
    $removeButton.Location = New-Object System.Drawing.Point(124, 334)
    $removeButton.Enabled = $false
    $form.Controls.Add($removeButton)

    $reportsButton = New-Object System.Windows.Forms.Button
    $reportsButton.Text = 'Reports...'
    $reportsButton.Size = New-Object System.Drawing.Size(100, 32)
    $reportsButton.Location = New-Object System.Drawing.Point(232, 334)
    $form.Controls.Add($reportsButton)

    $buildButton = New-Object System.Windows.Forms.Button
    $buildButton.Text = 'Build'
    $buildButton.Size = New-Object System.Drawing.Size(100, 32)
    $buildButton.Location = New-Object System.Drawing.Point(424, 334)
    $buildButton.Enabled = ($list.Items.Count -gt 0)
    $form.Controls.Add($buildButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Exit'
    $cancelButton.Size = New-Object System.Drawing.Size(100, 32)
    $cancelButton.Location = New-Object System.Drawing.Point(644, 334)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $buildButton
    $form.CancelButton = $cancelButton

    $list.Add_SelectedIndexChanged({
        $hasSelection = ($list.SelectedIndex -ge 0)
        $buildButton.Enabled = $hasSelection
        $removeButton.Enabled = $hasSelection
    })

    $buildButton.Add_Click({
        if ($list.SelectedIndex -lt 0) {
            return
        }

        $form.Tag = [string]$list.SelectedItem
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $list.Add_DoubleClick({
        if ($list.SelectedIndex -ge 0) {
            $buildButton.PerformClick()
        }
    })

    $addButton.Add_Click({
        $selected = Browse-ForProject

        if ([string]::IsNullOrWhiteSpace($selected)) {
            return
        }

        try {
            $selected = Remember-Project -Path $selected
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not remember that project:`n$($_.Exception.Message)",
                'Android Build and Install',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        $list.Items.Clear()
        foreach ($saved in @(Get-SavedProjects)) {
            [void]$list.Items.Add($saved)
        }
        $list.SelectedItem = $selected
    })

    $removeButton.Add_Click({
        if ($list.SelectedIndex -lt 0) {
            return
        }

        $removeIndex = $list.SelectedIndex
        $remaining = @()

        for ($i = 0; $i -lt $list.Items.Count; $i++) {
            if ($i -ne $removeIndex) {
                $remaining += [string]$list.Items[$i]
            }
        }

        Save-SavedProjects -Projects $remaining
        $list.Items.RemoveAt($removeIndex)

        if ($list.Items.Count -gt 0) {
            $list.SelectedIndex = [Math]::Min($removeIndex, $list.Items.Count - 1)
        }
    })

    $reportsButton.Add_Click({
        Show-Reports
    })

    $form.Add_Shown({
        if ($list.Items.Count -gt 0) {
            $list.SelectedIndex = 0
            $list.Focus()
        }
    })

    $result = $form.ShowDialog()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return [string]$form.Tag
}

function Invoke-ProjectBuild {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runner,
        '-Project', $ProjectPath
    )

    $previousPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe @arguments
        return [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

$lastExitCode = 0
$nextProject = $Project

while ($true) {
    if ([string]::IsNullOrWhiteSpace($nextProject)) {
        $nextProject = Select-SavedProject

        if ([string]::IsNullOrWhiteSpace($nextProject)) {
            break
        }
    }

    try {
        $nextProject = Remember-Project -Path $nextProject
    }
    catch {
        # The per-build runner will present the normal path validation error.
    }

    $lastExitCode = Invoke-ProjectBuild -ProjectPath $nextProject
    $nextProject = $null
}

exit $lastExitCode
