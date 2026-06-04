// Headless runtime smoke for --editor mode JS. Loads the editor JS stack into
// jsdom with a mock fileOp backend and exercises the real UI code paths:
//   1. boot + lazy file tree render (dirs first)
//   2. expanding a directory lazily lists its children
//   3. opening a markdown file renders a preview + Source/Source tabs
//   4. editing the source marks dirty and Save round-trips through writeFile
//   5. opening a non-markdown file shows a plain source editor
//   6. opening a binary/oversized file shows the error state (no crash)
//
// jsdom can only cover the JS half; the Swift FileService is covered by
// scripts/editor-smoke.sh against the real binary.

import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const SRC = "src/main.swift";
const src = readFileSync(SRC, "utf8");

function extractRaw(name) {
  const m = src.match(new RegExp(`(?:^|\\n)let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`));
  return m ? m[1] : null;
}

const micromark = extractRaw("micromarkJS");
const markdownRenderer = extractRaw("markdownRendererJS");
const highlight = extractRaw("highlightJS");
const editor = extractRaw("editorJS");

for (const [name, val] of [["micromarkJS", micromark], ["markdownRendererJS", markdownRenderer], ["highlightJS", highlight], ["editorJS", editor]]) {
  if (!val) { console.error(`FAIL: could not extract ${name}`); process.exit(1); }
}

// Minimal editor DOM scaffold (mirrors editorHTML).
const dom = new JSDOM(`<!DOCTYPE html><html><body>
  <div id="editor-app">
    <aside id="editor-sidebar"><div id="editor-root-name" class="editor-root-name"></div><div id="editor-tree" class="editor-tree"></div></aside>
    <main id="editor-main"><div id="editor-tabbar" class="editor-tabbar"></div><div id="editor-content" class="editor-content"></div></main>
  </div>
</body></html>`, { runScripts: "outside-only", url: "agent://host/index.html" });

const w = dom.window;
// Editor uses window.webkit.messageHandlers.fileOp when present; leave it absent
// so fileOp falls through to __fileOpMock.
w.HTMLElement.prototype.scrollIntoView = function () {};

for (const [name, js] of [["micromarkJS", micromark], ["markdownRendererJS", markdownRenderer], ["highlightJS", highlight], ["editorJS", editor]]) {
  try { w.eval(js); } catch (e) { console.error(`FAIL: ${name} threw on load:`, e.message); process.exit(1); }
}

// In-memory mock filesystem.
const FS = {
  "": { dir: true, entries: [
    { name: "sub", path: "sub", type: "dir" },
    { name: "readme.md", path: "readme.md", type: "file" },
    { name: "data.json", path: "data.json", type: "file" },
  ]},
  "sub": { dir: true, entries: [{ name: "notes.txt", path: "sub/notes.txt", type: "file" }] },
  "readme.md": { content: "# Title\n\nBody **bold**.\n" },
  "data.json": { content: '{\n  "a": 1\n}\n' },
  "sub/notes.txt": { content: "alpha\nbeta\n" },
  "links.md": { content: "[ext](https://example.com/x) and [int](other.md) and [up](sub/notes.txt)\n" },
  "other.md": { content: "# Other doc\n\nReached via link.\n" },
  "fm.md": { content: "---\ntitle: My Doc\ntags: a, b\n---\n\n# Real Heading\n\nBody para.\n" },
};
w.__fileOpMock = (op, path, content) => {
  if (op === "listDir") { const e = FS[path]; return e && e.dir ? { ok: true, path, entries: e.entries } : { ok: false, error: "not a dir" }; }
  if (op === "readFile") { const e = FS[path]; return e && e.content != null ? { ok: true, path, content: e.content } : { ok: false, error: "not a file" }; }
  if (op === "writeFile") { FS[path] = { content }; return { ok: true, path }; }
  return { ok: false, error: "unknown op" };
};

const tick = () => new Promise(r => setTimeout(r, 10));

