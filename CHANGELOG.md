# Changelog

All notable changes to ProcWatch are documented here. This project adheres to
[Semantic Versioning](https://semver.org/) and the
[Keep a Changelog](https://keepachangelog.com/) format.

## [0.2.0] — 2026-06-10

### Added
- **System-tray app (`Tray.ps1`)** running in the interactive user session under
  Windows PowerShell 5.1 `-STA`:
  - State-coloured tray icon (green = monitoring, amber = paused / recent breach,
    grey = engine down/stale), generated at runtime (no binary assets in the repo).
  - Context menu: Pause/Resume monitoring, Edit config, Open logs folder, Recent
    activity, About, Exit.
  - Subsumes the old headless agent — it now both shows status and raises the
    interactive BurntToast breach toasts.
- **Engine heartbeat (`status.json`)** — the engine publishes a small status file
  each loop (pid, heartbeat time, paused flag, processes watched, breach count,
  last breach). The tray reads it to reflect live state without any privilege; a
  stale heartbeat (3 missed intervals) is treated as "engine down".
- **Pause / Resume** — new `pause`/`resume` commands and a `paused` config flag.
  When paused the engine still samples and heartbeats but takes no action, so
  resuming is instant. Event IDs 1005.
- `Get-PWVersion`, `Write-PWStatus`, `Get-PWStatus` helpers in the module.

### Changed
- Installer now registers **ProcWatch-Tray** (replacing **ProcWatch-Agent**) and
  installs BurntToast into Windows PowerShell 5.1 (the tray's host). Upgrades and
  uninstall clean up the old `ProcWatch-Agent` task automatically.
- Installer now stops any running ProcWatch processes before deploying. An old
  engine surviving an upgrade holds the single-instance mutex, which made the
  newly started engine exit silently (the upgrade only took effect at the next
  reboot); a surviving pre-0.2.0 agent would also compete with the tray for the
  notify queue. It also removes the superseded `Agent.ps1` from the install dir.
- Installer grants Users:Modify on `config.json` so the tray's "Edit config"
  can save without elevation, and `Save-PWConfig` re-asserts that ACE after its
  atomic tmp-and-rename replace (which otherwise drops it — review credit:
  Codex on PR #1).
- BurntToast is fetched via pwsh 7's `Save-Module` directly into 5.1's AllUsers
  module path when pwsh 7 is present; 5.1's own NuGet-provider bootstrap proved
  hang-prone and remains only as the fallback.
- Engine single-instance mutex name is now derived from the data root, so a
  sandboxed test instance can never collide with the deployed SYSTEM engine's
  mutex (previously caused an "Access denied" when tests ran alongside the
  service).
- `Status.ps1` shows the version, the heartbeat block, and `paused`.

### Removed
- `Agent.ps1` (folded into `Tray.ps1`).

## [0.1.0] — 2026-06-07

### Added
- Initial release: SYSTEM monitor engine, user-session agent (BurntToast
  notifications with Kill / Whitelist / Ignore buttons), `procwatch://` protocol
  handler, install/uninstall/status helpers, and a sandboxed test suite.
- Sustained-CPU detection with grace window, per-PID streak tracking, PID-reuse
  guard, auto-restart of allowlisted shells with a circuit breaker, and a
  file-queue IPC design that keeps all privileged actions in the SYSTEM engine.

[0.2.0]: https://github.com/pizzimenti/ProcWatch/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/pizzimenti/ProcWatch/releases/tag/v0.1.0
