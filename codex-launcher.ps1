param(
    [ValidateSet('official', 'thirdparty', 'thirdparty-preserve-auth', 'thirdparty-pure', 'check', 'doctor', 'bootstrap', 'menu')]
    [string]$Mode = 'menu',

    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:LauncherVersion = 'v0.4.2'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    # Console encoding is best-effort on older hosts.
}

$Script:UserProfile = [Environment]::GetFolderPath('UserProfile')
$Script:LauncherHome = Join-Path $Script:UserProfile '.codex-launcher'
$Script:ConfigPath = Join-Path $Script:LauncherHome 'launcher-config.json'
$Script:BackupDir = Join-Path $Script:LauncherHome 'backup'
$Script:DefaultCodexHome = Join-Path $Script:UserProfile '.codex'
$Script:ActiveConfigPath = Join-Path $Script:DefaultCodexHome 'config.toml'
$Script:ActiveAuthPath = Join-Path $Script:DefaultCodexHome 'auth.json'
$Script:CodexGlobalStatePath = Join-Path $Script:DefaultCodexHome '.codex-global-state.json'
$Script:LauncherStateDir = Join-Path $Script:LauncherHome 'state'
$Script:CodexUiStateSnapshotPath = Join-Path $Script:LauncherStateDir 'codex-ui-state.json'
$Script:CCSwitchHome = Join-Path $Script:UserProfile '.cc-switch'
$Script:CCSwitchSettingsPath = Join-Path $Script:CCSwitchHome 'settings.json'
$Script:CCSwitchBackupDir = Join-Path $Script:CCSwitchHome 'backups'
$Script:ProfileDir = Join-Path $Script:LauncherHome 'profiles'
$Script:ThirdPartyProfileDir = Join-Path $Script:ProfileDir 'thirdparty'
$Script:OfficialProfileDir = Join-Path $Script:ProfileDir 'official'
$Script:ThirdPartyEnvVars = @(
    'OPENAI_API_KEY',
    'OPENAI_BASE_URL',
    'OPENAI_API_BASE',
    'OPENAI_PROVIDER',
    'CODEX_API_KEY'
)
$Script:CodexProcessNames = @('Codex', 'codex', 'OpenAI Codex')
$Script:CCSwitchProcessNames = @('ccswitch', 'cc-switch', 'CCSwitch')
$Script:CodexUiStateTopLevelKeys = @(
    'electron-main-window-bounds',
    'electron-avatar-overlay-bounds',
    'electron-avatar-overlay-open',
    'electron-saved-workspace-roots',
    'active-workspace-roots',
    'project-order',
    'project-writable-roots',
    'pinned-project-ids',
    'pinned-thread-ids',
    'use-copilot-auth-if-available'
)
$Script:CodexUiStateAtomKeys = @(
    'agent-mode-by-host-id',
    'composer-auto-context-enabled',
    'diff-filter',
    'sidebar-collapsed-groups',
    'sidebar-collapsed-sections-v1',
    'sidebar-width',
    'skip-full-access-confirm',
    'has-seen-fast-mode-announcement',
    'has-seen-fast-mode-home-banner',
    'has-seen-knowledge-work-announcement',
    'has-seen-codex-mobile-announcement',
    'codex-mobile-sidebar-nav-item-clicked-v1',
    'electron:onboarding-plugin-checklist-active',
    'electron:onboarding-primary-runtime-install-ready',
    'electron:onboarding-primary-runtime-install-requested',
    'electron:onboarding-projectless-completed',
    'electron:onboarding-welcome-pending'
)
$Script:ConfigPreserveSectionPrefixes = @(
    'marketplaces',
    'marketplaces.',
    'plugins.',
    'mcp_servers',
    'mcp_servers.',
    'windows',
    'features',
    'projects.',
    'desktop'
)
$Script:ConfigPreserveTopLevelKeys = @(
    'notify',
    'disable_response_storage'
)

function Write-Info {
    param([string]$Message)
    Write-Host "[info] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-ErrorLine {
    param([string]$Message)
    Write-Host "[error] $Message" -ForegroundColor Red
}

function Write-Next {
    param([string]$Message)
    Write-Host "[next] $Message" -ForegroundColor Cyan
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function New-DefaultLauncherConfig {
    $defaults = New-Object PSObject -Property @{
        codexPath = ''
        ccswitchPath = ''
        historySyncBackendPath = ''
    }

    return $defaults
}

function Read-LauncherConfig {
    $defaults = New-DefaultLauncherConfig

    if (-not (Test-Path -LiteralPath $Script:ConfigPath -PathType Leaf)) {
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $defaults
        }
        $config = $raw | ConvertFrom-Json
        foreach ($name in @('codexPath', 'ccswitchPath', 'historySyncBackendPath')) {
            if (-not ($config.PSObject.Properties.Name -contains $name)) {
                Add-Member -InputObject $config -NotePropertyName $name -NotePropertyValue ''
            }
        }
        return $config
    } catch {
        throw "Failed to read launcher config '$Script:ConfigPath': $($_.Exception.Message)"
    }
}

function Load-LauncherConfig {
    Ensure-Directory -Path $Script:LauncherHome
    return (Read-LauncherConfig)
}

function Write-LauncherConfigIfMissing {
    param(
        $Config,
        [switch]$NoWrite
    )

    if (Test-Path -LiteralPath $Script:ConfigPath -PathType Leaf) {
        Write-Ok "????????$Script:ConfigPath"
        return
    }

    $codexPath = ''
    $ccswitchPath = ''
    $foundCodexExe = Find-CodexExecutable -Config $Config
    if ($foundCodexExe) {
        $codexPath = $foundCodexExe
    }
    $foundCCSwitch = Resolve-CCSwitchPath -Config $Config
    if ($foundCCSwitch) {
        $ccswitchPath = $foundCCSwitch
    }

    if ($NoWrite) {
        Write-Info "NoLaunch: ????????????$Script:ConfigPath"
        if ($codexPath) {
            Write-Info "NoLaunch: ???? codexPath=$codexPath"
        }
        return
    }

    Ensure-Directory -Path $Script:LauncherHome
    $json = @{
        codexPath = $codexPath
        ccswitchPath = $ccswitchPath
        historySyncBackendPath = ''
        notes = @(
            'This file is machine-local and must not contain secrets.',
            'Set codexPath or ccswitchPath only when auto-discovery fails.',
            'historySyncBackendPath is optional; when empty the launcher looks for the sibling codex-history-sync-windows-work project.',
            'Do not place API keys, tokens, passwords, cookies, provider secrets, or auth.json contents here.'
        )
    } | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $Script:ConfigPath -Value $json -Encoding UTF8
    Write-Ok "???????????$Script:ConfigPath"
}

function Test-ExecutablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($Path)) -PathType Leaf)
}

function Resolve-LinkTarget {
    param([string]$LinkPath)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($LinkPath)
        if (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath)) {
            return $shortcut.TargetPath
        }
    } catch {
        return $null
    }
    return $null
}

function Find-ExecutableByName {
    param(
        [string[]]$Names,
        [string[]]$Roots
    )

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($name in $Names) {
            $direct = Join-Path $root $name
            if (Test-Path -LiteralPath $direct -PathType Leaf) {
                return $direct
            }
        }

        foreach ($name in $Names) {
            try {
                $found = Get-ChildItem -LiteralPath $root -Filter $name -File -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty FullName
                if ($found) {
                    return $found
                }
            } catch {
                # Some install roots contain protected folders; skip unreadable branches.
            }
        }
    }

    return $null
}

function Find-ShortcutTarget {
    param([string[]]$NamePatterns)

    $shortcutRoots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        ([Environment]::GetFolderPath('Desktop')),
        (Join-Path $env:PUBLIC 'Desktop')
    )

    foreach ($root in $shortcutRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($pattern in $NamePatterns) {
            $links = Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -like $pattern }
            foreach ($link in $links) {
                $target = Resolve-LinkTarget -LinkPath $link.FullName
                if (Test-ExecutablePath -Path $target) {
                    return $target
                }
            }
        }
    }

    return $null
}

function Get-DesktopShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Windows Launcher.lnk')
}

function Get-ShortcutInfo {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return New-Object PSObject -Property @{
            Path = $Path
            TargetPath = $shortcut.TargetPath
            Arguments = $shortcut.Arguments
            WorkingDirectory = $shortcut.WorkingDirectory
            IconLocation = $shortcut.IconLocation
        }
    } catch {
        return New-Object PSObject -Property @{
            Path = $Path
            TargetPath = ''
            Arguments = ''
            WorkingDirectory = ''
            IconLocation = ''
        }
    }
}

