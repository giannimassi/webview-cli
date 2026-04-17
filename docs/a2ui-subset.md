# A2UI Subset

`webview-cli --a2ui` ships a minimal renderer for a subset of Google's [A2UI v0.8 standard catalog](https://a2ui.org/specification/v0.8-a2ui/). The subset covers the four agent-UI patterns the tool is optimized for: **approval, form, select, acknowledgement**.

Additionally, `webview-cli` extends A2UI with a `MarkdownDoc` component for markdown review workflows.

## Supported components

| Component | Key props | Notes |
|-----------|-----------|-------|
| `Column` | `children.explicitList` | Vertical stack with default gap |
| `Row` | `children.explicitList`, `alignment` (`center` \| `end` \| `space-between`) | Horizontal, wraps on narrow windows |
| `Card` | `child` (single ID) or `children.explicitList` | Visual container with padding + border |
| `Text` | `text.literalString`, `usageHint` (`h1` \| `h2` \| `h3` \| `subtitle` \| `body` \| `caption`) | Typography styles baked in |
| `TextInput` | `label.literalString`, `placeholder.literalString`, `fieldName`, `multiline` (bool), `value.literalString` | `multiline=true` renders a `<textarea>` |
| `Select` | `label.literalString`, `fieldName`, `options` (array of `{value, label}` or strings) | Native `<select>` with custom chevron |
| `Checkbox` | `label.literalString`, `fieldName`, `checked` (bool) | Apple-blue accent |
| `RadioGroup` | `label.literalString`, `fieldName`, `options` (array), `value` (initial selection) | Mutually exclusive; first option selected by default |
| `Image` | `url` (literal or dataRef), `alt`, `width`, `height` | Supports remote URLs and `agent://` scheme |
| `Button` | `label.literalString`, `variant` (`primary` \| `secondary` \| `danger` \| `success`), `action.name`, `action.context` | Clicking fires the `complete` handler with collected form data |
| `Divider` | — | Horizontal rule |
| `MarkdownDoc` | `fieldName` (required), `text` (required), `allowComments` (bool), `allowEdits` (bool), `allowHtml` (bool), `title` (string) | Renders markdown with optional comment sidebar + edit tab. Composed value reflects enabled toggles (see props below). |

## MarkdownDoc component

### Purpose

The `MarkdownDoc` component renders markdown content inside an A2UI form. It enables spec review workflows where the user reviews a generated markdown document, adds inline and document-level comments, optionally edits the source, and submits structured feedback.

### Props

| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `fieldName` | string | — | yes | Key under which the review payload goes in form `data`. |
| `text` | string | — | yes | The markdown content to render. |
| `allowComments` | bool | false | no | Enable paragraph-level comments (inline + document-level comment field). |
| `allowEdits` | bool | false | no | Enable source editor tab (Preview/Source tabs). |
| `allowHtml` | bool | false | no | Disable HTML sanitization. Default strips `<script>`, `<iframe>`, event handlers, `javascript:` URLs. |
| `title` | string | — | no | Optional subheading displayed above the document. |

### Output shape

When a button with `action.name="submit"` is clicked, the `MarkdownDoc` component contributes a field to the form's `data` object:

```json
{
  "action": "submit",
  "data": {
    "<fieldName>": {
      "comments": [...],
      "doc_comment": "...",
      "edited_text": "...",
      "modified": bool
    },
    "<other-field>": "..."
  }
}
```

The `<fieldName>` value is an object whose shape depends on which toggles are enabled:

| allowComments | allowEdits | Output |
|---|---|---|
| false | false | `{}` (empty object, no review payload) |
| true | false | `{"comments": [...], "doc_comment": "..."}` |
| false | true | `{"edited_text": "...", "modified": bool}` |
| true | true | `{"comments": [...], "doc_comment": "...", "edited_text": "...", "modified": bool}` |

**Field definitions:**

- `comments`: array of comment objects. Each has `source_line_start` (int), `source_line_end` (int), `quoted_text` (string), `body` (string). Always present when `allowComments=true`. Empty array `[]` if no comments were added.
- `doc_comment`: document-level comment (string). Always present when `allowComments=true`. Empty string `""` if left blank.
- `edited_text`: full markdown source at submit time. Always present when `allowEdits=true`.
- `modified`: boolean indicating whether the source differs from the input. Always present when `allowEdits=true`.

### Example: mixed form with spec review

```jsonl
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["card"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"card","component":{"Card":{"children":{"explicitList":["title","spec","rollout","btns"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"title","component":{"Text":{"usageHint":"h2","text":{"literalString":"Review and approve"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"spec","component":{"MarkdownDoc":{"fieldName":"review","text":"# Deploy Plan\n\nPhase 1: 10% traffic.\n\nPhase 2: full rollout.","allowComments":true,"allowEdits":false}}}]}}
{"surfaceUpdate":{"components":[{"id":"rollout","component":{"RadioGroup":{"label":{"literalString":"Proceed?"},"fieldName":"decision","options":[{"value":"approve","label":"Approve"},{"value":"reject","label":"Reject"}]}}}]}}
{"surfaceUpdate":{"components":[{"id":"btns","component":{"Row":{"alignment":"end","children":{"explicitList":["cancel","submit"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"cancel","component":{"Button":{"label":{"literalString":"Cancel"},"variant":"secondary","action":{"name":"cancel"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"submit","component":{"Button":{"label":{"literalString":"Submit"},"variant":"primary","action":{"name":"submit"}}}}]}}
{"beginRendering":{"root":"root"}}
```

