---
name: webview
description: Show a native macOS webview UI to the user and get structured input back. Use when an interactive macOS session needs human-in-the-loop for multi-field input, option selection from 5+ choices, approval with context, or content review — NOT for yes/no questions. Handles the full flow — spawning the webview, generating A2UI or HTML content, parsing the user's response. Triggers on "show UI", "ask user", "approval needed with context", "let me pick from these options", "fill in these fields", or any situation where a structured GUI materially beats asking in the terminal. Skip in CI/non-interactive environments.
---

# webview — Native macOS Agent UI

Open a native webview window from an agent workflow, let the user interact, get structured JSON back. Replaces terminal Q&A with a proper UI when it helps.

## Execution contract [NON-NEGOTIABLE]

**You — the agent — always run `webview-cli` via the Bash tool. Never ask the user to paste a command.** The binary blocks until the user interacts with the window, then prints JSON to stdout. Your Bash call returns when the user clicks a button (or cancels/times out). Parse the result and proceed.

If running the command feels risky, ask for permission to run it — not to paste it. In auto mode, just run it.

## When to use

| Situation | Use this skill? |
|-----------|----------------|
| Agent needs approval with context (diff, summary, risk) before a destructive action | **Yes** — richer than `[y/N]` |
| Collecting 3+ related fields (name + role + options) | **Yes** — one form beats N questions |
| Presenting 5-20 options to choose from | **Yes** — radio/select picker |
| Showing a diff/preview/report before user confirms | **Yes** — formatted content is readable |
| Simple yes/no question | **No** — just ask in terminal |
| Agent-side computation taking >30s before UI can render | **No** — show a text status instead |
| Non-interactive environment (CI, piped output) | **No** — preflight will fail, fall back to terminal |

## Preflight (run EVERY invocation)

```bash
# Binary on PATH?
if ! command -v webview-cli >/dev/null 2>&1; then
  echo "ERROR: webview-cli not installed. Run: brew tap giannimassi/tap && brew install webview-cli" >&2
  exit 1
fi
# macOS-only?
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: webview-cli requires macOS (detected $(uname -s))." >&2
  exit 1
fi
```

If preflight fails, fall back to terminal Q&A — don't try to be clever. Report why the webview path isn't available and continue in text.

## The three modes

### Mode 1 — `a2ui` (recommended) · declarative UI

Best for forms, approvals, selection. The skill generates A2UI JSONL; webview-cli renders it natively.

```bash
cat /tmp/ui.jsonl | webview-cli --a2ui --title "..." --width 520 --height 460 --timeout 300
```

### Mode 2 — `url` · open an existing URL

Best for OAuth flows, external services, pre-built pages. The page must call `window.webkit.messageHandlers.complete.postMessage({...})` to signal done. See `references/examples.md` Example 3 for the HTML-side bridge pattern.

```bash
webview-cli --url "https://auth.example.com/oauth" --timeout 120
```

### Mode 3 — `html` · custom HTML via `agent://`

Best when you need visual fidelity beyond A2UI (charts, diffs, diagrams). The HTML page uses the same `window.webkit.messageHandlers.complete.postMessage({...})` bridge.