function Find-LegacyShortcuts {
    $shortcutNames = @(
        'Start Codex With CC Switch.lnk',
        'Start Codex With CC Switch.url'
    )
    $roots = @(
        ([Environment]::GetFolderPath('Desktop')),
        (Join-Path $env:PUBLIC 'Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    )

    $found = @()
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($name in $shortcutNames) {
            $path = Join-Path $root $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $found += $path
            }
        }
        try {
            $found += @(Get-ChildItem -LiteralPath $root -Filter 'Start Codex With*.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        } catch {
            # Ignore protected Start Menu branches.
        }
    }

    return @($found | Select-Object -Unique)
}

function Backup-ShortcutMetadata {
    param(
        [string[]]$ShortcutPaths,
        [string]$Reason,
        [switch]$NoWrite
    )

    if (-not $ShortcutPaths -or $ShortcutPaths.Count -eq 0) {
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $Script:BackupDir ("shortcuts.$timestamp.$Reason.txt")
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($path in $ShortcutPaths) {
        $info = Get-ShortcutInfo -Path $path
        $lines.Add("Shortcut: $path")
        if ($info) {
            $lines.Add("Target: $($info.TargetPath)")
            $lines.Add("Arguments: $($info.Arguments)")
            $lines.Add("WorkingDirectory: $($info.WorkingDirectory)")
            $lines.Add("IconLocation: $($info.IconLocation)")
        }
        $lines.Add('')
    }

    if ($NoWrite) {
        Write-Info "NoLaunch: ???????????? $backupPath"
        return
    }

    Ensure-Directory -Path $Script:BackupDir
    Set-Content -LiteralPath $backupPath -Value $lines.ToArray() -Encoding UTF8
    Write-Ok "???????????$backupPath"
}

function New-LauncherShortcut {
    param([switch]$NoWrite)

    $shortcutPath = Get-DesktopShortcutPath
    $scriptPath = $PSCommandPath
    $scriptRoot = Split-Path -Parent $scriptPath
    $existing = @()
    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        $existing += $shortcutPath
    }

    Backup-ShortcutMetadata -ShortcutPaths $existing -Reason 'before-bootstrap-shortcut' -NoWrite:$NoWrite

    if ($NoWrite) {
        Write-Info "NoLaunch: ??????????????$shortcutPath"
        return
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode menu"
    $shortcut.WorkingDirectory = $scriptRoot

    if ([string]::IsNullOrWhiteSpace($shortcut.IconLocation)) {
        $iconCandidate = Join-Path $scriptRoot 'assets\codex-default-pet.ico'
        if (Test-Path -LiteralPath $iconCandidate -PathType Leaf) {
            $shortcut.IconLocation = "$iconCandidate,0"
        }
    }

    $shortcut.Save()
    Write-Ok "?????????????$shortcutPath"
}

function Test-LocalPort {
    param([int]$Port)

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne(300)
        if ($success) {
            $client.EndConnect($result)
        }
        $client.Close()
        return $success
    } catch {
        return $false
    }
}

function Find-StartAppId {
    param([string]$NamePattern)
    try {
        $app = Get-StartApps |
            Where-Object { $_.Name -like $NamePattern -or $_.AppID -like $NamePattern } |
            Select-Object -First 1
        if ($app -and -not [string]::IsNullOrWhiteSpace($app.AppID)) {
            return $app.AppID
        }
    } catch {
        return $null
    }
    return $null
}

function Find-CodexStartAppId {
    try {
        $apps = @(Get-StartApps | Where-Object {
            ($_.Name -eq 'Codex' -and $_.AppID -like 'OpenAI.Codex*') -or
            ($_.AppID -like 'OpenAI.Codex_*!App')
        })
        if ($apps.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($apps[0].AppID)) {
            return $apps[0].AppID
        }
    } catch {
        return $null
    }
    return $null
}

function Test-CodexExecutableCandidate {
    param([string]$Path)

    if (-not (Test-ExecutablePath -Path $Path)) {
        return $false
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '(?i)History\s*Sync|CodexHistorySync|codex-windows-launcher|start-codex-with-ccswitch|\\bin\\codex\.exe$') {
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName($expanded)
    if ($fileName -notin @('Codex.exe', 'OpenAI Codex.exe')) {
        return $false
    }

    return $true
}

function Find-CodexAppxExecutable {
    try {
        $packages = @(Get-AppxPackage | Where-Object {
            $_.Name -like '*Codex*' -or
            $_.PackageFullName -like '*Codex*' -or
            $_.PackageFamilyName -like 'OpenAI.Codex*'
        })

        foreach ($pkg in $packages) {
            if ([string]::IsNullOrWhiteSpace($pkg.InstallLocation) -or -not (Test-Path -LiteralPath $pkg.InstallLocation -PathType Container)) {
                continue
            }

            $directCandidates = @(
                (Join-Path $pkg.InstallLocation 'app\Codex.exe'),
                (Join-Path $pkg.InstallLocation 'Codex.exe'),
                (Join-Path $pkg.InstallLocation 'app\OpenAI Codex.exe')
            )
            foreach ($candidate in $directCandidates) {
                if (Test-CodexExecutableCandidate -Path $candidate) {
                    return $candidate
                }
            }

            $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                continue
            }

            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
            $matches = [regex]::Matches($manifest, 'Executable="([^"]+)"')
            foreach ($match in $matches) {
                $relative = $match.Groups[1].Value -replace '/', '\'
                $candidate = Join-Path $pkg.InstallLocation $relative
                if (Test-CodexExecutableCandidate -Path $candidate) {
                    return $candidate
                }
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Find-CodexExecutable {
    param($Config)

    if (Test-CodexExecutableCandidate -Path $Config.codexPath) {
        return [Environment]::ExpandEnvironmentVariables($Config.codexPath)
    }

    $appxExe = Find-CodexAppxExecutable
    if (Test-CodexExecutableCandidate -Path $appxExe) {
        return $appxExe
    }

    $commonPaths = @(
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\Codex.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI Codex\Codex.exe')
    )

    foreach ($path in $commonPaths) {
        if (Test-CodexExecutableCandidate -Path $path) {
            return [Environment]::ExpandEnvironmentVariables($path)
        }
    }

    $shortcutTarget = Find-ShortcutTarget -NamePatterns @('Codex', 'OpenAI Codex')
    if (Test-CodexExecutableCandidate -Path $shortcutTarget) {
        return $shortcutTarget
    }

    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'OpenAI'),
        $env:LOCALAPPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
    $exe = Find-ExecutableByName -Names @('Codex.exe', 'OpenAI Codex.exe') -Roots $roots
    if (Test-CodexExecutableCandidate -Path $exe) {
        return $exe
    }

    return $null
}

function Resolve-CodexLaunchTarget {
    param($Config)

    $exe = Find-CodexExecutable -Config $Config
    if ($exe) {
        return New-Object PSObject -Property @{
            Kind = 'Exe'
            Value = $exe
        }
    }

    $appId = Find-CodexStartAppId
    if ($appId) {
        return New-Object PSObject -Property @{ Kind = 'AppId'; Value = $appId }
    }

    return $null
}

function Resolve-CCSwitchPath {
    param($Config)

    if (Test-ExecutablePath -Path $Config.ccswitchPath) {
        return [Environment]::ExpandEnvironmentVariables($Config.ccswitchPath)
    }

    $runningPath = Get-RunningExecutablePathByNames -Names $Script:CCSwitchProcessNames
    if (Test-ExecutablePath -Path $runningPath) {
        return $runningPath
    }

    $shortcutTarget = Find-ShortcutTarget -NamePatterns @('*CCSwitch*', '*CC Switch*', '*ccswitch*', '*cc-switch*')
    if (Test-ExecutablePath -Path $shortcutTarget) {
        return $shortcutTarget
    }

    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
    return Find-ExecutableByName -Names @('CCSwitch.exe', 'ccswitch.exe', 'cc-switch.exe') -Roots $roots
}

function Get-ProcessesByNames {
    param([string[]]$Names)
    $nameSet = @{}
    foreach ($name in $Names) {
        $nameSet[$name.ToLowerInvariant()] = $true
    }

    Get-CimInstance Win32_Process |
        Where-Object {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $_.Name -and ($nameSet.ContainsKey($_.Name.ToLowerInvariant()) -or $nameSet.ContainsKey($baseName.ToLowerInvariant()))
        }
}

function Get-RunningExecutablePathByNames {
    param([string[]]$Names)

    $proc = Get-ProcessesByNames -Names $Names |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
        Select-Object -First 1

    if ($proc) {
        return $proc.ExecutablePath
    }

    return $null
}

function Get-ProcessesByPath {
    param([string]$Path)
    if (-not (Test-ExecutablePath -Path $Path)) {
        return @()
    }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and ([string]::Compare($_.ExecutablePath, $resolved, $true) -eq 0)
    })
}

function Test-ProcessRunning {
    param(
        [string]$Path,
        [string[]]$Names
    )

    if (Test-ExecutablePath -Path $Path) {
        if (@(Get-ProcessesByPath -Path $Path).Count -gt 0) {
            return $true
        }
    }

    return ((Get-ProcessesByNames -Names $Names | Measure-Object).Count -gt 0)
}

function Stop-LauncherProcess {
    param(
        [string]$DisplayName,
        [string]$PreferredPath,
        [string[]]$FallbackNames,
        [int]$TimeoutSeconds = 8,
        [switch]$NoLaunch
    )

    $matches = @()
    if (Test-ExecutablePath -Path $PreferredPath) {
        $matches = @(Get-ProcessesByPath -Path $PreferredPath)
        if ($matches.Count -gt 0) {
            Write-Info "Closing $DisplayName by configured executable path."
        }
    }

    if ($matches.Count -eq 0) {
        $matches = @(Get-ProcessesByNames -Names $FallbackNames)
        if ($matches.Count -gt 0) {
            Write-Info "Closing $DisplayName by conservative process-name match."
        }
    }

    if ($NoLaunch) {
        if ($matches.Count -gt 0) {
            Write-Info "NoLaunch: would close $($matches.Count) $DisplayName process(es)."
        }
        return $true
    }

    foreach ($proc in $matches) {
        try {
            $liveProcess = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
            if (-not $liveProcess) {
                continue
            }
            if ($liveProcess.MainWindowHandle -ne 0) {
                Write-Info "?????? $DisplayName ?? $($proc.ProcessId)??????????"
                [void]$liveProcess.CloseMainWindow()
            } else {
                Write-Info "$DisplayName ?? $($proc.ProcessId) ?????????????????"
            }
        } catch {
            Write-Warn "Could not close $DisplayName process $($proc.ProcessId): $($_.Exception.Message)"
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ProcessRunning -Path $PreferredPath -Names $FallbackNames)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }

    if (Test-ProcessRunning -Path $PreferredPath -Names $FallbackNames) {
        Write-Warn "$DisplayName ??? $TimeoutSeconds ??????????????"
        foreach ($proc in $matches) {
            try {
                $liveProcess = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
                if ($liveProcess) {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                }
            } catch {
                Write-Warn "Could not force close $DisplayName process $($proc.ProcessId): $($_.Exception.Message)"
            }
        }
    }

    $forceDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $forceDeadline) {
        if (-not (Test-ProcessRunning -Path $PreferredPath -Names $FallbackNames)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }

    if (Test-ProcessRunning -Path $PreferredPath -Names $FallbackNames) {
        Write-Warn "$DisplayName ???????????????????????????"
        return $false
    }

    return $true
}

function Set-EnvForChildLaunch {
    param([hashtable]$SetValues, [string[]]$RemoveNames)

    $names = @()
    if ($SetValues) {
        $names += @($SetValues.Keys)
    }
    if ($RemoveNames) {
        $names += $RemoveNames
    }
    $names = @($names | Select-Object -Unique)

    $snapshot = @{}
    foreach ($name in $names) {
        $snapshot[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    foreach ($name in $RemoveNames) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    foreach ($name in $SetValues.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$SetValues[$name], 'Process')
    }

    return $snapshot
}

function Restore-ProcessEnv {
    param([hashtable]$Snapshot)
    foreach ($name in $Snapshot.Keys) {
        [Environment]::SetEnvironmentVariable($name, $Snapshot[$name], 'Process')
    }
}

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Start-AppIdTarget {
    param([string]$AppId)

    $shellPath = 'shell:AppsFolder\' + $AppId
    $errors = New-Object System.Collections.Generic.List[string]

    if (Test-IsElevated) {
        Write-ErrorLine '??????????????? Windows AppId ?? Codex?'
        Write-Next '??????????????? Codex Windows Launcher?????? PowerShell ????'
        Write-Next '????????????? doctor???????? AppId???? launcher-config.json ???? Codex Desktop ? codexPath?'
        return
    }

    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList $shellPath -ErrorAction Stop | Out-Null
        return
    } catch {
        $errors.Add("Start-Process explorer.exe: $($_.Exception.Message)")
    }

    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.ShellExecute('explorer.exe', $shellPath, '', 'open', 1)
        return
    } catch {
        $errors.Add("Shell.Application: $($_.Exception.Message)")
    }

    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'start', '""', $shellPath) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        return
    } catch {
        $errors.Add("cmd start: $($_.Exception.Message)")
    }

    Write-ErrorLine '???? Windows AppId ?? Codex?'
    foreach ($message in $errors) {
        Write-Warn $message
    }
    if (Test-IsElevated) {
        Write-Next '??????????????????????? Codex Windows Launcher????? PowerShell ???'
    } else {
        Write-Next "???????????? Codex??? $Script:ConfigPath ??? codexPath?"
    }
    Write-Next '????? doctor ????? Exe ?? AppId ?????v0.3 ??????? Codex.exe?'
}

