# Codex Windows 启动器

**中文（当前）** | [English](README.en.md)

当前版本：`v0.4.33`

一个 Windows PowerShell 启动器，用来在 Codex Desktop 的官方登录态和第三方路由状态之间切换：

- 官方模式：恢复已保存的 ChatGPT / OpenAI 官方登录态并启动 Codex。
- 第三方模式，保留官方登录文件：使用 CCSwitch / custom 第三方 key 路由，不强制官方 OAuth 校验，也不恢复第三方 `auth.json`。
- 第三方模式，纯第三方/API-key：恢复第三方配置和第三方 `auth.json`。
- 修复模式：备份并清理 Codex Desktop 的 Electron/UI 崩溃缓存，用于启动后只显示“糟糕，出错了”的情况。

这个项目主要负责启动和切换 Codex Desktop。菜单 `1` 和菜单 `2` 会在启动 Codex 前检查本地聊天状态；如果聊天状态干净，就完全跳过聊天恢复；如果发现异常且能找到 Codex History Sync Tool，就对当前默认 `%USERPROFILE%\.codex` 执行定向历史同步；如果找不到该工具，就明确提示“不涉及聊天记录恢复”并继续启动 Codex。它不会复制聊天正文、跨账号同步云端记录、迁移 `auth.json`、token、API key 或 CC Switch 数据库。


## 两个项目怎么配合