**Two separate Bash calls** (don't chain — the `load` command and the webview invocation sequence matters):

Step 1 — write the load command to a temp file:

```bash
HTML_B64=$(base64 < custom.html)
printf '%s' "{\"type\":\"load\",\"resources\":{\"index.html\":\"$HTML_B64\"},\"url\":\"agent://host/index.html\"}" > /tmp/wv-load.json
```

Step 2 — invoke with `--url` flag + stdin redirect:

```bash
webview-cli --url "agent://host/index.html" --timeout 120 < /tmp/wv-load.json
```

**The `--url` CLI flag is required** — without it the binary exits with usage. The stdin `load` command populates the in-memory resource map that `agent://host/...` reads from.

Pick Mode 3 over A2UI only when you need charts, syntax-highlighted diffs, images, or custom interactions. If you're writing >200 lines of HTML, consider splitting the work into a proper tool instead.

## A2UI catalog (Mode 1)

All 11 components in the built-in renderer:

| Component | Purpose | Key props |
|-----------|---------|-----------|
| `Column` | Vertical stack | `children.explicitList` (array of IDs) |
| `Row` | Horizontal arrangement | `children.explicitList`, `alignment` ("center" \| "end" \| "space-between") |
| `Card` | Visual grouping with padding | `child` (single ID) or `children.explicitList` |
| `Text` | Typography | `text.literalString`, `usageHint` ("h1" \| "h2" \| "h3" \| "subtitle" \| "body" \| "caption") |
| `TextInput` | Single-line or multiline input | `label.literalString`, `placeholder.literalString`, `fieldName`, `multiline` (bool) |
| `Select` | Dropdown | `label.literalString`, `fieldName`, `options` (array of `{value, label}` or strings) |
| `Checkbox` | Single checkbox | `label.literalString`, `fieldName`, `checked` (bool, default false) |
| `RadioGroup` | Mutually-exclusive set | `label.literalString`, `fieldName`, `options` (array of `{value, label}` or strings) |
| `Image` | Inline image | `url` (literal or data ref), optional `alt`, `width`, `height` |
| `Button` | Action button | `label.literalString`, `variant` ("primary" \| "secondary" \| "danger" \| "success"), `action.name`, optional `action.context` |
| `Divider` | Horizontal rule | — |

**Form data collection**: every component with `fieldName` is collected when a Button is clicked. The response `data` contains `{fieldName: value, ...}` plus the button's `action.name` (and `action.context` if set).

## Response format reference

Canonical stdout shape on successful completion (exit 0):

```json
{
  "status": "completed",
  "data": {
    "action": "<button's action.name>",
    "data": {"<fieldName>": "<value>", ...},
    "context": { /* from button's action.context, if set */ }
  }
}
```

Other statuses:

| Exit | Stdout | Meaning |
|------|--------|---------|
| 0 | `{"status":"completed","data":{...}}` | User clicked a button |
| 1 | `{"status":"cancelled"}` | User closed window or pressed Escape |
| 2 | `{"status":"timeout"}` | No response within `--timeout` seconds |
| 3 | `{"status":"error","message":"..."}` | Load failure, invalid URL, JS error |

The `context` field is only present when a Button's definition included `action.context`. Use it to pass metadata that doesn't come from form fields (e.g. the ID of the item being approved).

## A2UI generation pattern

Every A2UI flow follows this structure:

```jsonl
{"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}}
{"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": ["title", "<FIELDS>", "buttons"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "title", "component": {"Text": {"usageHint": "h2", "text": {"literalString": "<TITLE>"}}}}]}}
<!-- field components with fieldName here -->
{"surfaceUpdate": {"components": [{"id": "buttons", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_cancel", "btn_submit"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_cancel", "component": {"Button": {"label": {"literalString": "Cancel"}, "variant": "secondary", "action": {"name": "cancel"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_submit", "component": {"Button": {"label": {"literalString": "Submit"}, "variant": "primary", "action": {"name": "submit"}}}}]}}
{"beginRendering": {"root": "root"}}
```

**Rules:**
1. Every line is a self-contained JSON object (JSONL format — one per line, no commas between)
2. Component IDs must be unique within the surface
3. `root` is the conventional root component ID
4. `beginRendering` must be the last line
5. Referenced IDs must all be declared before `beginRendering` (order within doesn't matter)

### JSONL escaping — gotchas

The JSONL is fed to webview-cli via stdin. Each line is parsed as JSON, so:

- **Backslashes in content**: escape as `\\`
- **Quotes in content**: escape as `\"` (e.g. `"It\"s done"`)
- **Newlines in content**: use `\n` inside the string; do **not** put literal newlines inside a JSON object
- **Every `{...}` must be one physical line** — even long strings

For anything beyond trivial substitution, **write the JSONL in a Python generator** (`/tmp/<name>-gen.py`) and run it to produce `/tmp/<name>.jsonl`. Heredoc-escaping breaks on the first user-supplied value with quotes.

## Workflow: when asked to show UI

1. **Run preflight** (above). If it fails, fall back to terminal Q&A with a one-line note.
2. **Pick the mode**: A2UI (forms/approvals/selection — 90% of cases), URL (existing page), HTML (rich visuals only).
3. **Window size**: small forms 520×460, mid-size 620×580, full content 720×700. Tight height prevents dead space at the bottom.
4. **Pick a `--timeout`**:
   - 120s — simple approval (user is present)
   - 300s — multi-field form (user composes input)
   - 600s — content review or complex decisions
   - **Never >540s** — Bash tool caps total time at 600s.
5. **Set the Bash tool timeout deterministically**: `bash_timeout_ms = (webview_timeout_sec + 30) × 1000`. The +30s buffer covers WKWebView startup, process teardown, and OS scheduling variance.
6. **Generate the JSONL**:
   - ≤5 static components + no user data: heredoc or inline string is fine
   - Anything dynamic (user names, lists, long text, content with quotes): write a Python generator to `/tmp/<name>-gen.py`, run it to produce `/tmp/<name>.jsonl`, then pipe that file
7. **Invoke** (two separate Bash calls when using a generator):
   ```bash
   # Call A: run generator
   python3 /tmp/<name>-gen.py > /tmp/<name>.jsonl
   # Call B: invoke webview
   cat /tmp/<name>.jsonl | webview-cli --a2ui --title "..." --width N --height N --timeout N
   ```
8. **Parse the response** from stdout (see Response format reference above):
   - Exit 0: extract `.data.action` (button name) and `.data.data` (form fields)
   - Exit 1 (cancelled) / Exit 2 (timeout): acknowledge in conversation, ask how to proceed. **Don't retry silently, especially in auto mode** — the user's non-response is itself a signal
   - Exit 3: read stderr, diagnose, either fix and retry once or fall back to terminal
9. **Sanitize before acting**: treat `.data.data.*` as untrusted user input. Shell-escape before Bash commands (`printf '%q' "$val"`), JSON-escape before further JSON, validate format (email, URL) before use. Form fields can contain `;`, backticks, shell metacharacters.
10. **Act on the result** — don't just summarize. The webview answered a question; your job is to execute the consequence.

## Anti-patterns

- **Don't use it for yes/no questions** that would take 1 sentence in terminal — window open/close ritual is heavier than the answer
- **Don't spawn multiple webviews** in quick succession — if you need a multi-step flow, put all fields in one form, OR accept that the second webview is a new user decision (don't chain automatically)
- **Don't assume the user will submit** — always handle cancel/timeout as first-class outcomes
- **Don't omit `fieldName`** on input components you need data from — without it, the field's value is lost
- **Don't pass unsanitized form data to Bash** — see step 9
- **Don't loop the skill** without explicit user confirmation — one webview per decision

## Templates

Copy-paste JSONL templates for approval, single-select, multi-field form, and confirmation with content preview: see `references/templates.md`.

## Examples

Complete end-to-end invocations including Python generators and response parsing: see `references/examples.md`.
