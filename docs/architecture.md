# Architecture

One Swift file, ~500 lines. This doc explains the shape.

## Process shape

```
Parent (shell / Claude Code / MCP server)
   │
   │ spawn("webview-cli", [args])
   │ stdin  = A2UI JSONL or agent:// load commands
   │ stdout = final JSON result
   │ stderr = diagnostics
   ▼
webview-cli (NSApplication.accessory)
   ├── NSWindow (borderless, programmatic — no XIB)
   │    └── WKWebView
   │         ├── WKURLSchemeHandler for agent://
   │         ├── WKScriptMessageHandler for complete / ready
   │         └── WKNavigationDelegate (didFinish, didFail*)
   ├── stdin reader (DispatchSourceRead on FD 0)
   ├── Timer (for --timeout)
   └── NSEvent local monitor (Escape key)
```

## Why NSApplication at all

WKWebView cannot run without a live `NSApplication` main run loop — there is no "headless WKWebView" on macOS. Minimum viable setup:

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon
app.delegate = delegate
app.run()                            // blocks; drives the event loop
```

`.accessory` activation policy means no Dock icon and no menu bar — the binary looks and feels like a CLI tool even though it owns a full Cocoa app internally.

## Lifecycle

1. `main` parses CLI args into `Config`
2. `NSApplication` starts, activation policy set to `.accessory`
3. `applicationDidFinishLaunching` fires → `AppCoordinator.run()`:
   - Configures `WKWebViewConfiguration` (message handlers, user script, scheme handler)
   - Creates `NSWindow` + `WKWebView`
   - If `--a2ui`: loads the built-in renderer from the scheme handler, reads stdin JSONL in a background thread, flushes to JS on `didFinish`
   - If `--url`: validates URL, loads it
   - Starts optional `--timeout` timer
4. User interacts. Web content calls `window.webkit.messageHandlers.complete.postMessage(...)`.
5. `userContentController(_:didReceive:)` catches the message → `emitAndExit(status: "completed", data: body, code: 0)`
6. `emitAndExit` serializes JSON, writes to stdout, calls `exit(0)`.

## Why `exit()` and not `NSApp.terminate(nil)`

`NSApp.terminate` always calls `exit(0)` internally, which loses our exit code semantics. Direct `exit(N)` preserves the cancel/timeout/error codes. `applicationWillTerminate` still fires via the OS's SIGTERM handler to provide a safety-net JSON emit if the process is killed externally before `emitAndExit` runs.

## The agent:// scheme

`WKURLSchemeHandler` is registered at `WKWebViewConfiguration.setURLSchemeHandler(_, forURLScheme: "agent")`. Requests to `agent://host/<path>` hit `AgentSchemeHandler.webView(_:start:)` which looks up `<path>` in an in-memory `[String: (Data, String)]` map (content + MIME type).

Resources are pushed into the map via stdin `load` commands. No HTTP server, no port allocation, no temp files. This enables:

- `--a2ui` mode: the renderer HTML/CSS/JS are preloaded before the webview navigates to `agent://host/index.html`
- Custom HTML mode: agents pipe arbitrary static sites (base64-encoded) and the webview serves them from memory

## The A2UI renderer

Embedded as a string literal in `main.swift` (`a2uiRendererHTML`, `a2uiRendererCSS`, `a2uiRendererJS`). The JS is ~180 lines of vanilla ES — no React, no framework, no build step. It:

1. Accepts a JSONL array via `window.__a2uiLoad(jsonString)` (called from Swift via `evaluateJavaScript`)
2. Parses messages into a `Map<componentId, component>` (adjacency list model)
3. Recursively renders from the `beginRendering.root` ID → DOM
4. Wires Button clicks to `window.webkit.messageHandlers.complete.postMessage({action, data, context})`

Why embed instead of ship as separate files? The binary-is-the-release story. `brew install` drops one file. No post-install steps, no surprising paths, no version skew between binary and JS.

## stdin → JS: UTF-8 safety

Naive approach: `evaluateJavaScript("__a2uiLoad('\(payload)')")` breaks on quotes and multibyte chars. Current approach: base64-encode in Swift, decode in JS with `TextDecoder('utf-8')`.

```swift
let b64 = Data(payload.utf8).base64EncodedString()
let js = "window.__a2uiLoad(new TextDecoder('utf-8').decode(Uint8Array.from(atob('\(b64)'), c => c.charCodeAt(0))))"
```

This preserves em-dashes, emoji, CJK, and any other non-ASCII content the agent might generate.

## Race-free stdin/render handoff

A subtle bug in an earlier version: stdin could finish before the webview had loaded the renderer script, so `window.__a2uiLoad` was undefined when Swift called `evaluateJavaScript`. Fix:

1. stdin read completes → store payload in `pendingA2UIPayload`
2. `WKNavigationDelegate.webView(_:didFinish:)` fires → set `rendererReady = true`
3. `flushA2UIIfReady()` runs whenever either side completes — guarded by both flags

This handles both "stdin first" and "navigation first" orderings correctly.

## What's intentionally missing

- **No persistent state**: each invocation is isolated. Cookies, localStorage, and `WKWebsiteDataStore` are ephemeral. OAuth flows that require persisted sessions need a separate mechanism (out of scope for v0.1).
- **No IPC beyond stdio**: no sockets, no D-Bus, no XPC. If the parent wants to stream updates, use `evaluateJavaScript` via a future `patch` command (roadmap v1.1).
- **No sandboxing**: v0.1 assumes trusted agents. CSP + App Sandbox entitlements planned for v1.1.
