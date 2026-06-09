# Codex Windows 启动器

一个 Windows PowerShell 启动器，用来在 Codex Desktop 的官方登录态和第三方路由状态之间切换：

- 官方模式：恢复已保存的 ChatGPT / OpenAI 官方登录态并启动 Codex。
- 第三方模式，保留官方登录：使用 CCSwitch / custom 路由，但不恢复第三方 `auth.json`。
- 第三方模式，纯第三方/API-key：恢复第三方配置和第三方 `auth.json`。

这个项目只负责启动和切换 Codex Desktop。历史同步、项目列表修复、知识库同步等工具应单独使用，不属于本启动器职责。

## 方案说明

Windows 版 Codex Desktop 通过 Windows AppId 启动时，通常会读取默认 `%USERPROFILE%\.codex`。给桌面版单独设置 `CODEX_HOME` 并不稳定，所以本启动器采用本地 profile 文件切换：

- `%USERPROFILE%\.codex-launcher\profiles\official`：官方登录态和非 custom 配置。
- `%USERPROFILE%\.codex-launcher\profiles\thirdparty`：CCSwitch/custom 配置；纯第三方模式也可使用其中的 API-key 风格登录态。
- `%USERPROFILE%\.codex-launcher\backup`：切换前的本地备份。

启动器只在本机复制、恢复、备份这些 profile 文件，不打印、不上传、不转换 `auth.json` 或 token 内容。

启动 Codex Desktop 时，启动器会优先寻找真实桌面程序，而不是直接依赖 Windows AppId：

1. 先使用本机 `launcher-config.json` 中显式设置的 `codexPath`。
2. 再通过 `Get-AppxPackage` 自动查找 MSIX/AppX 安装包中的 `app\Codex.exe`。
3. 再检查常见安装目录和开始菜单快捷方式。
4. 最后才 fallback 到 Windows AppId。

`%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe` 是 Codex CLI，不是 Codex Desktop，启动器会明确排除它。

## 文件

- `codex-launcher.ps1`：启动器入口。
- `launcher-config.example.json`：不含密钥的配置示例。
- `scripts/create-desktop-shortcut.ps1`：创建桌面快捷方式。
- `tests/codex-launcher.tests.ps1`：Pester 静态安全检查。
- `.gitignore`：阻止本地 profile、日志、快捷方式、图标和密钥进入仓库。

## 安装

在 PowerShell 中进入项目目录：

```powershell
.\codex-launcher.ps1 -Mode bootstrap
.\codex-launcher.ps1 -Mode doctor
```

也可以直接运行启动器。首次使用、缺配置、快捷方式指向旧路径或检测到旧快捷方式时，会自动进入 `bootstrap`：

```powershell
.\codex-launcher.ps1
```

如果你有自己的本地图标，可以这样指定；图标文件不建议提交到公有仓库：

```powershell
.\scripts\create-desktop-shortcut.ps1 -IconPath "D:\icons\codex.ico" -Force
```

## 菜单说明

### 1. 官方模式：恢复官方登录态并启动 Codex

适合进入 OpenAI / ChatGPT 官方登录态。

行为：

1. 关闭 CCSwitch。
2. 关闭旧的 Codex Desktop 进程。
3. 如果已经保存过官方 profile，恢复它并启动 Codex。
4. 如果没有官方 profile，清理默认 `.codex` 中的 custom provider 配置，并暂时移走 API-key 风格的 `auth.json`。
5. 启动 Codex Desktop，让用户正常网页登录。
6. 官方登录态会在后续安全切换时自动保存；不会把第三方/API-key 状态误保存为官方状态。

保存过官方状态后，再选菜单 `1` 应该复用本地官方登录态，不应每次都跳网页登录。

### 2. 第三方模式：保留官方登录信息并使用第三方路由

这是推荐的日常第三方模式。它切换到 CCSwitch/custom 路由，但尽量保留官方 ChatGPT / OpenAI 登录态。

行为：

1. 关闭旧的 Codex Desktop。
2. 如果当前默认 `.codex` 看起来是官方态，自动安全保存官方登录文件。
3. 只恢复已保存的第三方 `config.toml`。
4. 保留当前官方 `auth.json`；如果当前不是官方登录态，则尝试从 official profile 只恢复 `auth.json`。
5. 开启 CCSwitch 的 Codex 应用增强：`preserveCodexOfficialAuthOnSwitch=true`。
6. 重启或启动 CCSwitch，检查 `127.0.0.1:15721`，并确认增强已开启。
7. 启动 Codex Desktop。

