#!/usr/bin/env bash
# Binary smoke test for --editor mode. Drives the `fileop` stdin protocol
# against a throwaway temp dir and asserts on stdout + on-disk effects.
# This is the CI-testable seam for the Swift FileService (no GUI needed):
# the same code services the GUI's `fileOp` message handler.
set -u

BIN="${1:-./webview-cli}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/webview-editor-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# Fixture tree.
mkdir -p "$TMP/sub"
printf '# Title\n\nBody.\n' > "$TMP/readme.md"
printf 'alpha\nbeta\n' > "$TMP/sub/notes.txt"
printf 'secret\n' > "$TMP/.hidden"

# op <json> -> stdout (data object), exits binary via --timeout fallback.
op() {
  printf '%s\n' "$1" | "$BIN" --editor "$TMP" --timeout 3 2>/dev/null
}

# 1. listDir root: dirs first, dotfiles hidden.
OUT="$(op '{"type":"fileop","op":"listDir","path":""}')"
echo "$OUT" | grep -q '"ok":true' || fail "listDir not ok: $OUT"
echo "$OUT" | grep -q '"name":"sub"' || fail "listDir missing sub dir: $OUT"
echo "$OUT" | grep -q '"name":"readme.md"' || fail "listDir missing readme.md: $OUT"
echo "$OUT" | grep -q '.hidden' && fail "listDir leaked dotfile: $OUT"
# dir 'sub' must sort before file 'readme.md'
echo "$OUT" | grep -oE '"name":"(sub|readme.md)"' | head -1 | grep -q sub || fail "dirs not sorted first: $OUT"
echo "PASS: editor listDir (dirs first, dotfiles hidden)"

# 2. readFile round-trips UTF-8 content.
OUT="$(op '{"type":"fileop","op":"readFile","path":"readme.md"}')"
echo "$OUT" | grep -q '"ok":true' || fail "readFile not ok: $OUT"
echo "$OUT" | grep -q '# Title' || fail "readFile missing content: $OUT"
echo "PASS: editor readFile round-trips content"

# 3. writeFile persists to disk.
op '{"type":"fileop","op":"writeFile","path":"created.txt","content":"written by smoke\n"}' >/dev/null
[ -f "$TMP/created.txt" ] || fail "writeFile did not create file"
grep -q 'written by smoke' "$TMP/created.txt" || fail "writeFile content mismatch"
echo "PASS: editor writeFile persists to disk"

# 4. Path escape via ../ is rejected (read + write).
OUT="$(op '{"type":"fileop","op":"readFile","path":"../../../../etc/hosts"}')"
echo "$OUT" | grep -q 'escapes root' || fail "readFile escape not rejected: $OUT"
OUT="$(op '{"type":"fileop","op":"writeFile","path":"../escape.txt","content":"x"}')"
echo "$OUT" | grep -q 'escapes root' || fail "writeFile escape not rejected: $OUT"
[ -f "$TMP/../escape.txt" ] && fail "escape write actually landed on disk"
echo "PASS: editor rejects ../ path escapes (read + write)"

# 5. Opening a file path uses its parent dir as the root.
OUT="$(printf '%s\n' '{"type":"fileop","op":"listDir","path":""}' | "$BIN" --editor "$TMP/readme.md" --timeout 3 2>/dev/null)"
echo "$OUT" | grep -q '"name":"readme.md"' || fail "file-as-root did not open parent dir: $OUT"
echo "PASS: editor file-as-root opens parent directory"

# 6. Nonexistent root errors cleanly (exit 3, error JSON).
OUT="$("$BIN" --editor "$TMP/does-not-exist" --timeout 3 2>/dev/null)"
echo "$OUT" | grep -q '"status":"error"' || fail "missing root did not error: $OUT"
echo "PASS: editor missing root emits error"

# 7. listAll returns a flat recursive file list (for ⌘P quick-open).
printf 'needle one\n' > "$TMP/sub/deep.txt"
OUT="$(op '{"type":"fileop","op":"listAll"}')"
echo "$OUT" | grep -q '"ok":true' || fail "listAll not ok: $OUT"
echo "$OUT" | grep -q 'readme.md' || fail "listAll missing top file: $OUT"
echo "$OUT" | grep -q 'deep.txt' || fail "listAll missing nested file: $OUT"
echo "$OUT" | grep -q '.hidden' && fail "listAll leaked dotfile: $OUT"
echo "PASS: editor listAll returns flat recursive file list"

# 8. search greps file contents across the tree, case-insensitive, with line numbers.
printf 'Needle in caps\n' > "$TMP/sub/notes.txt"
OUT="$(op '{"type":"fileop","op":"search","query":"needle"}')"
echo "$OUT" | grep -q '"ok":true' || fail "search not ok: $OUT"
echo "$OUT" | grep -q 'deep.txt' || fail "search missed lowercase match: $OUT"
echo "$OUT" | grep -q 'notes.txt' || fail "search missed case-insensitive match: $OUT"
echo "$OUT" | grep -q '"line":1' || fail "search missing line number: $OUT"
echo "PASS: editor search greps contents case-insensitively with line numbers"

# 9. search is scoped — it never reads outside the root.
echo 'needle' > "$TMP/../outside-needle.txt" 2>/dev/null || true
OUT="$(op '{"type":"fileop","op":"search","query":"needle"}')"
echo "$OUT" | grep -q 'outside-needle' && fail "search leaked a match from outside root: $OUT"
rm -f "$TMP/../outside-needle.txt" 2>/dev/null || true
echo "PASS: editor search stays within root"

echo "All editor smoke tests pass"
