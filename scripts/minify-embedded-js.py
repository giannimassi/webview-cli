#!/usr/bin/env python3
"""
Minify embedded JavaScript constants in src/main.swift.

Minifies markdownRendererJS with esbuild and re-embeds it.
"""

import sys
import os
import subprocess
import re
import tempfile

ESBUILD_PATH = '/tmp/webview-cli-minify/node_modules/.bin/esbuild'

def extract_js_const(content, name, raw=False):
    """Extract a JS constant from Swift source code."""
    if raw:
        pattern = rf'let {re.escape(name)} = #"""(.*?)"""#'
        flags = re.DOTALL
    else:
        pattern = rf'let {re.escape(name)} = """(.*?)"""\n'
        flags = re.DOTALL
    
    match = re.search(pattern, content, flags)
    if not match:
        return None, match
    
    return match.group(1), match

def minify_with_esbuild(js_code):
    """Minify JavaScript using esbuild."""
    with tempfile.TemporaryDirectory() as tmpdir:
        input_file = os.path.join(tmpdir, 'input.js')
        output_file = os.path.join(tmpdir, 'output.min.js')
        
        with open(input_file, 'w') as f:
            f.write(js_code)
        
        result = subprocess.run([
            ESBUILD_PATH,
            input_file,
            '--minify',
            f'--outfile={output_file}'
        ], capture_output=True, text=True)
        
        if result.returncode != 0:
            raise RuntimeError(f"esbuild failed: {result.stderr}")
        
        with open(output_file, 'r') as f:
            return f.read()

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    main_file = os.path.join(repo_root, 'src', 'main.swift')
    
    if not os.path.exists(ESBUILD_PATH):
        print(f"ERROR: esbuild not found at {ESBUILD_PATH}", file=sys.stderr)
        return 1
    
    with open(main_file, 'r') as f:
        original = f.read()
    
    print("Extracting JS constants...")
    
    # Only minify markdownRendererJS
    md_code, md_match = extract_js_const(original, 'markdownRendererJS', raw=True)
    if not md_code:
        print("ERROR: Could not find markdownRendererJS constant", file=sys.stderr)
        return 1
    
    print(f"  markdownRendererJS: {len(md_code)} bytes")
    
    print("\nMinifying with esbuild...")
    
    try:
        md_min = minify_with_esbuild(md_code)
        md_ratio = 100*len(md_min)//len(md_code)
        saved = len(md_code) - len(md_min)
        print(f"  markdownRendererJS: {len(md_code)} -> {len(md_min)} bytes ({md_ratio}%, saved {saved} bytes)")
    except Exception as e:
        print(f"ERROR minifying markdownRendererJS: {e}", file=sys.stderr)
        return 1
    
    print("\nRe-embedding...")
    
    # Direct string replacement using the matched portion
    old_const = original[md_match.start():md_match.end()]
    new_const = f'let markdownRendererJS = #"""\n{md_min}\n"""#\n'
    
    print("Replacing in src/main.swift...")
    
    modified = original.replace(old_const, new_const, 1)
    
    if modified == original:
        print("ERROR: Failed to replace markdownRendererJS", file=sys.stderr)
        return 1
    
    # Write back
    with open(main_file, 'w') as f:
        f.write(modified)
    
    print("\nDone!")
    print(f"Binary size reduction: ~{saved} bytes from markdownRendererJS")
    return 0

if __name__ == '__main__':
    sys.exit(main())
