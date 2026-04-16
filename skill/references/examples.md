# Worked Examples

Complete end-to-end invocations showing how an agent uses the webview skill.

## Example 1: Deploy approval

**Agent's reasoning**: "I'm about to run a production deploy. I should get human approval first, with space for a comment that goes into the deploy log."

**Invocation:**

```bash
cat <<'EOF' | webview-cli --a2ui --title "Deploy Approval" --width 540 --height 520 --timeout 300
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["card"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"card","component":{"Card":{"child":"content"}}}]}}
{"surfaceUpdate":{"components":[{"id":"content","component":{"Column":{"children":{"explicitList":["title","subtitle","divider","changes","comment","buttons"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"title","component":{"Text":{"usageHint":"h2","text":{"literalString":"Deploy to Production"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"subtitle","component":{"Text":{"usageHint":"subtitle","text":{"literalString":"Review changes before approving. Comment will be logged."}}}}]}}
{"surfaceUpdate":{"components":[{"id":"divider","component":{"Divider":{}}}]}}
{"surfaceUpdate":{"components":[{"id":"changes","component":{"Text":{"usageHint":"body","text":{"literalString":"Branch: feature/rate-limit-v2\n3 files changed, 47 insertions, 12 deletions\nAll CI checks passing\nLast commit: fix(api): handle rate-limit response event"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"comment","component":{"TextInput":{"label":{"literalString":"Deploy note (optional)"},"placeholder":{"literalString":"e.g. urgent fix for customer X"},"fieldName":"note","multiline":true}}}]}}
{"surfaceUpdate":{"components":[{"id":"buttons","component":{"Row":{"alignment":"end","children":{"explicitList":["btn_cancel","btn_deploy"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn_cancel","component":{"Button":{"label":{"literalString":"Cancel"},"variant":"secondary","action":{"name":"cancel"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn_deploy","component":{"Button":{"label":{"literalString":"Deploy"},"variant":"success","action":{"name":"approve"}}}}]}}
{"beginRendering":{"root":"root"}}
EOF
```

**Parsing the response (in Bash):**

```bash
RESULT=$(cat <<'EOF' | webview-cli --a2ui ...)  # from above
EXIT=$?

if [ $EXIT -eq 0 ]; then
  ACTION=$(echo "$RESULT" | jq -r '.data.action')
  if [ "$ACTION" = "approve" ]; then
    NOTE=$(echo "$RESULT" | jq -r '.data.data.note')
    echo "Approved. Note: $NOTE"
    # run the deploy
  else
    echo "Cancelled via button"
  fi
elif [ $EXIT -eq 1 ]; then
  echo "User closed the window"
elif [ $EXIT -eq 2 ]; then
  echo "Timed out — no response in 5 minutes"
fi
```

## Example 2: Pick a reviewer

**Agent's reasoning**: "The PR needs a reviewer. CODEOWNERS suggests three people — let the user pick."

```bash
cat <<'EOF' | webview-cli --a2ui --title "Pick a Reviewer" --width 460 --height 360 --timeout 120
{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["card"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"card","component":{"Card":{"child":"content"}}}]}}
{"surfaceUpdate":{"components":[{"id":"content","component":{"Column":{"children":{"explicitList":["title","prompt","reviewer","buttons"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"title","component":{"Text":{"usageHint":"h2","text":{"literalString":"Pick a Reviewer"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"prompt","component":{"Text":{"usageHint":"body","text":{"literalString":"CODEOWNERS suggests these three — who should review?"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"reviewer","component":{"Select":{"label":{"literalString":"Reviewer"},"fieldName":"reviewer","options":[{"value":"alice","label":"alice (backend)"},{"value":"bob","label":"bob (infra)"},{"value":"carol","label":"carol (frontend)"}]}}}]}}
{"surfaceUpdate":{"components":[{"id":"buttons","component":{"Row":{"alignment":"end","children":{"explicitList":["btn_skip","btn_ok"]}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn_skip","component":{"Button":{"label":{"literalString":"Skip"},"variant":"secondary","action":{"name":"skip"}}}}]}}
{"surfaceUpdate":{"components":[{"id":"btn_ok","component":{"Button":{"label":{"literalString":"Assign"},"variant":"primary","action":{"name":"assign"}}}}]}}
{"beginRendering":{"root":"root"}}
EOF
```

Response: `{"status":"completed","data":{"action":"assign","data":{"reviewer":"alice"},"context":{}}}`

## Example 3: Rich HTML (custom visual, not A2UI)

When A2UI's component set isn't enough — e.g. showing a rendered diff with syntax highlighting, or a chart.

