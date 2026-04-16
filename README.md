# webview-cli

Lightweight macOS-native webview for agent workflows. Opens a URL (or a declarative A2UI-described UI), lets the user interact, returns structured JSON on stdout.

Designed as an agent primitive — Claude Code (or any CLI agent) spawns it like a bash command and gets typed results back. 171KB single binary, ~180ms warm startup on Apple Silicon.

## Install

```bash
make install   # copies to ~/bin/webview-cli
```

Requires macOS 12+ and Swift toolchain.

## Usage

### Open a URL

```bash
webview-cli --url "https://example.com" --timeout 60
```

The page calls `window.webkit.messageHandlers.complete.postMessage({...})` to signal done. The JSON payload appears on stdout, exit code 0.

### A2UI mode — declarative UI from the agent

```bash
cat <<'EOF' | webview-cli --a2ui --title "Approval" --width 520 --height 460 --timeout 300
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["card"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"card","component":{"Card":{"child":"content"}}}]}}
{"surfaceUpdate":{"components":[{"id":"content","component":{"Column":{"children":{"explicitList":["title","btn"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"title","component":{"Text":{"usageHint":"h2","text":{"literalString":"Hello"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn","component":{"Button":{"label":{"literalString":"OK"},"action":{"name":"ok"}}}}]}}
{"beginRendering":{"root":"root"}}
EOF
```

See `examples/a2ui-approval.jsonl` for a complete form example.

### Stdin protocol — pipe custom HTML

```bash
HTML_B64=$(base64 < custom.html)
(echo "{\"type\":\"load\",\"resources\":{\"index.html\":\"$HTML_B64\"},\"url\":\"agent://host/index.html\"}"; cat) | webview-cli --timeout 120
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed — data in stdout JSON |
| 1 | Cancelled (user closed window or Escape) |
| 2 | Timeout |
| 3 | Error |

## Stdout shape

```json
{"status":"completed","data":<anything the page/A2UI button posted>}
{"status":"cancelled"}
{"status":"timeout"}
{"status":"error","message":"..."}
```

## A2UI catalog (built-in)

Supported components: `Text`, `TextInput`, `Button`, `Column`, `Row`, `Card`, `Select`, `Checkbox`, `Divider`. Subset of A2UI v0.8's standard catalog, focused on form/approval/selection use cases. Not supported yet: Image, List, RadioGroup, data binding expressions, catalog negotiation, progressive rendering.

## Why not Electron / Tauri / Wails

- Electron: 50-150MB runtime, 500ms+ startup
- Tauri: 5-10MB runtime, ~200ms startup, still ships a wrapper
- This: **171KB binary, 180ms startup, ships nothing** — uses the OS's own WebKit

Trade-off: macOS-only. Acceptable when the caller (agent) is already running on macOS.

## Architecture

Single `main.swift` file (~500 lines). NSApplication with `activationPolicy(.accessory)` (no Dock icon) → WKWebView in programmatic NSWindow. WKScriptMessageHandler bridges JS → stdout. WKURLSchemeHandler serves `agent://` URLs from an in-memory resource map fed via stdin.

## Related

- [AG-UI](https://docs.ag-ui.com/) — agent-user interaction protocol (not adopted; network-oriented, we use stdio instead)
- [A2UI](https://a2ui.org/) — declarative UI protocol (subset adopted as the in-process rendering format)

## Build from source

```bash
git clone <this-repo>
cd webview-cli
make build
```

Compiles with `swiftc -O -target arm64-apple-macos12.0 -framework WebKit -framework AppKit main.swift -o webview-cli`.
