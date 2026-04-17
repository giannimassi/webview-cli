# A2UI Templates

Copy-paste templates for the four most common agent-UI patterns. Each is a complete JSONL — pipe it directly to `webview-cli --a2ui`.

## 1. Approval with optional comment

Use for: deploy approval, destructive action confirmation, agent plan approval.

```jsonl
{"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}}
{"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": ["title", "subtitle", "divider", "description", "comment", "buttons"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "title", "component": {"Text": {"usageHint": "h2", "text": {"literalString": "<TITLE>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "subtitle", "component": {"Text": {"usageHint": "subtitle", "text": {"literalString": "<SUBTITLE>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "divider", "component": {"Divider": {}}}]}}
{"surfaceUpdate": {"components": [{"id": "description", "component": {"Text": {"usageHint": "body", "text": {"literalString": "<DESCRIPTION>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "comment", "component": {"TextInput": {"label": {"literalString": "Comment (optional)"}, "placeholder": {"literalString": "Add context..."}, "fieldName": "comment", "multiline": true}}}]}}
{"surfaceUpdate": {"components": [{"id": "buttons", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_reject", "btn_approve"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_reject", "component": {"Button": {"label": {"literalString": "Reject"}, "variant": "danger", "action": {"name": "reject"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_approve", "component": {"Button": {"label": {"literalString": "Approve"}, "variant": "success", "action": {"name": "approve"}}}}]}}
{"beginRendering": {"root": "root"}}
```

**Response shape:**
```json
{"status":"completed","data":{"action":"approve","data":{"comment":"looks good"},"context":{}}}
```
or
```json
{"status":"completed","data":{"action":"reject","data":{"comment":"reason"},"context":{}}}
```

## 2. Single-select from options

Use for: pick a branch, choose a PR reviewer, select config preset.

```jsonl
{"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}}
{"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": ["title", "prompt", "select", "buttons"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "title", "component": {"Text": {"usageHint": "h2", "text": {"literalString": "<TITLE>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "prompt", "component": {"Text": {"usageHint": "body", "text": {"literalString": "<PROMPT>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "select", "component": {"Select": {"label": {"literalString": "Choice"}, "fieldName": "choice", "options": [{"value": "opt_a", "label": "Option A"}, {"value": "opt_b", "label": "Option B"}, {"value": "opt_c", "label": "Option C"}]}}}]}}
{"surfaceUpdate": {"components": [{"id": "buttons", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_cancel", "btn_select"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_cancel", "component": {"Button": {"label": {"literalString": "Cancel"}, "variant": "secondary", "action": {"name": "cancel"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_select", "component": {"Button": {"label": {"literalString": "Select"}, "variant": "primary", "action": {"name": "select"}}}}]}}
{"beginRendering": {"root": "root"}}
```

**Response shape:**
```json
{"status":"completed","data":{"action":"select","data":{"choice":"opt_b"},"context":{}}}
```

## 3. Multi-field form

Use for: collecting structured config (name, email, role), filling out agent parameters.

```jsonl
{"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}}
{"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": ["title", "name", "email", "role", "notes", "buttons"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "title", "component": {"Text": {"usageHint": "h2", "text": {"literalString": "<TITLE>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "name", "component": {"TextInput": {"label": {"literalString": "Name"}, "placeholder": {"literalString": "Full name"}, "fieldName": "name"}}}]}}
{"surfaceUpdate": {"components": [{"id": "email", "component": {"TextInput": {"label": {"literalString": "Email"}, "placeholder": {"literalString": "you@example.com"}, "fieldName": "email"}}}]}}
{"surfaceUpdate": {"components": [{"id": "role", "component": {"Select": {"label": {"literalString": "Role"}, "fieldName": "role", "options": [{"value": "admin", "label": "Admin"}, {"value": "editor", "label": "Editor"}, {"value": "viewer", "label": "Viewer"}]}}}]}}
{"surfaceUpdate": {"components": [{"id": "notes", "component": {"TextInput": {"label": {"literalString": "Notes"}, "placeholder": {"literalString": "Anything else..."}, "fieldName": "notes", "multiline": true}}}]}}
{"surfaceUpdate": {"components": [{"id": "buttons", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_cancel", "btn_submit"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_cancel", "component": {"Button": {"label": {"literalString": "Cancel"}, "variant": "secondary", "action": {"name": "cancel"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_submit", "component": {"Button": {"label": {"literalString": "Submit"}, "variant": "primary", "action": {"name": "submit"}}}}]}}
{"beginRendering": {"root": "root"}}
```

**Response shape:**
```json
{"status":"completed","data":{"action":"submit","data":{"name":"...","email":"...","role":"editor","notes":"..."},"context":{}}}
```

## 4. Confirmation with multi-line content

Use for: showing a diff, plan summary, test output for review before proceeding.

```jsonl
{"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}}
{"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": ["title", "summary", "divider", "details", "buttons"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "title", "component": {"Text": {"usageHint": "h2", "text": {"literalString": "<TITLE>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "summary", "component": {"Text": {"usageHint": "subtitle", "text": {"literalString": "<ONE-LINE SUMMARY>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "divider", "component": {"Divider": {}}}]}}
{"surfaceUpdate": {"components": [{"id": "details", "component": {"Text": {"usageHint": "body", "text": {"literalString": "<MULTI-LINE CONTENT — CAN BE LONG>"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "buttons", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_no", "btn_yes"]}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_no", "component": {"Button": {"label": {"literalString": "Back"}, "variant": "secondary", "action": {"name": "back"}}}}]}}
{"surfaceUpdate": {"components": [{"id": "btn_yes", "component": {"Button": {"label": {"literalString": "Proceed"}, "variant": "primary", "action": {"name": "proceed"}}}}]}}
{"beginRendering": {"root": "root"}}
```

**Response shape:**
```json
{"status":"completed","data":{"action":"proceed","data":{},"context":{}}}
```
or
```json
{"status":"completed","data":{"action":"back","data":{},"context":{}}}
```

(`data.data` is empty because this template has no `fieldName` inputs — it's an acknowledgement-only flow.)

## Template variables guide

When substituting into templates:

- **Titles**: 3-6 words, imperative or declarative. "Deploy Approval Required", "Choose a Base Branch".
- **Subtitles**: one sentence, ~10-15 words, give context.
- **Descriptions**: can be multi-paragraph but no markdown — plain text only (the renderer doesn't parse markdown).
- **Button labels**: 1-2 words, action verb. "Approve" > "Yes, I approve".
- **Field names**: snake_case identifiers. These become JSON keys in the response.
- **Field labels**: human-readable, Title Case.

## Escaping rules

The JSONL is fed to webview-cli via stdin. Each line is parsed as JSON, so:
- Escape backslashes: `\\`
- Escape quotes inside strings: `\"`
- Newlines in text content: `\n`
- Don't put literal newlines INSIDE a JSON object — each `{...}` must be one physical line.

If you have multi-paragraph content, build the JSON in a heredoc or construct it programmatically and write to a temp file, then `cat tempfile | webview-cli --a2ui ...`.
