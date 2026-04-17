# Markdown Editor — Design

Status: **design locked, pending implementation plan**
Author: Gianni (brainstormed with Claude Opus 4.7)
Date: 2026-04-17

## Problem

Agents produce markdown content — specs, design docs, PR descriptions, drafts — that humans need to review, comment on, or edit before the agent proceeds. The current webview-cli catalog (A2UI forms with `Text`, `TextInput`, `Button`, etc.) can show markdown-as-plain-text in a `Text` component, but there's no way to:

1. Render the markdown (headings, lists, code blocks, emphasis)
2. Attach structured comments to specific paragraphs
3. Allow inline edits and capture the edited text
4. Return all of this as structured JSON the agent can act on

The target use case is **iterative spec review**: agent writes v1 → human reviews in a native window, comments on paragraphs, maybe edits a few → submits → agent reads the structured feedback and writes v2.

## Non-goals

- **Not a general-purpose markdown editor.** No Monaco, no CodeMirror, no live preview Obsidian-style. Scope is "review an agent-produced doc and send back structured feedback."
- **Not a diff viewer.** Separate future feature (see roadmap ideas).
- **Not a collaborative editor.** Single user, one session, one submit.
- **Not syntax-highlighted code.** Fenced code blocks render as plain monospace. Highlight.js can be added later if needed.
- **Not an HTML-in-markdown sandbox.** HTML is stripped by default. `--allow-html` flag exists as an escape hatch for trusted content.

## User-facing shape

### Two independent toggles

The caller picks what interactions the window supports:

| `comments` | `edits` | Window shows | Submit returns |
|------------|---------|--------------|----------------|
| off | off | Rendered preview + Submit/Cancel | `{status: "acknowledged"}` |
| on  | off | Rendered preview + comment sidebar + doc-level comment field | `{comments: [...], doc_comment: "..."}` |
| off | on  | Tabbed Preview/Source + Submit/Cancel | `{edited_text: "...", modified: bool}` |
| on  | on  | Tabbed Preview/Source + comment sidebar + doc-level field | `{comments: [...], doc_comment: "...", edited_text: "...", modified: bool}` |

Fields are always present in the output when their toggle is on — even if empty — so agent code can treat them as predictable.

### Layout

- **`edits=off`**: preview-only. Single pane of rendered markdown. Right sidebar for comments if `comments=on`. Bottom bar for doc-level comment if `comments=on`.
- **`edits=on`**: tabbed Preview / Source. Preview tab shows rendered markdown (with comment pins if `comments=on`). Source tab shows a plain `<textarea>` with the raw markdown, monospace font, tab-indent support. Switching tabs re-renders the preview from current source.

Not chosen: split view (overkill for typical spec sizes), Obsidian-style live preview (would need a real editor engine, blows the size budget).

### Inline comments

- Anchor unit: **paragraph / block** (any markdown AST block — paragraph, heading, list item, blockquote, code block).
- Interaction: in Preview, clicking any block:
  1. Highlights the block
  2. Opens / scrolls to a **composer card** in the right sidebar, pre-filled with the quoted block text
  3. User types the comment body; `Cmd+Enter` or a Save button commits it to the sidebar's comment list
  4. The block in the preview picks up a pin indicator (💬) once committed
- Clicking an existing comment card in the sidebar scrolls its anchored block into view and highlights it.
- Composer and comments all live in the sidebar — no inline-expanding forms in the document body (keeps the doc flowing).
- Each comment carries:
  ```json
  {
    "source_line_start": 5,
    "source_line_end": 7,
    "quoted_text": "The payment-service rollout will happen in two phases.",
    "body": "clarify canary %"
  }
  ```
  `quoted_text` is the block's text at comment time. This makes comments drift-resilient: if the user also edited the source and the line numbers shifted, the agent can still match by quoted content.

Not chosen: arbitrary text selection (cross-element ranges are messy without a real editor framework); line-level gutter comments (forces the user into source view, breaks the "read the rendered spec" flow).

### Doc-level comment

A separate textarea that's always visible when `comments=on`. One string, returned as `doc_comment`. Used for "overall" feedback that doesn't anchor to any specific paragraph.

### Edit payload

When `edits=on`:
- `edited_text`: the full markdown text at submit time. Always a string, even if unchanged.
- `modified`: boolean, `true` if the source differs from the input.

Full text (not diff) — simplest for the agent to consume. Diff is an optimization we'll add only if doc sizes become a problem.

### Button labels

The primary action button label depends on active toggles:

| State | Primary button | Secondary |
|-------|---------------|-----------|
| both toggles off | **OK** | Cancel |
| any toggle on | **Submit** | Cancel |

### Keyboard

- `Cmd+Enter` → Submit (or OK)
- `Esc` → Cancel (returns `{status: "cancelled"}`)
- `Cmd+/` → toggle Preview/Source (when `edits=on`)
- `Cmd+W` → Cancel (standard macOS)
- Inside the comment composer: `Cmd+Enter` commits the comment (not the whole window)

## Invocation surfaces

Two ways to use markdown support. Both produce the same output shape.

