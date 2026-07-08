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
        Assert-ContainsText $script:Readme '当前版本：`v0\.4\.33`'
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
        Assert-ContainsText $script:ExampleConfigRaw '"historySyncBackendPath"'
        Assert-DoesNotContainText $script:ExampleConfigRaw '"officialCleanConfig"'
        Assert-DoesNotContainText $script:ExampleConfigRaw 'gpt-5\.1'
    }

    It 'keeps README UTF-8 Chinese text intact' {
        $cjkCount = ([regex]::Matches($script:Readme, '[\u4e00-\u9fff]')).Count
        if ($cjkCount -lt 100) {
            throw "README appears mojibake or lossy: only $cjkCount CJK characters found."
        }

        $questionRuns = ([regex]::Matches($script:Readme, '\?{4,}')).Count
        if ($questionRuns -gt 0) {
            throw "README contains suspicious replacement-question-mark runs."
        }
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
        Assert-ContainsText $script:Launcher 'Prepare-OfficialProfileForOfficialMode'
        Assert-ContainsText $script:Launcher 'Test-OfficialProfileCacheNeedsUpdate'
        Assert-ContainsText $script:Launcher 'Save-OfficialProfileIfCurrentLooksOfficial'
        Assert-ContainsText $script:Launcher 'OnlyIfCacheMissingOrOlder'
        Assert-ContainsText $script:Launcher 'Test-CurrentLooksOfficialProfile'
        Assert-ContainsText $script:Launcher '当前默认 \.codex 已是官方登录态；跳过恢复旧 official profile'
        Assert-ContainsText $script:Launcher '当前官方登录态已可用且缓存不旧；不重复保存官方 profile'
        Assert-ContainsText $script:Launcher '保存官方 profile 失败；继续使用当前官方登录态启动'
        Assert-ContainsText $script:Launcher 'try \{[\s\S]*Save-OfficialProfile -NoWrite:\$NoWrite[\s\S]*\} catch \{'
        Assert-ContainsText $script:Launcher 'Ensure-OfficialAuthForPreserveMode'
        Assert-ContainsText $script:Launcher 'Restore-OfficialAuthOnly'
        Assert-ContainsText $script:Launcher 'before-\$ProfileName-save'
    }

    It 'supports bootstrap and read-only doctor modes' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping bootstrap/doctor check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher "ValidateSet\('official', 'thirdparty', 'thirdparty-preserve-auth', 'thirdparty-pure', 'repair', 'check', 'doctor', 'bootstrap', 'menu'\)"
        Assert-DoesNotContainText $script:Launcher "'saveofficial'"
        Assert-ContainsText $script:Launcher 'Invoke-Bootstrap'
        Assert-ContainsText $script:Launcher 'Invoke-Doctor'
        Assert-ContainsText $script:Launcher '\$Script:LauncherVersion = ''v0\.4\.33'''
        Assert-DoesNotContainText $script:Launcher 'Test-Path[^\r\n]+-PathType\s+Leaf\s+-and'
        Assert-ContainsText $script:Launcher 'Codex Windows 启动器 \$Script:LauncherVersion'
        Assert-ContainsText $script:Launcher 'Codex Windows Launcher 诊断 \$Script:LauncherVersion'
        Assert-ContainsText $script:Launcher "Mode -in @\('check', 'doctor'\)"
        Assert-ContainsText $script:Launcher 'Read-LauncherConfig'
        Assert-ContainsText $script:Launcher 'Write-LauncherConfigIfMissing'
        Assert-ContainsText $script:Launcher 'New-LauncherShortcut'
        Assert-ContainsText $script:Launcher 'RunLogPath'
        Assert-ContainsText $script:Launcher 'Write-LauncherLog'
        Assert-ContainsText $script:Launcher 'Protect-LogMessage'
        Assert-ContainsText $script:Launcher '本次日志文件'
        Assert-ContainsText $script:Launcher '定向历史恢复退出码'
        Assert-ContainsText $script:Launcher '历史状态摘要 before'
        Assert-ContainsText $script:Launcher '历史状态摘要 after'
        Assert-ContainsText $script:Launcher '菜单 1 阶段：检查并按需恢复聊天记录'
        Assert-ContainsText $script:Launcher '--expected-provider'
        Assert-ContainsText $script:Launcher '\$historyProviderArgs'
        Assert-DoesNotContainText $script:Launcher 'Add-Content[^\n]+auth\.json'
    }

    It 'supports a repair mode for Codex Desktop crash state without touching credentials' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping repair mode check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Start-RepairMode'
        Assert-ContainsText $script:Launcher 'Backup-CodexDesktopCrashState'
        Assert-ContainsText $script:Launcher 'Clear-CodexDesktopCrashState'
        Assert-ContainsText $script:Launcher 'Export-CodexDesktopRepairEvidence'
        Assert-ContainsText $script:Launcher 'Reset-LauncherUiSnapshotAfterRepair'
        Assert-ContainsText $script:Launcher 'Test-RecentDesktopRepair'
        Assert-ContainsText $script:Launcher 'repair-evidence\.txt'
        Assert-ContainsText $script:Launcher 'launcher-log-'
        Assert-ContainsText $script:Launcher 'CodexElectronStateDirs'
        Assert-ContainsText $script:Launcher 'Local Storage'
        Assert-ContainsText $script:Launcher 'Session Storage'
        Assert-ContainsText $script:Launcher 'Code Cache'
        Assert-ContainsText $script:Launcher 'Network'
        Assert-ContainsText $script:Launcher '修复 Codex Desktop 启动错误页'
        Assert-ContainsText $script:Launcher '已备份并清理 Codex Desktop 崩溃缓存'
        Assert-ContainsText $script:Launcher '已保存 Codex Desktop 修复证据'
        Assert-ContainsText $script:Launcher '已隔离启动器保存的 Codex UI 快照'
        Assert-ContainsText $script:Launcher '刚执行过 repair，跳过恢复旧 UI 快照'
        Assert-ContainsText $script:Launcher "'repair' \{ Start-RepairMode -Config \`$config -NoLaunch:\`$NoLaunch \}"
        Assert-ContainsText $script:Launcher 'Write-Next "如修复后仍看到错误页，请发送本次日志文件：\$Script:RunLogPath"'
        Assert-DoesNotContainText $script:Launcher 'Remove-Item[^\n]+auth\.json'
        Assert-DoesNotContainText $script:Launcher 'Remove-Item\s+-LiteralPath\s+\$Script:DefaultCodexHome\s+-Recurse'
    }

    It 'detects likely Codex Desktop error page state and suggests repair' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping launch health check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Test-CodexDesktopRepairRecommended'
        Assert-ContainsText $script:Launcher 'Write-CodexDesktopRepairSuggestion'
        Assert-ContainsText $script:Launcher 'Test-CodexLaunchHealth'
        Assert-ContainsText $script:Launcher 'Codex Desktop 可能进入错误页或启动后立即退出'
        Assert-ContainsText $script:Launcher '建议运行修复模式'
        Assert-ContainsText $script:Launcher 'codex-launcher\.ps1'
        Assert-ContainsText $script:Launcher '-Mode repair'
        Assert-ContainsText $script:Launcher 'Invoke-Doctor'
        Assert-ContainsText $script:Launcher 'Test-CodexDesktopRepairRecommended'
        Assert-ContainsText $script:Launcher 'Start-LaunchTarget'
        Assert-ContainsText $script:Launcher 'Test-CodexLaunchHealth'
        Assert-ContainsText $script:Launcher 'Get-Item -LiteralPath \$Script:CodexGlobalStatePath'
        Assert-ContainsText $script:Launcher 'Get-ChildItem -LiteralPath \$Script:CodexElectronDataDir'
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
        Assert-ContainsText $script:Launcher 'Invoke-HistorySyncBeforeCodexLaunch'
        Assert-ContainsText $script:Launcher 'Resolve-HistorySyncBackendPath'
        Assert-ContainsText $script:Launcher 'historySyncBackendPath'
        Assert-ContainsText $script:Launcher 'Get-ConfigPreservationBaseline'
        Assert-ContainsText $script:Launcher 'Merge-PreservedCodexConfigSections'
        Assert-ContainsText $script:Launcher 'ConfigPreserveSectionPrefixes'
        Assert-ContainsText $script:Launcher 'marketplaces\.'
        Assert-ContainsText $script:Launcher 'plugins\.'
        Assert-ContainsText $script:Launcher 'mcp_servers'
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
        Assert-ContainsText $script:Launcher 'New-OfficialAuthBaselineForPreserveMode'
        Assert-ContainsText $script:Launcher 'Restore-OfficialAuthBaselineForPreserveMode'
        Assert-ContainsText $script:Launcher 'preserve-auth-baseline'
        Assert-ContainsText $script:Launcher '最终 auth\.json 已确认是官方 ChatGPT/OAuth 登录态，且匹配菜单 2 基准 hash'

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
        $baselineIndex = $preserveBody.IndexOf('New-OfficialAuthBaselineForPreserveMode')
        $officialConfirmIndex = $preserveBody.IndexOf('Confirm-OfficialAuthForPreserveMode')
        $finalOfficialConfirmIndex = $preserveBody.LastIndexOf('Confirm-OfficialAuthForPreserveMode')
        $mergeConfigIndex = $preserveBody.IndexOf('Merge-PreservedCodexConfigSections')
        $historySyncIndex = $preserveBody.IndexOf('Invoke-HistorySyncBeforeCodexLaunch')
        $launchIndex = $preserveBody.IndexOf('Start-LaunchTarget')
        if ($prepIndex -lt 0 -or $restoreIndex -lt 0 -or $baselineIndex -lt 0 -or $firstAuthIndex -lt 0 -or $enableIndex -lt 0 -or $restartIndex -lt 0 -or $enhanceConfirmIndex -lt 0 -or $secondAuthIndex -lt 0 -or $officialConfirmIndex -lt 0 -or $finalOfficialConfirmIndex -lt 0 -or $confirmIndex -lt 0 -or $mergeConfigIndex -lt 0 -or $historySyncIndex -lt 0 -or $launchIndex -lt 0 -or $prepIndex -gt $baselineIndex -or $baselineIndex -gt $restoreIndex -or $restoreIndex -gt $firstAuthIndex -or $firstAuthIndex -gt $enableIndex -or $enableIndex -gt $restartIndex -or $restartIndex -gt $enhanceConfirmIndex -or $enhanceConfirmIndex -gt $secondAuthIndex -or $secondAuthIndex -gt $officialConfirmIndex -or $officialConfirmIndex -gt $confirmIndex -or $confirmIndex -gt $mergeConfigIndex -or $mergeConfigIndex -gt $historySyncIndex -or $historySyncIndex -gt $finalOfficialConfirmIndex -or $finalOfficialConfirmIndex -gt $launchIndex) {
            throw 'Preserve-auth mode must close Codex/CCSwitch, pin the starting official auth baseline, confirm route config, merge preserved plugin/runtime config, sync history visibility, reconfirm auth baseline, then launch Codex.'
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
        Assert-ContainsText $script:Launcher 'ContainsKey\(\$Key\)'
        Assert-ContainsText $script:Launcher 'ConvertTo-PlainJsonValue'
        Assert-DoesNotContainText $script:Launcher '\$Map\.Contains\(\$Key\)'
        Assert-DoesNotContainText $script:Launcher '\$serializer\.Serialize\(\$Value\)'
        Assert-ContainsText $script:Launcher 'Set-OfficialConfigProviderOpenAI'
        Assert-ContainsText $script:Launcher 'model_provider = "openai"'
        Assert-ContainsText $script:Launcher "ExpectedProvider 'openai'"
        Assert-DoesNotContainText $script:Launcher "CodexUiStateAtomKeys = @\([^)]*prompt-history"
        Assert-DoesNotContainText $script:Launcher "CodexUiStateAtomKeys = @\([^)]*auth"
        Assert-DoesNotContainText $script:Launcher "CodexUiStateAtomKeys = @\([^)]*token"

        $officialStart = $script:Launcher.IndexOf('function Start-OfficialMode')
        $ensureStart = $script:Launcher.IndexOf('function Ensure-CCSwitchRunning')
        $officialBody = $script:Launcher.Substring($officialStart, $ensureStart - $officialStart)
        $officialStopCheckIndex = $officialBody.IndexOf('官方模式未能完全关闭 Codex 或 CCSwitch')
        $officialSaveIndex = $officialBody.IndexOf('Save-CodexUiStateSnapshot')
        $officialPrepareProfileIndex = $officialBody.IndexOf('Prepare-OfficialProfileForOfficialMode')
        $officialProviderIndex = $officialBody.IndexOf('Set-OfficialConfigProviderOpenAI')
        $officialRestoreUiIndex = $officialBody.IndexOf('Restore-CodexUiStateSnapshot')
        $officialHistorySyncIndex = $officialBody.IndexOf('Invoke-HistorySyncBeforeCodexLaunch')
        $officialLaunchIndex = $officialBody.IndexOf('Start-LaunchTarget')
        if ($officialStopCheckIndex -lt 0 -or $officialSaveIndex -lt 0 -or $officialPrepareProfileIndex -lt 0 -or $officialProviderIndex -lt 0 -or $officialRestoreUiIndex -lt 0 -or $officialHistorySyncIndex -lt 0 -or $officialLaunchIndex -lt 0 -or $officialStopCheckIndex -gt $officialSaveIndex -or $officialSaveIndex -gt $officialPrepareProfileIndex -or $officialPrepareProfileIndex -gt $officialProviderIndex -or $officialProviderIndex -gt $officialRestoreUiIndex -or $officialRestoreUiIndex -gt $officialHistorySyncIndex -or $officialHistorySyncIndex -gt $officialLaunchIndex) {
            throw 'Official mode must stop old processes, save UI preferences, prepare official profile without overwriting fresh login, force openai provider, restore UI preferences, sync history visibility, then launch Codex.'
        }

        $preserveStart = $script:Launcher.IndexOf('function Start-ThirdPartyPreserveAuthMode')
        $pureStart = $script:Launcher.IndexOf('function Start-ThirdPartyPureMode')
        $preserveBody = $script:Launcher.Substring($preserveStart, $pureStart - $preserveStart)
        $preserveSaveIndex = $preserveBody.IndexOf('Save-CodexUiStateSnapshot')
        $preserveRestoreConfigIndex = $preserveBody.IndexOf('Restore-ThirdPartyConfig')
        $preserveRestoreUiIndex = $preserveBody.IndexOf('Restore-CodexUiStateSnapshot')
        $preserveLaunchIndex = $preserveBody.IndexOf('Start-LaunchTarget')
        if ($preserveSaveIndex -lt 0 -or $preserveRestoreConfigIndex -lt 0 -or $preserveLaunchIndex -lt 0 -or $preserveSaveIndex -gt $preserveRestoreConfigIndex -or $preserveRestoreConfigIndex -gt $preserveLaunchIndex) {
            throw 'Preserve-auth mode must save UI preferences before switching config and then launch Codex.'
        }
        if ($preserveRestoreUiIndex -ge 0) {
            throw 'Preserve-auth mode must not restore saved UI state before launch; stale .codex-global-state.json can reopen the Codex error page.'
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

    It 'force-closes Codex and CCSwitch during mode switches' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping third-party process cleanup check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'TimeoutSeconds = 8'
        Assert-ContainsText $script:Launcher 'Test-ProcessRunning -Path \$PreferredPath -Names \$FallbackNames'
        Assert-ContainsText $script:Launcher 'return \(@\(Get-ProcessesByPath -Path \$Path\)\.Count -gt 0\)'
        Assert-ContainsText $script:Launcher 'CloseMainWindow'
        Assert-ContainsText $script:Launcher '等待本地状态写盘'
        Assert-ContainsText $script:Launcher '最多等待 \$TimeoutSeconds 秒'
        Assert-ContainsText $script:Launcher '没有主窗口，直接强制关闭'
        Assert-ContainsText $script:Launcher 'ForceImmediately'
        Assert-ContainsText $script:Launcher '立即强制关闭 \$DisplayName'
        Assert-ContainsText $script:Launcher 'Stop-LauncherProcess -DisplayName ''Codex'' -PreferredPath \$codexProcessPath -FallbackNames \$Script:CodexProcessNames -ForceImmediately'
        Assert-ContainsText $script:Launcher 'Stop-LauncherProcess -DisplayName ''Codex'' -PreferredPath \$CodexPath -FallbackNames \$Script:CodexProcessNames -TimeoutSeconds 10 -ForceImmediately'
        Assert-ContainsText $script:Launcher '准备强制关闭'
        Assert-ContainsText $script:Launcher 'Start-Sleep -Milliseconds 250'
        Assert-ContainsText $script:Launcher 'Codex 或 CCSwitch 没有完全退出'
        Assert-ContainsText $script:Launcher 'ReadyTimeoutSeconds = 20'
        Assert-ContainsText $script:Launcher 'CCSwitch 本地路由已就绪'
        Assert-ContainsText $script:Launcher '未检测到本地路由监听：127\.0\.0\.1:15721，本次不会启动 Codex'
        Assert-ContainsText $script:Launcher 'Start-Sleep -Milliseconds 500'
        Assert-ContainsText $script:Launcher 'Start-Sleep -Seconds 2'
        Assert-ContainsText $script:Launcher '\$runningPath = Get-RunningExecutablePathByNames -Names \$Script:CCSwitchProcessNames'
    }

    It 'captures Codex Desktop launch evidence when the app reaches an error page' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping Codex launch evidence check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Export-CodexDesktopLaunchEvidence'
        Assert-ContainsText $script:Launcher 'Get-CodexDesktopLogRoots'
        Assert-ContainsText $script:Launcher 'LocalCache\\Local\\Codex\\Logs'
        Assert-ContainsText $script:Launcher 'launch-evidence'
        Assert-ContainsText $script:Launcher 'codex-desktop-log'
        Assert-ContainsText $script:Launcher 'recent_windows_application_events'
        Assert-ContainsText $script:Launcher 'Oops, an error has occurred'
        Assert-ContainsText $script:Launcher 'Update Codex'
        Assert-ContainsText $script:Launcher '\$summary\.HasCustomProviderSection'
        Assert-ContainsText $script:Launcher '\$summary\.HasLocalRouteBaseUrl'
        Assert-DoesNotContainText $script:Launcher '\$summary\.HasCustomSection'
        Assert-DoesNotContainText $script:Launcher '\$summary\.HasLocalRoute[;\)]'

        $launchHealthStart = $script:Launcher.IndexOf('function Test-CodexLaunchHealth')
        $ccSwitchStart = $script:Launcher.IndexOf('function Backup-CCSwitchSettingsFile')
        $launchHealthBody = $script:Launcher.Substring($launchHealthStart, $ccSwitchStart - $launchHealthStart)
        $evidenceIndex = $launchHealthBody.IndexOf('Export-CodexDesktopLaunchEvidence')
        $repairSuggestionIndex = $launchHealthBody.IndexOf('Write-CodexDesktopRepairSuggestion')
        if ($evidenceIndex -lt 0 -or $repairSuggestionIndex -lt 0 -or $evidenceIndex -gt $repairSuggestionIndex) {
            throw 'Launch health must export Codex Desktop evidence before asking the user to repair or send logs.'
        }
    }

    It 'keeps menu 2 on custom routing while preserving official OAuth UI state' {
        if (-not (Test-Path -LiteralPath $LauncherPath)) {
            Write-Host 'Skipping preserve-auth route auth check because codex-launcher.ps1 is not present.'
            return
        }

        Assert-ContainsText $script:Launcher 'Set-PreserveAuthCustomProviderRequiresOfficialAuth'
        Assert-ContainsText $script:Launcher 'Ensure-ThirdPartyCustomProviderConfig'
        Assert-ContainsText $script:Launcher 'Get-ActiveConfigProviderSummary'
        Assert-ContainsText $script:Launcher 'HasCustomProviderSection'
        Assert-ContainsText $script:Launcher 'HasLocalRouteBaseUrl'
        Assert-ContainsText $script:Launcher 'requires_openai_auth = true'
        Assert-DoesNotContainText $script:Launcher 'Set-PreserveAuthCustomProviderSkipsOfficialAuth'
        Assert-ContainsText $script:Launcher 'model_provider = "custom"'
        Assert-ContainsText $script:Launcher '\[model_providers\.custom\]'
        Assert-ContainsText $script:Launcher 'History Sync Tool 能识别 custom provider'
        Assert-ContainsText $script:Launcher '--json\$providerArgText status'
        Assert-ContainsText $script:Launcher '--codex-home \$Script:DefaultCodexHome'
        Assert-ContainsText $script:Launcher '--json\$providerArgText sync'
        Assert-ContainsText $script:Launcher 'Invoke-HistorySyncBackendCommand'
        Assert-ContainsText $script:Launcher 'Invoke-HistorySyncBackendRawCommand'
        Assert-ContainsText $script:Launcher 'Test-HistorySyncProviderMatchesExpected'
        Assert-ContainsText $script:Launcher 'cc-switch-local-route'
        Assert-ContainsText $script:Launcher '旧版 Codex History Sync Tool 将 CCSwitch/custom 路由识别为 provider=openai'
        Assert-ContainsText $script:Launcher '\$ErrorActionPreference = ''Continue'''
        Assert-ContainsText $script:Launcher 'finally \{\s*\$ErrorActionPreference = \$previousErrorActionPreference'
        Assert-ContainsText $script:Launcher 'ExpectedProviderUnsupported'
        Assert-ContainsText $script:Launcher 'CommandUnsupported'
        Assert-ContainsText $script:Launcher 'Test-HistorySyncCommandUnsupported'
        Assert-ContainsText $script:Launcher '旧版 Codex History Sync Tool 不支持 --expected-provider'
        Assert-ContainsText $script:Launcher '为避免把聊天记录修到 \$currentProvider 通道'
        Assert-ContainsText $script:Launcher '请先升级 codex-history-sync-tool-windows'
        Assert-ContainsText $script:Launcher '当前 Codex History Sync Tool 版本不支持启动器需要的 status/sync 命令'
        Assert-ContainsText $script:Launcher '跳过历史检查并继续启动 Codex'
        Assert-ContainsText $script:Launcher '降级为旧参数调用'
        Assert-ContainsText $script:Launcher '执行历史状态检查\(\$attempt/3\)'
        Assert-ContainsText $script:Launcher '等待 1 秒后复查 provider'
        Assert-ContainsText $script:Launcher '定向恢复当前 \.codex'
        Assert-ContainsText $script:Launcher '定向恢复后仍有聊天异常'
        Assert-ContainsText $script:Launcher 'HardRemaining'
        Assert-ContainsText $script:Launcher 'SessionMetaRemaining'
        Assert-ContainsText $script:Launcher 'CwdPrefixRemaining'
        Assert-ContainsText $script:Launcher 'cwd前缀软异常'
        Assert-ContainsText $script:Launcher 'session_meta软异常'
        Assert-ContainsText $script:Launcher '不再反复等待修复'
        Assert-ContainsText $script:Launcher '不阻止启动'
        Assert-DoesNotContainText $script:Launcher '--one-click-safe-sync'
        Assert-ContainsText $script:Launcher '未找到 Codex History Sync Tool；本次不涉及聊天记录恢复'
        Assert-ContainsText $script:Launcher '历史同步目标 provider='
        Assert-ContainsText $script:Launcher '历史同步目标 provider 不符合预期'
        Assert-ContainsText $script:Launcher '本次不会执行历史恢复，也不会启动 Codex，避免把聊天记录修到错误通道'
        Assert-ContainsText $script:Launcher '启动器已阻止继续进入错误聊天通道'
        Assert-ContainsText $script:Launcher "ExpectedProvider 'custom'"
        Assert-ContainsText $script:Launcher '历史状态已干净'
        Assert-ContainsText $script:Launcher '正在调用 Codex History Sync Tool 定向恢复'
        Assert-ContainsText $script:Launcher 'Codex History Sync Tool 定向恢复完成'

        $preserveStart = $script:Launcher.IndexOf('function Start-ThirdPartyPreserveAuthMode')
        $pureStart = $script:Launcher.IndexOf('function Start-ThirdPartyPureMode')
        $preserveBody = $script:Launcher.Substring($preserveStart, $pureStart - $preserveStart)
        Assert-ContainsText $preserveBody 'Save-OfficialAuthOnlyIfCurrentLooksOfficial'
        Assert-DoesNotContainText $preserveBody 'Save-OfficialProfileIfCurrentLooksOfficial'
        $repairIndex = $preserveBody.IndexOf('Ensure-ThirdPartyCustomProviderConfig')
        $mergeIndex = $preserveBody.IndexOf('Merge-PreservedCodexConfigSections')
        $requiresAuthIndex = $preserveBody.IndexOf('Set-PreserveAuthCustomProviderRequiresOfficialAuth')
        $historySyncCheckIndex = $preserveBody.IndexOf('Invoke-HistorySyncBeforeCodexLaunch')
        $launchIndex = $preserveBody.IndexOf('Start-LaunchTarget')
        if ($repairIndex -lt 0 -or $mergeIndex -lt 0 -or $requiresAuthIndex -lt 0 -or $historySyncCheckIndex -lt 0 -or $launchIndex -lt 0 -or $repairIndex -gt $mergeIndex -or $mergeIndex -gt $requiresAuthIndex -or $requiresAuthIndex -gt $historySyncCheckIndex -or $historySyncCheckIndex -gt $launchIndex) {
            throw 'Preserve-auth mode must repair custom provider, merge config, require official OAuth UI state for custom route, try history sync, then launch Codex.'
        }
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

