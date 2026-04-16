---
name: webview
description: Show a native macOS webview UI to the user and get structured input back. Use when an agent needs human-in-the-loop: approval, form input, option selection, or rich content display. Handles the full flow — spawning the webview, generating A2UI or HTML content, parsing the user's response. Triggers on "show UI", "ask user", "approval needed", "let me pick", "confirm", "fill in", or any situation where a structured GUI beats asking in the terminal.
---

# webview — Native macOS Agent UI

Open a native webview window from an agent workflow, let the user interact, get structured JSON back. Replaces terminal Q&A with a proper UI when it helps.

## When to use

| Situation | Use this skill? |
|-----------|----------------|
| Agent needs approval before a destructive action | **Yes** — richer than yes/no text |
| Collecting multiple related fields (name + role + options) | **Yes** — one form beats N questions |
| Presenting 5-20 options to choose from | **Yes** — select dropdown or card grid |
| Showing a diff/preview/report before user confirms | **Yes** — formatted content is readable |
| Simple yes/no question | **No** — just ask in terminal |
| Answer needs >30s of thinking | **No** — webview will feel heavy |
| User is in a CI/non-interactive environment | **No** — falls back to error |

## Execution contract [NON-NEGOTIABLE]

**You — the agent — always run `webview-cli` via the Bash tool. Never ask the user to paste a command.** The binary blocks until the user interacts with the window, then prints JSON to stdout. Your Bash call returns when the user clicks a button (or cancels/times out). Parse the result and proceed.

If running the command feels risky, the correct action is to ask for permission to run it — not to ask the user to paste it. In auto mode, just run it.

## Preflight (run EVERY invocation before the main Bash call)

```bash
# 1. Check binary is on PATH
if ! command -v webview-cli >/dev/null 2>&1; then
  # 2. Try to build from source
  if [ -d "$HOME/dev/fun/webview-cli" ]; then
    make -C "$HOME/dev/fun/webview-cli" install
  else
    echo "ERROR: webview-cli not installed and source not at ~/dev/fun/webview-cli" >&2
    exit 1
  fi
fi
```

If preflight fails (not installed, non-macOS, build error), fall back to terminal Q&A via the standard conversation path — don't try to be clever. Report why the webview path isn't available and continue in text.

## The three modes

### Mode 1: `a2ui` — generate declarative UI (recommended)

Best for forms, approvals, selection. The skill generates A2UI JSONL describing the UI; webview-cli renders it with the built-in catalog. **No HTML authoring needed.**

```bash
echo '<A2UI JSONL>' | webview-cli --a2ui --title "..." --width 520 --height 460 --timeout 300
```

Stdout (on completion): `{"status":"completed","data":{"action":"approve","data":{"comment":"..."}}}`
Exit codes: 0=ok, 1=cancelled, 2=timeout, 3=error

### Mode 2: `url` — open an existing URL

Best for OAuth flows, external services, pre-built pages.

```bash
webview-cli --url "https://auth.example.com/oauth" --timeout 120
```

The page must call `window.webkit.messageHandlers.complete.postMessage({...})` to signal done.

### Mode 3: `html` — custom HTML via agent://

Best when you need visual fidelity beyond A2UI (charts, diagrams, custom layouts).

```bash
# Encode HTML as base64
HTML_B64=$(base64 < custom.html)
# Send load command via stdin, then keep stdin open
(echo "{\"type\":\"load\",\"resources\":{\"index.html\":\"$HTML_B64\"},\"url\":\"agent://host/index.html\"}"; cat) | webview-cli --timeout 120
```

The HTML page uses the same `window.webkit.messageHandlers.complete.postMessage({...})` bridge.

## A2UI catalog (Mode 1)

Components available in the built-in renderer:

