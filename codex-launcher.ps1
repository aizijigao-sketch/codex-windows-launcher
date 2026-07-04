param(
    [ValidateSet('official', 'thirdparty', 'thirdparty-preserve-auth', 'thirdparty-pure', 'check', 'doctor', 'bootstrap', 'menu')]
    [string]$Mode = 'menu',

    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:LauncherVersion = 'v0.4.13'

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
$Script:LogDir = Join-Path $Script:LauncherHome 'logs'
$Script:RunLogPath = Join-Path $Script:LogDir ("launcher.{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

function Protect-LogMessage {
    param([string]$Message)

    if ($null -eq $Message) {
        return ''
    }

    $safe = $Message
    $safe = $safe -replace '(?i)(sk-[a-z0-9_-]{8,})', '<redacted-api-key>'
    $safe = $safe -replace '(?i)(api[_-]?key\s*[:=]\s*)[^,\s;"]+', '$1<redacted>'
    $safe = $safe -replace '(?i)(token\s*[:=]\s*)[^,\s;"]+', '$1<redacted>'
    $safe = $safe -replace '(?i)(password\s*[:=]\s*)[^,\s;"]+', '$1<redacted>'
    $safe = $safe -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^,\s;"]+', '$1<redacted>'
    return $safe
}

function Write-LauncherLog {
    param(
        [string]$Level,
        [string]$Message
    )

    try {
        if (-not (Test-Path -LiteralPath $Script:LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:LogDir -Force -ErrorAction Stop | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $safe = Protect-LogMessage -Message $Message
        Add-Content -LiteralPath $Script:RunLogPath -Value "[$timestamp][$Level] $safe" -Encoding UTF8
    } catch {
        # Logging must never break launching.
    }
}

function Write-Info {
    param([string]$Message)
    Write-LauncherLog -Level 'info' -Message $Message
    Write-Host "[info] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-LauncherLog -Level 'warn' -Message $Message
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-LauncherLog -Level 'ok' -Message $Message
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-ErrorLine {
    param([string]$Message)
    Write-LauncherLog -Level 'error' -Message $Message
    Write-Host "[error] $Message" -ForegroundColor Red
}

function Write-Next {
    param([string]$Message)
    Write-LauncherLog -Level 'next' -Message $Message
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
        Write-Ok "配置文件已存在：$Script:ConfigPath"
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
        Write-Info "NoLaunch: 将会创建非敏感配置文件：$Script:ConfigPath"
        if ($codexPath) {
            Write-Info "NoLaunch: 将会写入 codexPath=$codexPath"
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
    Write-Ok "已创建非敏感配置文件：$Script:ConfigPath"
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
        Write-Info "NoLaunch: 将会备份快捷方式元数据到 $backupPath"
        return
    }

    Ensure-Directory -Path $Script:BackupDir
    Set-Content -LiteralPath $backupPath -Value $lines.ToArray() -Encoding UTF8
    Write-Ok "已备份快捷方式元数据：$backupPath"
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
        Write-Info "NoLaunch: 将会创建或更新桌面快捷方式：$shortcutPath"
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
    Write-Ok "已创建或更新桌面快捷方式：$shortcutPath"
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
        return (@(Get-ProcessesByPath -Path $Path).Count -gt 0)
    }

    return ((Get-ProcessesByNames -Names $Names | Measure-Object).Count -gt 0)
}

function Stop-LauncherProcess {
    param(
        [string]$DisplayName,
        [string]$PreferredPath,
        [string[]]$FallbackNames,
        [int]$TimeoutSeconds = 8,
        [switch]$ForceImmediately,
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
            if ($ForceImmediately) {
                Write-Info "NoLaunch: 将会立即强制关闭 $DisplayName。"
            }
        }
        return $true
    }

    if ($ForceImmediately) {
        if ($matches.Count -gt 0) {
            Write-Info "立即强制关闭 $DisplayName，不等待主窗口退出。"
        }
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
        Start-Sleep -Milliseconds 250
        return (-not (Test-ProcessRunning -Path $PreferredPath -Names $FallbackNames))
    }

    foreach ($proc in $matches) {
        try {
            $liveProcess = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
            if (-not $liveProcess) {
                continue
            }
            if ($liveProcess.MainWindowHandle -ne 0) {
                Write-Info "正在温和关闭 $DisplayName 进程 $($proc.ProcessId)，等待本地状态写盘，最多等待 $TimeoutSeconds 秒。"
                [void]$liveProcess.CloseMainWindow()
            } else {
                Write-Info "$DisplayName 进程 $($proc.ProcessId) 没有主窗口，直接强制关闭。"
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
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
        Write-Warn "$DisplayName 未能在 $TimeoutSeconds 秒内自行退出，准备强制关闭。"
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
        Write-Warn "$DisplayName 仍在运行，配置切换可能不会立即生效。请手动关闭后重试。"
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
        Write-ErrorLine '当前是管理员窗口，无法可靠通过 Windows AppId 启动 Codex。'
        Write-Next '请关闭这个窗口，直接双击桌面的 Codex Windows Launcher，或打开普通 PowerShell 再运行。'
        Write-Next '如果普通窗口仍失败，请运行 doctor；启动目标若仍是 AppId，需要在 launcher-config.json 设置真实 Codex Desktop 的 codexPath。'
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

    Write-ErrorLine '无法通过 Windows AppId 启动 Codex。'
    foreach ($message in $errors) {
        Write-Warn $message
    }
    if (Test-IsElevated) {
        Write-Next '当前窗口是管理员模式。请关闭它，直接双击桌面的 Codex Windows Launcher，或用普通 PowerShell 运行。'
    } else {
        Write-Next "请尝试从开始菜单直接启动 Codex，或在 $Script:ConfigPath 里设置 codexPath。"
    }
    Write-Next '也可以运行 doctor 查看当前是 Exe 还是 AppId 启动目标。v0.3 会优先使用真实 Codex.exe。'
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
            Write-Info "正在启动 Codex：AppId $($Target.Value)"
            Start-AppIdTarget -AppId $Target.Value
        } else {
            Write-Info "正在启动 Codex：Exe $($Target.Value)"
            Start-Process -FilePath $Target.Value | Out-Null
        }
    } finally {
        Restore-ProcessEnv -Snapshot $snapshot
    }
    Write-Next "如聊天记录仍异常，请发送本次日志文件：$Script:RunLogPath"
}

function Resolve-HistorySyncBackendPath {
    param($Config)

    if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.historySyncBackendPath)) {
        $configured = [Environment]::ExpandEnvironmentVariables($Config.historySyncBackendPath)
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            Write-Info "Codex History Sync Tool 来源：launcher-config.json，路径=$configured"
            return (Resolve-Path -LiteralPath $configured).ProviderPath
        }
        Write-Warn "配置中的 historySyncBackendPath 不存在：$configured"
    }

    $launcherDir = Split-Path -Parent $PSCommandPath
    $projectsDir = Split-Path -Parent $launcherDir
    $sibling = Join-Path $projectsDir 'codex-history-sync-windows-work\sync_backend.py'
    if (Test-Path -LiteralPath $sibling -PathType Leaf) {
        Write-Info "Codex History Sync Tool 来源：相邻项目自动发现，路径=$sibling"
        return (Resolve-Path -LiteralPath $sibling).ProviderPath
    }

    Write-Warn '未自动发现相邻的 Codex History Sync Tool 后端。'
    return $null
}

function Get-ObjectValue {
    param(
        $Object,
        [string]$Key,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Key)) {
            return $Object[$Key]
        }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Key]
    if ($property) {
        return $property.Value
    }

    return $Default
}

function Get-ConfigSectionTextFromContent {
    param(
        [string]$Text,
        [string]$SectionName
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $capture = $false
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Text -split "`r?`n")) {
        $section = Get-ConfigSectionName -Line $line
        if ($null -ne $section) {
            if ($capture -and $section -ne $SectionName) {
                break
            }
            $capture = ($section -eq $SectionName)
        }

        if ($capture) {
            $result.Add($line)
        }
    }

    return ($result.ToArray() -join "`n")
}

