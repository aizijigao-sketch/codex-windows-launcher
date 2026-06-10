param(
    [ValidateSet('official', 'thirdparty', 'thirdparty-preserve-auth', 'thirdparty-pure', 'check', 'doctor', 'bootstrap', 'menu')]
    [string]$Mode = 'menu',

    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:LauncherVersion = 'v0.4.1'

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
        foreach ($name in @('codexPath', 'ccswitchPath')) {
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
        notes = @(
            'This file is machine-local and must not contain secrets.',
            'Set codexPath or ccswitchPath only when auto-discovery fails.',
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
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
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
            Start-AppIdTarget -AppId $Target.Value
        } else {
            Start-Process -FilePath $Target.Value | Out-Null
        }
    } finally {
        Restore-ProcessEnv -Snapshot $snapshot
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
        Write-Info "NoLaunch: 将会备份 CCSwitch 设置到本机目录：$backupPath"
        return $backupPath
    }

    Ensure-Directory -Path $Script:CCSwitchBackupDir
    Copy-Item -LiteralPath $Script:CCSwitchSettingsPath -Destination $backupPath -Force
    Write-Info '已备份 CCSwitch 设置文件到本机 .cc-switch\backups。'
    return $backupPath
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

    Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $ccswitchPath -FallbackNames $Script:CCSwitchProcessNames -NoLaunch:$NoLaunch | Out-Null
    Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $codexProcessPath -FallbackNames $Script:CodexProcessNames -NoLaunch:$NoLaunch | Out-Null
    Set-CCSwitchCodexEnhancement -Enabled $false -NoWrite:$NoLaunch | Out-Null

    if (Restore-OfficialProfile -NoWrite:$NoLaunch) {
        Write-Info '已找到官方状态缓存；将恢复它，不强制重新登录。'
    } else {
        Write-Warn '没有已保存的官方状态。首次官方启动可能需要网页登录。'
        Repair-ActiveConfigForOfficial -NoWrite:$NoLaunch
        Disable-ApiKeyAuthForOfficial -NoWrite:$NoLaunch
    }

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

    Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $Path -FallbackNames $Script:CCSwitchProcessNames -NoLaunch:$NoLaunch | Out-Null

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
    $codexClosed = Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $CodexPath -FallbackNames $Script:CodexProcessNames -TimeoutSeconds 10 -NoLaunch:$NoLaunch
    $ccswitchClosed = Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $CCSwitchPath -FallbackNames $Script:CCSwitchProcessNames -TimeoutSeconds 10 -NoLaunch:$NoLaunch

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

    Save-OfficialProfileIfCurrentLooksOfficial -NoWrite:$NoLaunch | Out-Null
    Restore-ThirdPartyConfig -NoWrite:$NoLaunch | Out-Null
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