When the user clicks **Submit**, the response is:

```json
{
  "status": "completed",
  "data": {
    "action": "submit",
    "data": {
      "review": {
        "comments": [
          {
            "source_line_start": 3,
            "source_line_end": 3,
            "quoted_text": "Phase 1: 10% traffic.",
            "body": "Is this a timed window or event-based?"
          }
        ],
        "doc_comment": "Looks solid. Proceed."
      },
      "decision": "approve"
    }
  }
}
```

The `review` key (the component's `fieldName`) contains the review payload, and `decision` holds the radio selection.

### Interaction model

**When `allowComments=false` and `allowEdits=false`:**
- Read-only preview of rendered markdown.

**When `allowComments=true` (and `allowEdits=false`):**
- Rendered preview is clickable. Click any block to attach a paragraph-level comment.
- Right sidebar shows comment composer and existing comments.
- Document-level comment field at bottom.

**When `allowEdits=true` (and `allowComments=false`):**
- Two tabs: **Preview** (rendered) and **Source** (plain textarea).
- `Cmd+/` toggles between tabs.
- Tab-indent support in source editor.

**When both are true:**
- Preview tab includes comment pins and composer.
- Source tab is plain editor.
- Both reviews (comments + edited source) are captured and returned.

### HTML sanitization

By default, raw HTML embedded in the markdown is stripped:
- `<script>`, `<iframe>`, `<object>`, `<embed>` elements removed
- Event handler attributes removed
- `javascript:` and `data:` URLs converted to safe placeholders
- Image data URIs allowed (allow-listed)

Set `allowHtml=true` to disable sanitization. When enabled and the user edits source (if `allowEdits=true`), edited content is rendered through the same sanitization path.

### For more detail

See [`docs/protocol.md#markdown-mode`](protocol.md#markdown-mode) for the complete markdown mode specification, including keyboard shortcuts, output shape matrix, and error handling.

## Message types

Three message types from A2UI v0.8 are supported:

- `surfaceUpdate` — adds/updates components in the adjacency map
- `dataModelUpdate` — stores values; `literalString` props work fully, `dataRef` props do basic path lookup
- `beginRendering` — signals "render now", must be the last message

Unsupported: `deleteSurface`, catalog negotiation (`catalogId`), inline catalogs, progressive rendering optimizations, `createSurface` (v0.9).

## Form data collection

Every component with a `fieldName` prop contributes to the data payload when any `Button` is clicked. The collected payload is:

```json
{
  "action": "<button's action.name>",
  "data": { "<fieldName>": "<value>", ... },
  "context": { /* button's action.context object, if any */ }
}
```

Checkbox values are booleans. Select and TextInput values are strings. MarkdownDoc values are objects (see MarkdownDoc section above).

## Dynamic values

`Text.text` and `TextInput.value` accept either a literal or a data reference:

```json
{"text": {"literalString": "Hello"}}
{"text": {"dataRef": "/user/name"}}
```

Data references use a slash-separated path against the current data model (fed by `dataModelUpdate.contents`). Nested lookups work (e.g. `/user/profile/name`), but full RFC 6901 JSON Pointer is not implemented.

## Example: approval with comment

```jsonl
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["card"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"card","component":{"Card":{"child":"content"}}}]}}
{"surfaceUpdate":{"components":[{"id":"content","component":{"Column":{"children":{"explicitList":["title","comment","btns"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"title","component":{"Text":{"usageHint":"h2","text":{"literalString":"Deploy?"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"comment","component":{"TextInput":{"label":{"literalString":"Note"},"fieldName":"note","multiline":true}}}]}}
{"surfaceUpdate":{"components":[{"id":"btns","component":{"Row":{"alignment":"end","children":{"explicitList":["cancel","go"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"cancel","component":{"Button":{"label":{"literalString":"Cancel"},"variant":"secondary","action":{"name":"cancel"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"go","component":{"Button":{"label":{"literalString":"Deploy"},"variant":"success","action":{"name":"approve"}}}}]}}
{"beginRendering":{"root":"root"}}
```

Response on Approve click:

```json
{"status":"completed","data":{"action":"approve","data":{"note":"LGTM"},"context":{}}}
```

## Why a subset

The A2UI spec has ~30 components in the standard catalog. Shipping all of them would bloat the renderer beyond the 250-line budget without improving the agent-UI patterns this tool targets. If your use case needs `List` or other components not shipped yet, open an issue — they're on the roadmap.

For richer UIs, use `--url` mode and serve custom HTML via `agent://`.

## Roadmap

- v0.2: `List` component, better `dataModelUpdate` support, full JSON Pointer data binding
- v1.0: Full A2UI v0.8 standard catalog, declared spec compliance
- v1.1: A2UI v0.9 (`createSurface`, client-side functions)
