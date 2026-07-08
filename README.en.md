# Codex Windows Launcher

[中文](README.md) | **English (current)**

Current version: `v0.4.33`

Codex Windows Launcher is a PowerShell launcher for switching Codex Desktop on Windows between official ChatGPT/OpenAI login and third-party or CCSwitch routing.

It manages local launcher profiles, starts and stops Codex Desktop and CCSwitch in a defined order, and can call Codex History Sync Tool before launch to repair local history visibility. It does not copy cloud chats, migrate credentials, manage API keys, or upload local Codex data.

## Modes

- `1. Official mode`: restores the saved ChatGPT/OpenAI official login profile and starts Codex Desktop.
- `2. Third-party mode, preserve official login file`: uses CCSwitch/custom third-party key routing without forcing official OAuth validation and without restoring third-party `auth.json`.
- `3. Third-party/API-key mode`: restores third-party configuration and third-party `auth.json`.
- `4. Repair`: backs up and clears Codex Desktop Electron/UI crash cache when the app opens to the error page.
- `5. Doctor`: read-only diagnostics.
- `6. Bootstrap`: creates local launcher config and shortcuts.

## Relationship With Codex History Sync Tool

This project is the launcher and mode switcher. The companion project [`codex-history-sync-tool-windows`](https://github.com/aizijigao-sketch/codex-history-sync-tool-windows) repairs local history visibility, provider metadata, session indexes, archive indexes, and project lists.

Recommended source layout:

```text
<your-projects-root>\codex-windows-launcher
<your-projects-root>\codex-history-sync-windows-work
```

Default integration:

- Menu `1` expects provider `openai`.
- Menu `2` expects provider `custom`.
- Before starting Codex, menus `1` and `2` look for `codex-history-sync-windows-work\sync_backend.py` and run an `--expected-provider` sync against the default `%USERPROFILE%\.codex`.
- If Codex History Sync Tool is not installed or not discoverable, this launcher can still switch profiles and start Codex, but it cannot repair local history visibility.

## Required Software

- Windows 10/11.
- PowerShell 5.1 or PowerShell 7.
- Codex Desktop.
- CCSwitch for third-party/custom routing.
- Python 3 if using the source version of Codex History Sync Tool.
- Pester only for running developer tests.

## Configuration Ownership

- Complete official ChatGPT/OpenAI login inside Codex Desktop and the browser.
- Configure third-party provider, model mapping, Base URL, and API keys inside CCSwitch or the provider tool.
- Edit `%USERPROFILE%\.codex-launcher\launcher-config.json` only when automatic discovery of Codex, CCSwitch, or History Sync Tool fails.
- Do not put API keys, tokens, cookies, passwords, provider secrets, or `auth.json` content in launcher config.

## Quick Start

```powershell
.\codex-launcher.ps1 -Mode bootstrap
.\codex-launcher.ps1 -Mode doctor
.\codex-launcher.ps1
```

Common direct modes:

```powershell
.\codex-launcher.ps1 -Mode official
.\codex-launcher.ps1 -Mode thirdparty-preserve-auth
.\codex-launcher.ps1 -Mode thirdparty-pure
.\codex-launcher.ps1 -Mode repair
```

## Safety Boundaries

Allowed:

- Save and restore local profile files under `%USERPROFILE%\.codex-launcher\profiles`.
- Start and stop local Codex Desktop and CCSwitch processes.
- Back up and repair explicit custom-provider entries in `%USERPROFILE%\.codex\config.toml`.
- Create local launcher config and desktop shortcuts during bootstrap.

Not allowed:

- Print, export, upload, hash, convert, or migrate `auth.json` token content.
- Convert OAuth tokens into API keys.
- Manage third-party API keys.
- Modify CCSwitch provider, Base URL, model mapping, local route config, database, or key store.
- Delete `%USERPROFILE%\.codex`, `%USERPROFILE%\.cc-switch`, or CCSwitch data.
- Copy `.codex`, `.cc-switch`, `auth.json`, tokens, API keys, refresh tokens, or provider databases between computers.

## Tests

## Recent Notes

`v0.4.14` avoids repeated pre-launch history waits when the only remaining issue is a `session_meta` soft mismatch, usually caused by the currently active Codex session file being busy. Provider, database visibility, `session_index.jsonl`, and archive-index issues still block launch until repaired.

`v0.4.15` also treats `cwd_prefix_threads` as a soft issue. Codex Desktop can rewrite thread `cwd` values with the Windows long-path `\\?\...` prefix after a normal run; when provider/model, indexes, and archive state are already correct, this no longer triggers a full pre-launch sync.

`v0.4.16` adds compatibility with older Codex History Sync Tool builds. If the local `sync_backend.py` does not support `--expected-provider`, the launcher automatically falls back to the older argument set and still validates the provider locally before repairing or launching.

`v0.4.17` handles even older Codex History Sync Tool builds. If the local `sync_backend.py` does not support the `status` / `sync` subcommands and only returns usage text, the launcher skips history checks and continues starting Codex while recommending a History Sync Tool upgrade. Provider safety checks still apply when valid JSON status is available.

`v0.4.18` adds `repair` mode. When Codex Desktop only opens to the error page, the launcher closes Codex, backs up and clears Electron cache directories under `%APPDATA%\Codex` plus `.codex-global-state.json`, then starts Codex again. It does not delete `auth.json`, `config.toml`, chats, profiles, or CCSwitch data.

`v0.4.19` adds automatic repair suggestions and evidence capture. `doctor` checks recent Codex Desktop UI state changes and suggests `repair` when appropriate; each Codex launch now performs a lightweight health check and prints a repair command if the process exits quickly. `repair` also writes `repair-evidence.txt` and copies recent launcher logs into the backup folder for future debugging.

`v0.4.20` prevents the error page from returning after `repair` followed by menu `1`. `repair` now quarantines the launcher's saved Codex UI snapshot and writes a local repair marker; shortly after repair, official and third-party switches skip restoring the old UI snapshot so stale Electron state is not reintroduced.

`v0.4.21` prevents a freshly completed official login from being overwritten by an older official profile cache. Menu `1` now checks whether the current default `.codex` already looks like an official login before restoring cached state; if so, it saves that current state as the latest official profile first.

`v0.4.22` turns menu `1` into a state-aware official profile flow. If the current default `.codex` already looks like an official login, the launcher skips restoring the old official profile and only updates the cache when it is missing or older. It restores cached official state only when the current state is not confirmed official, making menu `1` / `2` / `3` switching safer.

`v0.4.23` fixes menu `1` stopping before launch when the current state is already official but saving the official profile cache fails. Cache saving is now non-blocking in that path: the launcher logs a warning and continues starting Codex with the current official login.

`v0.4.24` fixes a PowerShell expression parsing error in menu `1` when checking whether the official profile cache needs an update. `Test-Path` and `-and` conditions now use explicit parentheses so `-and` is not parsed as a `Test-Path` parameter.

`v0.4.25` fixes the older Codex History Sync Tool compatibility path under Windows PowerShell 5.1. When an old `sync_backend.py` does not support `--expected-provider` and writes usage text to stderr, the launcher now treats that stderr as command output inside the wrapper, falls back to the older argument set, and no longer blocks menu `1` / `2` from starting Codex.

`v0.4.26` fixes a provider-detection mismatch between menu `2` and older History Sync Tool builds. If the active `config.toml` is confirmed as a CCSwitch/custom route and the old tool reports `login_mode=cc-switch-local-route` while still returning `current_provider=openai`, the launcher treats that status as compatible with the third-party route instead of blocking Codex startup.

`v0.4.27` restores the menu `2` history-repair safety boundary. If an older History Sync Tool does not support `--expected-provider custom` and there is still history work to repair, the launcher no longer falls back to running `sync`, because that can write third-party/custom-route history into the `openai` bucket. It now asks the user to upgrade History Sync Tool first.

`v0.4.28` narrows what menu `2` saves as official state. Preserve-auth third-party mode now saves only a confirmed official `auth.json`, not the active custom-route `config.toml`, so an old official profile cannot overwrite a freshly completed login.

`v0.4.29` improves post-launch error-page diagnostics. After menus `1`, `2`, or `3` start Codex, if the Codex process exits quickly or local Electron/UI state changes while the app shows `Oops, an error has occurred` / `Update Codex` / `Try again`, the launcher writes `%USERPROFILE%\.codex-launcher\backup\launch-evidence.*` with launch evidence, Windows Application events, Codex Desktop logs, and the current launcher log so future fixes can use real logs instead of screenshots only.

`v0.4.30` fixes a `v0.4.29` StrictMode failure in launch evidence capture. The evidence writer now uses the real config summary fields `HasCustomProviderSection` and `HasLocalRouteBaseUrl`, so the post-launch health check no longer interrupts menu `2`.

`v0.4.31` tried to set menu `2` to `requires_openai_auth = false`, but that prevents Codex UI from loading plugin and workspace state as the official account. `v0.4.33` corrects that direction.

`v0.4.32` corrects menu `2` UI state restoration boundaries. Menu `2` still saves the Codex UI snapshot for backup and diagnostics, but it no longer restores an old `.codex-global-state.json` before launch, avoiding reopening a stale "Oops, an error has occurred" state.

`v0.4.33` corrects the final menu `2` authentication boundary. Menu `2` is official account UI state plus CCSwitch/custom routing, so it writes `requires_openai_auth = true`; each menu `2` run pins the currently active official `auth.json` as a temporary baseline, so a later menu `1` re-login can be followed by menu `2` without restoring an older login file.

```powershell
Invoke-Pester -Path .\tests\codex-launcher.tests.ps1
```
