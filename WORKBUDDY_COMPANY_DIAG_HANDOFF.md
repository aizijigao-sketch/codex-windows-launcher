# Codex Windows Launcher 公司电脑诊断交接文档

面向：公司电脑上的 WorkBuddy  
项目：`codex-windows-launcher`  
当前公开版本：`v0.4.27`  
诊断目标：找出“菜单 1 / `-Mode official`、菜单 2 / `-Mode thirdparty-preserve-auth` 执行后 Codex Desktop 没有启动或仍要求登录”的真实原因，并产出可回传给维护者的证据文档。

## 重要边界

本次只做诊断和取证，不要继续手工热修 `codex-launcher.ps1`。

禁止操作：

- 不要删除 `%USERPROFILE%\.codex`。
- 不要删除 `%USERPROFILE%\.codex-launcher`。
- 不要删除 `%APPDATA%\Codex`，除非用户明确让你运行启动器自带 `-Mode repair`。
- 不要打印、复制、上传 `auth.json` 内容。
- 不要打印、复制、上传 API key、token、cookie、CCSwitch 数据库内容。
- 不要用正则批量替换 `$Script:` 相关代码。

允许操作：

- 读取版本号、日志、配置摘要。
- 验证脚本语法。
- 运行 `doctor`、`official`、`thirdparty-preserve-auth`、`repair`。
- 收集 Windows 事件日志、启动器日志、文件是否存在、进程是否启动。
- 对敏感文件只记录“存在/不存在、大小、更新时间、SHA256 前 12 位”，不要记录正文。

## 已知背景

之前公司电脑遇到过两个已修复的问题：

1. `v0.4.22`：菜单 1 发现当前 `.codex` 已是官方登录态后，保存 official profile 缓存失败会中断，导致没有走到启动 Codex。
2. `v0.4.23` 热修过程中曾把版本行写坏为 `$Script:LauncherVersion\ = 'v0.4.23'`。
3. 随后又发现 `Test-Path ... -PathType Leaf -and ...` 在 PowerShell 里解析错误，已在 `v0.4.24` 用显式括号修复。

当前 GitHub `main` 已发布 `v0.4.27`，理论上包含：

- official profile 缓存保存失败时只报警，不阻止启动。
- `Test-Path` 与 `-and` 条件表达式语法修复。
- 旧版 `sync_backend.py` 不支持 `--expected-provider` 并输出 usage 到 stderr 时，启动器会正确降级为旧参数调用，不再因此阻止菜单 `1` / `2` 启动 Codex。
- 旧版 History Sync Tool 把 CCSwitch/custom 路由报成 `provider=openai` 但同时报 `login_mode=cc-switch-local-route` 时，菜单 `2` 不再误判 provider 不匹配。
- 但旧版 History Sync Tool 不能接收 `--expected-provider custom` 且还有待修复聊天异常时，菜单 `2` 不会降级执行 `sync`，避免把聊天写到错误通道。

如果公司电脑仍然不能启动，优先怀疑：

- 如果菜单 1 和菜单 2 都不能启动，优先怀疑两个模式共用的启动链路，而不是单独的官方登录态保存逻辑。
- 公司电脑没有真正升级到 `v0.4.24`。
- 本地脚本仍残留热修损坏内容。
- `Start-LaunchTarget` 没有执行到，前面还有新的异常。
- Codex Desktop 启动目标路径失效或 WindowsApps 权限/打包应用启动方式有问题。
- Codex Desktop 进程启动后立刻退出。
- Codex Desktop 启动了，但 Electron/UI 状态损坏，窗口不可见或错误页。
- official profile / auth 状态判断与实际 Codex Desktop 登录态不一致。

## 一键生成诊断包

请在公司电脑 PowerShell 里运行下面命令。它只收集诊断信息，不会打印 `auth.json` 正文，也不会修改登录态。

```powershell
$ErrorActionPreference = 'Continue'
$launcherRoot = 'E:\AI-Workspace\20_Projects\codex-windows-launcher'
$launcher = Join-Path $launcherRoot 'codex-launcher.ps1'
$outRoot = Join-Path $env:USERPROFILE ('Desktop\codex-launcher-diagnostic-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report = Join-Path $outRoot 'workbuddy-diagnostic-report.md'
$artifactDir = Join-Path $outRoot 'artifacts'

New-Item -ItemType Directory -Force -Path $outRoot,$artifactDir | Out-Null

function Add-Report {
    param([string]$Text)
    Add-Content -LiteralPath $report -Value $Text -Encoding UTF8
}

function Add-Section {
    param([string]$Title)
    Add-Report ""
    Add-Report "## $Title"
    Add-Report ""
}

function Add-Code {
    param([string]$Text)
    Add-Report '```text'
    Add-Report $Text
    Add-Report '```'
}

