# Changelog

All notable changes to webview-cli. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.2] — 2026-04-17

### Added
- `--x`, `--y`, `--screen` CLI flags for precise window positioning (top-left origin, point-based, 0-indexed screen)
- Window ID is emitted to stderr as `[wid] <id>` — enables `screencapture -l <id>` for clean captures
- CSS: multi-line text in `Text` components now preserves newlines (`white-space: pre-wrap`)
- Five screenshots in `media/` showing real agent-UI patterns (deploy approval, PR picker, config form, destructive confirmation, triage)

### Changed
- Diagnostic stderr output on startup: screen list + chosen screen + final window rect. Useful for automation and debugging.

## [0.1.1] — 2026-04-17

### Added
- `RadioGroup` component for A2UI rendering (mutually-exclusive option selection)
- `Image` component for A2UI rendering (remote or agent:// URLs, size control)
- One-command `install.sh` that handles Homebrew tap + formula install + Claude Code skill install + smoke test
- Codex / Gemini / MCP integration examples (`examples/openai-codex-tool.md`)
- README rewritten around agent-native usage (skill-first, not raw JSONL)

### Fixed
- Form-data collection now correctly handles radio button groups (only checked option contributes)

## [0.1.0] — 2026-04-17

Public launch. First stable release.

### Added

- Single-file Swift CLI wrapping `WKWebView` for AI agent workflows
- Three modes of operation:
  - `--url <url>` to open any URL (http/https/file/agent)
  - `--a2ui` to read A2UI v0.8 JSONL from stdin and render with the built-in renderer
  - Stdin `load` command for piping custom HTML resources via `agent://` scheme
- A2UI renderer supporting 9 components: `Text`, `TextInput`, `Button`, `Column`, `Row`, `Card`, `Select`, `Checkbox`, `Divider`
- Stdout JSON protocol: `{"status":"completed","data":{...}}` / `cancelled` / `timeout` / `error`
- Exit codes: `0` completed, `1` cancelled, `2` timeout, `3` error
- `WKScriptMessageHandler` bridge for `complete` and `ready` events
- `applicationWillTerminate` safety net: emits `cancelled` on SIGTERM
- Escape key and `Cmd+W` both emit `cancelled`
- Homebrew tap at `giannimassi/homebrew-tap`
- `/webview` skill for Claude Code agents with templates for approval, select, form, and confirmation patterns

### Performance

- 193KB binary (no runtime dependencies beyond macOS system frameworks)
- ~180ms cold-start on Apple Silicon (spawn → page rendered)
- macOS 12+ (Swift runtime ships with OS, no bundled libswiftCore)

### Known limitations

- macOS-only — no Linux or Windows port
- No data-binding expressions (`dataModelUpdate` not fully supported)
- No `--css` custom-theme flag (opinionated defaults only)
- No persistent cookie storage across invocations
- No code signing or notarization — Gatekeeper will warn on first open unless installed via brew