function Start-LaunchTarget {
    param(
        $Target,
        [hashtable]$SetEnv,
        [string[]]$RemoveEnv,
        [switch]$NoLaunch
    )

    if (-not $Target) {
        throw "Codex executable was not found. Set codexPath in '$Script:ConfigPath'."
    }

    if ($NoLaunch) {
        Write-Info "NoLaunch: would start Codex via $($Target.Kind): $($Target.Value)"
        if ($SetEnv -and $SetEnv.ContainsKey('CODEX_HOME')) {
            Write-Info "NoLaunch: child CODEX_HOME=$($SetEnv['CODEX_HOME'])"
        }
        if ($RemoveEnv -contains 'CODEX_HOME') {
            Write-Info 'NoLaunch: child CODEX_HOME would be removed.'
        }
        return
    }

    $snapshot = Set-EnvForChildLaunch -SetValues $SetEnv -RemoveNames $RemoveEnv
    try {
        if ($Target.Kind -eq 'AppId') {
            Start-AppIdTarget -AppId $Target.Value
        } else {
            Start-Process -FilePath $Target.Value | Out-Null
        }
    } finally {
        Restore-ProcessEnv -Snapshot $snapshot
    }
}

function Resolve-HistorySyncBackendPath {
    param($Config)

    if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.historySyncBackendPath)) {
        $configured = [Environment]::ExpandEnvironmentVariables($Config.historySyncBackendPath)
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return (Resolve-Path -LiteralPath $configured).ProviderPath
        }
        Write-Warn "???? historySyncBackendPath ????$configured"
    }

    $launcherDir = Split-Path -Parent $PSCommandPath
    $projectsDir = Split-Path -Parent $launcherDir
    $sibling = Join-Path $projectsDir 'codex-history-sync-windows-work\sync_backend.py'
    if (Test-Path -LiteralPath $sibling -PathType Leaf) {
        return (Resolve-Path -LiteralPath $sibling).ProviderPath
    }

    return $null
}

function Invoke-HistorySyncBeforeCodexLaunch {
    param(
        $Config,
        [string]$Reason,
        [switch]$NoLaunch
    )

    $backendPath = Resolve-HistorySyncBackendPath -Config $Config
    if (-not $backendPath) {
        Write-Warn '??? Codex History Sync Tool ???????? Codex???????????'
        Write-Next '??????? launcher-config.json ?? historySyncBackendPath???????????? 20_Projects ????'
        return $false
    }

    if ($NoLaunch) {
        Write-Info "NoLaunch: ????? Codex ????????py -3 $backendPath --json sync"
        return $true
    }

    Write-Info "?? Codex ????????$Reason"
    try {
        $completed = & py -3 $backendPath --json sync 2>&1
        $raw = ($completed | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warn '????????????????? Codex?'
            return $false
        }
        $payload = $raw | ConvertFrom-Json
        if ($payload.ok -ne $true) {
            Write-Warn "????????$($payload.error)"
            Write-Next '?????????????? Codex History Sync Tool ??????/????'
            return $false
        }
        $status = $payload.status
        Write-Ok "?????????=$($payload.sync_rounds)??????=$($status.movable_threads)???=$($payload.backup_path)"
        return $true
    } catch {
        Write-Warn "?????????$($_.Exception.Message)"
        Write-Next '????????????????? Codex???????????? Codex History Sync Tool?'
        return $false
    }
}

function New-MinimalOfficialConfig {
    @(
        '# Official Codex profile managed by codex-launcher.',
        '# Keep this profile free of custom provider and base_url settings.'
    ) -join [Environment]::NewLine
}

function Backup-LauncherFile {
    param(
        [string]$Path,
        [string]$Reason,
        [switch]$NoWrite
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leaf = [System.IO.Path]::GetFileName($Path)
    $backupPath = Join-Path $Script:BackupDir ("$leaf.$timestamp.$Reason.bak")

    if ($NoWrite) {
        Write-Info "NoLaunch: would back up $leaf to $backupPath"
        return $backupPath
    }

    Ensure-Directory -Path $Script:BackupDir
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Info "Backed up $leaf to $backupPath"
    return $backupPath
}

function Backup-CCSwitchSettingsFile {
    param([switch]$NoWrite)

    if (-not (Test-Path -LiteralPath $Script:CCSwitchSettingsPath -PathType Leaf)) {
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $Script:CCSwitchBackupDir "settings.json.$timestamp.before-codex-enhancement.bak"

    if ($NoWrite) {
        Write-Info "NoLaunch: ???? CCSwitch ????????$backupPath"
        return $backupPath
    }

    Ensure-Directory -Path $Script:CCSwitchBackupDir
    Copy-Item -LiteralPath $Script:CCSwitchSettingsPath -Destination $backupPath -Force
    Write-Info '??? CCSwitch ??????? .cc-switch\backups?'
    return $backupPath
}

function New-JsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 100
    return $serializer
}

function Read-JsonMapFile {
    param([string]$Path)

    $serializer = New-JsonSerializer
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $serializer.DeserializeObject($raw)
}

function Write-JsonMapFile {
    param(
        [string]$Path,
        $Value
    )

    $serializer = New-JsonSerializer
    $json = $serializer.Serialize($Value)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Test-MapHasKey {
    param(
        $Map,
        [string]$Key
    )

    if ($null -eq $Map) {
        return $false
    }

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }

    return ($Map.PSObject.Properties.Name -contains $Key)
}

function Get-MapValue {
    param(
        $Map,
        [string]$Key
    )

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map[$Key]
    }

    return $Map.$Key
}

