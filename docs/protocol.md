# Protocol

The wire protocol `webview-cli` speaks with its parent process.

## Spawn model

`webview-cli` is a short-lived CLI. A parent process (shell script, AI agent, automation tool) spawns it with arguments, pipes data on stdin, reads result from stdout, checks exit code, and continues.

The binary **blocks** until the user interacts with the window, the window is closed, or the timeout fires. There is no long-running daemon.

## Command-line arguments

```
webview-cli [--url <url>] [--a2ui] [options]

Options:
  --url <url>        URL to open (http/https/file/agent). Required unless --a2ui.
  --a2ui             A2UI mode: read A2UI v0.8 JSONL from stdin and render.
  --title <string>   Window title (default: "webview-cli")
  --width <int>      Window width in pixels (default: 1024)
  --height <int>     Window height in pixels (default: 768)
  --timeout <int>    Auto-close after N seconds. 0 = no timeout (default: 0).
  --help, -h         Show usage and exit.
```

## Stdin protocol

### `--a2ui` mode

Feed A2UI v0.8 JSONL on stdin. Each line is one message. The stream is read to EOF before rendering, then all messages are applied in order. See [a2ui-subset.md](a2ui-subset.md) for supported components.

```bash
cat <<'EOF' | webview-cli --a2ui --timeout 120
{"surfaceUpdate":{"components":[{"id":"root","component":{"Text":{"text":{"literalString":"Hello"}}}}]}}
{"beginRendering":{"root":"root"}}
EOF
```

### `agent://` scheme (URL mode)

When using `--url`, you can pipe JSON commands on stdin to load in-process resources served via the `agent://` URL scheme. This lets an agent push arbitrary HTML/CSS/JS into the webview without an HTTP server.

```json
{"type":"load","resources":{"index.html":"<base64>","app.js":"<base64>"},"url":"agent://host/index.html"}
{"type":"close"}
```

| Command | Fields | Behavior |
|---------|--------|----------|
| `load` | `resources` (object mapping path → base64 content), optional `url` to navigate | Stores resources in the in-memory map served by `agent://host/<path>`. If `url` is present, navigates to it. |
| `close` | — | Programmatically cancel. Emits `{"status":"cancelled"}`, exit 1. |

All content is base64-encoded. MIME type is inferred from file extension (`.html`, `.js`, `.css`, `.json`, `.svg`, `.png`).

## Stdout contract

A single JSON object on stdout, then the process exits. The object shape is:

```json
{"status":"completed","data":<user-submitted data>}
{"status":"cancelled"}
{"status":"timeout"}
{"status":"error","message":"<description>"}
```

- `completed` — web content called `window.webkit.messageHandlers.complete.postMessage(...)`. `data` is the postMessage payload (any JSON-serializable value).
- `cancelled` — user closed the window (Cmd+W, red button) or pressed Escape. No `data`.
- `timeout` — elapsed `--timeout` seconds without a result. No `data`.
- `error` — load failure, invalid URL, or other unrecoverable error. `message` is a short diagnostic.

### A2UI button responses

In `--a2ui` mode, when the user clicks a `Button`, the payload shape is:

```json
{
  "action": "<button's action.name>",
  "data": { "<fieldName>": "<value>", ... },
  "context": { /* button's action.context object, if any */ }
}
```

`data` is collected from every component with a `fieldName` property. Buttons without an `action.name` default to `"click"`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed successfully. Data is in stdout JSON. |
| 1 | Cancelled. Stdout JSON has `"status":"cancelled"`. |
| 2 | Timeout. Stdout JSON has `"status":"timeout"`. |
| 3 | Error. Stdout JSON has `"status":"error"`, stderr has more detail. |

Exit code is authoritative. Parse stdout only if you need the returned data.

## Stderr

Stderr is for diagnostics only. Never parsed by the caller. Messages include:

- `[ready]` — page fired `ready` message handler
- `[js-error] <msg> at <url>:<line>` — unhandled JavaScript error in page
- `[stdin] Invalid command: <line>` — malformed stdin command
- `[a2ui] JS eval error: <detail>` — renderer script failed to run
- `[agent] Failed to decode base64 for <path>` — bad resource in `load` command

## Web → Native bridge

Web content running in the webview can send data back to the parent via:

```js
// Signal completion (causes webview-cli to emit stdout and exit)
window.webkit.messageHandlers.complete.postMessage({any: "json"});

// Signal that the page has loaded and is ready (optional — useful for A2UI renderer)
window.webkit.messageHandlers.ready.postMessage({});
```

Any JSON-serializable object can be passed.

## Process lifecycle invariants

- The process always emits exactly one stdout JSON before exit.
- If the process receives SIGTERM/SIGINT before emitting, `applicationWillTerminate` writes `{"status":"cancelled"}` and exits.
- `NSApp.terminate` is intentionally not used — exit code is preserved via direct `exit(N)`.
- No subprocess leaks: WKWebView's GPU/network processes terminate when the parent exits.
