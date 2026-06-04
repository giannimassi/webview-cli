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

// 5. Open a non-markdown file -> plain source editor (no preview tabs).
await w.__editorOpenFile("data.json");
await tick();
if (w.document.querySelector(".editor-md-tabs")) { console.error("FAIL: non-markdown file should not show markdown tabs"); process.exit(1); }
const codeArea = w.document.querySelector(".editor-content textarea.editor-source");
if (!codeArea || !codeArea.value.includes('"a": 1')) { console.error("FAIL: code file did not open in source editor"); process.exit(1); }
console.log("PASS: non-markdown file opens in plain source editor");

// 6. Error state for a file the backend rejects.
w.__fileOpMock = (op) => ({ ok: false, error: "not a UTF-8 text file", binary: true });
await w.__editorOpenFile("blob.bin");
await tick();
const empty = w.document.querySelector(".editor-content .editor-empty");
if (!empty || !/Binary or oversized/.test(empty.textContent)) { console.error("FAIL: binary file error state missing"); process.exit(1); }
console.log("PASS: binary/oversized file shows error state without crashing");

console.log("All editor runtime smoke checks pass");
