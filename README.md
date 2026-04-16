<p align="center">
  <h1 align="center">webview-cli</h1>
  <p align="center"><strong>Native macOS UIs for CLI AI agents.</strong><br>
  193KB single binary · ~180ms cold start · no Electron · no npm</p>
</p>

<p align="center">
  <!-- HERO GIF GOES HERE — replace media/hero.gif with the 30s demo before launch -->
  <img src="media/hero.gif" alt="webview-cli demo: agent asks for deploy approval, user responds in native window, JSON returned on stdout" width="640">
</p>

<p align="center">
  <a href="https://github.com/giannimassi/webview-cli/actions"><img src="https://github.com/giannimassi/webview-cli/workflows/CI/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-12%2B-black" alt="macOS 12+"></a>
  <a href="#install"><img src="https://img.shields.io/badge/binary-193KB-green" alt="193KB"></a>
</p>

```bash
brew tap giannimassi/tap
brew install webview-cli
```

---

## What it is

Your agent spawns `webview-cli` like a bash command. Pipes in a description of the UI it wants. A real macOS window opens in under 200ms. The user interacts — types, clicks, picks. Structured JSON comes back on stdout. The process exits. The agent continues.

No Electron runtime, no npm tree, no persistent daemon, no browser context. Just a Unix tool that speaks JSON and renders native UIs.

## Quick start

```bash
cat <<'EOF' | webview-cli --a2ui --title "Deploy" --width 540 --height 480 --timeout 120
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["card"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"card","component":{"Card":{"child":"content"}}}]}}
{"surfaceUpdate":{"components":[{"id":"content","component":{"Column":{"children":{"explicitList":["title","note","buttons"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"title","component":{"Text":{"usageHint":"h2","text":{"literalString":"Deploy to production?"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"note","component":{"TextInput":{"label":{"literalString":"Note"},"fieldName":"note","multiline":true}}}]}}
{"surfaceUpdate":{"components":[{"id":"buttons","component":{"Row":{"alignment":"end","children":{"explicitList":["btn_c","btn_d"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn_c","component":{"Button":{"label":{"literalString":"Cancel"},"variant":"secondary","action":{"name":"cancel"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn_d","component":{"Button":{"label":{"literalString":"Deploy"},"variant":"success","action":{"name":"approve"}}}}]}}
{"beginRendering":{"root":"root"}}
EOF
```

Click Deploy and stdout gets:

```json
{"status":"completed","data":{"action":"approve","data":{"note":"LGTM"},"context":{}}}
```

Exit code is `0`. Cancel → exit `1`. Timeout → exit `2`. Error → exit `3`.

## Use cases

### Deploy approval

<img src="media/approval.png" alt="Approval form" width="420" align="right">

Agent wants to run a destructive action. Pop a real UI with the context (what it wants to do, why) plus a comment field. User says yes/no with one click — the comment goes into the deploy log.

[→ `examples/hero-deploy-approval.jsonl`](examples/hero-deploy-approval.jsonl)

<br clear="all">

### Pick from agent-found options

<img src="media/select.png" alt="Selection form" width="420" align="right">

Agent enumerates candidates (PRs to review, branches to rebase onto, customers to inspect). User picks one. Agent continues with their choice.

[→ `examples/multi-field-form.jsonl`](examples/)

<br clear="all">

### Form input

<img src="media/form.png" alt="Multi-field form" width="420" align="right">

Agent needs structured config. One form beats N terminal prompts. Text, select, checkbox, textarea — all native.

<br clear="all">

### Custom HTML via `agent://`

When A2UI's 9 components aren't enough (charts, diagrams, diff views), pipe base64-encoded HTML on stdin. webview-cli serves it from an in-memory scheme handler. No HTTP server needed.

[→ `docs/protocol.md#agent-scheme`](docs/protocol.md)

## Why not Electron / Tauri / osascript

| | webview-cli | Electron | Tauri | osascript |
|---|---|---|---|---|
| Binary size | **193KB** | 50MB+ | 8-15MB | built-in |
| Cold start | **~180ms** | 500-800ms | 300-500ms | ~300ms |
| Rich HTML/CSS | ✅ | ✅ | ✅ | ❌ (2 buttons + text) |
| Structured JSON out | ✅ | app-specific | app-specific | ❌ (string) |
| Spawnable subprocess | ✅ | ❌ (app lifecycle) | ❌ (app lifecycle) | ✅ |
| Runtime dependencies | **none** | Electron runtime | WebKit2 + Rust | none |

`gum` is in a different category — it's a terminal UI toolkit, not a native-window tool. Use `gum` for TUI spinners and selection; use `webview-cli` when you want a real window.

## Supported A2UI components

`Text`, `TextInput`, `Button`, `Column`, `Row`, `Card`, `Select`, `Checkbox`, `Divider`. Subset of [Google's A2UI v0.8 standard catalog](https://a2ui.org/specification/v0.8-a2ui/). See [`docs/a2ui-subset.md`](docs/a2ui-subset.md) for the full reference.

Not shipped yet: `Image`, `List`, `RadioGroup`. On the roadmap for v0.2.

## Install

### Homebrew (recommended)

```bash
brew tap giannimassi/tap
brew install webview-cli
```

### From source

```bash
git clone https://github.com/giannimassi/webview-cli.git
cd webview-cli
make install   # copies to ~/bin/webview-cli
```

Requires macOS 12+ and the Swift toolchain (bundled with Xcode or Xcode Command Line Tools).

## Claude Code skill

`webview-cli` ships with a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) so agents can `generate form → show → parse result` in one call:

```bash
ln -s "$(pwd)/skill" ~/.claude/skills/webview
```

The skill includes four copy-paste templates (approval, select, form, confirmation) and full workflow documentation. See [`skill/README.md`](skill/README.md).

## How it works

One Swift file, ~500 lines. `NSApplication` with `.accessory` policy (no Dock icon), one `NSWindow` with a `WKWebView`, `WKScriptMessageHandler` bridging JS to stdout, `WKURLSchemeHandler` serving an embedded renderer via `agent://`. Stdin feeds A2UI JSONL into the renderer. See [`docs/architecture.md`](docs/architecture.md) for the full tour.

The renderer itself is ~200 lines of vanilla JS — no React, no framework, no build step. It's embedded as a string literal in the Swift binary.

## Protocol

Full stdin/stdout/exit-code reference in [`docs/protocol.md`](docs/protocol.md).

## Why macOS only

The target user is already on macOS (Claude Code, Cursor, Codex CLI users skew heavily macOS). Cross-platform is possible with GTK/WebView2 — PRs welcome, but the maintainer is not splitting attention at v0.1. See [CONTRIBUTING.md](CONTRIBUTING.md) for scope.

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [A2UI](https://a2ui.org/) by Google — the declarative UI spec this implements a subset of
- [CopilotKit](https://docs.ag-ui.com/) — for popularizing the agent-UI space and publishing reference renderers

---

<p align="center">
  Built by <a href="https://github.com/giannimassi">@giannimassi</a>. If this helped you, <a href="https://github.com/giannimassi/webview-cli">leaving a star</a> is appreciated.
</p>
