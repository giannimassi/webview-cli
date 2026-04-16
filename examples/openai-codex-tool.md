# Using webview-cli with OpenAI Codex CLI, Gemini CLI, and other agents

The binary is agent-agnostic. Anything that can spawn a subprocess and read stdout can use it.

## OpenAI Codex CLI tool definition

If you're running Codex CLI, register `webview-cli` as a tool:

```python
# codex_tools/webview.py
import subprocess, json

def ask_user_via_webview(
    title: str,
    fields: list[dict],      # [{"type": "text", "label": "Name", "fieldName": "name"}, ...]
    primary_action: str = "Submit",
    timeout_sec: int = 300,
) -> dict:
    """
    Show a native macOS form, get structured input back.

    fields: list of A2UI-component dicts. Each needs 'type' (TextInput/Select/Checkbox/RadioGroup)
            and 'fieldName', plus type-specific props (label, options, etc.)

    Returns: {"action": <button name>, "data": {<fieldName>: <value>, ...}}
    """
    messages = _build_a2ui_form(title, fields, primary_action)
    jsonl = "\n".join(json.dumps(m) for m in messages)

    result = subprocess.run(
        ["webview-cli", "--a2ui", "--title", title, "--timeout", str(timeout_sec)],
        input=jsonl, capture_output=True, text=True
    )

    if result.returncode == 0:
        payload = json.loads(result.stdout)
        return payload["data"]
    elif result.returncode == 1:
        return {"action": "cancelled"}
    elif result.returncode == 2:
        return {"action": "timeout"}
    else:
        raise RuntimeError(f"webview-cli error: {result.stderr}")


def _build_a2ui_form(title, fields, primary_action):
    msgs = []
    field_ids = []

    msgs.append({"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}})
    msgs.append({"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}})

    # Title
    msgs.append({"surfaceUpdate": {"components": [{"id": "title", "component": {"Text": {"usageHint": "h2", "text": {"literalString": title}}}}]}})

    # Fields
    for i, f in enumerate(fields):
        fid = f"f{i}"
        field_ids.append(fid)
        t = f["type"]
        if t == "TextInput":
            comp = {"TextInput": {"label": {"literalString": f["label"]}, "fieldName": f["fieldName"], "multiline": f.get("multiline", False)}}
        elif t == "Select":
            comp = {"Select": {"label": {"literalString": f["label"]}, "fieldName": f["fieldName"], "options": f["options"]}}
        elif t == "Checkbox":
            comp = {"Checkbox": {"label": {"literalString": f["label"]}, "fieldName": f["fieldName"], "checked": f.get("checked", False)}}
        elif t == "RadioGroup":
            comp = {"RadioGroup": {"label": {"literalString": f["label"]}, "fieldName": f["fieldName"], "options": f["options"]}}
        else:
            raise ValueError(f"Unsupported field type: {t}")
        msgs.append({"surfaceUpdate": {"components": [{"id": fid, "component": comp}]}})

    # Buttons
    msgs.append({"surfaceUpdate": {"components": [{"id": "btns", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_c", "btn_go"]}}}}]}})
    msgs.append({"surfaceUpdate": {"components": [{"id": "btn_c", "component": {"Button": {"label": {"literalString": "Cancel"}, "variant": "secondary", "action": {"name": "cancel"}}}}]}})
    msgs.append({"surfaceUpdate": {"components": [{"id": "btn_go", "component": {"Button": {"label": {"literalString": primary_action}, "variant": "primary", "action": {"name": "submit"}}}}]}})

    # Content column
    msgs.append({"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": ["title"] + field_ids + ["btns"]}}}}]}})
    msgs.append({"beginRendering": {"root": "root"}})

    return msgs
```

Use from your Codex session:

```python
result = ask_user_via_webview(
    title="Deploy Approval",
    fields=[
        {"type": "RadioGroup", "label": "Rollout", "fieldName": "rollout",
         "options": [{"value": "canary", "label": "Canary (10%)"}, {"value": "full", "label": "Full rollout"}]},
        {"type": "TextInput", "label": "Deploy note", "fieldName": "note", "multiline": True},
    ],
    primary_action="Deploy",
    timeout_sec=120,
)
# result = {"action": "submit", "data": {"rollout": "canary", "note": "..."}}
```

## Gemini CLI

Gemini CLI tools follow a similar pattern — wrap the subprocess call in a function/tool definition. The exact schema depends on which Gemini tool framework you use (function calling vs custom tool specs). Above Python function works unchanged as the implementation; you only need to expose it with the right metadata for your framework.

## MCP server

Expose as an MCP tool:

```typescript
// In your MCP server
server.tool("ask_user_form", {
  title: z.string(),
  fields: z.array(/* ... */),
}, async ({ title, fields }) => {
  const { stdout, exitCode } = await spawnCapture("webview-cli", ["--a2ui", "--title", title, "--timeout", "300"], {
    input: buildA2uiJsonl(title, fields),
  });
  if (exitCode === 0) return { content: [{ type: "text", text: stdout }] };
  if (exitCode === 1) return { content: [{ type: "text", text: "cancelled" }] };
  // etc.
});
```

## Generic pattern

Any agent framework works the same way:

1. Define a function that takes a UI description and an optional timeout
2. Build A2UI JSONL from the description (or accept it directly if your agent's smart enough)
3. `subprocess.run(["webview-cli", "--a2ui", ...])` with the JSONL on stdin
4. Parse `stdout` as JSON when `returncode == 0`
5. Map other exit codes to appropriate return values

The magic is that the tool is just a CLI. No SDK to install, no auth, no network calls. Just a subprocess you can reach from any language.
