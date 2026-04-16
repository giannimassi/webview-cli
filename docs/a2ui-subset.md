# A2UI Subset

`webview-cli --a2ui` ships a minimal renderer for a subset of Google's [A2UI v0.8 standard catalog](https://a2ui.org/specification/v0.8-a2ui/). The subset covers the four agent-UI patterns the tool is optimized for: **approval, form, select, acknowledgement**.

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
| `Button` | `label.literalString`, `variant` (`primary` \| `secondary` \| `danger` \| `success`), `action.name`, `action.context` | Clicking fires the `complete` handler with collected form data |
| `Divider` | — | Horizontal rule |

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

Checkbox values are booleans. Select and TextInput values are strings.

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

The A2UI spec has ~30 components in the standard catalog. Shipping all of them would bloat the renderer beyond the 200-line budget without improving the four target patterns. If your use case needs `Image`, `List`, `RadioGroup`, or other components, open an issue — they're on the roadmap for v1.1.

For richer UIs, use `--url` mode and serve custom HTML via `agent://`.

## Roadmap

- v0.2: `RadioGroup`, `Image`, better `dataModelUpdate` support
- v1.0: Full A2UI v0.8 standard catalog, declared spec compliance
- v1.1: A2UI v0.9 (`createSurface`, client-side functions)
