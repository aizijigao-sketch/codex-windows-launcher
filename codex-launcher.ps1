param(
    [ValidateSet('official', 'thirdparty', 'saveofficial', 'check', 'menu')]
    [string]$Mode = 'menu',

    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Load-LauncherConfig {
    Ensure-Directory -Path $Script:LauncherHome

    $defaults = New-Object PSObject -Property @{
        codexPath = ''
        ccswitchPath = ''
    }

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
    if ($expanded -match '(?i)History\s*Sync|CodexHistorySync|codex-windows-launcher|start-codex-with-ccswitch') {
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName($expanded)
    if ($fileName -notin @('Codex.exe', 'OpenAI Codex.exe')) {
        return $false
    }

    return $true
}

function Resolve-CodexLaunchTarget {
    param($Config)

    if (Test-CodexExecutableCandidate -Path $Config.codexPath) {
        return New-Object PSObject -Property @{
            Kind = 'Exe'
            Value = [Environment]::ExpandEnvironmentVariables($Config.codexPath)
        }
    }

    $appId = Find-CodexStartAppId
    if ($appId) {
        return New-Object PSObject -Property @{ Kind = 'AppId'; Value = $appId }
    }

    $roots = @(
        'C:\Program Files\WindowsApps',
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
    $exe = Find-ExecutableByName -Names @('Codex.exe', 'OpenAI Codex.exe') -Roots $roots
    if (Test-CodexExecutableCandidate -Path $exe) {
        return New-Object PSObject -Property @{ Kind = 'Exe'; Value = $exe }
    }

    $shortcutTarget = Find-ShortcutTarget -NamePatterns @('Codex', 'OpenAI Codex')
    if (Test-CodexExecutableCandidate -Path $shortcutTarget) {
        return New-Object PSObject -Property @{ Kind = 'Exe'; Value = $shortcutTarget }
    }

    return $null
}

function Resolve-CCSwitchPath {
    param($Config)

    if (Test-ExecutablePath -Path $Config.ccswitchPath) {
        return [Environment]::ExpandEnvironmentVariables($Config.ccswitchPath)
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
        return
    }

    foreach ($proc in $matches) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-Warn "Could not close $DisplayName process $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
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
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $Target.Value) | Out-Null
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
        [switch]$NoWrite
    )

    if (-not $NoWrite) {
        Ensure-Directory -Path $ProfileDir
    }

    $saved = $false
    foreach ($name in @('config.toml', 'auth.json')) {
        $source = Join-Path $Script:DefaultCodexHome $name
        $target = Join-Path $ProfileDir $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            if ($NoWrite) {
                Write-Info "NoLaunch: would save $ProfileName profile file $name"
            } else {
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
        [switch]$NoWrite
    )

    $restored = $false
    foreach ($name in @('config.toml', 'auth.json')) {
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

function Restore-ThirdPartyProfile {
    param([switch]$NoWrite)

    $restored = Restore-ProfileFiles -ProfileName 'thirdparty' -ProfileDir $Script:ThirdPartyProfileDir -NoWrite:$NoWrite
    if (-not $restored) {
        Write-Warn '没有找到已保存的第三方状态；第三方模式会沿用当前默认 .codex 状态。'
    }
}

function Test-AuthLooksApiKey {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $auth = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
        $names = @($auth.PSObject.Properties.Name)
        if ($names -contains 'auth_mode') {
            $mode = [string]$auth.auth_mode
            if ($mode -eq 'chatgpt') {
                return $false
            }
        }
        return ($names -contains 'OPENAI_API_KEY')
    } catch {
        Write-Warn "Could not parse auth.json metadata. It will be backed up for official sign-in."
        return $true
    }
}

function Test-ActiveConfigLooksCustom {
    if (-not (Test-Path -LiteralPath $Script:ActiveConfigPath -PathType Leaf)) {
        return $false
    }

    return (Select-String -LiteralPath $Script:ActiveConfigPath -Pattern 'model_provider\s*=\s*"custom"|\[model_providers\.custom\]|127\.0\.0\.1:15721|base_url\s*=' -Quiet)
}

function Test-CurrentLooksOfficialProfile {
    if (-not (Test-Path -LiteralPath $Script:ActiveAuthPath -PathType Leaf)) {
        return $false
    }

    if (Test-AuthLooksApiKey -Path $Script:ActiveAuthPath) {
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

function Disable-ApiKeyAuthForOfficial {
    param([switch]$NoWrite)

    if (-not (Test-Path -LiteralPath $Script:ActiveAuthPath -PathType Leaf)) {
        Write-Info '未找到默认 auth.json；Codex 应该会要求官方登录。'
        return
    }

    if (-not (Test-AuthLooksApiKey -Path $Script:ActiveAuthPath)) {
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

function Invoke-Check {
    param($Config)

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
    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    $codexProcessPath = $Config.codexPath
    if ($codexTarget -and $codexTarget.Kind -eq 'Exe') {
        $codexProcessPath = $codexTarget.Value
    }

    Stop-LauncherProcess -DisplayName 'CCSwitch' -PreferredPath $ccswitchPath -FallbackNames $Script:CCSwitchProcessNames -NoLaunch:$NoLaunch
    Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $codexProcessPath -FallbackNames $Script:CodexProcessNames -NoLaunch:$NoLaunch

    if (Restore-OfficialProfile -NoWrite:$NoLaunch) {
        Write-Info '已找到官方状态缓存；将恢复它，不强制重新登录。'
    } else {
        Write-Warn '没有已保存的官方状态。首次官方启动可能需要网页登录。'
        Repair-ActiveConfigForOfficial -NoWrite:$NoLaunch
        Disable-ApiKeyAuthForOfficial -NoWrite:$NoLaunch
    }

    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv $Script:ThirdPartyEnvVars -NoLaunch:$NoLaunch
}

function Save-CurrentAsOfficialMode {
    param([switch]$NoLaunch)

    Save-OfficialProfileIfCurrentLooksOfficial -NoWrite:$NoLaunch | Out-Null
}

function Ensure-CCSwitchRunning {
    param(
        [string]$Path,
        [switch]$NoLaunch
    )

    if (Test-ProcessRunning -Path $Path -Names $Script:CCSwitchProcessNames) {
        Write-Info 'CCSwitch 已经在运行。'
        return
    }

    if (-not (Test-ExecutablePath -Path $Path)) {
        throw "CCSwitch 未运行，也没有找到可执行文件。请在 '$Script:ConfigPath' 里设置 ccswitchPath。"
    }

    if ($NoLaunch) {
        Write-Info "NoLaunch: 将会启动 CCSwitch：$Path"
        return
    }

    Write-Info "正在启动 CCSwitch：$Path"
    Start-Process -FilePath $Path | Out-Null
}

function Start-ThirdPartyMode {
    param($Config, [switch]$NoLaunch)

    $codexTarget = Resolve-CodexLaunchTarget -Config $Config
    $ccswitchPath = Resolve-CCSwitchPath -Config $Config
    $codexProcessPath = $Config.codexPath
    if ($codexTarget -and $codexTarget.Kind -eq 'Exe') {
        $codexProcessPath = $codexTarget.Value
    }

    Ensure-CCSwitchRunning -Path $ccswitchPath -NoLaunch:$NoLaunch
    Stop-LauncherProcess -DisplayName 'Codex' -PreferredPath $codexProcessPath -FallbackNames $Script:CodexProcessNames -NoLaunch:$NoLaunch
    Save-OfficialProfileIfCurrentLooksOfficial -NoWrite:$NoLaunch | Out-Null
    Restore-ThirdPartyProfile -NoWrite:$NoLaunch

    if (-not $NoLaunch) {
        Start-Sleep -Seconds 1
    }

    Start-LaunchTarget -Target $codexTarget -SetEnv @{} -RemoveEnv @('CODEX_HOME') -NoLaunch:$NoLaunch
}

function Show-Menu {
    param($Config)

    while ($true) {
        Write-Host ''
        Write-Host '=============================='
        Write-Host ' Codex Windows 启动器'
        Write-Host '=============================='
        Write-Host '1. 官方模式：恢复官方登录态并启动 Codex'
        Write-Host '   - 首次可能需要网页登录；保存过官方状态后会复用，不应每次登录。'
        Write-Host '2. 第三方模式：恢复 CCSwitch/custom 状态并重载 Codex'
        Write-Host '   - 切换前如果当前是官方态，会自动保存官方状态。'
        Write-Host '3. 保存当前为官方状态'
        Write-Host '   - 官方网页登录成功后点一次；当前若是第三方/API-key 状态不会保存。'
        Write-Host '4. 检查当前状态'
        Write-Host '5. 退出'
        $choice = Read-Host '请输入数字'

        switch ($choice) {
            '1' { Start-OfficialMode -Config $Config -NoLaunch:$NoLaunch; return }
            '2' { Start-ThirdPartyMode -Config $Config -NoLaunch:$NoLaunch; return }
            '3' { Save-CurrentAsOfficialMode -NoLaunch:$NoLaunch; return }
            '4' { Invoke-Check -Config $Config; if ($NoLaunch) { return } }
            '5' { return }
            default { Write-Warn '请输入 1、2、3、4 或 5。' }
        }
    }
}

$config = Load-LauncherConfig

switch ($Mode) {
    'official' { Start-OfficialMode -Config $config -NoLaunch:$NoLaunch }
    'thirdparty' { Start-ThirdPartyMode -Config $config -NoLaunch:$NoLaunch }
    'saveofficial' { Save-CurrentAsOfficialMode -NoLaunch:$NoLaunch }
    'check' { Invoke-Check -Config $config }
    'menu' { Show-Menu -Config $config }
}

