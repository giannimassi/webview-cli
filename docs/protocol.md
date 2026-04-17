# Protocol

The wire protocol `webview-cli` speaks with its parent process.

## Spawn model

`webview-cli` is a short-lived CLI. A parent process (shell script, AI agent, automation tool) spawns it with arguments, pipes data on stdin, reads result from stdout, checks exit code, and continues.

The binary **blocks** until the user interacts with the window, the window is closed, or the timeout fires. There is no long-running daemon.

## Command-line arguments

```
webview-cli [--url <url>] [--a2ui] [--markdown] [options]

Options:
  --url <url>        URL to open (http/https/file/agent). Required unless --a2ui or --markdown.
  --a2ui             A2UI mode: read A2UI v0.8 JSONL from stdin and render.
  --markdown         Markdown mode: read markdown from stdin and render with optional review UI.
  --title <string>   Window title (default: "webview-cli")
  --width <int>      Window width in pixels (default: 1024)
  --height <int>     Window height in pixels (default: 768)
  --timeout <int>    Auto-close after N seconds. 0 = no timeout (default: 0).
  --comments         Enable comment UI (inline + doc-level). Requires --markdown. Default: false.
  --edits            Enable source editor tab. Requires --markdown. Default: false.
  --allow-html       Pass raw HTML through. Default strips <script>/<iframe>/handlers. Default: false.
  --help, -h         Show usage and exit.
```

**Note:** `--markdown`, `--a2ui`, and `--url` are mutually exclusive. Exactly one must be specified.

## Stdin protocol

### `--a2ui` mode

Feed A2UI v0.8 JSONL on stdin. Each line is one message. The stream is read to EOF before rendering, then all messages are applied in order. See [a2ui-subset.md](a2ui-subset.md) for supported components.

```bash
cat <<'EOF' | webview-cli --a2ui --timeout 120
{"surfaceUpdate":{"components":[{"id":"root","component":{"Text":{"text":{"literalString":"Hello"}}}}]}}
{"beginRendering":{"root":"root"}}
EOF
```

### `--markdown` mode

Feed markdown text on stdin. The markdown is parsed, rendered as HTML, and displayed in a window. Optional review features (comments, edits) can be enabled.

```bash
cat spec.md | webview-cli --markdown --comments --title "Review spec" --timeout 600
```

The markdown parser supports CommonMark core: headings, paragraphs, lists, emphasis, links, blockquotes, code blocks. HTML is stripped by default (removes `<script>`, `<iframe>`, `<object>`, event handler attributes, `javascript:` and `data:` URLs). Use `--allow-html` to pass raw HTML through.

When `--comments` is on, the rendered preview includes inline comment anchors on each block (paragraph, heading, list item, etc.). When `--edits` is on, the window shows a Preview tab (rendered markdown) and a Source tab (editable textarea with markdown source).

