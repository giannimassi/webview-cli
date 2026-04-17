# Markdown review with edits

Use this pattern when you want the human to optionally edit the markdown in addition to commenting.

The window shows two tabs: **Preview** (rendered markdown with optional comment sidebar) and **Source** (plain-text editor). The human can review the rendered doc, add paragraph-level comments, and also make direct edits to the source. The agent receives the final edited text and knows whether it was modified.

## Example flow

```bash
SPEC=$(cat <<'EOF'
# Payment Processing SLA

## Uptime target
99.9% availability monthly.

## Response time
Median response latency: < 100ms (p95: < 300ms).

## Data retention
Transaction logs retained for 7 years per regulation.
EOF
)

RESULT=$(echo "$SPEC" | webview-cli --markdown --comments --edits --title "Review: Payment SLA" --timeout 600)

# Check exit code
case $? in
  0) 
    echo "Submitted. Extracting edited text and modification flag:"
    EDITED=$(echo "$RESULT" | jq -r '.data.data.edited_text')
    MODIFIED=$(echo "$RESULT" | jq -r '.data.data.modified')
    echo "Modified: $MODIFIED"
    echo "---"
    echo "$EDITED"
    ;;
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
          "source_line_start": 4,
          "source_line_end": 4,
          "quoted_text": "99.9% availability monthly.",
          "body": "Is this calendar month or rolling 30 days?"
        }
      ],
      "doc_comment": "Good. Minor comment above.",
      "edited_text": "# Payment Processing SLA\n\n## Uptime target\n99.99% availability monthly (rolling 30-day window).\n\n## Response time\nMedian response latency: < 100ms (p95: < 300ms).\n\n## Data retention\nTransaction logs retained for 7 years per regulation.\n",
      "modified": true
    }
  }
}
```

**Field meanings:**

- `comments`: array of paragraph-level comments (same as `markdown-review.md`)
- `doc_comment`: document-level comment field
- `edited_text`: the complete markdown source at submit time (full text, not a diff)
- `modified`: boolean. `true` if the user edited the source. `false` if no changes were made (even if comments were added).

## Interaction model

**Preview tab:**
- Shows rendered markdown with inline comment pins (💬)
- Click any paragraph to open a comment composer in the sidebar
- Existing comments appear as cards in the sidebar. Click a card to scroll and highlight its block.
- `Cmd+/` switches to Source tab

**Source tab:**
- Plain `<textarea>` with the full markdown source
- Tab key inserts spaces (4-space indent by default)
- `Cmd+/` switches back to Preview tab
- Switching tabs re-renders the preview from the current source

**Keyboard shortcuts:**
- `Cmd+Enter` → Submit (from anywhere in the window)
- `Cmd+Enter` → Commit comment (inside the comment composer)
- `Esc` → Cancel
- `Cmd+W` → Cancel
- `Cmd+/` → Toggle Preview/Source (when `--edits` is on)

## Integration notes

- Exit code `0` is success. Always check it first.
- `edited_text` is the full source at submit time. If you need to detect what changed, compare against your input, or extract a diff yourself.
- `modified` is a boolean convenience flag. Use it to decide whether to apply the edits or skip validation if nothing changed.
- Both `comments` and `edited_text` can appear in the same response. The user may have reviewed and commented while also making edits.

See also: [`markdown-review.md`](markdown-review.md) for review-only mode without editing.
