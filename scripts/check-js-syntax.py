#!/usr/bin/env python3
# Parse-check the JS string literals embedded inside src/main.swift with
# `node --check`. Catches syntax errors that Swift cheerfully accepts
# (embedded strings are opaque to swiftc) but that break at runtime in
# WKWebView.
#
# Handles both raw (#-quoted) and non-raw Swift multi-line strings. For
# non-raw strings, Swift interprets escapes like \\ -> \, \" -> ",
# \n -> newline, etc. We mirror that with Python's `unicode_escape`
# codec so what we pipe to node matches what the binary serves.
#
# Exits 0 on clean parse of every detected constant. Exits 1 with
# diagnostic output on the first failure.
import re
import subprocess
import sys

SRC = "src/main.swift"

def extract_raw(content: str, name: str) -> str | None:
    m = re.search(rf'(?ms)^let {name} = #"""\n(.*?)\n"""#', content)
    return m.group(1) if m else None

def extract_plain(content: str, name: str) -> str | None:
    m = re.search(rf'(?ms)^let {name} = """\n(.*?)\n"""\n', content)
    if not m:
        return None
    return m.group(1).encode("utf-8").decode("unicode_escape")

def check(name: str, js: str) -> bool:
    proc = subprocess.run(
        ["node", "--check", "-"],
        input=js,
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        print(f"PASS: {name} parses cleanly")
        return True
    print(f"FAIL: {name} has a syntax error")
    print(proc.stderr.rstrip())
    return False

def main() -> int:
    with open(SRC) as f:
        content = f.read()

    targets = [
        ("a2uiRendererJS",      extract_plain(content, "a2uiRendererJS")),
        ("markdownRendererJS",  extract_raw(content,   "markdownRendererJS")),
        ("micromarkJS",         extract_raw(content,   "micromarkJS")),
    ]

    ok = True
    for name, js in targets:
        if js is None:
            print(f"WARN: could not locate {name}; skipping")
            continue
        if not check(name, js):
            ok = False
            break
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