function Get-ActiveConfigProviderSummary {
    param([string]$Path = $Script:ActiveConfigPath)

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $text = ''
    if ($exists) {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }

    $modelProvider = ''
    if ($text -match '(?m)^\s*model_provider\s*=\s*["'']([^"'']+)["'']') {
        $modelProvider = $Matches[1]
    }

    $model = ''
    if ($text -match '(?m)^\s*model\s*=\s*["'']([^"'']+)["'']') {
        $model = $Matches[1]
    }

    $customProviderText = Get-ConfigSectionTextFromContent -Text $text -SectionName 'model_providers.custom'

    return New-Object PSObject -Property @{
        Exists = $exists
        ModelProvider = $modelProvider
        Model = $model
        HasCustomProviderSection = (-not [string]::IsNullOrWhiteSpace($customProviderText))
        HasLocalRouteBaseUrl = ($customProviderText -match '(?m)^\s*base_url\s*=.*(127\.0\.0\.1:15721|localhost:15721)')
        RequiresOpenAIAuth = ($customProviderText -match '(?m)^\s*requires_openai_auth\s*=\s*true\s*(#.*)?$')
    }
}

function Format-ActiveConfigProviderSummary {
    param($Summary)

    if (-not $Summary) {
        return 'config=<missing-summary>'
    }

    return ("exists={0}; model_provider={1}; model={2}; custom_section={3}; local_route={4}; requires_openai_auth={5}" -f `
        $Summary.Exists,
        $Summary.ModelProvider,
        $Summary.Model,
        $Summary.HasCustomProviderSection,
        $Summary.HasLocalRouteBaseUrl,
        $Summary.RequiresOpenAIAuth)
}

function Write-ActiveConfigProviderSummary {
    param([string]$Stage)

    Write-Info ("config 摘要 {0}：{1}" -f $Stage, (Format-ActiveConfigProviderSummary -Summary (Get-ActiveConfigProviderSummary)))
}

function Get-HistorySyncStatusObject {
    param($Payload)

    $status = Get-ObjectValue -Object $Payload -Key 'status'
    if ($status) {
        return $status
    }
    return $Payload
}

function Get-HistorySyncRemainingWork {
    param(
        $Payload,
        [int]$SkippedBusy = 0
    )

    $status = Get-HistorySyncStatusObject -Payload $Payload
    $remaining = 0
    foreach ($field in @('movable_threads', 'movable_database_threads', 'movable_session_meta_entries', 'missing_session_index_entries', 'archived_index_mismatch_threads')) {
        $value = Get-ObjectValue -Object $status -Key $field
        if ($null -ne $value) {
            $remaining += [int]$value
        }
    }

    return @{
        Remaining = $remaining
        SkippedBusy = $SkippedBusy
        Status = $status
    }
}

function Format-HistoryStatusSummary {
    param($Payload)

    $status = Get-HistorySyncStatusObject -Payload $Payload
    if (-not $status) {
        return 'status=<missing>'
    }

    $loginMode = Get-ObjectValue -Object (Get-ObjectValue -Object $status -Key 'login_mode') -Key 'mode'
    return ("provider={0}; source={1}; login={2}; total={3}; movable={4}; db={5}; visibility={6}; session_meta={7}; missing_index={8}; archived_mismatch={9}; indexed={10}; sessions={11}; provider_error={12}" -f `
        (Get-ObjectValue -Object $status -Key 'current_provider'),
        (Get-ObjectValue -Object $status -Key 'current_provider_source'),
        $loginMode,
        (Get-ObjectValue -Object $status -Key 'total_threads'),
        (Get-ObjectValue -Object $status -Key 'movable_threads'),
        (Get-ObjectValue -Object $status -Key 'movable_database_threads'),
        (Get-ObjectValue -Object $status -Key 'visibility_movable_threads'),
        (Get-ObjectValue -Object $status -Key 'movable_session_meta_entries'),
        (Get-ObjectValue -Object $status -Key 'missing_session_index_entries'),
        (Get-ObjectValue -Object $status -Key 'archived_index_mismatch_threads'),
        (Get-ObjectValue -Object $status -Key 'indexed_threads'),
        (Get-ObjectValue -Object $status -Key 'session_file_count'),
        (Get-ObjectValue -Object $status -Key 'provider_resolution_error'))
}