// 1. Boot + tree render.
w.__editorBoot(JSON.stringify({ root: "edroot", initialFile: "" }));
await tick(); await tick();
const rows = () => Array.from(w.document.querySelectorAll("#editor-tree .editor-tree-row"));
let topRows = rows();
if (topRows.length < 3) { console.error("FAIL: expected >=3 top-level tree rows, got", topRows.length); process.exit(1); }
if (w.document.getElementById("editor-root-name").textContent !== "edroot") { console.error("FAIL: root name not set"); process.exit(1); }
// Dirs first: the first row must be the 'sub' directory.
if (!topRows[0].classList.contains("is-dir") || topRows[0].dataset.path !== "sub") {
  console.error("FAIL: dirs not sorted first; first row is", topRows[0].dataset.path); process.exit(1);
}
console.log("PASS: editor boots and renders file tree (dirs first)");

// 2. Expand a directory lazily.
const subRow = topRows.find(r => r.dataset.path === "sub");
subRow.dispatchEvent(new w.Event("click", { bubbles: true }));
await tick(); await tick();
const notesRow = rows().find(r => r.dataset.path === "sub/notes.txt");
if (!notesRow) { console.error("FAIL: expanding 'sub' did not reveal notes.txt"); process.exit(1); }
console.log("PASS: expanding a directory lazily lists children");

// 3. Open a markdown file -> preview rendered + tabs.
await w.__editorOpenFile("readme.md");
await tick();
const preview = w.document.querySelector(".editor-md-preview");
if (!preview || !preview.querySelector("h1")) { console.error("FAIL: markdown preview missing <h1>"); process.exit(1); }
if (preview.querySelector("h1").textContent !== "Title") { console.error("FAIL: preview <h1> wrong:", preview.querySelector("h1").textContent); process.exit(1); }
if (!w.document.querySelector(".editor-md-tabs")) { console.error("FAIL: markdown tabs missing"); process.exit(1); }
console.log("PASS: opening markdown renders preview + tabs");

// 4. Edit source -> dirty -> save round-trips through writeFile.
const srcArea = w.document.querySelector(".editor-content textarea.editor-source");
if (!srcArea) { console.error("FAIL: markdown source textarea missing"); process.exit(1); }
srcArea.value = "# Title\n\nEdited body.\n";
srcArea.dispatchEvent(new w.Event("input", { bubbles: true }));
if (!w.__editorCurrent().dirty) { console.error("FAIL: editing did not mark dirty"); process.exit(1); }
await w.__editorSave();
await tick();
if (FS["readme.md"].content !== "# Title\n\nEdited body.\n") { console.error("FAIL: save did not persist via writeFile, got:", JSON.stringify(FS["readme.md"].content)); process.exit(1); }
if (w.__editorCurrent().dirty) { console.error("FAIL: still dirty after save"); process.exit(1); }
console.log("PASS: editing marks dirty and Save round-trips through writeFile");

// 5. Open a recognized code file -> highlighted code editor (no markdown tabs).
await w.__editorOpenFile("data.json");
await tick();
if (w.document.querySelector(".editor-md-tabs")) { console.error("FAIL: code file should not show markdown tabs"); process.exit(1); }
const codeInput = w.document.querySelector(".editor-content .editor-code .editor-code-input");
if (!codeInput || !codeInput.value.includes('"a": 1')) { console.error("FAIL: code file did not open in code editor"); process.exit(1); }
const codePre = w.document.querySelector(".editor-content .editor-code pre.editor-code-hl code");
if (!codePre || !codePre.querySelector(".hl-str") || !codePre.querySelector(".hl-num")) {
  console.error("FAIL: code editor not highlighted; pre HTML:", codePre && codePre.innerHTML); process.exit(1);
}
console.log("PASS: code file opens in highlighted code editor");

// 5b. Plain (unrecognized extension) file -> plain source editor.
await w.__editorOpenFile("sub/notes.txt");
await tick();
const plainArea = w.document.querySelector(".editor-content textarea.editor-source");
if (!plainArea || !plainArea.value.includes("alpha")) { console.error("FAIL: .txt did not open in plain source editor"); process.exit(1); }
if (w.document.querySelector(".editor-content .editor-code")) { console.error("FAIL: .txt should not use highlighted code editor"); process.exit(1); }
console.log("PASS: unrecognized extension opens in plain source editor");

