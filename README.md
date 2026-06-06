# Codex Windows 启动器

一个 Windows PowerShell 启动器，用来在 Codex Desktop 的两个本地状态之间切换：

- 官方模式：恢复已保存的 ChatGPT / OpenAI 官方登录态并启动 Codex。
- 第三方模式：恢复已保存的 CCSwitch / custom 路由状态并重载 Codex。

这个项目只负责启动和切换 Codex Desktop。历史同步、项目列表修复、知识库同步等工具应单独使用，不属于本启动器职责。

## 方案说明

Windows 版 Codex Desktop 通过 Windows AppId 启动时，通常会读取默认 `%USERPROFILE%\.codex`。给桌面版单独设置 `CODEX_HOME` 并不稳定，所以本启动器采用本地 profile 文件切换：

- `%USERPROFILE%\.codex-launcher\profiles\official`：官方登录态和非 custom 配置。
- `%USERPROFILE%\.codex-launcher\profiles\thirdparty`：CCSwitch/custom 配置和第三方 API-key 风格登录态。
- `%USERPROFILE%\.codex-launcher\backup`：切换前的本地备份。

启动器只在本机复制、恢复、备份这些 profile 文件，不打印、不上传、不转换 `auth.json` 或 token 内容。

## 文件

- `codex-launcher.ps1`：启动器入口。
- `launcher-config.example.json`：不含密钥的配置示例。
- `scripts/create-desktop-shortcut.ps1`：创建桌面快捷方式。
- `tests/codex-launcher.tests.ps1`：Pester 静态安全检查。
- `.gitignore`：阻止本地 profile、日志、快捷方式、图标和密钥进入仓库。

## 安装

在 PowerShell 中进入项目目录：

```powershell
.\codex-launcher.ps1
```

可选：创建桌面快捷方式。

```powershell
.\scripts\create-desktop-shortcut.ps1 -Force
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
6. 第一次官方登录成功后，建议选择菜单 `3` 保存当前官方状态。

保存过官方状态后，再选菜单 `1` 应该复用本地官方登录态，不应每次都跳网页登录。

### 2. 第三方模式：恢复 CCSwitch/custom 状态并重载 Codex

适合回到 CCSwitch 管理的第三方路由。

行为：

1. 确认 CCSwitch 正在运行；没有运行则启动它。
2. 关闭旧的 Codex Desktop。
3. 如果当前默认 `.codex` 看起来是官方态，先自动保存为官方 profile。
4. 恢复已保存的第三方 profile。
5. 启动 Codex Desktop。

第三方 provider、模型映射、Base URL 和 key 都应在 CCSwitch 里管理，本启动器不会修改这些内容。

### 3. 保存当前为官方状态

官方网页登录成功并确认能正常进入 Codex 后，选择菜单 `3`。启动器会检查当前默认 `.codex`：

- 如果当前不像 API-key/custom 状态，就保存为官方 profile。
- 如果当前仍像第三方状态，就拒绝保存，避免把错误状态缓存为官方。

### 4. 检查当前状态

显示当前默认 `.codex`、已保存 profile、Codex 启动目标和 CCSwitch 状态。

## 首次使用流程

建立官方状态：

```powershell
.\codex-launcher.ps1
```

1. 选择 `4` 检查当前状态。
2. 选择 `1` 启动官方模式。
3. 如果 Codex 要求网页登录，用官方 ChatGPT / OpenAI 账号登录。
4. 登录完成并确认能进入官方状态后，关闭 Codex。
5. 再打开启动器，选择 `3` 保存当前为官方状态。

建立第三方状态：

1. 先在 CCSwitch 里配置 provider、模型映射和第三方 key。
2. 运行启动器并选择 `2`。
3. 之后需要切回第三方时，继续选择 `2` 即可。

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
.\codex-launcher.ps1 -Mode saveofficial
.\codex-launcher.ps1 -Mode check
```

不真正启动程序，只检查将要执行的动作：

```powershell
.\codex-launcher.ps1 -Mode official -NoLaunch
.\codex-launcher.ps1 -Mode thirdparty -NoLaunch
```

## 安全边界

启动器允许做：

- 在 `%USERPROFILE%\.codex-launcher\profiles` 下保存和恢复本地 profile 文件。
- 在官方模式里清理当前启动器进程和 Codex 子进程里的第三方环境变量。
- 启动或关闭本机 Codex 与 CCSwitch 进程。
- 备份并修复默认 `%USERPROFILE%\.codex\config.toml` 中明确的 custom provider 配置。
- 备份并暂时移走 API-key 风格的 `%USERPROFILE%\.codex\auth.json`，以便官方网页登录。

启动器不允许做：

- 打印、导出、上传、哈希或转换 `auth.json` token 内容。
- 把 OAuth token 转换成 API key。
- 管理第三方 key。
- 修改 CCSwitch provider、Base URL、模型映射或本地路由配置。
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
