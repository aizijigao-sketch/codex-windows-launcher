param(
    [string]$ShortcutName = 'Codex Windows Launcher',
    [string]$IconPath = '',
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$launcherPath = Join-Path $projectRoot 'codex-launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "Launcher script was not found: $launcherPath"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop ($ShortcutName + '.lnk')

if ((Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and -not $Force) {
    throw "Shortcut already exists: $shortcutPath. Re-run with -Force to replace it."
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`" -Mode menu"
$shortcut.WorkingDirectory = $projectRoot

if (-not [string]::IsNullOrWhiteSpace($IconPath)) {
    $expandedIconPath = [Environment]::ExpandEnvironmentVariables($IconPath)
    if (-not (Test-Path -LiteralPath $expandedIconPath -PathType Leaf)) {
        throw "Icon file was not found: $expandedIconPath"
    }
    $shortcut.IconLocation = "$expandedIconPath,0"
}

$shortcut.Save()
Write-Host "Created shortcut: $shortcutPath"
