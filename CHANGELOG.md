# Changelog

All notable changes to webview-cli. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`--editor <path>` mode** — turns webview-cli into a small native text editor over a directory (or a single file's parent dir):
  - **File navigation** — a lazy-expanding file tree sidebar (dotfiles hidden, dirs first). Click a file to open it.
  - **Syntax highlighting** — a compact dependency-free tokenizer (js/ts, python, go, rust, swift, json, yaml, bash, sql, css, c-like fallback) colors code files in a live editor and fenced code blocks in markdown previews. Always HTML-escaped (XSS-safe).
  - **Markdown preview + link following** — markdown files open with Preview/Source tabs; external `http(s)` links open in the system browser, relative links resolve against the current file and open in the editor.
  - **Frontmatter** — a leading `---` YAML block is surfaced as a metadata block atop the preview (and stays editable in the Source view) rather than vanishing.
  - **⌘P quick-open** — fuzzy-find a file by name/path across the whole tree and open it.
  - **⌘⇧F content search** — grep file contents across the tree (scoped, case-insensitive); results group by file with line numbers, click to open at that line.
  - **Edits save to disk in place** (`⌘S`); the window stays open so you can keep navigating and editing.
  - **Regular app window** — editor mode runs with `.regular` activation policy (Dock icon + ⌘-Tab switcher), unlike the transient `.accessory` agent-prompt modes.
  - **`--comments` flow preserved** — with `--editor --comments`, click a preview block to attach a comment; **Submit** (`⌘↵`) returns `{action:"submit", file, edited_text, comments}` to the agent over stdout and closes, exactly like `--markdown --comments`.
- **Scoped file-I/O bridge** — a `fileOp` WKScriptMessageHandler (`listDir`/`readFile`/`writeFile`/`listAll`/`search`) scoped to the opened root, rejecting `../` and symlink escapes. `listAll` powers ⌘P; `search` powers ⌘⇧F (skips dotfiles + heavy build dirs like `node_modules`, caps walk/results). Also driveable via a `{"type":"fileop",...}` stdin command (the no-GUI CI test seam).
- **Editor test harnesses** — `scripts/editor-runtime-smoke.mjs` (jsdom: tree, open/edit/save, highlighting, links, frontmatter, comments) and `scripts/editor-smoke.sh` (binary: the `fileop` stdin protocol + path-escape rejection against a temp dir), both wired into `make test` + CI.

### Fixed

- **YAML frontmatter in `--markdown` mode** — a leading `---\n...\n---\n` block at the top of the input no longer renders as a stray `<hr>` + a setext `<h2>` containing the YAML keys. It's stripped from the preview while the Source tab still shows it unchanged and `data-src-start` / `data-src-end` annotations on downstream blocks stay anchored to the original line numbers (so comment payloads reference the lines the user actually sees).

## [0.2.0] — 2026-04-17

### Added

- **Markdown review/edit surface** via new `--markdown` CLI mode. Pipe markdown to stdin; a native window opens with a rendered preview, optional comment sidebar + edit tabs; structured JSON returns on stdout.
- **`MarkdownDoc` A2UI component** (`fieldName`, `text`, `allowComments`, `allowEdits`, `allowHtml`, `title`) — composable inside any A2UI form.
- **`--comments` flag**: click any paragraph/code block/heading to attach an inline comment; each carries `source_line_start`/`source_line_end`/`quoted_text`/`body`. Plus a doc-level "Overall comment" field.
- **`--edits` flag**: Preview/Source tabs (`Cmd+/` to toggle), tab-indent in source textarea, `modified` flag in submit payload.
- **`--allow-html` flag**: opt-in escape from default HTML sanitization.
- **GFM tables** with proper styling (collapsed borders, header background, alternating rows).
- **`action.copy`** prop on `Button`: clicking copies literal text to clipboard and flashes "Copied ✓". Composable with `action.name` so the agent can observe the copy.
- **"📋 Copy source" button** in every MarkdownDoc toolbar — copies the current source (respects live edits).
- **HTML sanitizer** strips `<script>`, `<iframe>`, `<object>`, `<embed>`, `<style>`, `<link>`, `<base>`, `<meta>`, all `on*` handlers, and `javascript:` / `vbscript:` / non-image `data:` URL schemes. `srcset` parsed per-candidate. Image `data:` URIs allow-listed to `png|jpeg|gif|webp|bmp|avif;base64,`.
- **Edit menu wired** (`Cmd+C`/`V`/`X`/`A`/`Z`). Previously the `.accessory`-policy app had no `NSApp.mainMenu`, so those shortcuts had nowhere to route — native text selection/copy/paste is now fully functional.
- **Keyboard shortcuts**: `Cmd+/` (toggle Preview/Source), `Cmd+Enter` (submit), `Esc` / `Cmd+W` (cancel).
- **Embedded `marked@12`** as a self-contained UMD (full CommonMark + GFM, including tables). Source-position annotations preserved via `marked.lexer` + byte-offset→line mapping on each top-level token.
- **Runtime JS smoke-test harness** (`scripts/runtime-smoke.mjs` via jsdom + `scripts/check-js-syntax.py` via `node --check`) runs in `make test`. Catches embedded-JS syntax and runtime bugs that `strings $BINARY | grep` never could.

### Changed

- **Binary size: 193KB → ~291KB**. The `193KB` number in the README and "193KB vs Electron's 50MB+" header have been updated accordingly. Story unchanged — still ~170× smaller than Electron.
- **`--help` output** documents the new flags in a "Modes" and "Options" layout.

### Fixed

- HTML sanitizer: closed Unicode-whitespace bypass for `javascript:` schemes (`\u00A0javascript:...` now stripped); `data:image/svg+xml` blocked (was allowed, would execute scripts in certain contexts); extended URL-attr list to include `srcset`, `poster`, `action`, `usemap`, `background`.
- Text selection: mouse-up that ended a selection drag no longer hijacks into opening a comment composer.
- Code-block and table blocks: 💬 pin indicator was clipped by `overflow-x: auto`; now anchored inside those blocks.

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
