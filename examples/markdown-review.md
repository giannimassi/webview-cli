# Markdown review with comments

Use this pattern when your agent wants a human to comment on a generated spec or document.

The agent produces markdown (a deployment plan, design doc, feature spec), pipes it to webview-cli with `--markdown --comments`, and the human reviews it with paragraph-level comments. The agent receives structured feedback and can iterate.

## Example flow

```bash
SPEC=$(cat <<'EOF'
# Deploy plan for payment-service

Phase 1: canary deploy to 10% traffic.

Phase 2: full rollout after 30 min of clean metrics.

## Rollback

Immediate revert to previous binary if error rate > 5%.
EOF
)

RESULT=$(echo "$SPEC" | webview-cli --markdown --comments --title "Review: deploy plan" --timeout 600)

# Check exit code
case $? in
  0) echo "User submitted review:" && echo "$RESULT" | jq . ;;
  1) echo "User cancelled." ;;
  2) echo "Timed out." ;;
  3) echo "Error: $(echo "$RESULT" | jq -r .message)" ;;
esac
```

## Returned JSON shape

When the user clicks **Submit**, the window emits:

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
          "quoted_text": "Phase 1: canary deploy to 10% traffic.",
          "body": "What's the traffic ramp rate? Linear or exponential?"
        },
        {
          "source_line_start": 7,
          "source_line_end": 7,
          "quoted_text": "Phase 2: full rollout after 30 min of clean metrics.",
          "body": "Define 'clean metrics' — P99 latency? Error rate? Both?"
        }
      ],
      "doc_comment": "Looks good overall. Add a rollback checklist at the end."
    }
  }
}
```

**Field meanings:**

- `comments`: array of paragraph-level comments (0 or more). Each comment has:
  - `source_line_start`, `source_line_end`: line numbers in the input markdown
  - `quoted_text`: the paragraph text at the time the comment was added (resilient to user edits)
  - `body`: the comment text
- `doc_comment`: a single document-level comment (string, may be empty). Returned even if the textarea was left blank.

**Exit codes:**

- `0` — submitted; `data` contains comments and doc_comment
- `1` — cancelled; no data
- `2` — timeout; no data
- `3` — error; `message` field explains why

## Integration notes

- Exit code is the authoritative signal. Always check it first.
- Inline comments anchor to specific paragraphs. Even if the user edits the source, comments carry their original `quoted_text` so the agent can reconcile.
- The `doc_comment` field is always present (may be empty string).
- Comments are returned in the order they were added.

See also: [`markdown-review-edits.md`](markdown-review-edits.md) for adding optional source editing.