### 1. `--markdown` CLI mode (shortcut for standalone review)

```bash
# Simplest: show markdown, Acknowledge/Cancel only
webview-cli --markdown < spec.md

# Comment-only review
webview-cli --markdown --comments < spec.md

# Edit + comment
webview-cli --markdown --comments --edits < spec.md

# With title, timeout, size
webview-cli --markdown --title "Review: Deploy Spec" --comments --timeout 600 < spec.md

# Allow raw HTML embedded in the markdown (opt-in)
webview-cli --markdown --comments --allow-html < trusted.md
```

New flags added to `webview-cli`:

| Flag | Type | Default | Effect |
|------|------|---------|--------|
| `--markdown` | bool | — | Reads markdown from stdin. Mutually exclusive with `--a2ui` and `--url`. |
| `--comments` | bool | false | Enables comment UI (inline + doc-level). |
| `--edits` | bool | false | Enables source editor tab. |
| `--allow-html` | bool | false | Passes raw HTML through. Default strips `<script>`, `<iframe>`, event handlers, `javascript:` URLs. |

Existing flags (`--title`, `--width`, `--height`, `--timeout`) apply as today.

### 2. `MarkdownDoc` A2UI component (composable)

For cases where markdown review is mixed with other form fields (e.g. "review this spec AND pick a rollout option AND add a note"):

```jsonl
{"surfaceUpdate":{"components":[{"id":"doc","component":{"MarkdownDoc":{"fieldName":"review","text":"# Spec...","allowComments":true,"allowEdits":true,"allowHtml":false}}}]}}
{"surfaceUpdate":{"components":[{"id":"rollout","component":{"RadioGroup":{"fieldName":"rollout","options":[{"value":"canary","label":"Canary"},{"value":"full","label":"Full"}]}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn","component":{"Button":{"label":{"literalString":"Submit"},"action":{"name":"submit"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["doc","rollout","btn"]}}}}]}}
{"beginRendering":{"root":"root"}}
```

Props:

| Prop | Type | Default | Notes |
|------|------|---------|-------|
| `fieldName` | string | required | Key under which the review payload goes in `data` |
| `text` | string (literal) | required | The markdown content to render |
| `allowComments` | bool | false | Same as `--comments` |
| `allowEdits` | bool | false | Same as `--edits` |
| `allowHtml` | bool | false | Same as `--allow-html` |
| `title` | string | — | Optional subheading shown above the doc |

In A2UI mode, submit data is collected as usual:

```json
{
  "status": "completed",
  "data": {
    "action": "submit",
    "data": {
      "review": {
        "comments": [...],
        "doc_comment": "...",
        "edited_text": "...",
        "modified": false
      },
      "rollout": "canary"
    }
  }
}
```