function Invoke-HistorySyncBeforeCodexLaunch {
    param(
        $Config,
        [string]$Reason,
        [string]$ExpectedProvider = '',
        [switch]$NoLaunch
    )

    $backendPath = Resolve-HistorySyncBackendPath -Config $Config
    if (-not $backendPath) {
        Write-Warn '未找到 Codex History Sync Tool；本次不涉及聊天记录恢复，只启动 Codex。'
        Write-Next '如需自动判断和一键恢复聊天记录，请在 launcher-config.json 设置 historySyncBackendPath，或把两个项目放在同一个 20_Projects 目录下。'
        return $true
    }

    $historyProviderArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedProvider)) {
        $historyProviderArgs = @('--expected-provider', $ExpectedProvider)
    }
    $providerArgText = if ($historyProviderArgs.Count -gt 0) { " $($historyProviderArgs -join ' ')" } else { '' }

    if ($NoLaunch) {
        Write-Info "NoLaunch: 将会在启动 Codex 前检查历史状态：py -3 $backendPath --codex-home $Script:DefaultCodexHome --json$providerArgText status"
        Write-Info "NoLaunch: 历史异常且 provider 匹配时将调用定向恢复：py -3 $backendPath --codex-home $Script:DefaultCodexHome --json$providerArgText sync"
        if (-not [string]::IsNullOrWhiteSpace($ExpectedProvider)) {
            Write-Info "NoLaunch: 历史同步期望 provider=$ExpectedProvider。"
        }
        return $true
    }

    Write-Info "启动 Codex 前检查历史状态：$Reason"
    Write-ActiveConfigProviderSummary -Stage 'history-sync 前'
    try {
        $statusPayload = $null
        $providerMismatch = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Info "执行历史状态检查($attempt/3)：py -3 $backendPath --codex-home $Script:DefaultCodexHome --json$providerArgText status"
            $statusCompleted = & py -3 $backendPath --codex-home $Script:DefaultCodexHome --json @historyProviderArgs status 2>&1
            Write-Info "历史状态检查($attempt/3)退出码：$LASTEXITCODE"
            $statusRaw = ($statusCompleted | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($statusRaw)) {
                Write-Warn '历史状态检查没有返回输出；继续启动 Codex。'
                return $true
            }

            $statusPayload = $statusRaw | ConvertFrom-Json
            if ((Get-ObjectValue -Object $statusPayload -Key 'ok') -ne $true) {
                Write-Warn "历史状态检查未完成：$(Get-ObjectValue -Object $statusPayload -Key 'error')；继续启动 Codex。"
                return $true
            }

            $currentProviderForAttempt = Get-ObjectValue -Object $statusPayload -Key 'current_provider'
            if ([string]::IsNullOrWhiteSpace($ExpectedProvider) -or $currentProviderForAttempt -eq $ExpectedProvider) {
                $providerMismatch = $false
                break
            }

            $providerMismatch = $true
            Write-Warn "历史同步目标 provider 暂不符合预期($attempt/3)：实际=$currentProviderForAttempt，期望=$ExpectedProvider。"
            Write-Info "历史状态摘要 mismatch($attempt/3)：$(Format-HistoryStatusSummary -Payload $statusPayload)"
            if ($attempt -lt 3) {
                Write-Info '等待 1 秒后复查 provider，避免 Codex/CCSwitch 刚退出后的短暂状态不一致。'
                Start-Sleep -Seconds 1
            }
        }

        $precheck = Get-HistorySyncRemainingWork -Payload $statusPayload
        $currentProvider = Get-ObjectValue -Object $statusPayload -Key 'current_provider'
        $totalThreads = Get-ObjectValue -Object $statusPayload -Key 'total_threads'
        Write-Info "历史同步目标 provider=$currentProvider，总线程=$totalThreads，待修复=$($precheck.Remaining)。"
        Write-Info "历史状态摘要 before：$(Format-HistoryStatusSummary -Payload $statusPayload)"
        if ($providerMismatch -or (-not [string]::IsNullOrWhiteSpace($ExpectedProvider) -and $currentProvider -ne $ExpectedProvider)) {
            Write-Warn "历史同步目标 provider 不符合预期：实际=$currentProvider，期望=$ExpectedProvider。"
            Write-ActiveConfigProviderSummary -Stage 'history-sync provider 不匹配时'
            Write-ErrorLine '历史同步目标 provider 不符合预期，本次不会执行历史恢复，也不会启动 Codex，避免把聊天记录修到错误通道。'
            Write-Next '请发送本次日志；重点查看 config 摘要与 history status 的 provider/source 是否一致。'
            return $false
        }

        if ($precheck.Remaining -le 0 -and -not $providerMismatch) {
            Write-Ok "历史状态已干净：总线程=$totalThreads，待修复=0；跳过修复。"
            return $true
        }

        Write-Warn "检测到聊天记录异常：待修复=$($precheck.Remaining)，provider异常=$providerMismatch。"
        Write-Info '正在调用 Codex History Sync Tool 定向恢复当前 .codex；可能需要几十秒，完成前请不要手动启动 Codex。'
        Write-Info "执行定向历史恢复：py -3 $backendPath --codex-home $Script:DefaultCodexHome --json$providerArgText sync"
        $completed = & py -3 $backendPath --codex-home $Script:DefaultCodexHome --json @historyProviderArgs sync 2>&1
        Write-Info "定向历史恢复退出码：$LASTEXITCODE"
        $raw = ($completed | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warn 'Codex History Sync Tool 没有返回输出；继续启动 Codex。'
            return $true
        }
        $payload = $raw | ConvertFrom-Json
        if ((Get-ObjectValue -Object $payload -Key 'ok') -ne $true) {
            Write-ErrorLine "Codex History Sync Tool 定向恢复未完成；本次不会启动 Codex：$(Get-ObjectValue -Object $payload -Key 'error')"
            Write-Next '请发送本次日志；启动器已避免进入未恢复聊天状态。'
            return $false
        }

        Write-Info "执行恢复后历史状态检查：py -3 $backendPath --codex-home $Script:DefaultCodexHome --json$providerArgText status"
        $postCompleted = & py -3 $backendPath --codex-home $Script:DefaultCodexHome --json @historyProviderArgs status 2>&1
        Write-Info "恢复后历史状态检查退出码：$LASTEXITCODE"
        $postRaw = ($postCompleted | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($postRaw)) {
            $postPayload = $postRaw | ConvertFrom-Json
            $postWork = Get-HistorySyncRemainingWork -Payload $postPayload
            $postProvider = Get-ObjectValue -Object $postPayload -Key 'current_provider'
            $postTotal = Get-ObjectValue -Object $postPayload -Key 'total_threads'
            Write-Info "定向恢复后历史状态：provider=$postProvider，总线程=$postTotal，剩余=$($postWork.Remaining)。"
            Write-Info "历史状态摘要 after：$(Format-HistoryStatusSummary -Payload $postPayload)"
            if (-not [string]::IsNullOrWhiteSpace($ExpectedProvider) -and $postProvider -ne $ExpectedProvider) {
                Write-ErrorLine "定向恢复后 provider 仍不符合预期：实际=$postProvider，期望=$ExpectedProvider。本次不会启动 Codex。"
                Write-Next '请发送本次日志；启动器已阻止继续进入错误聊天通道。'
                return $false
            }
            if ($postWork.Remaining -le 0) {
                Write-Ok 'Codex History Sync Tool 定向恢复完成，聊天状态已干净。'
                return $true
            }
            Write-ErrorLine "定向恢复后仍有聊天异常：剩余=$($postWork.Remaining)。本次不会启动 Codex。"
            Write-Next '请发送本次日志；如需临时使用，可手动打开 Codex History Sync Tool 恢复后再启动。'
            return $false
        }
        Write-ErrorLine '定向恢复后没有拿到可验证的历史状态，本次不会启动 Codex。'
        return $false
    } catch {
        Write-Warn "历史修复调用失败：$($_.Exception.Message)"
        Write-Next '本次不会复制凭据或聊天；也不会启动 Codex，避免进入未恢复聊天状态。'
        return $false
    }
}

function New-MinimalOfficialConfig {
    @(
        '# Official Codex profile managed by codex-launcher.',
        '# Keep this profile free of custom provider and base_url settings.',
        'model_provider = "openai"'
    ) -join [Environment]::NewLine
}