function Run-Capture {
    param(
        [string]$Title,
        [scriptblock]$Block
    )
    Add-Section $Title
    try {
        $text = & $Block 2>&1 | Out-String
        Add-Code $text.TrimEnd()
    } catch {
        Add-Code ("ERROR: " + $_.Exception.Message)
    }
}

function Get-SafeFileFact {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path=$Path; Exists=$false; Length=$null; LastWriteTime=$null; Sha256Prefix=$null }
    }
    $item = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    [pscustomobject]@{
        Path = $Path
        Exists = $true
        Length = $item.Length
        LastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Sha256Prefix = $hash.Substring(0,12)
    }
}

Set-Content -LiteralPath $report -Value "# WorkBuddy Codex Launcher 诊断报告`n`n生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n机器用户：$env:USERNAME`n" -Encoding UTF8

Run-Capture '系统与 PowerShell' {
    [pscustomobject]@{
        User = $env:USERNAME
        ComputerName = $env:COMPUTERNAME
        UserProfile = $env:USERPROFILE
        PSVersion = $PSVersionTable.PSVersion.ToString()
        CurrentDirectory = (Get-Location).Path
    } | Format-List
}

Run-Capture '启动器目录状态' {
    if (Test-Path -LiteralPath $launcherRoot) {
        Get-ChildItem -LiteralPath $launcherRoot -Force | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
    } else {
        "launcherRoot not found: $launcherRoot"
    }
}

Run-Capture '启动器版本和关键代码片段' {
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        Select-String -LiteralPath $launcher -Pattern 'LauncherVersion|function Start-LaunchTarget|function Start-OfficialMode|function Start-ThirdPartyPreserveAuthMode|Test-OfficialProfileCacheNeedsUpdate|保存官方 profile 失败|ActiveConfigPath.*cachedConfig|Start-LaunchTarget -Target' -Context 0,2 |
            ForEach-Object { $_.ToString() }
    } else {
        "launcher not found: $launcher"
    }
}

Run-Capture '启动器语法检查' {
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors) { $errors | Select-Object Message,Extent | Format-List } else { 'Parse OK' }
    } else {
        "launcher not found"
    }
}

Run-Capture 'Git 版本状态' {
    if (Test-Path -LiteralPath (Join-Path $launcherRoot '.git')) {
        Push-Location $launcherRoot
        try {
            git status --short --branch
            git log --oneline -5
            git remote -v
        } finally {
            Pop-Location
        }
    } else {
        "No .git directory"
    }
}

Run-Capture 'Codex Desktop 安装与进程' {
    '--- Get-AppxPackage OpenAI.Codex ---'
    Get-AppxPackage -Name 'OpenAI.Codex' | Select-Object Name,PackageFullName,InstallLocation,Version | Format-List
    '--- Codex processes ---'
    Get-Process | Where-Object { $_.ProcessName -match 'Codex|OpenAI' } | Select-Object ProcessName,Id,Path,StartTime | Format-Table -AutoSize
}

Run-Capture '关键配置和登录态文件事实摘要（不含正文）' {
    $paths = @(
        (Join-Path $env:USERPROFILE '.codex\auth.json'),
        (Join-Path $env:USERPROFILE '.codex\config.toml'),
        (Join-Path $env:USERPROFILE '.codex-launcher\launcher-config.json'),
        (Join-Path $env:USERPROFILE '.codex-launcher\profiles\official\auth.json'),
        (Join-Path $env:USERPROFILE '.codex-launcher\profiles\official\config.toml'),
        (Join-Path $env:USERPROFILE '.codex-launcher\profiles\thirdparty\auth.json'),
        (Join-Path $env:USERPROFILE '.codex-launcher\profiles\thirdparty\config.toml'),
        (Join-Path $env:APPDATA 'Codex\.codex-global-state.json')
    )
    $paths | ForEach-Object { Get-SafeFileFact $_ } | Format-Table -AutoSize
}

