#!/usr/bin/env bash
# webview-cli installer — one-command setup
# Usage:
#   curl -sSL https://raw.githubusercontent.com/giannimassi/webview-cli/main/install.sh | bash
#   curl -sSL https://raw.githubusercontent.com/giannimassi/webview-cli/main/install.sh | bash -s -- --with-claude-skill

set -euo pipefail

YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'

info()  { echo "${BLUE}▸${RESET} $*"; }
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}⚠${RESET} $*"; }
fail()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }

# Platform guard
[[ "$(uname -s)" == "Darwin" ]] || fail "webview-cli is macOS-only (detected $(uname -s))"

# Parse flags
INSTALL_CLAUDE_SKILL="auto"
for arg in "$@"; do
  case "$arg" in
    --with-claude-skill) INSTALL_CLAUDE_SKILL="yes" ;;
    --no-claude-skill)   INSTALL_CLAUDE_SKILL="no" ;;
  esac
done

# Install the binary via brew
if command -v webview-cli >/dev/null 2>&1; then
  ok "webview-cli already on PATH: $(command -v webview-cli)"
else
  info "Installing webview-cli via Homebrew tap..."
  command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install from https://brew.sh first."
  brew tap giannimassi/tap 2>&1 | tail -2
  brew install webview-cli
  ok "webview-cli installed: $(command -v webview-cli)"
fi

# Verify
webview-cli --help 2>&1 >/dev/null | head -1 | grep -q Usage || fail "webview-cli installed but --help failed"

# Claude Code skill (auto-detect or flag)
CLAUDE_DIR="$HOME/.claude/skills"
if [[ "$INSTALL_CLAUDE_SKILL" == "no" ]]; then
  info "Skipping Claude Code skill install (--no-claude-skill)"
elif [[ "$INSTALL_CLAUDE_SKILL" == "yes" ]] || [[ -d "$HOME/.claude" ]]; then
  SKILL_TARGET="$CLAUDE_DIR/webview"
  # Try cached clone first (tap directory has the repo)
  TAP_REPO="$(brew --repository 2>/dev/null)/Library/Taps/giannimassi/homebrew-tap"
  SKILL_SRC=""

  # Fetch skill from the installed formula — Homebrew doesn't keep the source tree around, so clone fresh
  if [[ ! -d "$SKILL_TARGET" ]]; then
    TMP=$(mktemp -d)
    info "Fetching Claude Code skill to $SKILL_TARGET..."
    git clone --depth 1 --filter=blob:none --sparse https://github.com/giannimassi/webview-cli.git "$TMP/webview-cli" >/dev/null 2>&1
    git -C "$TMP/webview-cli" sparse-checkout set skill >/dev/null 2>&1
    mkdir -p "$CLAUDE_DIR"
    cp -r "$TMP/webview-cli/skill" "$SKILL_TARGET"
    rm -rf "$TMP"
    ok "Skill installed to $SKILL_TARGET"
    info "Restart Claude Code to pick it up. Trigger with /webview in any session."
  else
    warn "Skill already exists at $SKILL_TARGET — not overwriting. Delete the directory and re-run to update."
  fi
else
  info "No ~/.claude directory detected; skipping Claude Code skill. Re-run with --with-claude-skill to force."
fi

# Smoke test
info "Smoke test..."
echo '{"surfaceUpdate":{"components":[{"id":"root","component":{"Text":{"usageHint":"h2","text":{"literalString":"Hello from webview-cli"}}}}]}}
{"beginRendering":{"root":"root"}}' | webview-cli --a2ui --title "webview-cli install OK" --width 420 --height 180 --timeout 2 >/dev/null 2>&1 && ok "Smoke test passed" || warn "Smoke test timed out — manual check recommended"

echo ""
ok "webview-cli is installed and ready."
echo ""
echo "Quick start:"
echo "  webview-cli --help"
echo "  cat examples/hero-deploy-approval.jsonl | webview-cli --a2ui --timeout 120"
echo ""
echo "Docs: https://github.com/giannimassi/webview-cli"