本项目是“启动和切换器”，另一个项目 [Codex History Sync Tool for Windows](https://github.com/aizijigao-sketch/codex-history-sync-tool-windows) 是“本地历史可见性修复工具”。

推荐放置方式：

```text
<your-projects-root>\codex-windows-launcher
<your-projects-root>\codex-history-sync-windows-work
```

默认联动规则：

- 启动器负责菜单、登录态 profile 切换、Codex Desktop 启动、CCSwitch 启停和本地路由状态检查。
- History Sync Tool 负责 `state_5.sqlite`、session metadata、`session_index.jsonl`、归档索引和项目列表的本地修复。
- 启动器菜单 `1` 期望 provider 为 `openai`；菜单 `2` 期望 provider 为 `custom`。
- 菜单 `1` 和菜单 `2` 启动前会尝试寻找相邻的 `codex-history-sync-windows-work\sync_backend.py`，并使用 `--expected-provider` 做定向同步。
- 如果 History Sync Tool 不存在，启动器仍可切换和启动 Codex，但不会修复聊天记录可见性。

## 需要的软件和配置边界

需要安装：

- Windows 10/11。
- PowerShell 5.1 或 PowerShell 7。
- Codex Desktop。
- CCSwitch：只有菜单 `2` / `3` 的第三方路由需要。
- Python 3：只有源码方式联动 History Sync Tool 时需要；如果只使用安装版 History Sync Tool，可通过它自己的安装包安装。
- Pester：仅开发者运行测试时需要。

需要在本机配置：

- Codex Desktop 官方登录：菜单 `1` 首次运行后在浏览器里完成 ChatGPT / OpenAI 登录。
- CCSwitch provider、模型映射、Base URL 和第三方 key：在 CCSwitch 里配置，不在启动器里配置。
- 启动器本机路径：自动发现失败时，编辑 `%USERPROFILE%\.codex-launcher\launcher-config.json` 的 `codexPath`、`ccSwitchPath` 或 `historySyncBackendPath`。
- History Sync Tool：如果你希望菜单 `1` / `2` 自动修复聊天可见性，请安装发布版，或把源码项目放在同一个 `20_Projects` 目录下。

不要配置或复制：

- 不要跨电脑复制 `auth.json`、`.codex`、`.cc-switch`、token、API key、refresh token 或 CCSwitch 数据库。
- 不要把第三方 key 写进 `launcher-config.json`。
- 不要把 Codex CLI 路径 `%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe` 当作 Codex Desktop 路径。

## 方案说明

Windows 版 Codex Desktop 通过 Windows AppId 启动时，通常会读取默认 `%USERPROFILE%\.codex`。给桌面版单独设置 `CODEX_HOME` 并不稳定，所以本启动器采用本地 profile 文件切换：

- `%USERPROFILE%\.codex-launcher\profiles\official`：官方登录态和非 custom 配置。
- `%USERPROFILE%\.codex-launcher\profiles\thirdparty`：CCSwitch/custom 配置；纯第三方模式也可使用其中的 API-key 风格登录态。
- `%USERPROFILE%\.codex-launcher\backup`：切换前的本地备份。
- `%USERPROFILE%\.codex-launcher\state\codex-ui-state.json`：切换前后保护的 Codex 界面偏好快照。

启动器只在本机复制、恢复、备份这些 profile 文件，不打印、不上传、不转换 `auth.json` 或 token 内容。

从 `v0.4.2` 开始，启动器会额外保护 Codex Desktop 的本地界面偏好，例如工作模式、窗口位置、侧边栏状态、已看过的提示等。它不会保存 `prompt-history`、线程正文、cookie、token 或 `auth.json` 内容。个性化如果由 Codex 官方账号云端保存，启动器只能避免本地状态被覆盖，不能强行改写云端账号设置。

`v0.4.3` 明确修复菜单 `2` 的配置保留边界：保留官方登录态的同时，也保留官方/当前配置里的插件、marketplace、MCP 和桌面设置，避免旧 thirdparty profile 把官方能力覆盖掉。

`v0.4.4` 优化启动前历史处理：菜单 `1` 和菜单 `2` 会先快速检查历史状态；如果聊天记录已经可见且没有待修复项，会直接跳过修复，不再每次等待完整同步。

`v0.4.5` 优化等待体验：关闭 Codex 时会提示最长等待时间，无主窗口子进程直接强制关闭；历史修复会显示正在运行的提示，失败或仍有剩余项时继续启动 Codex。

`v0.4.6` 修复官方模式历史可见性：菜单 `1` 恢复官方 profile 后会明确写入 `model_provider = "openai"`，再运行历史检查/修复；CCSwitch 关闭改为立即强制关闭，不再做主窗口等待。

`v0.4.7` 增强历史同步诊断：菜单 `1` 期望 provider 为 `openai`，菜单 `2` 期望 provider 为 `custom`；启动前会打印实际同步目标、总线程和待修复数，并显式把 History Sync Tool 绑定到默认 `%USERPROFILE%\.codex`。

`v0.4.8` 收敛聊天恢复职责：启动器只判断聊天状态是否异常；异常时调用 Codex History Sync Tool 的 `--one-click-safe-sync` 一键安全恢复；状态干净或工具不存在时不自行修复聊天。同时修复 Codex 界面偏好快照 JSON 序列化失败。

`v0.4.9` 修复 provider 不一致时只报警不恢复的问题：菜单 `1` / `2` 发现实际 provider 与期望 provider 不一致时，也会视为聊天/通道异常并调用 Codex History Sync Tool 一键安全恢复；一键恢复模式改为 `--mode auto`。

`v0.4.10` 增加落盘日志：每次运行会写入 `%USERPROFILE%\.codex-launcher\logs\launcher.yyyyMMdd-HHmmss.log`，记录菜单阶段、History Sync Tool 来源、status 摘要、一键恢复命令与退出码，便于定位聊天恢复失败；日志会做基础脱敏，不记录 `auth.json` 内容或 token。

`v0.4.11` 修复 History Sync Tool `status` 返回解析错误：`status` 命令返回顶层状态对象时不再误读 `.status` 子属性，避免菜单 `1` 在真正调用一键恢复前就失败。

`v0.4.12` 修复菜单 `2` 从官方模式切回第三方模式时的聊天恢复目标错误：启动器会把 thirdparty profile 的 `config.toml` 修正为 `model_provider = "custom"`、`[model_providers.custom]`、本地 CCSwitch route 和 `requires_openai_auth = true` 齐全后再调用 History Sync Tool；如果 History Sync Tool 仍识别到错误 provider，启动器会停止恢复和启动，避免把聊天记录修到错误通道。日志会额外输出脱敏 config 摘要。

`v0.4.13` 将启动前聊天恢复从 `--one-click-safe-sync --mode auto` 改为针对默认 `.codex` 的 `--json sync` 定向恢复：启动器会先最多 3 次复查 History Sync Tool 看到的 provider 是否稳定匹配菜单期望，再执行同步；恢复后如果 provider 仍不匹配或仍有待修复项，会停止启动，避免进入“看似已恢复但侧栏仍缺聊天”的状态。

`v0.4.14` 修复菜单 `2` 反复等待历史修复的问题：启动器现在只把 provider、数据库可见性、`session_index.jsonl` 和归档索引问题视为会影响聊天列表的硬异常；如果仅剩当前会话文件占用导致的 `session_meta` 软异常，会提示但继续启动，不再每次启动都等待几十秒。

`v0.4.15` 进一步收窄启动前硬异常判定：Codex Desktop 运行后可能重新把历史线程 `cwd` 写成 Windows 长路径前缀 `\\?\...`，这会被 History Sync Tool 报告为 `cwd_prefix_threads`，但 provider/model、索引和归档状态都正确时不应触发完整同步。启动器现在把 `cwd_prefix_threads` 也作为软异常提示并继续启动，避免菜单 `2` 每次都重复修复。

`v0.4.16` 增加旧版 Codex History Sync Tool 兼容：如果本地 `sync_backend.py` 不支持 `--expected-provider`，启动器会自动降级为旧参数调用，并继续在启动器侧校验 provider，避免旧工具 argparse 失败后直接阻止 Codex 启动。

`v0.4.17` 修复更旧的 Codex History Sync Tool 兼容：如果本地 `sync_backend.py` 连 `status` / `sync` 子命令都不支持并只返回 usage，启动器会跳过历史检查并继续启动 Codex，同时提示升级 History Sync Tool；有效 JSON 状态下仍会保留 provider 安全校验。

`v0.4.18` 增加 `repair` 修复模式：当 Codex Desktop 启动后只显示错误页时，可先关闭 Codex，备份并清理 `%APPDATA%\Codex` 下的 Electron 缓存目录和 `.codex-global-state.json`，再重新启动 Codex。此模式不删除 `auth.json`、`config.toml`、聊天记录、profile 或 CCSwitch 数据。

`v0.4.19` 增加自动修复建议和证据留存：`doctor` 会根据近期 Codex Desktop UI 状态变化提示是否建议运行 `repair`；每次启动 Codex 后会做轻量健康检查，如果进程很快退出会给出一键 repair 指令。`repair` 会在备份目录生成 `repair-evidence.txt`，并复制最近 launcher 日志，方便后续根据日志继续升级修复。

`v0.4.20` 修复 repair 后选择菜单 `1` 又触发错误页的问题：`repair` 会隔离启动器之前保存的 Codex UI 快照，并写入本机 repair 标记；短时间内再次切换官方/第三方模式时，启动器会跳过恢复旧 UI 快照，避免把坏的 Electron 状态重新带回。

`v0.4.21` 修复 repair 后手动官方登录成功、再选菜单 `1` 反而被旧 official profile 覆盖的问题：菜单 `1` 现在会在恢复缓存前先检查当前默认 `.codex` 是否已经是官方登录态；如果是，会先保存为最新官方 profile，再继续官方模式启动。

`v0.4.22` 将菜单 `1` 改为判断式官方状态机：如果当前默认 `.codex` 已经是官方登录态，启动器会跳过恢复旧 official profile，并且只有缓存缺失或较旧时才更新缓存；只有当前不是可确认官方态时，才恢复已保存的 official profile。这样日常官方使用不会反复覆盖登录态，菜单 `1` / `2` / `3` 来回切换时也更稳。

`v0.4.23` 修复菜单 `1` 在当前已是官方登录态时，因为保存 official profile 缓存失败而中断、导致 Codex 不启动的问题。保存缓存现在是非阻塞步骤：失败会写入 warn 日志，但继续使用当前官方登录态启动 Codex。

`v0.4.24` 修复菜单 `1` 检查 official profile 缓存时的 PowerShell 表达式解析错误：`Test-Path` 与 `-and` 条件现在使用显式括号，避免把 `-and` 误当作 `Test-Path` 参数而中断启动。

`v0.4.25` 修复旧版 Codex History Sync Tool 兼容在 Windows PowerShell 5.1 下失效的问题：旧 `sync_backend.py` 不支持 `--expected-provider` 并把 usage 写到 stderr 时，启动器现在会在命令包装层把 stderr 作为普通输出分析，正确降级为旧参数调用，不再因此阻止菜单 `1` / `2` 启动 Codex。

`v0.4.26` 修复菜单 `2` 与旧版 History Sync Tool 的 provider 口径不一致问题：当当前 `config.toml` 已确认是 CCSwitch/custom 路由，且旧工具返回 `login_mode=cc-switch-local-route` 但 `current_provider=openai` 时，启动器会将其视为第三方路由兼容状态，不再误判 provider 不匹配而阻止 Codex 启动。

`v0.4.27` 恢复菜单 `2` 的历史修复安全边界：如果旧版 History Sync Tool 不支持 `--expected-provider custom`，且当前仍有待修复聊天异常，启动器不会降级执行 `sync`，避免把第三方/custom 路由的历史写到 `openai` 通道；此时会提示先升级 History Sync Tool。

`v0.4.28` 收窄菜单 `2` 保存官方状态的范围：保留官方登录的第三方模式只会保存可确认的官方 `auth.json`，不再把当前 custom 路由下的 `config.toml` 作为完整 official profile 保存，避免旧 official profile 和新登录态互相覆盖。

`v0.4.29` 增强启动后错误页诊断：菜单 `1` / `2` / `3` 启动 Codex 后，如果 Codex 进程很快退出，或本地 Electron/UI 状态刚刚变化且界面显示 `Oops, an error has occurred` / `Update Codex` / `Try again`，启动器会在 `%USERPROFILE%\.codex-launcher\backup\launch-evidence.*` 保存启动证据、Windows Application 事件、Codex Desktop 日志和本次 launcher 日志，方便后续按日志修复，不再只靠截图判断。

`v0.4.30` 修复 `v0.4.29` 启动证据采集在 PowerShell StrictMode 下读取错误属性名导致菜单 `2` 中断的问题；证据采集现在使用真实 config 摘要字段 `HasCustomProviderSection` 和 `HasLocalRouteBaseUrl`，避免启动健康检查自身崩溃。

`v0.4.31` 曾尝试把菜单 `2` 改成 `requires_openai_auth = false`，但这会让 Codex UI 不按官方账号态加载插件和工作区能力；该方向已在 `v0.4.33` 修正。

`v0.4.32` 修正菜单 `2` 启动前的 UI 状态恢复边界：菜单 `2` 会保存 Codex UI 快照用于备份和诊断，但不会在启动前恢复旧 `.codex-global-state.json`，避免把曾经出现过的“糟糕，出错了”页面状态重新写回。

`v0.4.33` 修正菜单 `2` 的最终认证边界：菜单 `2` 是官方账号态 + CCSwitch/custom 路由，必须写入 `requires_openai_auth = true`，让 Codex UI 继续加载官方登录、插件和工作区能力；同时每次进入菜单 `2` 都以当前 active 官方 `auth.json` 建立临时基准，支持菜单 `1` 重新网页登录后再切换到菜单 `2`，不会死守旧登录文件。

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
3. 保存 Codex 界面偏好快照。
4. 如果已经保存过官方 profile，恢复它并启动 Codex。
5. 如果没有官方 profile，清理默认 `.codex` 中的 custom provider 配置，并暂时移走 API-key 风格的 `auth.json`。
6. 恢复 Codex 界面偏好。
7. 启动前尝试运行本地历史可见性修复，让官方模式也能看到当前通道应显示的本地聊天。
8. 启动 Codex Desktop，让用户正常网页登录。
9. 官方登录态会在后续安全切换时自动保存；不会把第三方/API-key 状态误保存为官方状态。

保存过官方状态后，再选菜单 `1` 应该复用本地官方登录态，不应每次都跳网页登录。
如果旧 Codex 或 CCSwitch 没有完全关闭，菜单 `1` 会停止切换，避免旧进程把刚恢复的登录态、界面偏好或历史索引覆盖回去。

### 2. 第三方模式：保留官方登录态并使用第三方路由

这是推荐的日常第三方模式。它切换到 CCSwitch/custom 路由，同时保留并要求 Codex Desktop 继续使用官方 ChatGPT / OpenAI 登录态，以便插件、工作区和官方账号能力仍按官方登录加载。

行为：

1. 关闭旧的 Codex Desktop。
2. 保存 Codex 界面偏好快照。
3. 如果当前默认 `.codex` 看起来是官方态，自动安全保存官方登录文件。
4. 恢复已保存的第三方路由配置。
5. 保留当前官方 `auth.json`；如果当前不是官方登录态，则尝试从 official profile 只恢复 `auth.json`。
6. 开启 CCSwitch 的 Codex 应用增强：`preserveCodexOfficialAuthOnSwitch=true`。
7. 重启或启动 CCSwitch，检查 `127.0.0.1:15721`，并确认增强已开启。
8. 再次恢复并确认官方 `auth.json` 文件仍匹配本次菜单 `2` 开始时的基准；如果你刚在菜单 `1` 重新登录过，这个基准就是新的官方登录文件。
9. 在第三方路由配置中合并保留官方/切换前的插件、marketplace、MCP、桌面设置，避免插件列表和官方能力被旧 thirdparty profile 覆盖。
10. 将 `[model_providers.custom]` 标记为 `requires_openai_auth = true`，让 custom/CCSwitch 路由仍按官方 OAuth UI 状态加载。
11. 不恢复旧 UI 快照，避免错误页状态复发；切换前保存的快照只作为备份和诊断证据。
12. 如果能找到 `codex-history-sync-windows-work\sync_backend.py`，启动前先同步本地聊天可见性到当前通道。
13. 启动 Codex Desktop。

菜单 `2` 不会恢复第三方 `auth.json`，因此不会用第三方登录文件覆盖官方登录文件。它也不会把旧 thirdparty profile 里的插件列表当成最终状态；官方/当前配置中的插件、marketplace、MCP 和桌面设置会被保留下来。

第三方 provider、模型映射、Base URL 和 key 都应在 CCSwitch 里管理，本启动器不会修改这些内容。

### 3. 第三方模式：纯第三方/API-key

适合只使用第三方 API-key 状态，不承诺官方插件、手机远程等官方能力可用。

行为：

1. 关闭旧的 Codex Desktop。
2. 保存 Codex 界面偏好快照。
3. 如果当前默认 `.codex` 看起来是官方态，自动安全保存官方状态。
4. 恢复第三方 `config.toml` 和第三方 `auth.json`。
5. 关闭 CCSwitch 的 Codex 应用增强：`preserveCodexOfficialAuthOnSwitch=false`。
6. 重启或启动 CCSwitch，检查 `127.0.0.1:15721`，并确认增强已关闭。
7. 恢复 Codex 界面偏好。
8. 启动 Codex Desktop。

菜单 `3` 不会覆盖已保存的 official profile。之后仍可通过菜单 `1` 回到官方模式。

### 4. 检查当前状态

菜单 `4` 会运行 `doctor`。这是只读诊断，不创建目录、不改配置、不启动或关闭程序。

它会检查：

- Codex Desktop 是否安装。
- CCSwitch 是否安装和运行。
- `127.0.0.1:15721` 是否监听。
- 当前 `.codex` 是官方态、API-key 态、未知态还是不存在。
- Codex 界面状态文件和界面偏好快照是否存在。
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