Run-Capture 'config.toml 脱敏摘要' {
    $config = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (Test-Path -LiteralPath $config -PathType Leaf) {
        $text = Get-Content -LiteralPath $config -Raw -Encoding UTF8
        [pscustomobject]@{
            Exists = $true
            HasCustomProviderSection = ($text -match '\[model_providers\.custom\]')
            HasLocalRoute = ($text -match '127\.0\.0\.1|localhost')
            ModelProviderLine = (($text -split "`r?`n") | Where-Object { $_ -match '^\s*model_provider\s*=' } | Select-Object -First 1)
            ModelLine = (($text -split "`r?`n") | Where-Object { $_ -match '^\s*model\s*=' } | Select-Object -First 1)
            RequiresOpenAIAuth = ($text -match 'requires_openai_auth\s*=\s*true')
        } | Format-List
    } else {
        "config.toml not found"
    }
}

Run-Capture '最近启动器日志列表' {
    $logDir = Join-Path $env:USERPROFILE '.codex-launcher\logs'
    if (Test-Path -LiteralPath $logDir) {
        Get-ChildItem -LiteralPath $logDir -Filter 'launcher.*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName,Length,LastWriteTime | Format-Table -AutoSize
    } else {
        "No launcher log dir: $logDir"
    }
}

$logDir = Join-Path $env:USERPROFILE '.codex-launcher\logs'
if (Test-Path -LiteralPath $logDir) {
    Get-ChildItem -LiteralPath $logDir -Filter 'launcher.*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $artifactDir $_.Name) -Force
    }
}

Run-Capture '运行 doctor' {
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -Mode doctor
    } else {
        "launcher not found"
    }
}

Run-Capture '运行 official 并记录退出情况' {
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -Mode official
        "official exit code: $LASTEXITCODE"
        Start-Sleep -Seconds 5
        Get-Process | Where-Object { $_.ProcessName -match 'Codex|OpenAI' } | Select-Object ProcessName,Id,Path,StartTime | Format-Table -AutoSize
    } else {
        "launcher not found"
    }
}

Run-Capture 'official 后最新启动器日志 tail' {
    $latest = Get-ChildItem (Join-Path $env:USERPROFILE '.codex-launcher\logs') -Filter 'launcher.*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        "LOG=$($latest.FullName)"
        Get-Content -LiteralPath $latest.FullName -Tail 260
        Copy-Item -LiteralPath $latest.FullName -Destination (Join-Path $artifactDir ('latest-' + $latest.Name)) -Force
    } else {
        "No launcher log found"
    }
}

Run-Capture '运行 thirdparty-preserve-auth 并记录退出情况' {
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -Mode thirdparty-preserve-auth
        "thirdparty-preserve-auth exit code: $LASTEXITCODE"
        Start-Sleep -Seconds 5
        Get-Process | Where-Object { $_.ProcessName -match 'Codex|OpenAI|CC Switch|cc-switch' } | Select-Object ProcessName,Id,Path,StartTime | Format-Table -AutoSize
    } else {
        "launcher not found"
    }
}

Run-Capture 'thirdparty-preserve-auth 后最新启动器日志 tail' {
    $latest = Get-ChildItem (Join-Path $env:USERPROFILE '.codex-launcher\logs') -Filter 'launcher.*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        "LOG=$($latest.FullName)"
        Get-Content -LiteralPath $latest.FullName -Tail 260
        Copy-Item -LiteralPath $latest.FullName -Destination (Join-Path $artifactDir ('latest-thirdparty-' + $latest.Name)) -Force
    } else {
        "No launcher log found"
    }
}

Run-Capture '直接启动 Codex Desktop 目标对照测试' {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' | Select-Object -First 1
    if (-not $pkg) {
        "OpenAI.Codex AppX package not found"
        return
    }
    $exe = Join-Path $pkg.InstallLocation 'app\Codex.exe'
    "PackageFullName=$($pkg.PackageFullName)"
    "InstallLocation=$($pkg.InstallLocation)"
    "Exe=$exe"
    "ExeExists=$(Test-Path -LiteralPath $exe -PathType Leaf)"
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        try {
            $p = Start-Process -FilePath $exe -PassThru -ErrorAction Stop
            "Start-Process returned PID=$($p.Id)"
        } catch {
            "Start-Process failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 5
        Get-Process | Where-Object { $_.ProcessName -match 'Codex|OpenAI' } | Select-Object ProcessName,Id,Path,StartTime | Format-Table -AutoSize
    }
}

