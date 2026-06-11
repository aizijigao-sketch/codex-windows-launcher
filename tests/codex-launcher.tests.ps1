Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$LauncherPath = Join-Path $ProjectRoot 'codex-launcher.ps1'
$ReadmePath = Join-Path $ProjectRoot 'README.md'
$ExampleConfigPath = Join-Path $ProjectRoot 'launcher-config.example.json'

function Assert-ContainsText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if ($Text -notmatch $Pattern) {
        throw "Expected text to match pattern: $Pattern"
    }
}

function Assert-DoesNotContainText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if ($Text -match $Pattern) {
        throw "Expected text not to match pattern: $Pattern"
    }
}

function Assert-ArrayContains {
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    if ($Expected -notin $Items) {
        throw "Expected array to contain: $Expected"
    }
}

Describe 'Codex Windows launcher documentation and configuration' {
    BeforeAll {
        $script:Readme = Get-Content -Raw -LiteralPath $ReadmePath
        $script:ExampleConfigRaw = Get-Content -Raw -LiteralPath $ExampleConfigPath
        $script:ExampleConfig = $script:ExampleConfigRaw | ConvertFrom-Json
    }

    It 'documents official and third-party modes' {
        Assert-ContainsText $script:Readme '官方模式'
        Assert-ContainsText $script:Readme '第三方模式'
        Assert-ContainsText $script:Readme 'bootstrap'
        Assert-ContainsText $script:Readme 'doctor'
        Assert-ContainsText $script:Readme '\.codex'
        Assert-ContainsText $script:Readme 'CCSwitch'
        Assert-ContainsText $script:Readme 'profiles'
        Assert-ContainsText $script:Readme '保留官方登录'
        Assert-ContainsText $script:Readme '纯第三方'
        Assert-DoesNotContainText $script:Readme 'saveofficial|保存当前为官方状态|网页登录成功后点一次'
    }

    It 'documents first use and safety boundaries' {
        Assert-ContainsText $script:Readme '首次使用流程'
        Assert-ContainsText $script:Readme '安全边界'
        Assert-ContainsText $script:Readme 'auth\.json'
        Assert-ContainsText $script:Readme 'OAuth tokens into API keys|OAuth token.*API key|转换'
    }

    It 'documents company shortcut cleanup while preserving CCSwitch data' {
        Assert-ContainsText $script:Readme 'Start Codex With CC Switch'
        Assert-ContainsText $script:Readme 'Desktop'
        Assert-ContainsText $script:Readme 'Start Menu'
        Assert-ContainsText $script:Readme '\.cc-switch'
        Assert-ContainsText $script:Readme 'do not delete|不要删除|不允许'
    }

    It 'keeps the example config free of obvious secrets' {
        Assert-DoesNotContainText $script:ExampleConfigRaw '(?i)sk-[a-z0-9]'
        Assert-DoesNotContainText $script:ExampleConfigRaw '(?i)api[_-]?key"\s*:\s*"[^"]+'
        Assert-DoesNotContainText $script:ExampleConfigRaw '(?i)token"\s*:\s*"[^"]+'
        Assert-DoesNotContainText $script:ExampleConfigRaw '(?i)password"\s*:\s*"[^"]+'
    }

    It 'keeps the example config limited to path hints and notes' {
        Assert-ContainsText $script:ExampleConfigRaw '"codexPath"'
        Assert-ContainsText $script:ExampleConfigRaw '"ccswitchPath"'
        Assert-DoesNotContainText $script:ExampleConfigRaw '"officialCleanConfig"'
        Assert-DoesNotContainText $script:ExampleConfigRaw 'gpt-5\.1'
    }
}