The `review` key (component's `fieldName`) holds the structured review payload.

### `--markdown` under the hood

`--markdown` is sugar: internally it constructs a minimal A2UI document with a single `MarkdownDoc` component plus an Acknowledge/Submit button, so the rendering path is unified. No separate renderer.

## Output contract

Top-level shape matches existing `webview-cli` protocol (see `docs/protocol.md`):

```json
{"status": "completed", "data": {...}}
{"status": "cancelled"}
{"status": "timeout"}
{"status": "error", "message": "..."}
```

The `data` shape when `--markdown` was used:

```json
{
  "action": "submit",
  "data": {
    "comments": [
      {
        "source_line_start": 5,
        "source_line_end": 7,
        "quoted_text": "The payment-service rollout...",
        "body": "clarify canary %"
      }
    ],
    "doc_comment": "Overall looks good but add a rollback checklist.",
    "edited_text": "# Deploy Spec\n\n...",
    "modified": true
  }
}
```

Field presence rules:
- `comments` and `doc_comment` exist iff `--comments` was on. `comments` is `[]` if no inline comments were added. `doc_comment` is `""` if the textarea was left empty.
- `edited_text` and `modified` exist iff `--edits` was on. `edited_text` is the full text at submit time (never a diff). `modified` is `true` iff the source differs from the input markdown.
- If both toggles were off, `data` is `{"action": "acknowledge"}` — the user just clicked OK.

## Architecture

webview-cli today is:

```
Swift binary (main.swift)
  │
  ├─ NSApplication + WKWebView
  ├─ WKScriptMessageHandler: JS → stdout bridge
  ├─ WKURLSchemeHandler: serves agent:// resources
  └─ Embedded renderer (JS + CSS string literal) for A2UI
```

Markdown support adds:

```
Embedded renderer (existing JS, ~250 lines)
  │
  └─ New module: markdown.js (~400-600 lines)
        ├─ Parser: CommonMark core only
        │   - headings, paragraphs, lists, emphasis, links, blockquotes, code
        │   - no tables, no task lists, no autolinks (deferred to phase 2)
        ├─ Renderer: AST → DOM with source-line annotations on each block
        ├─ Comment UI: pin on hover, composer on click, sidebar list
        ├─ Edit UI: tab switcher, plain textarea with Tab-indent handler
        └─ Serializer: collect comments + textarea value → structured object
```

### Parser choice — `micromark`

Locked: **`micromark` core** (~15–20KB minified, CommonMark compliant).

Why over the alternatives:
- **vs `marked` (~38KB):** `marked` is battle-tested but roughly 2× the size. Saving ~20KB matters here because the pitch *is* the size.
- **vs hand-rolled (~5–10KB):** smaller is tempting, but markdown edge cases (nested emphasis, reference links, fenced code with backtick counts) are where hand-rolled parsers quietly break. `micromark` is actively maintained and is the parser behind `remark` / `unified`, so it handles them correctly out of the box. The maintenance saving compounds.

We need a thin shim over `micromark`'s event stream to annotate each top-level block with its source line range — this is what comment anchoring hangs off. Cost: ~50–100 lines of JS.

**Size budget: ~28KB for everything new.** Breakdown:

| Component | Size |
|-----------|------|
| `micromark` core | ~18KB |
| Source-line shim | ~2KB |
| Comment UI logic (anchoring, composer, sidebar) | ~5KB |
| Edit UI logic (tab switch, textarea handler) | ~2KB |
| CSS (layout, composer, sidebar, tabs) | ~3KB |
| **Total addition** | **~28–30KB** |

**Target total binary: under 225KB** (up from 193KB — about a 15% increase). The README's "193KB" number gets updated; the "tiny vs Electron's 50MB+" story is unchanged.

Deferred until there's actual demand: tables, GFM task lists, footnotes, definition lists. If/when added, they come in as a `micromark-extension-gfm` opt-in and we re-measure.

### Sanitization

Default: strip `<script>`, `<iframe>`, `<object>`, `<embed>`, event handler attributes (`on*`), and `javascript:` / `data:` URLs from the parsed output before insertion into the DOM. `--allow-html` / `allowHtml: true` bypasses the strip.

## Error handling

| Scenario | Behavior |
|----------|----------|
| stdin is empty in `--markdown` mode | Exit with `{"status":"error","message":"no markdown provided on stdin"}` |
| Markdown has a parse error (unterminated fenced code, etc.) | Render best-effort; do not fail |
| `text` in `MarkdownDoc` is missing | Component renders placeholder "(no content)"; log warning |
| `--markdown` + `--a2ui` or `--markdown` + `--url` | Exit with error: flags are mutually exclusive |
| User closes window without submitting | Standard `cancelled` exit (1), no data |
| Oversized doc (>500KB) | Render, but log a perf warning to stderr. No hard cap. |

## Testing

Unit-level (in embedded JS, via a test harness):
- Parser: CommonMark compliance subset — fixture-based, ~30 docs covering headings, nested lists, fenced code, emphasis edge cases
- Source-line annotation: every parsed block carries correct `source_line_start` / `source_line_end`
- Comment serialization: click block → add comment → serialize → verify `quoted_text` and line range
- Sanitization: <script>, onclick=, javascript: URLs all stripped by default; preserved with `allowHtml`

Integration (via the Swift test harness that spawns webview-cli as a subprocess):
- `--markdown` + empty stdin → error exit
- `--markdown` simple doc → acknowledge → clean exit with status
- `--markdown --comments` → simulate click + comment via injected JS → verify output JSON shape
- `--markdown --edits` → simulate text change via injected JS → verify `edited_text` and `modified: true`
- `MarkdownDoc` as A2UI component alongside other inputs → verify combined form submission

Visual / manual:
- Test fixtures in `examples/markdown-review.md` and `examples/markdown-review-with-edits.md`
- `make test-markdown` target that spawns a representative window for manual QA

## Open questions (to resolve in the plan phase)

1. Whether inline code (`` `foo` ``) and code blocks need any syntax-highlight affordance in v1, or stay plain monospace (currently: plain)
   **Resolution:** No syntax highlight in v1. Plain monospace for both inline code and code blocks. Revisit if users request syntax highlighting as a common pain point.
2. Scroll-spy behavior: when you click a comment in the sidebar, should the rendered view scroll-and-highlight? (likely yes, nice-to-have)
   **Resolution:** Implemented in T9 (click comment card → scroll anchored block into view + highlight). Not full scroll-spy with active-block indicator, but meets the use case.
3. Behavior when `allowHtml=true` and user edits source to inject `<script>` — is the source view a trusted context? (likely: user edits are rendered in the preview with the same sanitization as the agent-provided markdown, unless `allowHtml` is on)
   **Resolution:** Source edits are rendered through the same sanitization path. When `allowHtml=true`, user-injected scripts would render (that is the consented behavior of the flag). When `allowHtml=false` (default), even user edits are sanitized. This is a known behavior and is documented in the protocol.

## Roadmap adjacencies (not in scope for this spec)

Features the user brainstormed alongside this one, deferred:

- **Speech-to-text input** — separate design. Likely needs background-session model rather than one-shot.
- **Diff viewer** with per-hunk accept/reject.
- **Persistent dock/menubar window** — long-lived companion for agent status.
- **Tree picker** — hierarchical select.
- **Inline streaming text** — agent streams a `Text` component live.
- **Image annotation** — draw boxes/arrows on screenshots.

Each will get its own design doc when picked up.
