# Changelog

All notable changes to webview-cli. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.3] — 2026-04-17

Council-review cleanup of the `/webview` Claude Code skill. No binary changes.

### Fixed
- **Mode 3 (custom HTML) example was broken** — missing `--url` flag; invocation would exit with usage error. Also replaced the chained `(cmd; cat) | webview-cli` pattern with two-step (write load command to temp file, then invoke with stdin redirect).
- **SKILL.md catalog was missing 3 supported components** — `Checkbox`, `RadioGroup`, `Image` now documented with their key props.
- **Template 4 (confirmation with content preview) had no response-shape example** — added both `proceed` and `back` response variants.
- **Preflight was personal-machine-specific** — removed the `~/dev/fun/webview-cli` build-from-source fallback; preflight now recommends `brew install` on missing binary and explicitly checks `uname -s` for macOS.

### Changed
- **Bash-tool timeout formula is now deterministic**: `bash_timeout_ms = (webview_timeout_sec + 30) × 1000`. Previously "generously". Noted the 600s Bash-tool cap (max webview timeout 540s).
- **Added a canonical Response Format Reference section** to SKILL.md covering all 4 status variants (`completed` / `cancelled` / `timeout` / `error`) and the `context` field.
- **Lifted JSONL escaping rules** (backslash, quotes, newlines) into SKILL.md as a visible callout — was previously buried in templates.md.
- **Workflow step 9 now warns to sanitize form data** before passing to Bash commands (shell-escape, validate format).
- **Trigger description narrowed** — dropped "confirm" (over-matched every `rm -rf` prompt) and "show UI" (too generic). Now specifies "multi-field", "5+ choices", "approval with context", "content review". Skip rule for CI/non-interactive made explicit.
- **"When to use" table clarified** the backward `>30s of thinking` heuristic — now "agent-side computation taking >30s before UI can render".

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