function Set-OfficialConfigProviderOpenAI {
    param([switch]$NoWrite)

    Ensure-Directory -Path $Script:DefaultCodexHome
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        if ($NoWrite) {
            Write-Info "NoLaunch: 将会创建官方配置并写入 model_provider = `"openai`"。"
            return $true
        }
        Set-Content -LiteralPath $Script:ActiveConfigPath -Value (New-MinimalOfficialConfig) -Encoding UTF8
        Write-Ok '已创建官方配置并写入 model_provider = "openai"。'
        return $true
    }

    $lines = @(Get-Content -LiteralPath $Script:ActiveConfigPath -Encoding UTF8)
    $result = New-Object System.Collections.Generic.List[string]
    $sawProvider = $false
    $changed = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*model_provider\s*=') {
            $result.Add('model_provider = "openai"')
            $sawProvider = $true
            if ($line -notmatch '^\s*model_provider\s*=\s*["'']openai["'']\s*(#.*)?$') {
                $changed = $true
            }
            continue
        }
        $result.Add($line)
    }

    if (-not $sawProvider) {
        $result.Insert(0, 'model_provider = "openai"')
        $changed = $true
    }

    if (-not $changed) {
        Write-Ok '官方配置已明确使用 model_provider = "openai"。'
        return $true
    }

    if ($NoWrite) {
        Write-Info 'NoLaunch: 将会把官方配置标记为 model_provider = "openai"。'
        return $true
    }

    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-official-provider-openai' | Out-Null
    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $result.ToArray() -Encoding UTF8
    Write-Ok '已把官方配置标记为 model_provider = "openai"。'
    return $true
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
        Write-Info "NoLaunch: 将会备份 CCSwitch 设置到本机目录：$backupPath"
        return $backupPath
    }

    Ensure-Directory -Path $Script:CCSwitchBackupDir
    Copy-Item -LiteralPath $Script:CCSwitchSettingsPath -Destination $backupPath -Force
    Write-Info '已备份 CCSwitch 设置文件到本机 .cc-switch\backups。'
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

function ConvertTo-PlainJsonValue {
    param(
        $Value,
        [int]$Depth = 0
    )

    if ($Depth -gt 80) {
        return $null
    }

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            if ($null -ne $key) {
                $map[[string]$key] = ConvertTo-PlainJsonValue -Value $Value[$key] -Depth ($Depth + 1)
            }
        }
        return $map
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-PlainJsonValue -Value $item -Depth ($Depth + 1))
        }
        return $items
    }

    $props = $Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' }
    if ($props) {
        $map = [ordered]@{}
        foreach ($prop in $props) {
            $map[$prop.Name] = ConvertTo-PlainJsonValue -Value $prop.Value -Depth ($Depth + 1)
        }
        return $map
    }

    return [string]$Value
}

function Write-JsonMapFile {
    param(
        [string]$Path,
        $Value
    )

    $plain = ConvertTo-PlainJsonValue -Value $Value
    $json = $plain | ConvertTo-Json -Depth 100 -Compress
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
        if ($Map.PSObject.Methods.Name -contains 'ContainsKey') {
            return $Map.ContainsKey($Key)
        }
        return (@($Map.Keys) -contains $Key)
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
        Write-Warn "未找到 Codex 界面状态文件：$Script:CodexGlobalStatePath"
        return $false
    }

    if ($NoWrite) {
        Write-Info "NoLaunch: 将会保存 Codex 界面偏好快照：$Script:CodexUiStateSnapshotPath"
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
        Write-Info '已保存 Codex 界面偏好快照。'
        return $true
    } catch {
        Write-Warn "保存 Codex 界面偏好快照失败：$($_.Exception.Message)"
        return $false
    }
}

function Restore-CodexUiStateSnapshot {
    param([switch]$NoWrite)

    if ($NoWrite) {
        Write-Info 'NoLaunch: 将会恢复 Codex 界面偏好快照。'
        return $true
    }

    if (-not (Test-Path -LiteralPath $Script:CodexUiStateSnapshotPath -PathType Leaf)) {
        Write-Warn "未找到 Codex 界面偏好快照：$Script:CodexUiStateSnapshotPath"
        return $false
    }

    if (-not (Test-Path -LiteralPath $Script:CodexGlobalStatePath -PathType Leaf)) {
        Write-Warn "未找到 Codex 界面状态文件：$Script:CodexGlobalStatePath"
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
        Write-Ok '已恢复 Codex 界面偏好。'
        return $true
    } catch {
        Write-Warn "恢复 Codex 界面偏好失败：$($_.Exception.Message)"
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

    $stateText = if ($Enabled) { '开启' } else { '关闭' }
    if (-not (Test-Path -LiteralPath $Script:CCSwitchSettingsPath -PathType Leaf)) {
        Write-Warn "未找到 CCSwitch 设置文件：$Script:CCSwitchSettingsPath"
        Write-Next "请先打开一次 CCSwitch；本次仍会继续启动，但无法自动${stateText} Codex 应用增强。"
        return $false
    }

    if ($NoWrite) {
        Write-Info "NoLaunch: 将会${stateText} CCSwitch Codex 应用增强：preserveCodexOfficialAuthOnSwitch=$Enabled"
        return $true
    }

    try {
        $raw = Get-Content -LiteralPath $Script:CCSwitchSettingsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warn 'CCSwitch 设置文件为空，无法自动修改 Codex 应用增强。'
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
        Write-Ok "已${stateText} CCSwitch Codex 应用增强。"
        return $true
    } catch {
        Write-Warn "修改 CCSwitch Codex 应用增强失败：$($_.Exception.Message)"
        Write-Next '本次不会打印 CCSwitch settings.json 内容；请避免把该文件上传到公有仓库。'
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
        Write-Warn '没有找到可保存的默认 Codex 配置文件，无法保存官方状态。'
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
        Write-Warn '没有找到已保存的官方登录文件；保留官方登录的第三方模式可能需要先完成一次官方登录。'
    }
    return $restored
}

function Restore-ThirdPartyProfile {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '没有找到已保存的第三方状态；第三方模式会沿用当前默认 .codex 状态。'
    }
}

function Restore-ThirdPartyConfig {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml') -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '没有找到已保存的第三方路由配置；会沿用当前默认 config.toml。'
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
        Write-Info '将以切换前的官方 config.toml 作为插件和桌面配置保留基准。'
        return $activeLines
    }

    $officialConfigPath = Join-Path $Script:OfficialProfileDir 'config.toml'
    $officialLines = Read-ConfigLines -Path $officialConfigPath
    if ($officialLines.Count -gt 0) {
        Write-Info '将以已保存的 official profile config.toml 作为插件和桌面配置保留基准。'
        return $officialLines
    }

    if ($activeLines.Count -gt 0) {
        Write-Warn '没有可确认的官方 config 基准；只能保留当前 config 中已有的非路由配置。'
        return $activeLines
    }

    Write-Warn '未找到可用于保留插件配置的 config.toml 基准。'
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
        Write-Warn '没有插件/桌面配置保留基准；跳过 config 合并。'
        return $false
    }
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        Write-Warn '当前 config.toml 不存在；跳过插件/桌面配置合并。'
        return $false
    }

    $activeLines = Read-ConfigLines -Path $Script:ActiveConfigPath
    $routeLines = Select-RouteConfigLines -Lines $activeLines
    $preservedLines = Select-PreservedConfigLines -Lines $BaselineLines
    if ($preservedLines.Count -eq 0) {
        Write-Warn '保留基准中没有发现可合并的插件、marketplace、MCP 或桌面配置。'
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
        Write-Info 'NoLaunch: 将会在第三方路由配置中合并保留官方插件、marketplace、MCP 和桌面设置。'
        return $true
    }

    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-preserve-config-merge' | Out-Null
    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $merged.ToArray() -Encoding UTF8
    Write-Ok '已保留官方插件、marketplace、MCP 和桌面设置，同时保留第三方路由配置。'
    return $true
}

function Set-PreserveAuthCustomProviderRequiresOfficialAuth {
    param([switch]$NoWrite)

    if (-not (Test-ActiveConfigLooksThirdPartyRoute)) {
        Write-Warn '当前 config.toml 不像 CCSwitch 本地路由；跳过官方 OAuth 路由标记修正。'
        return $false
    }

    $lines = Read-ConfigLines -Path $Script:ActiveConfigPath
    if ($lines.Count -eq 0) {
        Write-Warn '当前 config.toml 为空；无法修正 custom provider 官方登录标记。'
        return $false
    }

    $result = New-Object System.Collections.Generic.List[string]
    $section = ''
    $inCustomProvider = $false
    $sawCustomProvider = $false
    $sawRequiresAuth = $false
    $changed = $false

    foreach ($line in $lines) {
        $newSection = Get-ConfigSectionName -Line $line
        if ($null -ne $newSection) {
            if ($inCustomProvider -and -not $sawRequiresAuth) {
                $result.Add('requires_openai_auth = true')
                $changed = $true
            }
            $section = $newSection
            $inCustomProvider = ($section -eq 'model_providers.custom')
            if ($inCustomProvider) {
                $sawCustomProvider = $true
                $sawRequiresAuth = $false
            }
        }

        if ($inCustomProvider -and $line -match '^\s*requires_openai_auth\s*=') {
            $result.Add('requires_openai_auth = true')
            $sawRequiresAuth = $true
            if ($line -notmatch '^\s*requires_openai_auth\s*=\s*true\s*(#.*)?$') {
                $changed = $true
            }
            continue
        }

        $result.Add($line)
    }

    if ($inCustomProvider -and -not $sawRequiresAuth) {
        $result.Add('requires_openai_auth = true')
        $changed = $true
    }

    if (-not $sawCustomProvider) {
        Write-Warn '当前 config.toml 没有 [model_providers.custom]；无法标记第三方路由需要官方 OAuth。'
        return $false
    }

    if (-not $changed) {
        Write-Ok '第三方路由已标记为需要官方 OAuth 登录态。'
        return $true
    }

    if ($NoWrite) {
        Write-Info 'NoLaunch: 将会把第三方 custom provider 标记为 requires_openai_auth = true。'
        return $true
    }

    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-preserve-auth-requires-openai-auth' | Out-Null
    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $result.ToArray() -Encoding UTF8
    Write-Ok '已把第三方 custom provider 标记为需要官方 OAuth 登录态。'
    return $true
}

function Ensure-ThirdPartyCustomProviderConfig {
    param([switch]$NoWrite)

    Ensure-Directory -Path $Script:DefaultCodexHome
    $lines = Read-ConfigLines -Path $Script:ActiveConfigPath
    if ($lines.Count -eq 0) {
        $lines = @('model = "gpt-5.5"', '')
    }

    $summary = Get-ActiveConfigProviderSummary
    $needsModelProvider = ($summary.ModelProvider -ne 'custom')
    $needsCustomProvider = (-not $summary.HasCustomProviderSection)
    $needsRoute = (-not $summary.HasLocalRouteBaseUrl)
    $needsRequiresAuth = (-not $summary.RequiresOpenAIAuth)

    if (-not ($needsModelProvider -or $needsCustomProvider -or $needsRoute -or $needsRequiresAuth)) {
        Write-Ok '第三方 custom provider 配置已完整，可被历史同步工具识别。'
        return $true
    }

    $result = New-Object System.Collections.Generic.List[string]
    $modelProviderWritten = $false
    $insertedProvider = $false

    foreach ($line in $lines) {
        if (-not $insertedProvider -and $line -match '^\s*\[.*\]\s*$') {
            if (-not $modelProviderWritten) {
                $result.Add('model_provider = "custom"')
                $modelProviderWritten = $true
            }
            $insertedProvider = $true
        }

        if ($line -match '^\s*model_provider\s*=') {
            if (-not $modelProviderWritten) {
                $result.Add('model_provider = "custom"')
                $modelProviderWritten = $true
            }
            continue
        }

        $result.Add($line)
    }

    if (-not $modelProviderWritten) {
        $result.Insert(0, 'model_provider = "custom"')
    }

    $mergedText = ($result.ToArray() -join "`n")
    if ($mergedText -notmatch '(?m)^\s*\[model_providers\.custom\]\s*$') {
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
            $result.Add('')
        }
        $result.Add('[model_providers.custom]')
        $result.Add('name = "CCSwitch Local Route"')
        $result.Add('base_url = "http://127.0.0.1:15721/v1"')
        $result.Add('requires_openai_auth = true')
    } else {
        $result = New-Object System.Collections.Generic.List[string]
        $section = ''
        $inCustomProvider = $false
        $sawBaseUrl = $false
        $sawRequiresAuth = $false
        $modelProviderWritten = $false
        foreach ($line in $lines) {
            $newSection = Get-ConfigSectionName -Line $line
            if ($null -ne $newSection) {
                if ($inCustomProvider) {
                    if (-not $sawBaseUrl) {
                        $result.Add('base_url = "http://127.0.0.1:15721/v1"')
                    }
                    if (-not $sawRequiresAuth) {
                        $result.Add('requires_openai_auth = true')
                    }
                }
                $section = $newSection
                $inCustomProvider = ($section -eq 'model_providers.custom')
                $sawBaseUrl = $false
                $sawRequiresAuth = $false
            }

            if ($line -match '^\s*model_provider\s*=') {
                if (-not $modelProviderWritten) {
                    $result.Add('model_provider = "custom"')
                    $modelProviderWritten = $true
                }
                continue
            }
            if ($inCustomProvider -and $line -match '^\s*base_url\s*=') {
                $result.Add('base_url = "http://127.0.0.1:15721/v1"')
                $sawBaseUrl = $true
                continue
            }
            if ($inCustomProvider -and $line -match '^\s*requires_openai_auth\s*=') {
                $result.Add('requires_openai_auth = true')
                $sawRequiresAuth = $true
                continue
            }
            $result.Add($line)
        }
        if ($inCustomProvider) {
            if (-not $sawBaseUrl) {
                $result.Add('base_url = "http://127.0.0.1:15721/v1"')
            }
            if (-not $sawRequiresAuth) {
                $result.Add('requires_openai_auth = true')
            }
        }
        if (-not $modelProviderWritten) {
            $result.Insert(0, 'model_provider = "custom"')
        }
    }

    if ($NoWrite) {
        Write-Info 'NoLaunch: 将会修复第三方 config.toml，使 History Sync Tool 能识别 custom provider。'
        return $true
    }

    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-thirdparty-custom-provider-repair' | Out-Null
    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $result.ToArray() -Encoding UTF8
    Write-Ok '已修复第三方 custom provider 配置，History Sync Tool 应能识别 provider=custom。'
    Save-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml') | Out-Null
    return $true
}