// 6. Error state for a file the backend rejects.
w.__fileOpMock = (op) => ({ ok: false, error: "not a UTF-8 text file", binary: true });
await w.__editorOpenFile("blob.bin");
await tick();
const empty = w.document.querySelector(".editor-content .editor-empty");
if (!empty || !/Binary or oversized/.test(empty.textContent)) { console.error("FAIL: binary file error state missing"); process.exit(1); }
console.log("PASS: binary/oversized file shows error state without crashing");

// 7. Highlighter unit checks.
const hl = w.highlightCode("const x = 42; // note", "javascript");
if (!/hl-kw[^>]*>const</.test(hl)) { console.error("FAIL: highlightCode missing keyword span:", hl); process.exit(1); }
if (!/hl-num[^>]*>42</.test(hl)) { console.error("FAIL: highlightCode missing number span:", hl); process.exit(1); }
if (!/hl-com[^>]*>\/\/ note</.test(hl)) { console.error("FAIL: highlightCode missing comment span:", hl); process.exit(1); }
if (w.highlightCode("anything", "no-such-lang") !== null) { console.error("FAIL: unknown lang should return null"); process.exit(1); }
const pyStr = w.highlightCode("s = 'hi'", "python");
if (!/hl-str[^>]*>&#039;hi&#039;</.test(pyStr) && !/hl-str[^>]*>'hi'</.test(pyStr)) { console.error("FAIL: python string not highlighted:", pyStr); process.exit(1); }
if (w.highlightLangFor("main.go") !== "go") { console.error("FAIL: highlightLangFor(main.go) !== go"); process.exit(1); }
if (w.highlightLangFor("notes.xyz") !== null) { console.error("FAIL: highlightLangFor(notes.xyz) should be null"); process.exit(1); }
// XSS: angle brackets in code must be escaped, not live HTML.
const xss = w.highlightCode("x = '<script>'", "javascript");
if (/<script>/.test(xss)) { console.error("FAIL: highlighter did not escape <script>:", xss); process.exit(1); }
console.log("PASS: highlightCode tokenizes + escapes; highlightLangFor maps extensions");

// 8. Fenced code blocks in markdown preview get highlighted.
const mdc = w.document.createElement("div");
w.renderMarkdown("```js\nconst a = 1;\n```\n", mdc, {});
w.highlightCodeBlocks(mdc);
const fenced = mdc.querySelector("pre > code.hl");
if (!fenced || !fenced.querySelector(".hl-kw")) { console.error("FAIL: fenced code block not highlighted:", mdc.innerHTML); process.exit(1); }
console.log("PASS: fenced code blocks in markdown preview are highlighted");

// 9. Link following.
// Restore the real fileOp mock (test 6 replaced it with a reject-all).
w.__fileOpMock = (op, path, content) => {
  if (op === "listDir") { const e = FS[path]; return e && e.dir ? { ok: true, path, entries: e.entries } : { ok: false, error: "not a dir" }; }
  if (op === "readFile") { const e = FS[path]; return e && e.content != null ? { ok: true, path, content: e.content } : { ok: false, error: "not a file" }; }
  if (op === "writeFile") { FS[path] = { content }; return { ok: true, path }; }
  return { ok: false, error: "unknown op" };
};
// resolvePath unit checks.
if (w.__editorResolvePath("sub/doc.md", "../other.md") !== "other.md") { console.error("FAIL: resolvePath ../ wrong:", w.__editorResolvePath("sub/doc.md", "../other.md")); process.exit(1); }
if (w.__editorResolvePath("readme.md", "sub/x.md") !== "sub/x.md") { console.error("FAIL: resolvePath sibling-dir wrong"); process.exit(1); }
if (w.__editorResolvePath("a/b/c.md", "./d.md") !== "a/b/d.md") { console.error("FAIL: resolvePath ./ wrong"); process.exit(1); }
console.log("PASS: resolvePath collapses ./ and ../ against the current file dir");

// External link → openExternal bridge, NOT a file open.
let externalOpened = null;
w.__openExternalMock = (url) => { externalOpened = url; };
w.__editorHandleLink("https://example.com/x", "links.md");
await tick();
if (externalOpened !== "https://example.com/x") { console.error("FAIL: external link did not reach openExternal:", externalOpened); process.exit(1); }
console.log("PASS: external http link routes to openExternal bridge");

// Internal link → opens the target file in the editor.
await w.__editorOpenFile("links.md");
await tick();
const anchors = Array.from(w.document.querySelectorAll(".editor-md-preview a"));
const intLink = anchors.find(a => a.getAttribute("href") === "other.md");
if (!intLink) { console.error("FAIL: rendered preview missing internal link; anchors:", anchors.map(a => a.getAttribute("href"))); process.exit(1); }
intLink.dispatchEvent(new w.Event("click", { bubbles: true }));
await tick(); await tick();
if (w.__editorCurrent().path !== "other.md") { console.error("FAIL: clicking internal link did not open other.md; current:", w.__editorCurrent().path); process.exit(1); }
const otherH1 = w.document.querySelector(".editor-md-preview h1");
if (!otherH1 || otherH1.textContent !== "Other doc") { console.error("FAIL: other.md not rendered after link click"); process.exit(1); }
console.log("PASS: clicking an internal markdown link opens the target file");

// 10. Frontmatter rendered as a metadata block (not as body, not vanished).
await w.__editorOpenFile("fm.md");
await tick();
const fmBox = w.document.querySelector(".editor-md-preview .editor-md-frontmatter");
if (!fmBox) { console.error("FAIL: frontmatter metadata block missing"); process.exit(1); }
const fmKeys = Array.from(fmBox.querySelectorAll(".editor-fm-key")).map(k => k.textContent);
if (!fmKeys.includes("title") || !fmKeys.includes("tags")) { console.error("FAIL: frontmatter keys missing:", fmKeys); process.exit(1); }
const fmH1 = w.document.querySelector(".editor-md-preview h1");
if (!fmH1 || fmH1.textContent !== "Real Heading") { console.error("FAIL: body heading wrong (frontmatter leaked into body?):", fmH1 && fmH1.textContent); process.exit(1); }
console.log("PASS: frontmatter surfaced as metadata block; body heading intact");

// 11. Comment + submit flow (--comments) preserves the return-to-Claude path.
w.__editorBoot(JSON.stringify({ root: "edroot", initialFile: "", comments: true }));
await tick(); await tick();
await w.__editorOpenFile("readme.md");
await tick();
const submitBtn = Array.from(w.document.querySelectorAll("#editor-tabbar .editor-tab-btn")).find(b => /Submit/.test(b.textContent));
if (!submitBtn) { console.error("FAIL: --comments did not add a Submit button"); process.exit(1); }
const cblock = w.document.querySelector(".editor-md-preview [data-src-start]");
if (!cblock) { console.error("FAIL: no commentable block in preview"); process.exit(1); }
w.__editorOpenComposer(cblock, "readme.md", w.document.querySelector(".editor-md-preview"));
const cbody = w.document.querySelector(".editor-comment-composer .editor-comment-body");
cbody.value = "needs a rework";
cbody.dispatchEvent(new w.Event("input", { bubbles: true }));
const csave = w.document.querySelector(".editor-comment-composer .save");
if (csave.disabled) { console.error("FAIL: Save still disabled after typing a comment"); process.exit(1); }
csave.dispatchEvent(new w.Event("click", { bubbles: true }));
await tick();
if (w.__editorAllComments().length < 1 || w.__editorAllComments()[0].body !== "needs a rework") { console.error("FAIL: comment not recorded:", w.__editorAllComments()); process.exit(1); }
if (!cblock.getAttribute("data-has-comment")) { console.error("FAIL: commented block not marked"); process.exit(1); }
console.log("PASS: comment composer records a comment and marks the block");

let submitted = null;
w.__completeMock = (p) => { submitted = p; };
w.__editorSubmit();
if (!submitted || submitted.action !== "submit") { console.error("FAIL: submit did not emit a submit action:", submitted); process.exit(1); }
if (submitted.file !== "readme.md" || !submitted.comments.some(c => c.body === "needs a rework")) { console.error("FAIL: submit payload missing file/comments:", JSON.stringify(submitted)); process.exit(1); }
console.log("PASS: Submit returns {action:'submit', file, comments} to the complete bridge");

console.log("All editor runtime smoke checks pass");