菜单 `2` 不会恢复第三方 `auth.json`，因此不会用第三方登录文件覆盖官方登录文件。

第三方 provider、模型映射、Base URL 和 key 都应在 CCSwitch 里管理，本启动器不会修改这些内容。

### 3. 第三方模式：纯第三方/API-key

适合只使用第三方 API-key 状态，不承诺官方插件、手机远程等官方能力可用。

行为：

1. 关闭旧的 Codex Desktop。
2. 如果当前默认 `.codex` 看起来是官方态，自动安全保存官方状态。
3. 恢复第三方 `config.toml` 和第三方 `auth.json`。
4. 关闭 CCSwitch 的 Codex 应用增强：`preserveCodexOfficialAuthOnSwitch=false`。
5. 重启或启动 CCSwitch，检查 `127.0.0.1:15721`，并确认增强已关闭。
6. 启动 Codex Desktop。

菜单 `3` 不会覆盖已保存的 official profile。之后仍可通过菜单 `1` 回到官方模式。

### 4. 检查当前状态

菜单 `4` 会运行 `doctor`。这是只读诊断，不创建目录、不改配置、不启动或关闭程序。

它会检查：

- Codex Desktop 是否安装。
- CCSwitch 是否安装和运行。
- `127.0.0.1:15721` 是否监听。
- 当前 `.codex` 是官方态、API-key 态、未知态还是不存在。
- official profile、第三方路由配置、纯第三方/API-key 状态是否完整。
- 桌面快捷方式是否指向当前启动器脚本。
- 旧 `Start Codex With CC Switch` 快捷方式是否仍存在。

### 5. 初始化/升级本机启动器

菜单 `5` 会运行 `bootstrap`。它用于新电脑、升级、重新生成快捷方式或修复旧路径。

`bootstrap` 允许做：

1. 创建非敏感 `launcher-config.json`。
2. 创建或更新桌面快捷方式。
3. 备份旧快捷方式元数据。
4. 优先发现真实 `Codex.exe` 并写入本机配置，减少公司电脑 AppId 启动被拦的概率。
5. 输出下一步建议。

`bootstrap` 不会删除旧快捷方式，不会删除 `.codex`、`.cc-switch` 或 CCSwitch 数据库，不会复制或迁移任何登录态。

## 新电脑首次使用流程

每台电脑都要在本机初始化、本机登录、本机保存 profile。不要从其他电脑复制 `auth.json`、`.codex`、`.cc-switch`、token、API key 或 refresh token。

第一步：初始化和诊断。

```powershell
.\codex-launcher.ps1 -Mode bootstrap
.\codex-launcher.ps1 -Mode doctor
```

如果 `doctor` 显示 `Codex 启动目标：Exe ...`，这是推荐状态。若只显示 `AppId ...`，普通个人电脑通常仍可用；公司电脑或管理员窗口可能拦截 AppId 启动，此时优先在 `%USERPROFILE%\.codex-launcher\launcher-config.json` 中设置真实 `codexPath`。

第二步：建立官方状态。

```powershell
.\codex-launcher.ps1 -Mode official
```

如果 Codex 要求网页登录，用这台电脑上的浏览器完成官方 ChatGPT / OpenAI 登录。登录完成并确认能进入官方状态后，后续切换时启动器会自动安全保存这台电脑自己的官方状态。

保存过官方状态后，再运行官方模式应复用本机 official profile，不应每次都跳网页登录。

建立第三方状态：

1. 先在 CCSwitch 里配置 provider、模型映射和第三方 key。
2. 日常推荐运行启动器并选择 `2`，保留官方登录并使用第三方路由。
3. 如果明确需要纯第三方/API-key 状态，再选择 `3`。

## 配置