function Set-MapValue {
    param(
        $Map,
        [string]$Key,
        $Value
    )

    if ($Map -is [System.Collections.IDictionary]) {
        $Map[$Key] = $Value
        return
    }

    $property = $Map.PSObject.Properties[$Key]
    if ($property) {
        $property.Value = $Value
    } else {
        $Map | Add-Member -MemberType NoteProperty -Name $Key -Value $Value
    }
}

function Save-CodexUiStateSnapshot {
    param([switch]$NoWrite)

    if (-not (Test-Path -LiteralPath $Script:CodexGlobalStatePath -PathType Leaf)) {
        Write-Warn "??? Codex ???????$Script:CodexGlobalStatePath"
        return $false
    }

    if ($NoWrite) {
        Write-Info "NoLaunch: ???? Codex ???????$Script:CodexUiStateSnapshotPath"
        return $true
    }

    try {
        $state = Read-JsonMapFile -Path $Script:CodexGlobalStatePath
        $snapshot = @{}

        foreach ($key in $Script:CodexUiStateTopLevelKeys) {
            if (Test-MapHasKey -Map $state -Key $key) {
                $snapshot[$key] = Get-MapValue -Map $state -Key $key
            }
        }

        if (Test-MapHasKey -Map $state -Key 'electron-persisted-atom-state') {
            $atoms = Get-MapValue -Map $state -Key 'electron-persisted-atom-state'
            $atomSnapshot = @{}
            foreach ($key in $Script:CodexUiStateAtomKeys) {
                if (Test-MapHasKey -Map $atoms -Key $key) {
                    $atomSnapshot[$key] = Get-MapValue -Map $atoms -Key $key
                }
            }
            if ($atomSnapshot.Count -gt 0) {
                $snapshot['electron-persisted-atom-state'] = $atomSnapshot
            }
        }

        Ensure-Directory -Path $Script:LauncherStateDir
        Write-JsonMapFile -Path $Script:CodexUiStateSnapshotPath -Value $snapshot
        Write-Info '??? Codex ???????'
        return $true
    } catch {
        Write-Warn "?? Codex ?????????$($_.Exception.Message)"
        return $false
    }
}

function Restore-CodexUiStateSnapshot {
    param([switch]$NoWrite)

    if ($NoWrite) {
        Write-Info 'NoLaunch: ???? Codex ???????'
        return $true
    }

    if (-not (Test-Path -LiteralPath $Script:CodexUiStateSnapshotPath -PathType Leaf)) {
        Write-Warn "??? Codex ???????$Script:CodexUiStateSnapshotPath"
        return $false
    }

    if (-not (Test-Path -LiteralPath $Script:CodexGlobalStatePath -PathType Leaf)) {
        Write-Warn "??? Codex ???????$Script:CodexGlobalStatePath"
        return $false
    }

    try {
        $state = Read-JsonMapFile -Path $Script:CodexGlobalStatePath
        $snapshot = Read-JsonMapFile -Path $Script:CodexUiStateSnapshotPath

        Backup-LauncherFile -Path $Script:CodexGlobalStatePath -Reason 'before-ui-state-restore' | Out-Null

        foreach ($key in $Script:CodexUiStateTopLevelKeys) {
            if (Test-MapHasKey -Map $snapshot -Key $key) {
                Set-MapValue -Map $state -Key $key -Value (Get-MapValue -Map $snapshot -Key $key)
            }
        }

        if (Test-MapHasKey -Map $snapshot -Key 'electron-persisted-atom-state') {
            $atomSnapshot = Get-MapValue -Map $snapshot -Key 'electron-persisted-atom-state'
            if (Test-MapHasKey -Map $state -Key 'electron-persisted-atom-state') {
                $atoms = Get-MapValue -Map $state -Key 'electron-persisted-atom-state'
            } else {
                $atoms = @{}
                Set-MapValue -Map $state -Key 'electron-persisted-atom-state' -Value $atoms
            }

            foreach ($key in $Script:CodexUiStateAtomKeys) {
                if (Test-MapHasKey -Map $atomSnapshot -Key $key) {
                    Set-MapValue -Map $atoms -Key $key -Value (Get-MapValue -Map $atomSnapshot -Key $key)
                }
            }
        }

        Write-JsonMapFile -Path $Script:CodexGlobalStatePath -Value $state
        Write-Ok '??? Codex ?????'
        return $true
    } catch {
        Write-Warn "?? Codex ???????$($_.Exception.Message)"
        return $false
    }
}

function Get-CCSwitchCodexEnhancementState {
    if (-not (Test-Path -LiteralPath $Script:CCSwitchSettingsPath -PathType Leaf)) {
        return 'missing'
    }

    try {
        $raw = Get-Content -LiteralPath $Script:CCSwitchSettingsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return 'unknown'
        }
        $settings = $raw | ConvertFrom-Json
        $property = $settings.PSObject.Properties['preserveCodexOfficialAuthOnSwitch']
        if (-not $property) {
            return 'unset'
        }
        if ([bool]$property.Value) {
            return 'enabled'
        }
        return 'disabled'
    } catch {
        return 'unknown'
    }
}

function Set-CCSwitchCodexEnhancement {
    param(
        [bool]$Enabled,
        [switch]$NoWrite
    )

    $stateText = if ($Enabled) { '??' } else { '??' }
    if (-not (Test-Path -LiteralPath $Script:CCSwitchSettingsPath -PathType Leaf)) {
        Write-Warn "??? CCSwitch ?????$Script:CCSwitchSettingsPath"
        Write-Next "?????? CCSwitch???????????????${stateText} Codex ?????"
        return $false
    }

    if ($NoWrite) {
        Write-Info "NoLaunch: ??${stateText} CCSwitch Codex ?????preserveCodexOfficialAuthOnSwitch=$Enabled"
        return $true
    }

    try {
        $raw = Get-Content -LiteralPath $Script:CCSwitchSettingsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warn 'CCSwitch ????????????? Codex ?????'
            return $false
        }

        $settings = $raw | ConvertFrom-Json
        Backup-CCSwitchSettingsFile | Out-Null

        $property = $settings.PSObject.Properties['preserveCodexOfficialAuthOnSwitch']
        if ($property) {
            $property.Value = $Enabled
        } else {
            $settings | Add-Member -MemberType NoteProperty -Name 'preserveCodexOfficialAuthOnSwitch' -Value $Enabled
        }

        $json = $settings | ConvertTo-Json -Depth 100
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Script:CCSwitchSettingsPath, $json, $utf8NoBom)
        Write-Ok "?${stateText} CCSwitch Codex ?????"
        return $true
    } catch {
        Write-Warn "?? CCSwitch Codex ???????$($_.Exception.Message)"
        Write-Next '?????? CCSwitch settings.json ??????????????????'
        return $false
    }
}

function Save-ThirdPartyProfile {
    param([switch]$NoWrite)

    if (-not $NoWrite) {
        Ensure-Directory -Path $Script:ThirdPartyProfileDir
    }
    foreach ($name in @('config.toml', 'auth.json')) {
        $source = Join-Path $Script:DefaultCodexHome $name
        $target = Join-Path $Script:ThirdPartyProfileDir $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            if ($NoWrite) {
                Write-Info "NoLaunch: would save third-party profile file $name"
            } else {
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
        }
    }
}

function Save-ProfileFiles {
    param(
        [string]$ProfileName,
        [string]$ProfileDir,
        [string[]]$Files = @('config.toml', 'auth.json'),
        [switch]$NoWrite
    )

    if (-not $NoWrite) {
        Ensure-Directory -Path $ProfileDir
    }

    $saved = $false
    foreach ($name in $Files) {
        $source = Join-Path $Script:DefaultCodexHome $name
        $target = Join-Path $ProfileDir $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            if ($NoWrite) {
                Write-Info "NoLaunch: would save $ProfileName profile file $name"
            } else {
                Backup-LauncherFile -Path $target -Reason "before-$ProfileName-save" | Out-Null
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
            $saved = $true
        }
    }

    if ($saved -and -not $NoWrite) {
        Write-Info "Saved current default .codex files as $ProfileName profile."
    }

    return $saved
}

function Restore-ProfileFiles {
    param(
        [string]$ProfileName,
        [string]$ProfileDir,
        [string[]]$Files = @('config.toml', 'auth.json'),
        [switch]$NoWrite
    )

    $restored = $false
    foreach ($name in $Files) {
        $source = Join-Path $ProfileDir $name
        $target = Join-Path $Script:DefaultCodexHome $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Backup-LauncherFile -Path $target -Reason "before-$ProfileName-restore" -NoWrite:$NoWrite | Out-Null
            if ($NoWrite) {
                Write-Info "NoLaunch: would restore $ProfileName profile file $name"
            } else {
                Ensure-Directory -Path $Script:DefaultCodexHome
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
            $restored = $true
        }
    }

    return $restored
}