function Restore-ThirdPartyPureProfile {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml', 'auth.json') -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '没有找到已保存的纯第三方状态；纯第三方模式会沿用当前默认 .codex 状态。'
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
        Write-Warn '无法识别 auth.json 元数据；不会自动移动或保存为官方状态。'
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

function Test-ActiveConfigHasThirdPartyLocalRoute {
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        return $false
    }

    return (Select-String -LiteralPath $Script:ActiveConfigPath -Pattern '127\.0\.0\.1:15721|localhost:15721' -Quiet)
}

function Test-ActiveConfigLooksThirdPartyRoute {
    $summary = Get-ActiveConfigProviderSummary

    return ($summary.Exists `
        -and $summary.ModelProvider -eq 'custom' `
        -and $summary.HasCustomProviderSection `
        -and $summary.HasLocalRouteBaseUrl)
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
        Write-Info '当前默认 .codex 看起来是官方登录态；切换前会先保存为官方状态。'
        Save-OfficialProfile -NoWrite:$NoWrite
        return $true
    }

    Write-Warn '当前默认 .codex 不像官方登录态；不会保存为官方状态，避免误缓存第三方状态。'
    return $false
}

function Save-OfficialAuthOnlyIfCurrentLooksOfficial {
    param([switch]$NoWrite)

    if ((Get-AuthState -Path $Script:ActiveAuthPath) -ne 'official-like') {
        return $false
    }

    Write-Info '当前 auth.json 看起来是官方登录态；会保存官方登录文件。'
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

    Write-Warn '保留官方登录的第三方模式没有找到可确认的官方登录态；不会恢复第三方 auth.json。'
    return $false
}

function Confirm-OfficialAuthForPreserveMode {
    param([switch]$NoLaunch)

    if ($NoLaunch) {
        Write-Info 'NoLaunch: 将会确认最终 auth.json 仍是官方 ChatGPT/OAuth 登录态。'
        return $true
    }

    $authState = Get-AuthState -Path $Script:ActiveAuthPath
    if ($authState -eq 'official-like') {
        Write-Ok '最终 auth.json 已确认是官方 ChatGPT/OAuth 登录态。'
        return $true
    }

    Write-ErrorLine "最终 auth.json 不是官方登录态，而是 $authState；本次不会启动 Codex，避免继续显示 API 密钥登录。"
    Write-Next '请先用菜单 1 完成官方网页登录并保存官方状态，再选择菜单 2。'
    return $false
}

function Disable-ApiKeyAuthForOfficial {
    param([switch]$NoWrite)

    $authState = Get-AuthState -Path $Script:ActiveAuthPath

    if ($authState -eq 'none') {
        Write-Info '未找到默认 auth.json；Codex 应该会要求官方登录。'
        return
    }

    if ($authState -eq 'unknown') {
        Write-Warn '默认 auth.json 存在但无法安全识别；不会自动移走。请先手动确认登录态。'
        return
    }

    if ($authState -ne 'api-key-like') {
        Write-Info '默认 auth.json 不像 API-key 登录态；保持不动。'
        return
    }

    Save-ThirdPartyProfile -NoWrite:$NoWrite
    Backup-LauncherFile -Path $Script:ActiveAuthPath -Reason 'before-official-auth-switch' -NoWrite:$NoWrite | Out-Null

    if ($NoWrite) {
        Write-Info 'NoLaunch: 将会暂时移走 API-key auth.json，让 Codex 使用官方登录。'
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $disabledPath = Join-Path $Script:BackupDir ("auth.json.$timestamp.disabled-for-official")
    Move-Item -LiteralPath $Script:ActiveAuthPath -Destination $disabledPath -Force
    Write-Info '已暂时移走 API-key auth.json。如果没有官方会话，Codex 会要求官方登录。'
}

function Repair-ActiveConfigForOfficial {
    param([switch]$NoWrite)

    Ensure-Directory -Path $Script:DefaultCodexHome
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        if ($NoWrite) {
            Write-Info "NoLaunch: 将会创建默认官方配置：$Script:ActiveConfigPath"
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
        Write-Info '默认 .codex config 未发现 custom provider 配置。'
        return
    }

    Save-ThirdPartyProfile -NoWrite:$NoWrite
    Backup-LauncherFile -Path $Script:ActiveConfigPath -Reason 'before-official-config-switch' -NoWrite:$NoWrite | Out-Null

    if ($NoWrite) {
        Write-Info "NoLaunch: 将会从默认 .codex config 移除 $removed 行 custom provider 配置。"
        return
    }

    Set-Content -LiteralPath $Script:ActiveConfigPath -Value $kept.ToArray() -Encoding UTF8
    Write-Info "已从默认 .codex config 移除 $removed 行 custom provider 配置。"
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
    Write-Host "Codex Windows Launcher 诊断 $Script:LauncherVersion"
    Write-Host '---------------------------'

    $state = Detect-ExistingLauncherState
    if ($state.NeedsBootstrap) {
        Write-Warn "本机启动器状态需要初始化或升级：$($state.StateKind)"
        Write-Next '.\codex-launcher.ps1 -Mode bootstrap'
    } else {
        Write-Ok "本机启动器状态正常：$($state.StateKind)"
    }

    if ($state.ConfigExists) {
        Write-Ok "配置文件存在：$Script:ConfigPath"
    } else {
        Write-Warn "配置文件不存在：$Script:ConfigPath"
    }

    if ($state.DesktopShortcutExists) {
        if ($state.DesktopShortcutCurrent) {
            Write-Ok "桌面快捷方式指向当前脚本：$($state.DesktopShortcutPath)"
        } else {
            Write-Warn "桌面快捷方式不是当前脚本：$($state.DesktopShortcutPath)"
            $info = Get-ShortcutInfo -Path $state.DesktopShortcutPath
            if ($info -and -not [string]::IsNullOrWhiteSpace($info.IconLocation)) {
                $iconPath = ($info.IconLocation -split ',', 2)[0]
                if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
                    Write-Ok "快捷方式图标存在：$iconPath"
                } else {
                    Write-Warn "快捷方式图标路径不存在：$iconPath"
                }
            }
        }
    } else {
        Write-Warn "未找到桌面快捷方式：$($state.DesktopShortcutPath)"
    }

    if ($state.LegacyShortcuts.Count -gt 0) {
        Write-Warn '检测到旧 Start Codex With CC Switch 快捷方式；只建议删除快捷方式，不要删除 CCSwitch 数据。'
        foreach ($path in $state.LegacyShortcuts) {
            Write-Host "       $path"
        }
    }

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if ($codexTarget) {
        if ($codexTarget.Kind -eq 'Exe') {
            Write-Ok "Codex 启动目标：Exe $($codexTarget.Value)"
        } else {
            Write-Warn "Codex 启动目标：AppId $($codexTarget.Value)"
            Write-Next 'AppId 在公司电脑或管理员窗口可能被拦。若启动失败，请在 launcher-config.json 设置 codexPath。'
        }
    } else {
        Write-ErrorLine '未检测到 Codex Desktop。请先安装 Codex Desktop，再运行 bootstrap。'
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    if ($ccswitchPath) {
        Write-Ok "CCSwitch 路径：$ccswitchPath"
    } else {
        Write-Warn '未检测到 CCSwitch。官方模式仍可用，第三方模式暂不可用。'
    }

    if (Test-ProcessRunning -Path $ccswitchPath -Names $Script:CCSwitchProcessNames) {
        Write-Ok 'CCSwitch 正在运行。'
    } else {
        Write-Warn 'CCSwitch 未运行。'
    }

    if (Test-LocalPort -Port 15721) {
        Write-Ok '本地路由正在监听：127.0.0.1:15721'
    } else {
        Write-Warn '未检测到本地路由监听：127.0.0.1:15721'
    }

    switch (Get-CCSwitchCodexEnhancementState) {
        'enabled' { Write-Ok 'CCSwitch Codex 应用增强：已开启。菜单 2 会使用这个状态。' }
        'disabled' { Write-Warn 'CCSwitch Codex 应用增强：已关闭。菜单 3/官方模式会使用这个状态。' }
        'unset' { Write-Warn 'CCSwitch Codex 应用增强：未设置。启动器会在菜单 2/3 自动写入。' }
        'missing' { Write-Warn "未找到 CCSwitch 设置文件：$Script:CCSwitchSettingsPath" }
        default { Write-Warn 'CCSwitch Codex 应用增强：无法安全识别。' }
    }

    if (Test-Path -LiteralPath $Script:DefaultCodexHome -PathType Container) {
        Write-Ok "默认 .codex 目录存在：$Script:DefaultCodexHome"
    } else {
        Write-Warn "默认 .codex 目录不存在：$Script:DefaultCodexHome"
    }

    if (Test-Path -LiteralPath $Script:CodexGlobalStatePath -PathType Leaf) {
        Write-Ok 'Codex 界面状态文件存在；启动器会在切换时保护工作模式等本地偏好。'
    } else {
        Write-Warn "未找到 Codex 界面状态文件：$Script:CodexGlobalStatePath"
    }

    if (Test-Path -LiteralPath $Script:CodexUiStateSnapshotPath -PathType Leaf) {
        Write-Ok "Codex 界面偏好快照存在：$Script:CodexUiStateSnapshotPath"
    } else {
        Write-Warn '尚未生成 Codex 界面偏好快照；下次通过菜单 1/2/3 切换时会自动生成。'
    }

    $authState = Get-AuthState -Path $Script:ActiveAuthPath
    switch ($authState) {
        'official-like' { Write-Ok '默认 auth.json 看起来是官方 ChatGPT/OAuth 登录态。' }
        'api-key-like' { Write-Warn '默认 auth.json 看起来是 API-key 登录态。' }
        'unknown' { Write-Warn '默认 auth.json 存在但无法安全识别。' }
        default { Write-Warn '默认 auth.json 不存在。' }
    }

    if (Test-ActiveConfigLooksCustom) {
        Write-Warn '默认 .codex config 当前看起来是第三方/custom 模式。'
    } else {
        Write-Ok '默认 .codex config 未发现 custom provider 路由。'
    }

    if ($state.OfficialProfileComplete) {
        Write-Ok "官方 profile 完整：$Script:OfficialProfileDir"
    } elseif ($state.OfficialProfilePartial) {
        Write-Warn "官方 profile 不完整：$Script:OfficialProfileDir"
    } else {
        Write-Warn "未保存官方 profile：$Script:OfficialProfileDir"
    }

    if ($state.ThirdPartyProfileComplete) {
        Write-Ok "第三方路由配置可用：$Script:ThirdPartyProfileDir"
    } elseif ($state.ThirdPartyProfilePartial) {
        Write-Warn "第三方路由配置不完整：$Script:ThirdPartyProfileDir"
    } else {
        Write-Warn "未保存第三方路由配置：$Script:ThirdPartyProfileDir"
    }

    if ($state.ThirdPartyPureProfileComplete) {
        Write-Ok '纯第三方/API-key 状态可用。'
    } else {
        Write-Warn '纯第三方/API-key 状态不完整；菜单 3 可能沿用当前登录文件。'
    }

    Write-Next '新电脑建议顺序：bootstrap -> official -> thirdparty-preserve-auth。'
}

function Invoke-Bootstrap {
    param($Config, [switch]$NoLaunch)

    Write-Host ''
    Write-Host "Codex Windows Launcher 初始化 $Script:LauncherVersion"
    Write-Host '-----------------------------'

    $state = Detect-ExistingLauncherState
    Write-Info "检测结果：$($state.StateKind)，风险级别：$($state.RiskLevel)"

    if ($state.LegacyShortcuts.Count -gt 0) {
        Write-Warn '检测到旧 Start Codex With CC Switch 快捷方式。bootstrap 只记录，不删除。'
        Backup-ShortcutMetadata -ShortcutPaths $state.LegacyShortcuts -Reason 'legacy-shortcuts-detected' -NoWrite:$NoLaunch
    }

    Write-LauncherConfigIfMissing -Config $Config -NoWrite:$NoLaunch
    New-LauncherShortcut -NoWrite:$NoLaunch

    Invoke-Doctor -Config (Read-LauncherConfig)

    Write-Next '如果 Codex 已安装，下一步运行官方模式并完成网页登录：.\codex-launcher.ps1 -Mode official'
    Write-Next '之后切换第三方时，启动器会自动安全保存可确认的官方登录状态。'
}

function Invoke-Check {
    param($Config)

    Invoke-Doctor -Config $Config
    return

    Write-Info "启动器配置：$Script:ConfigPath"
    Write-Info "Codex Desktop 当前实际读取的配置目录：$Script:DefaultCodexHome"
    Write-Info "已保存的第三方状态目录：$Script:ThirdPartyProfileDir"
    Write-Info "已保存的官方状态目录：$Script:OfficialProfileDir"

    if (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf) {
        if (Test-ActiveConfigLooksCustom) {
            Write-Warn '默认 .codex config 当前看起来是第三方/custom 模式。'
        } else {
            Write-Info '默认 .codex config 没有发现 custom provider 路由。'
        }
    } else {
        Write-Warn '未找到默认 .codex config.toml。'
    }

    if (Test-AuthLooksApiKey -Path $Script:ActiveAuthPath) {
        Write-Warn '默认 auth.json 当前看起来是 API-key 登录态，不是官方 ChatGPT 登录态。'
    } else {
        Write-Info '默认 auth.json 不像 API-key 登录态，或文件不存在。'
    }

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if ($codexTarget) {
        Write-Info "Codex 启动目标：$($codexTarget.Kind) $($codexTarget.Value)"
    } else {
        Write-Warn "未找到 Codex。请在 '$Script:ConfigPath' 里设置 codexPath。"
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    if ($ccswitchPath) {
        Write-Info "CCSwitch 路径：$ccswitchPath"
    } else {
        Write-Warn "未找到 CCSwitch。请在 '$Script:ConfigPath' 里设置 ccswitchPath。"
    }

    if (Test-Path -LiteralPath $Script:DefaultCodexHome -PathType Container) {
        Write-Info '默认 .codex 目录存在。'
    } else {
        Write-Warn '未找到默认 .codex 目录。'
    }

    if (Test-ProcessRunning -Path $ccswitchPath -Names $Script:CCSwitchProcessNames) {
        Write-Info 'CCSwitch 正在运行。'
    } else {
        Write-Warn 'CCSwitch 未运行。'
    }
}

function Start-OfficialMode {
    param($Config, [switch]$NoLaunch)

    Write-Info '菜单 1 阶段：开始官方模式切换。'
    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if (-not $codexTarget) {
        Write-ErrorLine '未检测到 Codex Desktop。请先安装 Codex Desktop，然后运行 .\codex-launcher.ps1 -Mode bootstrap'
        return
    }

    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    $codexProcessPath = $Config.codexPath
    if ($codexTarget -and $codexTarget.Kind -eq 'Exe') {
        $codexProcessPath = $codexTarget.Value
    }

    $ccswitchClosed = Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $ccswitchPath -FallbackNames $Script:CCSwitchProcessNames -ForceImmediately -NoLaunch:$NoLaunch
    $codexClosed = Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $codexProcessPath -FallbackNames $Script:CodexProcessNames -ForceImmediately -NoLaunch:$NoLaunch
    Write-Info "菜单 1 阶段：进程关闭结果 CCSwitch=$ccswitchClosed Codex=$codexClosed。"
    if (-not $ccswitchClosed -or -not $codexClosed) {
        Write-ErrorLine '官方模式未能完全关闭 Codex 或 CCSwitch，本次不会继续切换，避免历史同步和登录态恢复被旧进程覆盖。'
        Write-Next '请手动关闭 Codex 和 CCSwitch 后再选择菜单 1。'
        return
    }

    Write-Info '菜单 1 阶段：保存 UI 快照并关闭 CCSwitch Codex 增强。'
    Save-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Set-CCSwitchCodexEnhancement -Enabled $false -NoWrite:$NoLaunch | Out-Null

    Write-Info '菜单 1 阶段：恢复 official profile。'
    if (Restore-OfficialProfile -NoWrite:$NoLaunch) {
        Write-Info '已找到官方状态缓存；将恢复它，不强制重新登录。'
    } else {
        Write-Warn '没有已保存的官方状态。首次官方启动可能需要网页登录。'
        Repair-ActiveConfigForOfficial -NoWrite:$NoLaunch
        Disable-ApiKeyAuthForOfficial -NoWrite:$NoLaunch
    }

    Write-Info '菜单 1 阶段：强制 official provider=openai。'
    Set-OfficialConfigProviderOpenAI -NoWrite:$NoLaunch | Out-Null
    Write-Info '菜单 1 阶段：恢复 UI 快照。'
    Restore-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    Write-Info '菜单 1 阶段：检查并按需恢复聊天记录。'
    if (-not (Invoke-HistorySyncBeforeCodexLaunch -Config $Config -Reason '菜单 1 已恢复官方登录态，启动前同步聊天可见性。' -ExpectedProvider 'openai' -NoLaunch:$NoLaunch)) {
        return
    }

    Write-Info '菜单 1 阶段：启动 Codex。'
    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv $Script:ThirdPartyEnvVars -NoLaunch:$NoLaunch
}

function Ensure-CCSwitchRunning {
    param(
        [string]$Path,
        [switch]$NoLaunch
    )

    if (Test-ProcessRunning -Path $Path -Names $Script:CCSwitchProcessNames) {
        Write-Info 'CCSwitch 已经在运行。'
        return $true
    }

    if (-not (Test-ExecutablePath -Path $Path)) {
        Write-Warn "CCSwitch 未运行，也没有找到可执行文件。请在 '$Script:ConfigPath' 里设置 ccswitchPath。"
        Write-Next '官方模式仍可使用；第三方模式需要先安装并登录 CCSwitch。'
        return $false
    }

    if ($NoLaunch) {
        Write-Info "NoLaunch: 将会启动 CCSwitch：$Path"
        return $true
    }

    Write-Info "正在启动 CCSwitch：$Path"
    Start-Process -FilePath $Path | Out-Null
    return $true
}

function Restart-CCSwitchForThirdParty {
    param(
        [string]$Path,
        [int]$ReadyTimeoutSeconds = 20,
        [switch]$NoLaunch
    )

    Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $Path -FallbackNames $Script:CCSwitchProcessNames -ForceImmediately -NoLaunch:$NoLaunch | Out-Null

    if (-not $NoLaunch) {
        Start-Sleep -Milliseconds 800
    }

    if (-not (Ensure-CCSwitchRunning -Path $Path -NoLaunch:$NoLaunch)) {
        return $false
    }

    if ($NoLaunch) {
        Write-Info 'NoLaunch: 将会等待 CCSwitch 本地路由端口 127.0.0.1:15721 就绪。'
        return $true
    }

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-LocalPort -Port 15721) {
            Write-Ok 'CCSwitch 本地路由已就绪：127.0.0.1:15721'
            Start-Sleep -Seconds 2
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    Write-ErrorLine '未检测到本地路由监听：127.0.0.1:15721，本次不会启动 Codex，避免继续走官方额度。'
    Write-Next '请确认 CCSwitch 已开启本地路由/自定义路由后重试。'
    return $false
}

function Confirm-CCSwitchCodexEnhancement {
    param(
        [bool]$ExpectedEnabled,
        [switch]$NoLaunch
    )

    $expectedText = if ($ExpectedEnabled) { '开启' } else { '关闭' }
    if ($NoLaunch) {
        Write-Info "NoLaunch: 将会确认 CCSwitch Codex 应用增强已${expectedText}。"
        return $true
    }

    $state = Get-CCSwitchCodexEnhancementState
    if (($ExpectedEnabled -and $state -eq 'enabled') -or ((-not $ExpectedEnabled) -and $state -eq 'disabled')) {
        Write-Ok "CCSwitch Codex 应用增强已${expectedText}。"
        return $true
    }

    Write-ErrorLine "CCSwitch Codex 应用增强未能确认${expectedText}，本次不会启动 Codex，避免继续使用错误额度。"
    Write-Next "请打开 CCSwitch 设置页检查“Codex 应用增强 / 切换第三方时保留官方登录”，当前检测状态：$state"
    return $false
}

function Stop-ProcessesBeforeThirdPartySwitch {
    param(
        [string]$CodexPath,
        [string]$CCSwitchPath,
        [switch]$NoLaunch
    )

    Write-Info '正在切换第三方模式：先关闭 Codex 和 CCSwitch，确保新配置会被重新读取。'
    $codexClosed = Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $CodexPath -FallbackNames $Script:CodexProcessNames -TimeoutSeconds 10 -ForceImmediately -NoLaunch:$NoLaunch
    $ccswitchClosed = Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $CCSwitchPath -FallbackNames $Script:CCSwitchProcessNames -TimeoutSeconds 10 -ForceImmediately -NoLaunch:$NoLaunch

    if (-not $codexClosed -or -not $ccswitchClosed) {
        Write-ErrorLine 'Codex 或 CCSwitch 没有完全退出，已停止本次切换，避免继续使用旧路由/旧登录状态。'
        Write-Next '请手动关闭 Codex 和 CCSwitch 后再运行启动器。'
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
        Write-Info 'NoLaunch: 将会检查当前 config.toml 是否为第三方/CCSwitch 路由配置。'
        return $true
    }

    if (Test-ActiveConfigLooksThirdPartyRoute) {
        Write-Ok '当前 config.toml 已切换为第三方/CCSwitch 路由配置。'
        return $true
    }

    Write-ErrorLine '当前 config.toml 不像第三方/CCSwitch 路由配置，本次不会启动 Codex。'
    Write-Next "请先保存第三方路由配置，或检查 $Script:ThirdPartyProfileDir\config.toml。"
    return $false
}

function Start-ThirdPartyPreserveAuthMode {
    param($Config, [switch]$NoLaunch)

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if (-not $codexTarget) {
        Write-ErrorLine '未检测到 Codex Desktop。请先安装 Codex Desktop，然后运行 .\codex-launcher.ps1 -Mode bootstrap'
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
    Write-ActiveConfigProviderSummary -Stage '菜单2 restore-thirdparty-config 后'
    if (-not (Ensure-ThirdPartyCustomProviderConfig -NoWrite:$NoLaunch)) {
        Write-ErrorLine '无法修复第三方 custom provider 配置，本次不会启动 Codex。'
        return
    }
    Write-ActiveConfigProviderSummary -Stage '菜单2 custom-provider-repair 后'
    if (-not (Ensure-OfficialAuthForPreserveMode -NoWrite:$NoLaunch)) {
        Write-ErrorLine '菜单 2 需要可确认的官方登录态，本次不会启动 Codex。'
        Write-Next '请先选择菜单 1 完成官方登录，然后再选择菜单 2。'
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
        Write-ErrorLine 'CCSwitch 重启后未能恢复官方登录态，本次不会启动 Codex。'
        return
    }

    if (-not (Confirm-OfficialAuthForPreserveMode -NoLaunch:$NoLaunch)) {
        return
    }

    if (-not (Confirm-ThirdPartyRouteConfigReady -NoLaunch:$NoLaunch)) {
        return
    }

    Merge-PreservedCodexConfigSections -BaselineLines $configPreservationBaseline -NoWrite:$NoLaunch | Out-Null
    Write-ActiveConfigProviderSummary -Stage '菜单2 preserve-config-merge 后'
    if (-not (Set-PreserveAuthCustomProviderRequiresOfficialAuth -NoWrite:$NoLaunch)) {
        return
    }
    Write-ActiveConfigProviderSummary -Stage '菜单2 requires-openai-auth 后'

    if (-not (Confirm-ThirdPartyRouteConfigReady -NoLaunch:$NoLaunch)) {
        return
    }

    Restore-CodexUiStateSnapshot -NoWrite:$NoLaunch | Out-Null
    if (-not (Invoke-HistorySyncBeforeCodexLaunch -Config $Config -Reason '菜单 2 已确认官方登录和第三方路由，启动前同步聊天可见性。' -ExpectedProvider 'custom' -NoLaunch:$NoLaunch)) {
        return
    }

    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv @('CODEX_HOME') -NoLaunch:$NoLaunch
}

function Start-ThirdPartyPureMode {
    param($Config, [switch]$NoLaunch)

    if (-not (Test-ProfileComplete -ProfileDir $Script:ThirdPartyProfileDir -Files @('config.toml', 'auth.json'))) {
        Write-ErrorLine '纯第三方/API-key 状态不完整：需要 thirdparty profile 同时包含 config.toml 和 auth.json。'
        Write-Next '如果只想使用第三方路由并保留官方登录，请选择菜单 2。'
        return
    }

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    if (-not $codexTarget) {
        Write-ErrorLine '未检测到 Codex Desktop。请先安装 Codex Desktop，然后运行 .\codex-launcher.ps1 -Mode bootstrap'
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

    Write-Warn 'thirdparty 命令已作为兼容别名处理：等同于 thirdparty-preserve-auth。'
    Start-ThirdPartyPreserveAuthMode -Config $Config -NoLaunch:$NoLaunch
}

function Show-Menu {
    param($Config)

    while ($true) {
        Write-Host ''
        Write-Host '=============================='
        Write-Host " Codex Windows 启动器 $Script:LauncherVersion"
        Write-Host '=============================='
        Write-Host '1. 官方模式：恢复官方登录态并启动 Codex'
        Write-Host '   - 首次可能需要网页登录；之后会自动安全保存并复用官方状态。'
        Write-Host '2. 第三方模式：保留官方登录信息并使用第三方路由'
        Write-Host '   - 日常推荐；只切换路由配置，不恢复第三方 auth.json。'
        Write-Host '3. 第三方模式：纯第三方/API-key'
        Write-Host '   - 备用模式；可恢复第三方 auth.json，但不会覆盖官方缓存。'
        Write-Host '4. 诊断/体检当前状态'
        Write-Host '   - 只读检查，不修改任何文件。'
        Write-Host '5. 初始化/升级本机启动器'
        Write-Host '   - 创建配置和桌面快捷方式，不删除旧数据。'
        Write-Host '6. 退出'
        $choice = Read-Host '请输入数字'

        switch ($choice) {
            '1' { Start-OfficialMode -Config $Config -NoLaunch:$NoLaunch; return }
            '2' { Start-ThirdPartyPreserveAuthMode -Config $Config -NoLaunch:$NoLaunch; return }
            '3' { Start-ThirdPartyPureMode -Config $Config -NoLaunch:$NoLaunch; return }
            '4' { Invoke-Doctor -Config (Read-LauncherConfig); if ($NoLaunch) { return } }
            '5' { Invoke-Bootstrap -Config $Config -NoLaunch:$NoLaunch; return }
            '6' { return }
            default { Write-Warn '请输入 1、2、3、4、5 或 6。' }
        }
    }
}

Write-Info "启动器版本：$Script:LauncherVersion；Mode=$Mode；NoLaunch=$NoLaunch"
Write-Info "本次日志文件：$Script:RunLogPath"

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

