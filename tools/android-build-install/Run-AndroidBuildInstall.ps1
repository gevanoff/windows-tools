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

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Normalize-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
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
    Save-SavedProjects -Projects @($normalized) + $existing

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
    $hint.Text = 'Double-click a project, or select it and click Build. Use Add to remember more repositories.'
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

    $buildButton = New-Object System.Windows.Forms.Button
    $buildButton.Text = 'Build'
    $buildButton.Size = New-Object System.Drawing.Size(100, 32)
    $buildButton.Location = New-Object System.Drawing.Point(424, 334)
    $buildButton.Enabled = ($list.Items.Count -gt 0)
    $form.Controls.Add($buildButton)

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

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
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

if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = Select-SavedProject

    if ([string]::IsNullOrWhiteSpace($Project)) {
        Write-Host 'Cancelled.'
        exit 0
    }
}

try {
    $Project = Remember-Project -Path $Project
}
catch {
    # Let the implementation provide the normal invalid-project error. Failure
    # to persist a convenience entry should not prevent a build attempt.
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logRoot "android-build-install-$timestamp.log"
$implementation = Join-Path $PSScriptRoot 'Build-And-Install-Android.ps1'

$childArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $implementation,
    '-Project', $Project
)

@(
    'Android Build and Install',
    "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "Computer: $env:COMPUTERNAME",
    "User: $env:USERNAME",
    "Launcher: $PSCommandPath",
    "Implementation: $implementation",
    "Selected project argument: $Project",
    "Saved project list: $projectsPath",
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