See [Markdown mode](#markdown-mode) below for the full interaction model and output shape.

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

## Markdown mode

### Flags

| Flag | Type | Default | Effect |
|------|------|---------|--------|
| `--markdown` | bool | — | Reads markdown from stdin. Mutually exclusive with `--a2ui` and `--url`. |
| `--comments` | bool | false | Enables paragraph-level comment UI (inline comments + document-level comment field). |
| `--edits` | bool | false | Enables source editor tab (Preview/Source tabs). |
| `--allow-html` | bool | false | Passes raw HTML embedded in markdown through; default strips unsafe content. |

### Interaction model

When both toggles are off (comments=false, edits=false):
- Shows rendered markdown in a read-only preview.
- Single button: **OK** (or **Cancel** to exit).
- User can only acknowledge and proceed.

When `--comments` is on:
- Rendered preview is clickable. Click any block (paragraph, heading, list item, code block) to attach a comment.
- Right sidebar shows comment composer and existing comments.
- Document-level comment field at the bottom (for overall feedback not anchored to a specific block).
- Each inline comment captures: `source_line_start`, `source_line_end`, `quoted_text`, `body`.

When `--edits` is on:
- Two tabs: **Preview** (rendered) and **Source** (plain textarea with markdown source).
- Tab switcher controlled by `Cmd+/` keyboard shortcut.
- Switching tabs re-renders the preview from current source.
- Tab-indent support in the source editor (Tab key inserts spaces).
- Tracks `modified` flag: `true` if source differs from input, `false` otherwise.

When both are on:
- Preview tab includes comment pins and composer.
- Source tab is plain editor.
- Submit returns both `comments` and `edited_text`.

### Output shape

Markdown mode returns the same top-level envelope as `--a2ui` mode:

```json
{"status": "completed", "data": {...}}
{"status": "cancelled"}
{"status": "timeout"}
{"status": "error", "message": "..."}
```

The `data` shape depends on which toggles were active:

| Toggles | Output shape |
|---------|--------------|
| both off | `{"action": "acknowledge"}` |
| `--comments` only | `{"action": "submit", "data": {"comments": [...], "doc_comment": "..."}}` |
| `--edits` only | `{"action": "submit", "data": {"edited_text": "...", "modified": bool}}` |
| both on | `{"action": "submit", "data": {"comments": [...], "doc_comment": "...", "edited_text": "...", "modified": bool}}` |

**Field definitions:**

- `comments`: array of comment objects. Each has `source_line_start` (int), `source_line_end` (int), `quoted_text` (string), `body` (string). Present only if `--comments` was on. Empty array `[]` if no comments were added.
- `doc_comment`: document-level comment (string). Present only if `--comments` was on. Empty string `""` if the textarea was left blank.
- `edited_text`: full markdown source at submit time (string). Present only if `--edits` was on.
- `modified`: boolean indicating whether the source differs from the input. Present only if `--edits` was on.

### Example outputs

**Comment-only review:**

```json
{
  "status": "completed",
  "data": {
    "action": "submit",
    "data": {
      "comments": [
        {
          "source_line_start": 5,
          "source_line_end": 5,
          "quoted_text": "Phase 1: canary deploy.",
          "body": "Clarify the ramp rate."
        }
      ],
      "doc_comment": "Looks good overall."
    }
  }
}
```

**Edit-only review:**

```json
{
  "status": "completed",
  "data": {
    "action": "submit",
    "data": {
      "edited_text": "# Updated spec\n\n...",
      "modified": true
    }
  }
}
```

**Both comments and edits:**

```json
{
  "status": "completed",
  "data": {
    "action": "submit",
    "data": {
      "comments": [...],
      "doc_comment": "...",
      "edited_text": "...",
      "modified": true
    }
  }
}
```

### Keyboard shortcuts

- `Cmd+Enter` → Submit (from anywhere in the window)
- `Cmd+Enter` → Commit comment (inside the comment composer, does not submit the whole window)
- `Esc` → Cancel
- `Cmd+W` → Cancel
- `Cmd+/` → Toggle Preview/Source (when `--edits` is on)

### HTML sanitization

By default, raw HTML embedded in the markdown is stripped of unsafe constructs:
- `<script>`, `<iframe>`, `<object>`, `<embed>` elements removed entirely
- Event handler attributes (`onclick`, `onerror`, etc.) removed
- `javascript:` and `data:` URLs converted to safe placeholders
- Image data URIs allowed (allow-listed)

Use `--allow-html` to disable sanitization and pass raw HTML through. This is useful for trusted content (e.g. HTML generated by the agent itself). When `--allow-html` is on and the user edits the source (if `--edits` is on), the edited source is rendered through the same sanitization path, so injected scripts would render.

For full details and design rationale, see [`docs/specs/2026-04-17-markdown-editor-design.md`](specs/2026-04-17-markdown-editor-design.md).

## Stdout contract

A single JSON object on stdout, then the process exits. The object shape is:

```json
{"status":"completed","data":<user-submitted data>}
{"status":"cancelled"}
{"status":"timeout"}
{"status":"error","message":"<description>"}
```

- `completed` — web content called `window.webkit.messageHandlers.complete.postMessage(...)` or user clicked a submit button. `data` is the postMessage payload (any JSON-serializable value).
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
