# /webview — Claude Code Skill

This directory is a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills). It teaches an agent how to use `webview-cli` productively — when to reach for it, how to generate A2UI JSONL, how to parse the response.

## Install

Symlink this directory into your Claude Code skills folder:

```bash
ln -s "$(pwd)/skill" ~/.claude/skills/webview
```

Or copy it:

```bash
cp -r skill ~/.claude/skills/webview
```

Restart Claude Code and type `/webview` — the skill should be available.

## What it does

When an agent needs human-in-the-loop — approval, form input, option selection, or rich content display — it invokes this skill. The skill generates A2UI JSONL, pipes it to `webview-cli --a2ui`, and parses the returned JSON. The agent continues with the typed result.

See `SKILL.md` for the full contract and `references/templates.md` for copy-paste JSONL templates.

## Prerequisites

`webview-cli` must be installed and on `$PATH`:

```bash
brew tap giannimassi/tap
brew install webview-cli
```

The skill runs a preflight check on every invocation and falls back to terminal Q&A if the binary is missing.