Run-Capture 'Codex / OpenAI 相关 Windows 事件日志' {
    $start = (Get-Date).AddHours(-6)
    Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$start } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'Application Error|Windows Error Reporting|\.NET Runtime' -or $_.Message -match 'Codex|OpenAI' } |
        Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message -First 30 |
        Format-List
}

Run-Capture 'Electron / Codex 应用数据目录摘要' {
    $dirs = @(
        (Join-Path $env:APPDATA 'Codex'),
        (Join-Path $env:LOCALAPPDATA 'OpenAI'),
        (Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0')
    )
    foreach ($dir in $dirs) {
        "### $dir"
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
        } else {
            "not found"
        }
    }
}

Compress-Archive -LiteralPath $outRoot -DestinationPath ($outRoot + '.zip') -Force
Write-Host "诊断完成：$report"
Write-Host "压缩包：$outRoot.zip"
```

## WorkBuddy 需要人工补充的判断

请在诊断报告最后补充下面结论，不要只贴命令输出：

1. 公司电脑实际运行的启动器版本是不是 `v0.4.24`？
2. `codex-launcher.ps1` 语法检查是否 `Parse OK`？
3. 运行 `-Mode official` 时，日志最后一行停在哪一步？
4. 运行 `-Mode thirdparty-preserve-auth` 时，日志最后一行停在哪一步？
5. 两个模式是否都出现同一个中断点？如果是，优先怀疑公共启动链路。
6. 日志里是否出现 `准备启动 Codex`、`Start-LaunchTarget`、`已启动 Codex` 或类似启动阶段信息？
7. `official` 和 `thirdparty-preserve-auth` 命令结束后 5 秒内，`Codex.exe` 进程是否存在？
8. 如果进程存在但窗口没出现，Windows 任务栏或任务管理器里是否能看到 Codex？
9. 如果进程启动后退出，Windows 事件日志里是否有 `Codex.exe` 崩溃记录？
10. `Get-AppxPackage OpenAI.Codex` 的 `InstallLocation` 是否存在？其中是否能找到 `app\Codex.exe`？
11. “直接启动 Codex Desktop 目标对照测试”是否能启动 Codex？
12. `%USERPROFILE%\.codex\auth.json` 是否存在，更新时间是否在用户“手动官方登录成功”之后？
13. `%USERPROFILE%\.codex-launcher\profiles\official\auth.json` 是否存在，更新时间是否晚于手动登录？
14. `config.toml` 摘要里 `model_provider` 是 `openai` 还是 `custom`？
15. 公司电脑是否用管理员 PowerShell 运行启动器？如果是，请补充一次“非管理员 PowerShell”分别运行 `-Mode official` 和 `-Mode thirdparty-preserve-auth` 的结果。

## 建议的最小复现顺序

WorkBuddy 不要同时尝试多个修复。按顺序做：

1. 运行上面“一键生成诊断包”。
2. 如果版本不是 `v0.4.27`，只做一键升级，不做其它判断。
3. 如果脚本语法错误，停止，回传错误和脚本版本，不要继续修。
4. 如果 `official` 和 `thirdparty-preserve-auth` 都没有走到启动阶段，定位两个日志共同中断的上一行。
5. 如果两个模式都走到启动阶段但没进程，重点查 `Start-LaunchTarget`、启动目标、管理员窗口、AppX/WindowsApps 启动方式。
6. 如果直接启动 Codex 目标也失败，优先查 Codex Desktop 安装或 Windows 事件日志，而不是启动器 profile 切换。
7. 如果直接启动能成功，但启动器两个模式失败，优先查启动器 `Start-LaunchTarget` 分支和环境变量清理。
8. 如果有进程但没窗口或马上退出，重点查 Electron/UI 状态和 Windows 事件日志。
9. 如果启动后要求登录，重点查当前 `.codex\auth.json` 与 official profile 的更新时间关系。

## 回传给维护者的文件

请把下面内容交回：

- `workbuddy-diagnostic-report.md`
- 同目录生成的 `.zip` 压缩包
- WorkBuddy 的人工结论，尤其是“official 和 thirdparty-preserve-auth 日志最后分别停在哪一行”
- 用户肉眼看到的现象：无窗口、闪退、错误页、还是打开后要求登录

维护者收到后再决定是否升级启动器。不要在公司电脑继续手工 patch。