| Component | Purpose | Key props |
|-----------|---------|-----------|
| `Column` | Vertical stack | `children.explicitList` (array of IDs) |
| `Row` | Horizontal arrangement | `children.explicitList`, `alignment` ("center" \| "end" \| "space-between") |
| `Card` | Visual grouping with padding | `child` (single ID) or `children.explicitList` |
| `Text` | Typography | `text.literalString`, `usageHint` ("h1" \| "h2" \| "h3" \| "subtitle" \| "body" \| "caption") |
| `TextInput` | Single-line or multiline input | `label.literalString`, `placeholder.literalString`, `fieldName`, `multiline` (bool) |
| `Select` | Dropdown | `label.literalString`, `fieldName`, `options` (array of `{value, label}` or strings) |
| `Button` | Action button | `label.literalString`, `variant` ("primary" \| "secondary" \| "danger" \| "success"), `action.name` |
| `Divider` | Horizontal rule | — |

**Form data collection**: any component with `fieldName` is collected when a Button is clicked. The `data` returned to the agent contains `{fieldName: value, ...}` plus the button's `action.name`.

## A2UI generation pattern

Every A2UI flow follows the same structure. Fill in the blanks:

```json
{"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "card_content"}}}]}}
{"surfaceUpdate": {"components": [{"id": "card_content", "component": {"Column": {"children": {"explicitList": ["<FIELDS>", "button_row"]}}}}]}}
<!-- field components here -->
{"surfaceUpdate": {"components": [{"id": "button_row", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_cancel", "btn_submit"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_cancel", "component": {"Button": {"label": {"literalString": "Cancel"}, "variant": "secondary", "action": {"name": "cancel"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_submit", "component": {"Button": {"label": {"literalString": "Submit"}, "variant": "primary", "action": {"name": "submit"}}}}]}}
{"beginRendering": {"root": "root"}}
```

**Rules:**
1. Every line is a self-contained JSON object (JSONL format — one per line, no commas between)
2. Component IDs must be unique within the surface
3. `root` is the conventional root component ID
4. `beginRendering` must be the last line — signals "ready to render"
5. Children reference IDs that are declared somewhere in the stream (order doesn't matter, but all must be present before `beginRendering`)

## Ready-to-use templates

See `references/templates.md` for copy-paste templates for:
- Approval (with optional comment field)
- Single-select from options
- Multi-field form
- Confirmation with diff preview

## Workflow: when asked to show UI

1. **Run preflight** (see above). If it fails, fall back to terminal Q&A.
2. **Pick the mode**: A2UI (forms/approvals/selection), URL (existing page), HTML (custom visual).
3. **Determine window size**: small forms 520×460, mid-size 720×580, full content 900×700.
4. **Set a timeout**: approvals 120s, forms 300s, content review 180s. Never omit — 0 means infinite hang. The Bash tool timeout MUST be > webview timeout + 10s buffer.
5. **Generate the A2UI JSONL** following the template pattern. For dynamic content (more than ~5 components or any user data), write a Python generator to `/tmp/<name>-gen.py` and a `/tmp/<name>.jsonl` output — safer than heredoc-escaping.
6. **Invoke via Bash tool**: single command pipes JSONL to webview-cli. Set the Bash `timeout` parameter generously (webview_timeout_sec × 1000 + 15000).
   ```bash
   cat /tmp/<name>.jsonl | webview-cli --a2ui --title "..." --width N --height N --timeout N
   ```
7. **Parse the response** from stdout:
   - Exit 0 + JSON: user submitted. Extract `.data.action` (button name) and `.data.data` (form fields).
   - Exit 1: cancelled. Acknowledge in the conversation and ask how to proceed — don't retry silently.
   - Exit 2: timeout. Same as cancel.
   - Exit 3: error. Read stderr, diagnose, either fix and retry or fall back to text.
8. **Act on the result** — don't just summarize. If the user picked a task, claim it. If they approved a deploy, run it. The webview answered a question; your job is to execute the consequence.

## Anti-patterns

- **Don't nest the skill inside a loop** without user confirmation. One webview per user decision, not N.
- **Don't use it for yes/no questions** that would take 1 sentence in terminal. The window open/close ritual is heavier than the question.
- **Don't assume the user will submit** — always handle cancel/timeout as first-class outcomes.
- **Don't omit `fieldName`** on input components if you want the data back. Without it, the field's value is lost.
- **Don't chain multiple webviews for a multi-step wizard** — put all fields in one form, or reconsider if the agent actually needs multi-step.

## Examples

See `references/examples.md` for complete worked examples with actual Bash invocations.