# Codex Desktop on Windows is launched through a Windows AppId. In practice it
# reads the default %USERPROFILE%\.codex profile, so CODEX_HOME-based isolation
# is not reliable here. The launcher therefore switches local profile files:
# - official profile: ChatGPT/OAuth login + non-custom config
# - thirdparty profile: CCSwitch/custom config + API-key-style auth
# The script copies profile files locally only; it does not print, upload, or
# transform token contents.
function Save-OfficialProfile {
    param([switch]$NoWrite)
    $saved = Save-ProfileFiles -ProfileName 'official' -ProfileDir $Script:OfficialProfileDir -NoWrite:$NoWrite
    if (-not $saved) {
        Write-Warn '?????????? Codex ??????????????'
    }
}

function Restore-OfficialProfile {
    param([switch]$NoWrite)
    return (Restore-ProfileFiles -ProfileName 'official' -ProfileDir $Script:OfficialProfileDir -NoWrite:$NoWrite)
}

function Restore-OfficialAuthOnly {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'official' -ProfileDir $Script:OfficialProfileDir -Files @('auth.json') -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '?????????????????????????????????????????'
    }
    return $restored
}

function Restore-ThirdPartyProfile {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '?????????????????????????? .codex ???'
    }
}

function Restore-ThirdPartyConfig {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml') -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '??????????????????????? config.toml?'
    }
    return $restored
}

function Get-ConfigSectionName {
    param([string]$Line)

    if ($Line -match '^\s*\[([^\]]+)\]\s*$') {
        return $Matches[1]
    }
    return $null
}

function Test-PreservedConfigSection {
    param([string]$Section)

    if ([string]::IsNullOrWhiteSpace($Section)) {
        return $false
    }
    foreach ($prefix in $Script:ConfigPreserveSectionPrefixes) {
        if ($Section -eq $prefix -or $Section.StartsWith($prefix)) {
            return $true
        }
    }
    return $false
}

function Test-PreservedTopLevelConfigLine {
    param([string]$Line)

    foreach ($key in $Script:ConfigPreserveTopLevelKeys) {
        if ($Line -match "^\s*$([regex]::Escape($key))\s*=") {
            return $true
        }
    }
    return $false
}

function Read-ConfigLines {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8)
}

function Get-ConfigPreservationBaseline {
    $activeLines = Read-ConfigLines -Path $Script:ActiveConfigPath
    $activeText = $activeLines -join "`n"
    if ($activeLines.Count -gt 0 -and -not (Test-ActiveConfigLooksCustom)) {
        Write-Info '???????? config.toml ??????????????'
        return $activeLines
    }

    $officialConfigPath = Join-Path $Script:OfficialProfileDir 'config.toml'
    $officialLines = Read-ConfigLines -Path $officialConfigPath
    if ($officialLines.Count -gt 0) {
        Write-Info '?????? official profile config.toml ??????????????'
        return $officialLines
    }

    if ($activeLines.Count -gt 0) {
        Write-Warn '???????? config ????????? config ??????????'
        return $activeLines
    }

    Write-Warn '????????????? config.toml ???'
    return @()
}

function Select-PreservedConfigLines {
    param([string[]]$Lines)

    $result = New-Object System.Collections.Generic.List[string]
    $section = ''
    foreach ($line in $Lines) {
        $newSection = Get-ConfigSectionName -Line $line
        if ($null -ne $newSection) {
            $section = $newSection
        }

        if ([string]::IsNullOrWhiteSpace($section)) {
            if (Test-PreservedTopLevelConfigLine -Line $line) {
                $result.Add($line)
            }
            continue
        }

        if (Test-PreservedConfigSection -Section $section) {
            $result.Add($line)
        }
    }
    return @($result)
}

function Select-RouteConfigLines {
    param([string[]]$Lines)

    $result = New-Object System.Collections.Generic.List[string]
    $section = ''
    foreach ($line in $Lines) {
        $newSection = Get-ConfigSectionName -Line $line
        if ($null -ne $newSection) {
            $section = $newSection
        }

        if ([string]::IsNullOrWhiteSpace($section)) {
            if (-not (Test-PreservedTopLevelConfigLine -Line $line)) {
                $result.Add($line)
            }
            continue
        }

        if (-not (Test-PreservedConfigSection -Section $section)) {
            $result.Add($line)
        }
    }
    return @($result)
}

function Merge-PreservedCodexConfigSections {
    param(
        [string[]]$BaselineLines,
        [switch]$NoWrite
    )

    if ($BaselineLines.Count -eq 0) {
        Write-Warn '????/??????????? config ???'
        return $false
    }
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        Write-Warn '?? config.toml ????????/???????'
        return $false
    }

    $activeLines = Read-ConfigLines -Path $Script:ActiveConfigPath
    $routeLines = Select-RouteConfigLines -Lines $activeLines
    $preservedLines = Select-PreservedConfigLines -Lines $BaselineLines
    if ($preservedLines.Count -eq 0) {
        Write-Warn '????????????????marketplace?MCP ??????'
        return $false
    }

    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($line in $routeLines) {
        $merged.Add($line)
    }
    if ($merged.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($merged[$merged.Count - 1])) {
        $merged.Add('')
    }
    foreach ($line in $preservedLines) {
        $merged.Add($line)
    }

    if ($NoWrite) {
        Write-Info 'NoLaunch: ????????????????????marketplace?MCP ??????'
        return $true
    }

    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-preserve-config-merge' | Out-Null
    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $merged.ToArray() -Encoding UTF8
    Write-Ok '????????marketplace?MCP ??????????????????'
    return $true
}

function Restore-ThirdPartyPureProfile {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml', 'auth.json') -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '???????????????????????????? .codex ???'
    }
    return $restored
}

function Get-AuthState {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'none'
    }

    try {
        $auth = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
        $names = @($auth.PSObject.Properties.Name)
        if ($names -contains 'OPENAI_API_KEY') {
            $value = [string]$auth.OPENAI_API_KEY
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return 'api-key-like'
            }
        }
        if ($names -contains 'auth_mode') {
            $mode = [string]$auth.auth_mode
            if ($mode -eq 'chatgpt') {
                return 'official-like'
            }
        }
        foreach ($name in $names) {
            if ($name -match '(?i)chatgpt|oauth') {
                return 'official-like'
            }
        }
        return 'unknown'
    } catch {
        Write-Warn '???? auth.json ???????????????????'
        return 'unknown'
    }
}

function Test-AuthLooksApiKey {
    param([string]$Path)
    return ((Get-AuthState -Path $Path) -eq 'api-key-like')
}

function Test-ActiveConfigLooksCustom {
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        return $false
    }

    return (Select-String -LiteralPath $Script:ActiveConfigPath -Pattern 'model_provider\s*=\s*"custom"|\[model_providers\.custom\]|127\.0\.0\.1:15721|base_url\s*=' -Quiet)
}

function Test-ActiveConfigLooksThirdPartyRoute {
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        return $false
    }

    return (Select-String -LiteralPath $Script:ActiveConfigPath -Pattern '127\.0\.0\.1:15721|localhost:15721' -Quiet)
}

function Test-CurrentLooksOfficialProfile {
    if (-not (Test-Path -LiteralPath $Script:ActiveAuthPath -PathType Leaf)) {
        return $false
    }

    if ((Get-AuthState -Path $Script:ActiveAuthPath) -ne 'official-like') {
        return $false
    }

    if (Test-ActiveConfigLooksCustom) {
        return $false
    }

    return $true
}

function Save-OfficialProfileIfCurrentLooksOfficial {
    param([switch]$NoWrite)

    if (Test-CurrentLooksOfficialProfile) {
        Write-Info '???? .codex ???????????????????????'
        Save-OfficialProfile -NoWrite:$NoWrite
        return $true
    }

    Write-Warn '???? .codex ?????????????????????????????'
    return $false
}

function Save-OfficialAuthOnlyIfCurrentLooksOfficial {
    param([switch]$NoWrite)

    if ((Get-AuthState -Path $Script:ActiveAuthPath) -ne 'official-like') {
        return $false
    }

    Write-Info '?? auth.json ????????????????????'
    Save-ProfileFiles -ProfileName 'official' -ProfileDir $Script:OfficialProfileDir -Files @('auth.json') -NoWrite:$NoWrite | Out-Null
    return $true
}

function Ensure-OfficialAuthForPreserveMode {
    param([switch]$NoWrite)

    $authState = Get-AuthState -Path $Script:ActiveAuthPath
    if ($authState -eq 'official-like') {
        Save-OfficialAuthOnlyIfCurrentLooksOfficial -NoWrite:$NoWrite | Out-Null
        return $true
    }

    if (Restore-OfficialAuthOnly -NoWrite:$NoWrite) {
        return $true
    }

    Write-Warn '????????????????????????????????? auth.json?'
    return $false
}

function Confirm-OfficialAuthForPreserveMode {
    param([switch]$NoLaunch)

    if ($NoLaunch) {
        Write-Info 'NoLaunch: ?????? auth.json ???? ChatGPT/OAuth ????'
        return $true
    }

    $authState = Get-AuthState -Path $Script:ActiveAuthPath
    if ($authState -eq 'official-like') {
        Write-Ok '?? auth.json ?????? ChatGPT/OAuth ????'
        return $true
    }

    Write-ErrorLine "?? auth.json ?????????? $authState??????? Codex??????? API ?????"
    Write-Next '????? 1 ????????????????????? 2?'
    return $false
}