```bash
# Write the HTML
cat > /tmp/wv-diff.html <<'EOF'
<!DOCTYPE html>
<html><head>
<style>
  body { font: 14px -apple-system; background: #0f0f23; color: #e0e0e0; padding: 1rem; }
  .diff { font-family: monospace; background: #16213e; padding: 1rem; border-radius: 8px; white-space: pre; }
  .add { color: #4ade80; } .rm { color: #f87171; }
  button { padding: 0.6rem 1.2rem; margin-right: 0.5rem; border: none; border-radius: 6px; cursor: pointer; }
  .primary { background: #4a6cf7; color: white; }
  .secondary { background: #2a2a4a; color: #ccc; }
</style></head><body>
<h2>Code Diff Review</h2>
<div class="diff"><span class="rm">- let x = 1;</span>
<span class="add">+ const x = 1;</span></div>
<div style="margin-top: 1rem;">
  <button class="secondary" onclick="done('reject')">Reject</button>
  <button class="primary" onclick="done('accept')">Accept</button>
</div>
<script>
  function done(action) {
    window.webkit.messageHandlers.complete.postMessage({action});
  }
</script>
</body></html>
EOF

# Base64-encode and pipe via the stdin load protocol
HTML_B64=$(base64 < /tmp/wv-diff.html)
(echo "{\"type\":\"load\",\"resources\":{\"index.html\":\"$HTML_B64\"},\"url\":\"agent://host/index.html\"}"; cat) | webview-cli --title "Diff Review" --width 720 --height 500 --timeout 180
```

## Example 4: Programmatic JSONL generation (Python)

When the form fields are dynamic, build the JSONL in code:

```python
import json
import subprocess

fields = [
    {"name": "repo_name", "label": "Repository name"},
    {"name": "description", "label": "Description", "multiline": True},
    {"name": "visibility", "label": "Visibility", "options": ["public", "private"]},
]

messages = [
    {"surfaceUpdate": {"components": [{"id": "root", "component": {"Column": {"children": {"explicitList": ["card"]}}}}]}},
    {"surfaceUpdate": {"components": [{"id": "card", "component": {"Card": {"child": "content"}}}]}},
]

field_ids = []
for f in fields:
    fid = f["name"]
    field_ids.append(fid)
    if "options" in f:
        comp = {"Select": {"label": {"literalString": f["label"]}, "fieldName": f["name"], "options": [{"value": o, "label": o} for o in f["options"]]}}
    else:
        comp = {"TextInput": {"label": {"literalString": f["label"]}, "fieldName": f["name"], "multiline": f.get("multiline", False)}}
    messages.append({"surfaceUpdate": {"components": [{"id": fid, "component": comp}]}})

messages.append({"surfaceUpdate": {"components": [{"id": "content", "component": {"Column": {"children": {"explicitList": field_ids + ["buttons"]}}}}]}})
messages.append({"surfaceUpdate": {"components": [{"id": "buttons", "component": {"Row": {"alignment": "end", "children": {"explicitList": ["btn_cancel", "btn_submit"]}}}}]}})
messages.append({"surfaceUpdate": {"components": [{"id": "btn_cancel", "component": {"Button": {"label": {"literalString": "Cancel"}, "variant": "secondary", "action": {"name": "cancel"}}}}]}})
messages.append({"surfaceUpdate": {"components": [{"id": "btn_submit", "component": {"Button": {"label": {"literalString": "Create"}, "variant": "primary", "action": {"name": "submit"}}}}]}})
messages.append({"beginRendering": {"root": "root"}})

jsonl = "\n".join(json.dumps(m) for m in messages)
result = subprocess.run(
    ["webview-cli", "--a2ui", "--title", "New Repo", "--width", "540", "--height", "480", "--timeout", "300"],
    input=jsonl, capture_output=True, text=True
)

if result.returncode == 0:
    payload = json.loads(result.stdout)
    print("User submitted:", payload["data"]["data"])
elif result.returncode == 1:
    print("Cancelled")
elif result.returncode == 2:
    print("Timed out")
```

## Graceful degradation

If `webview-cli` isn't installed or fails, fall back to terminal Q&A:

```bash
if ! command -v webview-cli &>/dev/null; then
  # Terminal fallback
  read -p "Deploy to prod? [y/N] " yn
  [ "$yn" = "y" ] && echo "deploying" || echo "cancelled"
else
  # Webview path
  webview-cli --a2ui ... # as above
fi
```

Agents should always check for the binary before invoking — don't assume it's available.