Describe 'codex-launcher.ps1 static safety checks' {
    BeforeAll {
        if (Test-Path -LiteralPath $LauncherPath) {
            $script:Launcher = Get-Content -Raw -LiteralPath $LauncherPath
            $parseErrors = $null
            $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($LauncherPath, [ref] $null, [ref] $parseErrors)
            $script:ParseErrors = $parseErrors
        }
        else {
            $script:Launcher = $null
            $script:Ast = $null
            $script:ParseErrors = @()
        }
    }

    It 'parses when the launcher script exists' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping launcher parse check because codex-launcher.ps1 is not present.'
            return
        }

        if ($script:ParseErrors) {
            throw ($script:ParseErrors | ForEach-Object { $_.Message } | Out-String)
        }
    }

    It 'does not contain token-copying or exfiltration keywords' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping launcher token safety check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-DoesNotContainText $script:Launcher '(?i)refresh[_-]?token'
        Assert-DoesNotContainText $script:Launcher '(?i)oauth.*api\s*key'
        Assert-DoesNotContainText $script:Launcher '(?i)upload.*token'
        Assert-DoesNotContainText $script:Launcher '(?i)export.*auth\.json'
        Assert-DoesNotContainText $script:Launcher '(?i)Invoke-WebRequest|curl|scp|sftp'
    }

    It 'keeps third-party mode from setting CODEX_HOME' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping CODEX_HOME check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'CODEX_HOME'
        Assert-ContainsText $script:Launcher '(?i)Remove.*CODEX_HOME|CODEX_HOME.*Remove|CODEX_HOME.*null'
    }

    It 'supports saving and restoring official profile cache' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping official profile cache check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Save-OfficialProfile'
        Assert-ContainsText $script:Launcher 'Restore-OfficialProfile'
        Assert-ContainsText $script:Launcher 'Save-OfficialProfileIfCurrentLooksOfficial'
        Assert-ContainsText $script:Launcher 'Test-CurrentLooksOfficialProfile'
        Assert-ContainsText $script:Launcher 'Ensure-OfficialAuthForPreserveMode'
        Assert-ContainsText $script:Launcher 'Restore-OfficialAuthOnly'
        Assert-ContainsText $script:Launcher 'before-\$ProfileName-save'
    }

    It 'supports bootstrap and read-only doctor modes' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping bootstrap/doctor check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher "ValidateSet\('official', 'thirdparty', 'thirdparty-preserve-auth', 'thirdparty-pure', 'check', 'doctor', 'bootstrap', 'menu'\)"
        Assert-DoesNotContainText $script:Launcher "'saveofficial'"
        Assert-ContainsText $script:Launcher 'Invoke-Bootstrap'
        Assert-ContainsText $script:Launcher 'Invoke-Doctor'
        Assert-ContainsText $script:Launcher '\$Script:LauncherVersion = ''v0\.4\.2'''
        Assert-ContainsText $script:Launcher 'Codex Windows 启动器 \$Script:LauncherVersion'
        Assert-ContainsText $script:Launcher 'Codex Windows Launcher 诊断 \$Script:LauncherVersion'
        Assert-ContainsText $script:Launcher "Mode -in @\('check', 'doctor'\)"
        Assert-ContainsText $script:Launcher 'Read-LauncherConfig'
        Assert-ContainsText $script:Launcher 'Write-LauncherConfigIfMissing'
        Assert-ContainsText $script:Launcher 'New-LauncherShortcut'
    }

    It 'prefers a real Codex executable before AppId fallback' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping Codex launch target preference check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Find-CodexExecutable'
        Assert-ContainsText $script:Launcher 'Find-CodexAppxExecutable'
        Assert-ContainsText $script:Launcher 'Get-AppxPackage'
        Assert-ContainsText $script:Launcher 'AppxManifest\.xml'
        Assert-ContainsText $script:Launcher 'app\\Codex\.exe'
        Assert-ContainsText $script:Launcher 'Codex.exe'
        Assert-ContainsText $script:Launcher 'OpenAI Codex.exe'
        Assert-ContainsText $script:Launcher 'bin\\\\codex'
        Assert-DoesNotContainText $script:Launcher 'OpenAI\\\\Codex\\\\bin\\\\codex\.exe'
        Assert-ContainsText $script:Launcher 'Find-CodexStartAppId'
        $exeIndex = $script:Launcher.IndexOf('$exe = Find-CodexExecutable -Config $Config')
        $appIdIndex = $script:Launcher.IndexOf('$appId = Find-CodexStartAppId')
        if ($exeIndex -lt 0 -or $appIdIndex -lt 0 -or $exeIndex -gt $appIdIndex) {
            throw 'Resolve-CodexLaunchTarget must prefer a real Codex executable before AppId fallback.'
        }
        $appxIndex = $script:Launcher.IndexOf('$appxExe = Find-CodexAppxExecutable')
        $commonPathIndex = $script:Launcher.IndexOf('$commonPaths = @(')
        if ($appxIndex -lt 0 -or $commonPathIndex -lt 0 -or $appxIndex -gt $commonPathIndex) {
            throw 'Find-CodexExecutable must try the AppX Desktop executable before broad path scanning.'
        }
    }

    It 'avoids AppId launch attempts from an elevated window' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping elevated AppId check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Test-IsElevated'
        Assert-ContainsText $script:Launcher '当前是管理员窗口，无法可靠通过 Windows AppId 启动 Codex'
        Assert-ContainsText $script:Launcher '真实 Codex Desktop 的 codexPath'
    }

    It 'splits third-party modes by auth preservation behavior' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping third-party mode split check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Start-ThirdPartyPreserveAuthMode'
        Assert-ContainsText $script:Launcher 'Start-ThirdPartyPureMode'
        Assert-ContainsText $script:Launcher 'Restore-ThirdPartyConfig'
        Assert-ContainsText $script:Launcher 'Restore-ThirdPartyPureProfile'
        Assert-ContainsText $script:Launcher 'Stop-ProcessesBeforeThirdPartySwitch'
        Assert-ContainsText $script:Launcher 'Confirm-ThirdPartyRouteConfigReady'
        Assert-ContainsText $script:Launcher 'Set-CCSwitchCodexEnhancement'
        Assert-ContainsText $script:Launcher 'Confirm-CCSwitchCodexEnhancement'
        Assert-ContainsText $script:Launcher 'preserveCodexOfficialAuthOnSwitch'
        Assert-ContainsText $script:Launcher 'Confirm-OfficialAuthForPreserveMode'
        Assert-ContainsText $script:Launcher '最终 auth.json 已确认是官方 ChatGPT/OAuth 登录态'
        Assert-ContainsText $script:Launcher 'Test-ActiveConfigLooksThirdPartyRoute'
        Assert-ContainsText $script:Launcher 'Get-RunningExecutablePathByNames'
        Assert-ContainsText $script:Launcher '确保新配置会被重新读取'
        Assert-ContainsText $script:Launcher '已停止本次切换，避免继续使用旧路由/旧登录状态'
        Assert-ContainsText $script:Launcher '本次不会启动 Codex'
        Assert-ContainsText $script:Launcher '纯第三方/API-key 状态不完整'
        Assert-ContainsText $script:Launcher "Files = @\('config\.toml', 'auth\.json'\)"
        Assert-ContainsText $script:Launcher 'Restore-ProfileFiles -ProfileName ''thirdparty'' -ProfileDir \$Script:ThirdPartyProfileDir -Files @\(''config\.toml''\)'
        Assert-ContainsText $script:Launcher 'Ensure-OfficialAuthForPreserveMode'

        $preserveStart = $script:Launcher.IndexOf('function Start-ThirdPartyPreserveAuthMode')
        $pureStart = $script:Launcher.IndexOf('function Start-ThirdPartyPureMode')
        if ($preserveStart -lt 0 -or $pureStart -lt 0 -or $preserveStart -gt $pureStart) {
            throw 'Third-party preserve-auth and pure mode functions must exist in the expected order.'
        }
        $preserveBody = $script:Launcher.Substring($preserveStart, $pureStart - $preserveStart)
        if ($preserveBody -match 'Restore-ThirdPartyPureProfile|Restore-ThirdPartyProfile') {
            throw 'Preserve-auth mode must not restore third-party auth.json.'
        }

        $prepIndex = $preserveBody.IndexOf('Stop-ProcessesBeforeThirdPartySwitch')
        $restoreIndex = $preserveBody.IndexOf('Restore-ThirdPartyConfig')
        $enableIndex = $preserveBody.IndexOf('Set-CCSwitchCodexEnhancement -Enabled $true')
        $confirmIndex = $preserveBody.IndexOf('Confirm-ThirdPartyRouteConfigReady')
        $restartIndex = $preserveBody.IndexOf('Restart-CCSwitchForThirdParty')
        $enhanceConfirmIndex = $preserveBody.IndexOf('Confirm-CCSwitchCodexEnhancement -ExpectedEnabled $true')
        $firstAuthIndex = $preserveBody.IndexOf('Ensure-OfficialAuthForPreserveMode')
        $secondAuthIndex = $preserveBody.IndexOf('Ensure-OfficialAuthForPreserveMode', $firstAuthIndex + 1)
        $officialConfirmIndex = $preserveBody.IndexOf('Confirm-OfficialAuthForPreserveMode')
        if ($prepIndex -lt 0 -or $restoreIndex -lt 0 -or $firstAuthIndex -lt 0 -or $enableIndex -lt 0 -or $restartIndex -lt 0 -or $enhanceConfirmIndex -lt 0 -or $secondAuthIndex -lt 0 -or $officialConfirmIndex -lt 0 -or $confirmIndex -lt 0 -or $prepIndex -gt $restoreIndex -or $restoreIndex -gt $firstAuthIndex -or $firstAuthIndex -gt $enableIndex -or $enableIndex -gt $restartIndex -or $restartIndex -gt $enhanceConfirmIndex -or $enhanceConfirmIndex -gt $secondAuthIndex -or $secondAuthIndex -gt $officialConfirmIndex -or $officialConfirmIndex -gt $confirmIndex) {
            throw 'Preserve-auth mode must close Codex/CCSwitch, restore config, restore official auth, enable CCSwitch Codex enhancement, restart CCSwitch, then re-restore and confirm official auth before route config.'
        }

        $pureEnd = $script:Launcher.IndexOf('function Start-ThirdPartyMode')
        $pureBody = $script:Launcher.Substring($pureStart, $pureEnd - $pureStart)
        if ($pureBody -notmatch "Test-ProfileComplete -ProfileDir \`$Script:ThirdPartyProfileDir -Files @\('config\.toml', 'auth\.json'\)") {
            throw 'Pure third-party mode must require both config.toml and auth.json before switching.'
        }
        $purePrepIndex = $pureBody.IndexOf('Stop-ProcessesBeforeThirdPartySwitch')
        $pureRestoreIndex = $pureBody.IndexOf('Restore-ThirdPartyPureProfile')
        $pureDisableIndex = $pureBody.IndexOf('Set-CCSwitchCodexEnhancement -Enabled $false')
        $pureConfirmIndex = $pureBody.IndexOf('Confirm-ThirdPartyRouteConfigReady')
        $pureRestartIndex = $pureBody.IndexOf('Restart-CCSwitchForThirdParty')
        $pureEnhanceConfirmIndex = $pureBody.IndexOf('Confirm-CCSwitchCodexEnhancement -ExpectedEnabled $false')
        if ($purePrepIndex -lt 0 -or $pureRestoreIndex -lt 0 -or $pureDisableIndex -lt 0 -or $pureRestartIndex -lt 0 -or $pureEnhanceConfirmIndex -lt 0 -or $pureConfirmIndex -lt 0 -or $purePrepIndex -gt $pureRestoreIndex -or $pureRestoreIndex -gt $pureDisableIndex -or $pureDisableIndex -gt $pureRestartIndex -or $pureRestartIndex -gt $pureEnhanceConfirmIndex -or $pureEnhanceConfirmIndex -gt $pureConfirmIndex) {
            throw 'Pure third-party mode must close Codex/CCSwitch, restore config/auth, disable CCSwitch Codex enhancement, restart CCSwitch, then confirm enhancement and route config.'
        }
    }

    It 'preserves safe Codex UI preferences across mode switches' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping Codex UI preference preservation check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher '\.codex-global-state\.json'
        Assert-ContainsText $script:Launcher 'codex-ui-state\.json'
        Assert-ContainsText $script:Launcher 'Save-CodexUiStateSnapshot'
        Assert-ContainsText $script:Launcher 'Restore-CodexUiStateSnapshot'
        Assert-ContainsText $script:Launcher 'agent-mode-by-host-id'
        Assert-ContainsText $script:Launcher 'composer-auto-context-enabled'
        Assert-ContainsText $script:Launcher 'sidebar-width'
        Assert-ContainsText $script:Launcher 'skip-full-access-confirm'
        Assert-ContainsText $script:Launcher 'Codex 界面偏好快照'
        Assert-DoesNotContainText $script:Launcher "CodexUiStateAtomKeys = @\([^)]*prompt-history"
        Assert-DoesNotContainText $script:Launcher "CodexUiStateAtomKeys = @\([^)]*auth"
        Assert-DoesNotContainText $script:Launcher "CodexUiStateAtomKeys = @\([^)]*token"

        $officialStart = $script:Launcher.IndexOf('function Start-OfficialMode')
        $ensureStart = $script:Launcher.IndexOf('function Ensure-CCSwitchRunning')
        $officialBody = $script:Launcher.Substring($officialStart, $ensureStart - $officialStart)
        $officialSaveIndex = $officialBody.IndexOf('Save-CodexUiStateSnapshot')
        $officialRestoreProfileIndex = $officialBody.IndexOf('Restore-OfficialProfile')
        $officialRestoreUiIndex = $officialBody.IndexOf('Restore-CodexUiStateSnapshot')
        $officialLaunchIndex = $officialBody.IndexOf('Start-LaunchTarget')
        if ($officialSaveIndex -lt 0 -or $officialRestoreProfileIndex -lt 0 -or $officialRestoreUiIndex -lt 0 -or $officialLaunchIndex -lt 0 -or $officialSaveIndex -gt $officialRestoreProfileIndex -or $officialRestoreProfileIndex -gt $officialRestoreUiIndex -or $officialRestoreUiIndex -gt $officialLaunchIndex) {
            throw 'Official mode must save UI preferences, restore profile, restore UI preferences, then launch Codex.'
        }

        $preserveStart = $script:Launcher.IndexOf('function Start-ThirdPartyPreserveAuthMode')
        $pureStart = $script:Launcher.IndexOf('function Start-ThirdPartyPureMode')
        $preserveBody = $script:Launcher.Substring($preserveStart, $pureStart - $preserveStart)
        $preserveSaveIndex = $preserveBody.IndexOf('Save-CodexUiStateSnapshot')
        $preserveRestoreConfigIndex = $preserveBody.IndexOf('Restore-ThirdPartyConfig')
        $preserveRestoreUiIndex = $preserveBody.IndexOf('Restore-CodexUiStateSnapshot')
        $preserveLaunchIndex = $preserveBody.IndexOf('Start-LaunchTarget')
        if ($preserveSaveIndex -lt 0 -or $preserveRestoreConfigIndex -lt 0 -or $preserveRestoreUiIndex -lt 0 -or $preserveLaunchIndex -lt 0 -or $preserveSaveIndex -gt $preserveRestoreConfigIndex -or $preserveRestoreConfigIndex -gt $preserveRestoreUiIndex -or $preserveRestoreUiIndex -gt $preserveLaunchIndex) {
            throw 'Preserve-auth mode must save UI preferences before switching and restore them before launch.'
        }

        $pureEnd = $script:Launcher.IndexOf('function Start-ThirdPartyMode')
        $pureBody = $script:Launcher.Substring($pureStart, $pureEnd - $pureStart)
        $pureSaveIndex = $pureBody.IndexOf('Save-CodexUiStateSnapshot')
        $pureRestoreProfileIndex = $pureBody.IndexOf('Restore-ThirdPartyPureProfile')
        $pureRestoreUiIndex = $pureBody.IndexOf('Restore-CodexUiStateSnapshot')
        $pureLaunchIndex = $pureBody.IndexOf('Start-LaunchTarget')
        if ($pureSaveIndex -lt 0 -or $pureRestoreProfileIndex -lt 0 -or $pureRestoreUiIndex -lt 0 -or $pureLaunchIndex -lt 0 -or $pureSaveIndex -gt $pureRestoreProfileIndex -or $pureRestoreProfileIndex -gt $pureRestoreUiIndex -or $pureRestoreUiIndex -gt $pureLaunchIndex) {
            throw 'Pure third-party mode must save UI preferences before switching and restore them before launch.'
        }
    }

    It 'waits for Codex and CCSwitch to exit before third-party switching' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping third-party process cleanup check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'TimeoutSeconds = 8'
        Assert-ContainsText $script:Launcher 'Test-ProcessRunning -Path \$PreferredPath -Names \$FallbackNames'
        Assert-ContainsText $script:Launcher 'Start-Sleep -Milliseconds 250'
        Assert-ContainsText $script:Launcher 'Codex 或 CCSwitch 没有完全退出'
        Assert-ContainsText $script:Launcher 'ReadyTimeoutSeconds = 20'
        Assert-ContainsText $script:Launcher 'CCSwitch 本地路由已就绪'
        Assert-ContainsText $script:Launcher '未检测到本地路由监听：127\.0\.0\.1:15721，本次不会启动 Codex'
        Assert-ContainsText $script:Launcher 'Start-Sleep -Milliseconds 500'
        Assert-ContainsText $script:Launcher 'Start-Sleep -Seconds 2'
        Assert-ContainsText $script:Launcher '\$runningPath = Get-RunningExecutablePathByNames -Names \$Script:CCSwitchProcessNames'
    }

    It 'treats unknown auth state conservatively' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping auth state check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Get-AuthState'
        Assert-ContainsText $script:Launcher "'api-key-like'"
        Assert-ContainsText $script:Launcher "'official-like'"
        Assert-ContainsText $script:Launcher "'unknown'"
        Assert-ContainsText $script:Launcher "authState -eq 'unknown'"
        Assert-ContainsText $script:Launcher '不会自动移走'
    }

    It 'backs up official config before repair writes' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping official backup check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher '(?i)backup'
        Assert-ContainsText $script:Launcher '(?i)Copy-Item'
        Assert-ContainsText $script:Launcher 'config\.toml'
    }

    It 'does not contain broad recursive deletion of Codex or CCSwitch data' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping broad deletion check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-DoesNotContainText $script:Launcher '(?i)Remove-Item\s+.*-Recurse.*\\\.codex'
        Assert-DoesNotContainText $script:Launcher '(?i)Remove-Item\s+.*-Recurse.*\\\.cc-switch'
        Assert-DoesNotContainText $script:Launcher '(?i)Remove-Item\s+.*-Recurse.*CCSwitch'
    }
}