function Disable-ApiKeyAuthForOfficial {
    param([switch]$NoWrite)

    $authState = Get-AuthState -Path $Script:ActiveAuthPath

    if ($authState -eq 'none') {
        Write-Info '????? auth.json?Codex ??????????'
        return
    }

    if ($authState -eq 'unknown') {
        Write-Warn '?? auth.json ???????????????????????????'
        return
    }

    if ($authState -ne 'api-key-like') {
        Write-Info '?? auth.json ?? API-key ?????????'
        return
    }

    Save-ThirdPartyProfile -NoWrite:$NoWrite
    Backup-LauncherFile -Path $Script:ActiveAuthPath -Reason 'before-official-auth-switch' -NoWrite:$NoWrite | Out-Null

    if ($NoWrite) {
        Write-Info 'NoLaunch: ?????? API-key auth.json?? Codex ???????'
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $disabledPath = Join-Path $Script:BackupDir ("auth.json.$timestamp.disabled-for-official")
    Move-Item -LiteralPath $Script:ActiveAuthPath -Destination $disabledPath -Force
    Write-Info '????? API-key auth.json??????????Codex ????????'
}

function Repair-ActiveConfigForOfficial {
    param([switch]$NoWrite)

    Ensure-Directory -Path $Script:DefaultCodexHome
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        if ($NoWrite) {
            Write-Info "NoLaunch: ???????????$Script:ActiveConfigPath"
            return
        }
        Set-Content -LiteralPath $Script:ActiveConfigPath -Value (New-MinimalOfficialConfig) -Encoding UTF8
        return
    }

    $lines = @(Get-Content -LiteralPath $Script:ActiveConfigPath -Encoding UTF8)
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = 0
    $skipCustomProvider = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*\[.*\]\s*$') {
            $skipCustomProvider = ($line -match '^\s*\[model_providers\.custom\]\s*$')
            if ($skipCustomProvider) {
                $removed++
                continue
            }
        }

        if ($skipCustomProvider) {
            $removed++
            continue
        }

        if ($line -match '^\s*model_provider\s*=\s*["'']custom["'']\s*(#.*)?$') {
            $removed++
            continue
        }

        $kept.Add($line)
    }

    if ($removed -eq 0) {
        Write-Info '?? .codex config ??? custom provider ???'
        return
    }

    Save-ThirdPartyProfile -NoWrite:$NoWrite
    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-official-config-switch' -NoWrite:$NoWrite | Out-Null

    if ($NoWrite) {
        Write-Info "NoLaunch: ????? .codex config ?? $removed ? custom provider ???"
        return
    }

    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $kept.ToArray() -Encoding UTF8
    Write-Info "???? .codex config ?? $removed ? custom provider ???"
}

