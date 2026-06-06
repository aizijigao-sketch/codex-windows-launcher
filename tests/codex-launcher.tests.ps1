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
        Assert-ContainsText $script:Readme '\.codex'
        Assert-ContainsText $script:Readme 'CCSwitch'
        Assert-ContainsText $script:Readme 'profiles'
        Assert-ContainsText $script:Readme 'saveofficial|保存当前为官方状态|官方 profile'
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

        Assert-ContainsText $script:Launcher 'saveofficial'
        Assert-ContainsText $script:Launcher 'Save-OfficialProfile'
        Assert-ContainsText $script:Launcher 'Restore-OfficialProfile'
        Assert-ContainsText $script:Launcher 'Save-OfficialProfileIfCurrentLooksOfficial'
        Assert-ContainsText $script:Launcher 'Test-CurrentLooksOfficialProfile'
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