配置文件是可选的。只有自动发现 Codex 或 CCSwitch 失败时，才需要复制示例配置：

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex-launcher"
Copy-Item .\launcher-config.example.json "$env:USERPROFILE\.codex-launcher\launcher-config.json"
notepad "$env:USERPROFILE\.codex-launcher\launcher-config.json"
```

不要把 API keys、tokens、cookies、passwords、provider secrets 或 `auth.json` 内容写进配置文件。

## 命令行模式

```powershell
.\codex-launcher.ps1
.\codex-launcher.ps1 -Mode official
.\codex-launcher.ps1 -Mode thirdparty
.\codex-launcher.ps1 -Mode thirdparty-preserve-auth
.\codex-launcher.ps1 -Mode thirdparty-pure
.\codex-launcher.ps1 -Mode bootstrap
.\codex-launcher.ps1 -Mode doctor
.\codex-launcher.ps1 -Mode check
```

不真正启动程序，只检查将要执行的动作：

```powershell
.\codex-launcher.ps1 -Mode official -NoLaunch
.\codex-launcher.ps1 -Mode thirdparty -NoLaunch
.\codex-launcher.ps1 -Mode thirdparty-pure -NoLaunch
```

## 安全边界

启动器允许做：

- 在 `%USERPROFILE%\.codex-launcher\profiles` 下保存和恢复本地 profile 文件。
- 在官方模式里清理当前启动器进程和 Codex 子进程里的第三方环境变量。
- 启动或关闭本机 Codex 与 CCSwitch 进程。
- 备份并修复默认 `%USERPROFILE%\.codex\config.toml` 中明确的 custom provider 配置。
- 备份并暂时移走 API-key 风格的 `%USERPROFILE%\.codex\auth.json`，以便官方网页登录。
- 在 `bootstrap` 中创建本机配置和桌面快捷方式。
- 在 `doctor` 中进行只读诊断。

启动器不允许做：

- 打印、导出、上传、哈希或转换 `auth.json` token 内容。
- 把 OAuth token 转换成 API key。
- 把无法识别的 `auth.json` 当作 API-key 登录态自动移走。
- 覆盖已有 official profile 而不先备份。
- 管理第三方 key。
- 修改 CCSwitch provider、Base URL、模型映射、本地路由配置、数据库或第三方 key。
- 修改 Windows 全局用户或机器环境变量。
- 删除 `%USERPROFILE%\.codex`、`%USERPROFILE%\.cc-switch` 或任何 CCSwitch 数据库/配置目录。

## 公司电脑旧快捷方式清理

如果本启动器替代旧的 `Start Codex With CC Switch` 快捷方式，只删除快捷方式文件，保留 CCSwitch 数据。

```powershell
$shortcutNames = @(
  'Start Codex With CC Switch.lnk',
  'Start Codex With CC Switch.url'
)

$locations = @(
  "$env:USERPROFILE\Desktop",
  "$env:PUBLIC\Desktop",
  "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
)

foreach ($location in $locations) {
  foreach ($name in $shortcutNames) {
    $path = Join-Path $location $name
    if (Test-Path -LiteralPath $path) {
      Write-Host "Delete shortcut only: $path"
      Remove-Item -LiteralPath $path
    }
  }
}
```

不要删除 `%USERPROFILE%\.cc-switch`、CCSwitch 数据库、CCSwitch 配置文件或 `%USERPROFILE%\.codex`。

## 测试

```powershell
Invoke-Pester .\tests\codex-launcher.tests.ps1
```

如果没有安装 Pester，也可以用 PowerShell parser 检查脚本：

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\codex-launcher.ps1), [ref]$null, [ref]$errors) | Out-Null
if ($errors) { $errors | Format-List } else { 'PARSE_OK' }
```

## 故障排查

- 官方模式第一次要求网页登录是正常的；启动器不会伪造或迁移官方 auth。
- 如果官方模式每次都要求网页登录，先确认网页登录成功后是否执行过菜单 `3`。
- 如果第三方模式不是预期 provider，先在 CCSwitch 里切好 provider，再运行菜单 `2`。
- 如果找不到 Codex 或 CCSwitch，把可执行文件路径写进 `%USERPROFILE%\.codex-launcher\launcher-config.json`。
- 如果窗口标题显示“管理员”，且 `doctor` 只检测到 `AppId`，公司电脑可能会拦截 `explorer.exe shell:AppsFolder\...`。请关闭管理员窗口，改用桌面快捷方式或普通 PowerShell；若仍失败，需要在配置中写入真实 Codex Desktop 的 `codexPath`。
