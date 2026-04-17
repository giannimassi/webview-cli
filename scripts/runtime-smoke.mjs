// Runtime smoke test. Loads the three JS constants out of src/main.swift
// into a jsdom window in the same order the a2uiRendererHTML does, then
// exercises the real code paths that WKWebView will hit:
//   1. window.micromark exists and renders markdown -> HTML
//   2. window.renderMarkdown exists and populates a container with
//      data-src-start / data-src-end attrs on block children
//   3. window.sanitizeMarkdownDOM strips <script> by default
//   4. window.__a2uiLoad exists (A2UI renderer booted)
//   5. A full MarkdownDoc render cycle produces a rendered preview and
//      doesn't emit JS errors

import { readFileSync } from "node:fs";
import { JSDOM } from "/tmp/webview-cli-testenv/node_modules/jsdom/lib/api.js";

const SRC = "src/main.swift";
const src = readFileSync(SRC, "utf8");

function extractRaw(name) {
  const m = src.match(new RegExp(`(?:^|\\n)let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`));
  return m ? m[1] : null;
}
function extractPlain(name) {
  const m = src.match(new RegExp(`(?:^|\\n)let ${name} = """\\n([\\s\\S]*?)\\n"""\\n`));
  if (!m) return null;
  // Apply Swift's non-raw string escapes (the ones actually used): \\\\ -> \\, \" -> ", \n -> newline, \t -> tab
  return m[1]
    .replace(/\\\\/g, "__BSLASH__")
    .replace(/\\"/g, '"')
    .replace(/\\n/g, "\n")
    .replace(/\\t/g, "\t")
    .replace(/__BSLASH__/g, "\\");
}

const micromark = extractRaw("micromarkJS");
const markdownRenderer = extractRaw("markdownRendererJS");
const a2ui = extractPlain("a2uiRendererJS");

if (!micromark || !markdownRenderer || !a2ui) {
  console.error("FAIL: could not extract one or more JS constants");
  process.exit(1);
}

const dom = new JSDOM(`<!DOCTYPE html><html><body><div id="a2ui-root"></div></body></html>`, {
  runScripts: "outside-only",
  url: "agent://host/index.html",
});

// Stub webkit bridge so the renderer JS doesn't throw when it tries to postMessage.
dom.window.webkit = {
  messageHandlers: {
    ready: { postMessage: () => {} },
    complete: { postMessage: () => {} },
  },
};

// jsdom lacks Element.prototype.scrollIntoView — stub so T9 card-click doesn't throw.
dom.window.HTMLElement.prototype.scrollIntoView = function () {};

// Evaluate scripts in the same order as the HTML template.
try {
  dom.window.eval(micromark);
} catch (e) {
  console.error("FAIL: micromarkJS threw on load:", e.message);
  process.exit(1);
}
try {
  dom.window.eval(markdownRenderer);
} catch (e) {
  console.error("FAIL: markdownRendererJS threw on load:", e.message);
  process.exit(1);
}
try {
  dom.window.eval(a2ui);
} catch (e) {
  console.error("FAIL: a2uiRendererJS threw on load:", e.message);
  process.exit(1);
}

const w = dom.window;

// 1. micromark global is present and renders.
if (typeof w.micromark !== "function") {
  console.error("FAIL: window.micromark is not a function");
  process.exit(1);
}
const mmOut = w.micromark("# hi");
if (!mmOut.includes("<h1>hi</h1>")) {
  console.error("FAIL: micromark output missing <h1>hi</h1>, got:", mmOut);
  process.exit(1);
}
console.log("PASS: window.micromark renders # hi -> <h1>hi</h1>");

// 2. renderMarkdown is present and annotates blocks.
if (typeof w.renderMarkdown !== "function") {
  console.error("FAIL: window.renderMarkdown is not a function");
  process.exit(1);
}
const container = w.document.createElement("div");
w.renderMarkdown("# Hi\n\nHello **world**.\n", container);
const blocks = container.querySelectorAll("[data-src-start]");
if (blocks.length < 2) {
  console.error(`FAIL: expected >=2 annotated blocks, got ${blocks.length}. container.innerHTML:`, container.innerHTML);
  process.exit(1);
}
const hasH1 = Array.from(blocks).some(b => b.tagName === "H1" || b.querySelector("h1"));
if (!hasH1) {
  console.error("FAIL: rendered DOM missing <h1>, container.innerHTML:", container.innerHTML);
  process.exit(1);
}
console.log(`PASS: window.renderMarkdown produced ${blocks.length} annotated blocks including <h1>`);

// 3. Sanitizer strips <script> by default.
if (typeof w.sanitizeMarkdownDOM !== "function") {
  console.error("FAIL: window.sanitizeMarkdownDOM is not a function");
  process.exit(1);
}
const sanitizeContainer = w.document.createElement("div");
sanitizeContainer.innerHTML = `<p>ok</p><script>window.__pwned=1</script>`;
w.sanitizeMarkdownDOM(sanitizeContainer, { allowHtml: false });
if (sanitizeContainer.querySelector("script")) {
  console.error("FAIL: sanitizer left <script> element in DOM");
  process.exit(1);
}
console.log("PASS: sanitizeMarkdownDOM strips <script> by default");

// 4. A2UI loader booted.
if (typeof w.__a2uiLoad !== "function") {
  console.error("FAIL: window.__a2uiLoad is not a function (A2UI renderer didn't export it)");
  process.exit(1);
}
console.log("PASS: window.__a2uiLoad is present");

// 5. Full MarkdownDoc render through the A2UI pipeline.
const a2uiJsonl = JSON.stringify([
  {"surfaceUpdate":{"components":[
    {"id":"root","component":{"Column":{"children":{"explicitList":["doc","btn"]}}}},
    {"id":"doc","component":{"MarkdownDoc":{"fieldName":"review","text":"# Header\n\nParagraph.","allowComments":true,"allowEdits":true}}},
    {"id":"btn","component":{"Button":{"label":{"literalString":"Submit"},"action":{"name":"submit"}}}}
  ]}},
  {"beginRendering":{"root":"root"}}
]);
try {
  w.__a2uiLoad(a2uiJsonl);
} catch (e) {
  console.error("FAIL: __a2uiLoad threw:", e.message);
  process.exit(1);
}
// Wait a microtask to let any async work settle.
await new Promise(r => setTimeout(r, 50));
const renderedDoc = w.document.querySelector(".a2ui-markdown-doc");
if (!renderedDoc) {
  console.error("FAIL: MarkdownDoc wrapper .a2ui-markdown-doc not in DOM after __a2uiLoad");
  process.exit(1);
}
const renderedH1 = renderedDoc.querySelector("h1");
if (!renderedH1 || !renderedH1.textContent.includes("Header")) {
  console.error("FAIL: MarkdownDoc preview missing rendered <h1>Header</h1>. Inner HTML:", renderedDoc.innerHTML.slice(0, 400));
  process.exit(1);
}
const tabs = renderedDoc.querySelector(".a2ui-markdown-tabs");
if (!tabs) {
  console.error("FAIL: allowEdits=true but no tabs rendered");
  process.exit(1);
}
const sidebar = renderedDoc.querySelector(".a2ui-markdown-comments-pane");
if (!sidebar) {
  console.error("FAIL: allowComments=true but no comment sidebar rendered");
  process.exit(1);
}
const docComment = renderedDoc.querySelector(".a2ui-markdown-doc-comment-body");
if (!docComment) {
  console.error("FAIL: allowComments=true but no overall-comment textarea rendered");
  process.exit(1);
}
console.log("PASS: A2UI MarkdownDoc rendered <h1> + tabs + sidebar + doc-comment textarea");

console.log("All runtime smoke checks pass");