function Test-ProfileComplete {
    param(
        [string]$ProfileDir,
        [string[]]$Files = @('config.toml', 'auth.json')
    )

    foreach ($name in $Files) {
        $path = Join-Path $ProfileDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Test-ProfilePartial {
    param(
        [string]$ProfileDir,
        [string[]]$Files = @('config.toml', 'auth.json')
    )

    $existing = 0
    foreach ($name in $Files) {
        $path = Join-Path $ProfileDir $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $existing++
        }
    }
    return (($existing -gt 0) -and ($existing -lt $Files.Count))
}

function Test-DesktopShortcutCurrent {
    $shortcutPath = Get-DesktopShortcutPath
    $info = Get-ShortcutInfo -Path $shortcutPath
    if (-not $info) {
        return $false
    }

    $expectedScript = $PSCommandPath
    return (($info.Arguments -like "*$expectedScript*") -and ($info.WorkingDirectory -eq (Split-Path -Parent $expectedScript)))
}

function Detect-ExistingLauncherState {
    $launcherHomeExists = Test-Path -LiteralPath $Script:LauncherHome -PathType Container
    $configExists = Test-Path -LiteralPath $Script:ConfigPath -PathType Leaf
    $officialExists = Test-Path -LiteralPath $Script:OfficialProfileDir -PathType Container
    $thirdPartyExists = Test-Path -LiteralPath $Script:ThirdPartyProfileDir -PathType Container
    $officialPartial = Test-ProfilePartial -ProfileDir $Script:OfficialProfileDir
    $thirdPartyPartial = Test-ProfilePartial -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml')
    $desktopShortcut = Get-DesktopShortcutPath
    $desktopShortcutExists = Test-Path -LiteralPath $desktopShortcut -PathType Leaf
    $desktopShortcutCurrent = Test-DesktopShortcutCurrent
    $legacyShortcuts = @(Find-LegacyShortcuts)
    $partialProfile = ($officialPartial -or $thirdPartyPartial)
    $shortcutConflict = ($desktopShortcutExists -and $legacyShortcuts.Count -gt 0)

    $stateKind = 'existing-launcher'
    if (-not $launcherHomeExists -and -not $desktopShortcutExists -and $legacyShortcuts.Count -eq 0) {
        $stateKind = 'fresh-install'
    } elseif (-not $launcherHomeExists -and $legacyShortcuts.Count -gt 0) {
        $stateKind = 'legacy-shortcut-only'
    } elseif ($partialProfile) {
        $stateKind = 'partial-profile'
    } elseif ($shortcutConflict) {
        $stateKind = 'conflicting-shortcuts'
    }

    $needsBootstrap = (-not $configExists -or -not $desktopShortcutCurrent -or $partialProfile -or $shortcutConflict -or $stateKind -eq 'fresh-install' -or $stateKind -eq 'legacy-shortcut-only')
    $riskLevel = 'ok'
    if ($partialProfile -or $shortcutConflict -or $legacyShortcuts.Count -gt 0) {
        $riskLevel = 'warn'
    }

    return New-Object PSObject -Property @{
        StateKind = $stateKind
        NeedsBootstrap = $needsBootstrap
        RiskLevel = $riskLevel
        LauncherHomeExists = $launcherHomeExists
        ConfigExists = $configExists
        OfficialProfileExists = $officialExists
        ThirdPartyProfileExists = $thirdPartyExists
        OfficialProfileComplete = (Test-ProfileComplete -ProfileDir $Script:OfficialProfileDir)
        OfficialAuthComplete = (Test-ProfileComplete -ProfileDir $Script:OfficialProfileDir -Files @('auth.json'))
        ThirdPartyProfileComplete = (Test-ProfileComplete -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml'))
        ThirdPartyPureProfileComplete = (Test-ProfileComplete -ProfileDir $Script:ThirdPartyProfileDir)
        OfficialProfilePartial = $officialPartial
        ThirdPartyProfilePartial = $thirdPartyPartial
        DesktopShortcutExists = $desktopShortcutExists
        DesktopShortcutCurrent = $desktopShortcutCurrent
        DesktopShortcutPath = $desktopShortcut
        LegacyShortcuts = $legacyShortcuts
    }
}

function Invoke-Doctor {
    param($Config)

    Write-Host ''
    Write-Host "Codex Windows Launcher ?? $Script:LauncherVersion"
    Write-Host '---------------------------'

    $state = Detect-ExistingLauncherState
    if ($state.NeedsBootstrap) {
        Write-Warn "????????????????$($state.StateKind)"
        Write-Next '.\codex-launcher.ps1 -Mode bootstrap'
    } else {
        Write-Ok "??????????$($state.StateKind)"
    }

    if ($state.ConfigExists) {
        Write-Ok "???????$Script:ConfigPath"
    } else {
        Write-Warn "????????$Script:ConfigPath"
    }

    if ($state.DesktopShortcutExists) {
        if ($state.DesktopShortcutCurrent) {
            Write-Ok "?????????????$($state.DesktopShortcutPath)"
        } else {
            Write-Warn "?????????????$($state.DesktopShortcutPath)"
            $info = Get-ShortcutInfo -Path $state.DesktopShortcutPath
            if ($info -and -not [string]::IsNullOrWhiteSpace($info.IconLocation)) {
                $iconPath = ($info.IconLocation -split ',', 2)[0]
                if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
                    Write-Ok "?????????$iconPath"
                } else {
                    Write-Warn "????????????$iconPath"
                }
            }
        }
    } else {
        Write-Warn "??????????$($state.DesktopShortcutPath)"
    }

    if ($state.LegacyShortcuts.Count -gt 0) {
        Write-Warn '???? Start Codex With CC Switch ??????????????????? CCSwitch ???'
        foreach ($path in $state.LegacyShortcuts) {
            Write-Host "       $path"
        }
    }

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if ($codexTarget) {
        if ($codexTarget.Kind -eq 'Exe') {
            Write-Ok "Codex ?????Exe $($codexTarget.Value)"
        } else {
            Write-Warn "Codex ?????AppId $($codexTarget.Value)"
            Write-Next 'AppId ???????????????????????? launcher-config.json ?? codexPath?'
        }
    } else {
        Write-ErrorLine '???? Codex Desktop????? Codex Desktop???? bootstrap?'
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    if ($ccswitchPath) {
        Write-Ok "CCSwitch ???$ccswitchPath"
    } else {
        Write-Warn '???? CCSwitch???????????????????'
    }

    if (Test-ProcessRunning -Path $ccswitchPath -Names $Script:CCSwitchProcessNames) {
        Write-Ok 'CCSwitch ?????'
    } else {
        Write-Warn 'CCSwitch ????'
    }

    if (Test-LocalPort -Port 15721) {
        Write-Ok '?????????127.0.0.1:15721'
    } else {
        Write-Warn '???????????127.0.0.1:15721'
    }

    switch (Get-CCSwitchCodexEnhancementState) {
        'enabled' { Write-Ok 'CCSwitch Codex ??????????? 2 ????????' }
        'disabled' { Write-Warn 'CCSwitch Codex ??????????? 3/????????????' }
        'unset' { Write-Warn 'CCSwitch Codex ???????????????? 2/3 ?????' }
        'missing' { Write-Warn "??? CCSwitch ?????$Script:CCSwitchSettingsPath" }
        default { Write-Warn 'CCSwitch Codex ????????????' }
    }

    if (Test-Path -LiteralPath $Script:DefaultCodexHome -PathType Container) {
        Write-Ok "?? .codex ?????$Script:DefaultCodexHome"
    } else {
        Write-Warn "?? .codex ??????$Script:DefaultCodexHome"
    }

    if (Test-Path -LiteralPath $Script:CodexGlobalStatePath -PathType Leaf) {
        Write-Ok 'Codex ?????????????????????????????'
    } else {
        Write-Warn "??? Codex ???????$Script:CodexGlobalStatePath"
    }

    if (Test-Path -LiteralPath $Script:CodexUiStateSnapshotPath -PathType Leaf) {
        Write-Ok "Codex ?????????$Script:CodexUiStateSnapshotPath"
    } else {
        Write-Warn '???? Codex ????????????? 1/2/3 ?????????'
    }

    $authState = Get-AuthState -Path $Script:ActiveAuthPath
    switch ($authState) {
        'official-like' { Write-Ok '?? auth.json ?????? ChatGPT/OAuth ????' }
        'api-key-like' { Write-Warn '?? auth.json ???? API-key ????' }
        'unknown' { Write-Warn '?? auth.json ??????????' }
        default { Write-Warn '?? auth.json ????' }
    }

    if (Test-ActiveConfigLooksCustom) {
        Write-Warn '?? .codex config ?????????/custom ???'
    } else {
        Write-Ok '?? .codex config ??? custom provider ???'
    }

    if ($state.OfficialProfileComplete) {
        Write-Ok "?? profile ???$Script:OfficialProfileDir"
    } elseif ($state.OfficialProfilePartial) {
        Write-Warn "?? profile ????$Script:OfficialProfileDir"
    } else {
        Write-Warn "????? profile?$Script:OfficialProfileDir"
    }

    if ($state.ThirdPartyProfileComplete) {
        Write-Ok "??????????$Script:ThirdPartyProfileDir"
    } elseif ($state.ThirdPartyProfilePartial) {
        Write-Warn "???????????$Script:ThirdPartyProfileDir"
    } else {
        Write-Warn "???????????$Script:ThirdPartyProfileDir"
    }

    if ($state.ThirdPartyPureProfileComplete) {
        Write-Ok '????/API-key ?????'
    } else {
        Write-Warn '????/API-key ???????? 3 ???????????'
    }

    Write-Next '????????bootstrap -> official -> thirdparty-preserve-auth?'
}

function Invoke-Bootstrap {
    param($Config, [switch]$NoLaunch)

    Write-Host ''
    Write-Host "Codex Windows Launcher ??? $Script:LauncherVersion"
    Write-Host '-----------------------------'

    $state = Detect-ExistingLauncherState
    Write-Info "?????$($state.StateKind)??????$($state.RiskLevel)"

    if ($state.LegacyShortcuts.Count -gt 0) {
        Write-Warn '???? Start Codex With CC Switch ?????bootstrap ????????'
        Backup-ShortcutMetadata -ShortcutPaths $state.LegacyShortcuts -Reason 'legacy-shortcuts-detected' -NoWrite:$NoLaunch
    }

    Write-LauncherConfigIfMissing -Config $Config -NoWrite:$NoLaunch
    New-LauncherShortcut -NoWrite:$NoLaunch

    Invoke-Doctor -Config (Read-LauncherConfig)

    Write-Next '?? Codex ?????????????????????.\codex-launcher.ps1 -Mode official'
    Write-Next '??????????????????????????????'
}

function Invoke-Check {
    param($Config)

    Invoke-Doctor -Config $Config
    return

    Write-Info "??????$Script:ConfigPath"
    Write-Info "Codex Desktop ????????????$Script:DefaultCodexHome"
    Write-Info "????????????$Script:ThirdPartyProfileDir"
    Write-Info "???????????$Script:OfficialProfileDir"

    if (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf) {
        if (Test-ActiveConfigLooksCustom) {
            Write-Warn '?? .codex config ?????????/custom ???'
        } else {
            Write-Info '?? .codex config ???? custom provider ???'
        }
    } else {
        Write-Warn '????? .codex config.toml?'
    }

    if (Test-AuthLooksApiKey -Path $Script:ActiveAuthPath) {
        Write-Warn '?? auth.json ?????? API-key ???????? ChatGPT ????'
    } else {
        Write-Info '?? auth.json ?? API-key ???????????'
    }

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if ($codexTarget) {
        Write-Info "Codex ?????$($codexTarget.Kind) $($codexTarget.Value)"
    } else {
        Write-Warn "??? Codex??? '$Script:ConfigPath' ??? codexPath?"
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    if ($ccswitchPath) {
        Write-Info "CCSwitch ???$ccswitchPath"
    } else {
        Write-Warn "??? CCSwitch??? '$Script:ConfigPath' ??? ccswitchPath?"
    }

    if (Test-Path -LiteralPath $Script:DefaultCodexHome -PathType Container) {
        Write-Info '?? .codex ?????'
    } else {
        Write-Warn '????? .codex ???'
    }

    if (Test-ProcessRunning -Path $ccswitchPath -Names $Script:CCSwitchProcessNames) {
        Write-Info 'CCSwitch ?????'
    } else {
        Write-Warn 'CCSwitch ????'
    }
}

function Start-OfficialMode {
    param($Config, [switch]$NoLaunch)

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if (-not $codexTarget) {
        Write-ErrorLine '???? Codex Desktop????? Codex Desktop????? .\codex-launcher.ps1 -Mode bootstrap'
        return
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    $codexProcessPath = $Config.codexPath
    if ($codexTarget -and $codexTarget.Kind -eq 'Exe') {
        $codexProcessPath = $codexTarget.Value
    }

    Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $ccswitchPath -FallbackNames $Script:CCSwitchProcessNames -NoLaunch:$NoLaunch | Out-Null
    Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $codexProcessPath -FallbackNames $Script:CodexProcessNames -NoLaunch:$NoLaunch | Out-Null
    Save-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Set-CCSwitchCodexEnhancement -Enabled $false -NoWrite:$NoLaunch | Out-Null

    if (Restore-OfficialProfile -NoWrite:$NoLaunch) {
        Write-Info '???????????????????????'
    } else {
        Write-Warn '??????????????????????????'
        Repair-ActiveConfigForOfficial -NoWrite:$NoLaunch
        Disable-ApiKeyAuthForOfficial -NoWrite:$NoLaunch
    }

    Restore-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv $Script:ThirdPartyEnvVars -NoLaunch:$NoLaunch
}

function Ensure-CCSwitchRunning {
    param(
        [string]$Path,
        [switch]$NoLaunch
    )

    if (Test-ProcessRunning -Path $Path -Names $Script:CCSwitchProcessNames) {
        Write-Info 'CCSwitch ??????'
        return $true
    }

    if (-not (Test-ExecutablePath -Path $Path)) {
        Write-Warn "CCSwitch ????????????????? '$Script:ConfigPath' ??? ccswitchPath?"
        Write-Next '?????????????????????? CCSwitch?'
        return $false
    }

    if ($NoLaunch) {
        Write-Info "NoLaunch: ???? CCSwitch?$Path"
        return $true
    }

    Write-Info "???? CCSwitch?$Path"
    Start-Process -FilePath $Path | Out-Null
    return $true
}

function Restart-CCSwitchForThirdParty {
    param(
        [string]$Path,
        [int]$ReadyTimeoutSeconds = 20,
        [switch]$NoLaunch
    )

    Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $Path -FallbackNames $Script:CCSwitchProcessNames -NoLaunch:$NoLaunch | Out-Null

    if (-not $NoLaunch) {
        Start-Sleep -Milliseconds 800
    }

    if (-not (Ensure-CCSwitchRunning -Path $Path -NoLaunch:$NoLaunch)) {
        return $false
    }

    if ($NoLaunch) {
        Write-Info 'NoLaunch: ???? CCSwitch ?????? 127.0.0.1:15721 ???'
        return $true
    }

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-LocalPort -Port 15721) {
            Write-Ok 'CCSwitch ????????127.0.0.1:15721'
            Start-Sleep -Seconds 2
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    Write-ErrorLine '???????????127.0.0.1:15721??????? Codex???????????'
    Write-Next '??? CCSwitch ???????/?????????'
    return $false
}

function Confirm-CCSwitchCodexEnhancement {
    param(
        [bool]$ExpectedEnabled,
        [switch]$NoLaunch
    )

    $expectedText = if ($ExpectedEnabled) { '??' } else { '??' }
    if ($NoLaunch) {
        Write-Info "NoLaunch: ???? CCSwitch Codex ?????${expectedText}?"
        return $true
    }

    $state = Get-CCSwitchCodexEnhancementState
    if (($ExpectedEnabled -and $state -eq 'enabled') -or ((-not $ExpectedEnabled) -and $state -eq 'disabled')) {
        Write-Ok "CCSwitch Codex ?????${expectedText}?"
        return $true
    }

    Write-ErrorLine "CCSwitch Codex ????????${expectedText}??????? Codex????????????"
    Write-Next "??? CCSwitch ??????Codex ???? / ?????????????????????$state"
    return $false
}

function Stop-ProcessesBeforeThirdPartySwitch {
    param(
        [string]$CodexPath,
        [string]$CCSwitchPath,
        [switch]$NoLaunch
    )

    Write-Info '????????????? Codex ? CCSwitch?????????????'
    $codexClosed = Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $CodexPath -FallbackNames $Script:CodexProcessNames -TimeoutSeconds 10 -NoLaunch:$NoLaunch
    $ccswitchClosed = Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $CCSwitchPath -FallbackNames $Script:CCSwitchProcessNames -TimeoutSeconds 10 -NoLaunch:$NoLaunch

    if (-not $codexClosed -or -not $ccswitchClosed) {
        Write-ErrorLine 'Codex ? CCSwitch ????????????????????????/??????'
        Write-Next '????? Codex ? CCSwitch ????????'
        return $false
    }

    if (-not $NoLaunch) {
        Start-Sleep -Milliseconds 500
    }

    return $true
}

function Confirm-ThirdPartyRouteConfigReady {
    param([switch]$NoLaunch)

    if ($NoLaunch) {
        Write-Info 'NoLaunch: ?????? config.toml ??????/CCSwitch ?????'
        return $true
    }

    if (Test-ActiveConfigLooksThirdPartyRoute) {
        Write-Ok '?? config.toml ???????/CCSwitch ?????'
        return $true
    }

    Write-ErrorLine '?? config.toml ?????/CCSwitch ??????????? Codex?'
    Write-Next "??????????????? $Script:ThirdPartyProfileDir\config.toml?"
    return $false
}

function Start-ThirdPartyPreserveAuthMode {
    param($Config, [switch]$NoLaunch)

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if (-not $codexTarget) {
        Write-ErrorLine '???? Codex Desktop????? Codex Desktop????? .\codex-launcher.ps1 -Mode bootstrap'
        return
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    $codexProcessPath = $Config.codexPath
    if ($codexTarget -and $codexTarget.Kind -eq 'Exe') {
        $codexProcessPath = $codexTarget.Value
    }

    if (-not (Stop-ProcessesBeforeThirdPartySwitch -CodexPath $codexProcessPath -CCSwitchPath $ccswitchPath -NoLaunch:$NoLaunch)) {
        return
    }

    Save-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    $configPreservationBaseline = Get-ConfigPreservationBaseline
    Save-OfficialProfileIfCurrentLooksOfficial -NoWrite:$NoLaunch | Out-Null
    Restore-ThirdPartyConfig -NoWrite:$NoLaunch | Out-Null
    if (-not (Ensure-OfficialAuthForPreserveMode -NoWrite:$NoLaunch)) {
        Write-ErrorLine '?? 2 ?????????????????? Codex?'
        Write-Next '?????? 1 ?????????????? 2?'
        return
    }

    if (-not (Set-CCSwitchCodexEnhancement -Enabled $true -NoWrite:$NoLaunch)) {
        return
    }

    if (-not (Restart-CCSwitchForThirdParty -Path $ccswitchPath -NoLaunch:$NoLaunch)) {
        return
    }

    if (-not (Confirm-CCSwitchCodexEnhancement -ExpectedEnabled $true -NoLaunch:$NoLaunch)) {
        return
    }

    if (-not (Ensure-OfficialAuthForPreserveMode -NoWrite:$NoLaunch)) {
        Write-ErrorLine 'CCSwitch ??????????????????? Codex?'
        return
    }

    if (-not (Confirm-OfficialAuthForPreserveMode -NoLaunch:$NoLaunch)) {
        return
    }

    if (-not (Confirm-ThirdPartyRouteConfigReady -NoLaunch:$NoLaunch)) {
        return
    }

    Merge-PreservedCodexConfigSections -BaselineLines $configPreservationBaseline -NoWrite:$NoLaunch | Out-Null
    if (-not (Confirm-ThirdPartyRouteConfigReady -NoLaunch:$NoLaunch)) {
        return
    }

    Restore-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Invoke-HistorySyncBeforeCodexLaunch -Config $Config -Reason '?? 2 ?????????????????????????' -NoLaunch:$NoLaunch | Out-Null
    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv @('CODEX_HOME') -NoLaunch:$NoLaunch
}

function Start-ThirdPartyPureMode {
    param($Config, [switch]$NoLaunch)

    if (-not (Test-ProfileComplete -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml', 'auth.json'))) {
        Write-ErrorLine '????/API-key ???????? thirdparty profile ???? config.toml ? auth.json?'
        Write-Next '???????????????????????? 2?'
        return
    }

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if (-not $codexTarget) {
        Write-ErrorLine '???? Codex Desktop????? Codex Desktop????? .\codex-launcher.ps1 -Mode bootstrap'
        return
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    $codexProcessPath = $Config.codexPath
    if ($codexTarget -and $codexTarget.Kind -eq 'Exe') {
        $codexProcessPath = $codexTarget.Value
    }

    if (-not (Stop-ProcessesBeforeThirdPartySwitch -CodexPath $codexProcessPath -CCSwitchPath $ccswitchPath -NoLaunch:$NoLaunch)) {
        return
    }

    Save-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Save-OfficialProfileIfCurrentLooksOfficial -NoWrite:$NoLaunch | Out-Null
    Restore-ThirdPartyPureProfile -NoWrite:$NoLaunch | Out-Null

    if (-not (Set-CCSwitchCodexEnhancement -Enabled $false -NoWrite:$NoLaunch)) {
        return
    }

    if (-not (Restart-CCSwitchForThirdParty -Path $ccswitchPath -NoLaunch:$NoLaunch)) {
        return
    }

    if (-not (Confirm-CCSwitchCodexEnhancement -ExpectedEnabled $false -NoLaunch:$NoLaunch)) {
        return
    }

    if (-not (Confirm-ThirdPartyRouteConfigReady -NoLaunch:$NoLaunch)) {
        return
    }

    Restore-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv @('CODEX_HOME') -NoLaunch:$NoLaunch
}

function Start-ThirdPartyMode {
    param($Config, [switch]$NoLaunch)

    Write-Warn 'thirdparty ??????????????? thirdparty-preserve-auth?'
    Start-ThirdPartyPreserveAuthMode -Config $Config -NoLaunch:$NoLaunch
}

function Show-Menu {
    param($Config)

    while ($true) {
        Write-Host ''
        Write-Host '=============================='
        Write-Host " Codex Windows ??? $Script:LauncherVersion"
        Write-Host '=============================='
        Write-Host '1. ??????????????? Codex'
        Write-Host '   - ????????????????????????????'
        Write-Host '2. ??????????????????????'
        Write-Host '   - ??????????????????? auth.json?'
        Write-Host '3. ??????????/API-key'
        Write-Host '   - ??????????? auth.json???????????'
        Write-Host '4. ??/??????'
        Write-Host '   - ?????????????'
        Write-Host '5. ???/???????'
        Write-Host '   - ???????????????????'
        Write-Host '6. ??'
        $choice = Read-Host '?????'

        switch ($choice) {
            '1' { Start-OfficialMode -Config $Config -NoLaunch:$NoLaunch; return }
            '2' { Start-ThirdPartyPreserveAuthMode -Config $Config -NoLaunch:$NoLaunch; return }
            '3' { Start-ThirdPartyPureMode -Config $Config -NoLaunch:$NoLaunch; return }
            '4' { Invoke-Doctor -Config (Read-LauncherConfig); if ($NoLaunch) { return } }
            '5' { Invoke-Bootstrap -Config $Config -NoLaunch:$NoLaunch; return }
            '6' { return }
            default { Write-Warn '??? 1?2?3?4?5 ? 6?' }
        }
    }
}

if ($Mode -in @('check', 'doctor')) {
    Invoke-Doctor -Config (Read-LauncherConfig)
    return
}

if ($Mode -eq 'bootstrap') {
    $config = Load-LauncherConfig
    Invoke-Bootstrap -Config $config -NoLaunch:$NoLaunch
    return
}

if ($Mode -eq 'menu') {
    $state = Detect-ExistingLauncherState
    if ($state.NeedsBootstrap) {
        $config = Load-LauncherConfig
        Invoke-Bootstrap -Config $config -NoLaunch:$NoLaunch
        return
    }
}

$config = Load-LauncherConfig

switch ($Mode) {
    'official' { Start-OfficialMode -Config $config -NoLaunch:$NoLaunch }
    'thirdparty' { Start-ThirdPartyMode -Config $config -NoLaunch:$NoLaunch }
    'thirdparty-preserve-auth' { Start-ThirdPartyPreserveAuthMode -Config $config -NoLaunch:$NoLaunch }
    'thirdparty-pure' { Start-ThirdPartyPureMode -Config $config -NoLaunch:$NoLaunch }
    'menu' { Show-Menu -Config $config }
}

