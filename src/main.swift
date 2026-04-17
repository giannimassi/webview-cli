import AppKit
import WebKit

// MARK: - CLI Argument Parsing

struct Config {
    var url: String = ""
    var title: String = "webview-cli"
    var width: Int = 1024
    var height: Int = 768
    var timeout: Int = 0
    var a2ui: Bool = false
    var x: Int? = nil  // nil = center on screen
    var y: Int? = nil
    var screen: Int = 0  // NSScreen index; 0 = main
    var markdownMode: Bool = false
    var comments: Bool = false
    var edits: Bool = false
    var allowHtml: Bool = false
}

func parseArgs() -> Config? {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--url":
            i += 1; guard i < args.count else { return nil }
            config.url = args[i]
        case "--title":
            i += 1; guard i < args.count else { return nil }
            config.title = args[i]
        case "--width":
            i += 1; guard i < args.count else { return nil }
            config.width = Int(args[i]) ?? 1024
        case "--height":
            i += 1; guard i < args.count else { return nil }
            config.height = Int(args[i]) ?? 768
        case "--timeout":
            i += 1; guard i < args.count else { return nil }
            config.timeout = Int(args[i]) ?? 0
        case "--a2ui":
            config.a2ui = true
        case "--markdown":
            config.markdownMode = true
        case "--comments":
            config.comments = true
        case "--edits":
            config.edits = true
        case "--allow-html":
            config.allowHtml = true
        case "--x":
            i += 1; guard i < args.count else { return nil }
            config.x = Int(args[i])
        case "--y":
            i += 1; guard i < args.count else { return nil }
            config.y = Int(args[i])
        case "--screen":
            i += 1; guard i < args.count else { return nil }
            config.screen = Int(args[i]) ?? 0
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            if config.url.isEmpty && !args[i].hasPrefix("-") {
                config.url = args[i]
            } else {
                writeStderr("Unknown argument: \(args[i])"); return nil
            }
        }
        i += 1
    }

    // Validate mutual exclusion: --markdown incompatible with --a2ui or --url
    if config.markdownMode {
        if config.a2ui {
            writeStderr("Error: --markdown and --a2ui are mutually exclusive")
            return nil
        }
        if !config.url.isEmpty {
            writeStderr("Error: --markdown and --url are mutually exclusive")
            return nil
        }
    }

    // In a2ui mode, URL is optional (uses agent://host/index.html)
    if !config.a2ui && !config.markdownMode && config.url.isEmpty { return nil }
    return config
}

func printUsage() {
    let usage = """
    Usage: webview-cli [--url <url>] [--a2ui] [--markdown] [options]

    Opens a native macOS webview. The page signals completion by calling:
      window.webkit.messageHandlers.complete.postMessage({...})

    Modes:
      --url <url>        Open a URL (http/https/file/agent)
      --a2ui             A2UI mode: reads A2UI JSONL from stdin, renders UI,
                         returns userAction on stdout
      --markdown         Markdown editor mode: reads markdown from stdin, renders
                         interactive editor with optional comments and edits

    Options:
      --title <title>    Window title (default: "webview-cli")
      --width <px>       Window width (default: 1024)
      --height <px>      Window height (default: 768)
      --timeout <sec>    Session timeout, 0=none (default: 0)
      --comments         Enable comments in markdown mode
      --edits            Enable edit tracking in markdown mode
      --allow-html       Allow HTML in markdown mode

    Stdin protocol (when using agent:// URLs or --a2ui):
      {"type":"load","resources":{"path.html":"<base64>","app.js":"<base64>"}}
      {"type":"close"}

    Exit codes: 0=completed, 1=cancelled, 2=timeout, 3=error
    """
    writeStderr(usage)
}

// MARK: - Output Helpers

func writeStdout(_ string: String) {
    if let data = (string + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func writeStderr(_ string: String) {
    if let data = (string + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func emitResult(status: String, data: Any? = nil, message: String? = nil) {
    var result: [String: Any] = ["status": status]
    if let data = data { result["data"] = data }
    if let message = message { result["message"] = message }
    if let jsonData = try? JSONSerialization.data(withJSONObject: result),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        writeStdout(jsonString)
    }
}

// MARK: - Agent Scheme Handler

class AgentSchemeHandler: NSObject, WKURLSchemeHandler {
    var resources: [String: (Data, String)] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = path.isEmpty ? "index.html" : path

        guard let (data, mime) = resources[key] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url, mimeType: mime,
            expectedContentLength: data.count, textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func loadResources(_ resources: [String: String]) {
        for (path, base64Content) in resources {
            guard let data = Data(base64Encoded: base64Content) else {
                writeStderr("[agent] Failed to decode base64 for \(path)")
                continue
            }
            let mime = mimeType(for: path)
            self.resources[path] = (data, mime)
        }
    }

    func loadRawResource(path: String, content: String, mime: String? = nil) {
        guard let data = content.data(using: .utf8) else { return }
        self.resources[path] = (data, mime ?? mimeType(for: path))
    }

    private func mimeType(for path: String) -> String {
        if path.hasSuffix(".html") { return "text/html" }
        if path.hasSuffix(".js") { return "application/javascript" }
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        if path.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }
}

// MARK: - Stdin Reader

class StdinReader {
    weak var coordinator: AppCoordinator?
    private var source: DispatchSourceRead?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        let stdin = FileHandle.standardInput
        source = DispatchSource.makeReadSource(fileDescriptor: stdin.fileDescriptor, queue: .global())
        source?.setEventHandler { [weak self] in
            let data = stdin.availableData
            guard !data.isEmpty else {
                // EOF — stdin closed
                return
            }
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                DispatchQueue.main.async {
                    self?.coordinator?.handleStdinCommand(line)
                }
            }
        }
        source?.resume()
    }
}

// MARK: - App Coordinator

class AppCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let config: Config
    var window: NSWindow!
    var webView: WKWebView!
    var hasEmitted = false
    var timeoutTimer: Timer?
    let schemeHandler = AgentSchemeHandler()
    // A2UI sync state
    var pendingA2UIPayload: String? = nil
    var rendererReady = false

    init(config: Config) {
        self.config = config
        super.init()
    }

    func run() {
        let webConfig = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "complete")
        contentController.add(self, name: "ready")

        let errorScript = WKUserScript(
            source: """
            window.onerror = function(msg, url, line, col, error) {
                window.webkit.messageHandlers.complete.postMessage({
                    __webview_cli_error: true, message: msg, url: url, line: line, col: col
                });
                return false;
            };
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        )
        contentController.addUserScript(errorScript)
        webConfig.userContentController = contentController

        // Register agent:// scheme handler
        webConfig.setURLSchemeHandler(schemeHandler, forURLScheme: "agent")

        webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = self

        // Select the target screen (0 = main, 1+ = secondary displays in NSScreen.screens order)
        let screens = NSScreen.screens
        for (i, s) in screens.enumerated() {
            writeStderr("[screen \(i)] frame=\(Int(s.frame.origin.x)),\(Int(s.frame.origin.y)) \(Int(s.frame.width))x\(Int(s.frame.height))\(s == NSScreen.main ? " MAIN" : "")")
        }
        let targetScreen = (config.screen >= 0 && config.screen < screens.count) ? screens[config.screen] : (NSScreen.main ?? screens.first!)
        let screenFrame = targetScreen.visibleFrame
        writeStderr("[chosen screen \(config.screen)] visibleFrame=\(Int(screenFrame.origin.x)),\(Int(screenFrame.origin.y)) \(Int(screenFrame.width))x\(Int(screenFrame.height))")
        // AppKit y=0 is BOTTOM of the global space. --y in CLI is from TOP of the target screen.
        let winX: CGFloat = config.x.map { CGFloat($0) + screenFrame.origin.x }
            ?? (screenFrame.width - CGFloat(config.width)) / 2 + screenFrame.origin.x
        let winY: CGFloat = config.y.map { screenFrame.maxY - CGFloat($0) - CGFloat(config.height) }
            ?? (screenFrame.height - CGFloat(config.height)) / 2 + screenFrame.origin.y
        let windowRect = NSRect(x: winX, y: winY, width: CGFloat(config.width), height: CGFloat(config.height))
        writeStderr("[window rect] x=\(Int(winX)) y=\(Int(winY)) w=\(config.width) h=\(config.height)")

        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = config.title
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false

        if config.a2ui {
            setupA2UIMode()
        } else {
            guard let url = URL(string: config.url), url.scheme != nil else {
                emitAndExit(status: "error", message: "Invalid URL (must include scheme): \(config.url)", code: 3)
                return
            }
            webView.load(URLRequest(url: url))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeStderr("[wid] \(window.windowNumber)")

        if config.timeout > 0 {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.timeout), repeats: false) { [weak self] _ in
                self?.handleTimeout()
            }
        }
    }

    // MARK: - A2UI Mode

    func setupA2UIMode() {
        // Load the built-in A2UI renderer into agent:// scheme
        schemeHandler.loadRawResource(path: "index.html", content: a2uiRendererHTML)
        schemeHandler.loadRawResource(path: "renderer.js", content: a2uiRendererJS)
        schemeHandler.loadRawResource(path: "styles.css", content: a2uiRendererCSS)
        schemeHandler.loadRawResource(path: "micromark.js", content: micromarkJS)

        // Read A2UI JSONL from stdin on a background thread
        readA2UIFromStdin()

        // Navigate to the renderer
        webView.load(URLRequest(url: URL(string: "agent://host/index.html")!))
    }

    func readA2UIFromStdin() {
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                lines.append(trimmed)
            }
            let jsonArray = "[" + lines.joined(separator: ",") + "]"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingA2UIPayload = jsonArray
                self.flushA2UIIfReady()
            }
        }
    }

    func flushA2UIIfReady() {
        guard rendererReady, let payload = pendingA2UIPayload else { return }
        pendingA2UIPayload = nil
        // Safely pass JSON string to JS by base64-encoding it — avoids all escape issues.
        // Decode via TextDecoder to preserve UTF-8 (atob alone returns latin1).
        let b64 = Data(payload.utf8).base64EncodedString()
        let js = """
        window.__a2uiLoad(new TextDecoder('utf-8').decode(Uint8Array.from(atob('\(b64)'), c => c.charCodeAt(0))))
        """
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { writeStderr("[a2ui] JS eval error: \(err)") }
        }
    }

    // MARK: - Stdin Commands (for agent:// mode)

    func handleStdinCommand(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            writeStderr("[stdin] Invalid command: \(line)")
            return
        }

        switch type {
        case "load":
            if let resources = json["resources"] as? [String: String] {
                schemeHandler.loadResources(resources)
                // If a URL was specified, navigate to it
                if let navigateTo = json["url"] as? String {
                    webView.load(URLRequest(url: URL(string: navigateTo)!))
                }
            }
        case "close":
            emitAndExit(status: "cancelled", code: 1)
        default:
            writeStderr("[stdin] Unknown command type: \(type)")
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "complete":
            if let body = message.body as? [String: Any], body["__webview_cli_error"] as? Bool == true {
                let errMsg = body["message"] as? String ?? "Unknown JS error"
                let errUrl = body["url"] as? String ?? ""
                let errLine = body["line"] as? Int ?? 0
                writeStderr("[js-error] \(errMsg) at \(errUrl):\(errLine)")
                return
            }
            emitAndExit(status: "completed", data: message.body, code: 0)
        case "ready":
            writeStderr("[ready] Page signaled ready")
        default: break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if config.a2ui {
            // A2UI renderer JS is loaded — safe to inject data now
            rendererReady = true
            flushA2UIIfReady()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emitAndExit(status: "error", message: "Navigation failed: \(error.localizedDescription)", code: 3)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitAndExit(status: "error", message: "Failed to load: \(error.localizedDescription)", code: 3)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        emitAndExit(status: "cancelled", code: 1)
    }

    func handleTimeout() {
        emitAndExit(status: "timeout", code: 2)
    }

    func emitAndExit(status: String, data: Any? = nil, message: String? = nil, code: Int32) {
        guard !hasEmitted else { return }
        hasEmitted = true
        timeoutTimer?.invalidate()
        emitResult(status: status, data: data, message: message)
        exit(code)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.run()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !coordinator.hasEmitted {
            coordinator.hasEmitted = true
            emitResult(status: "cancelled")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

// MARK: - Escape Key Handler

class KeyEventMonitor {
    var monitor: Any?
    weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.coordinator?.emitAndExit(status: "cancelled", code: 1)
                return nil
            }
            return event
        }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

// MARK: - Embedded A2UI Renderer

let a2uiRendererHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>A2UI</title>
<link rel="stylesheet" href="agent://host/styles.css">
</head>
<body>
<div id="a2ui-root"></div>
<script src="agent://host/renderer.js"></script>
</body>
</html>
"""

let a2uiRendererCSS = """
:root {
  --bg: #1c1c1e;
  --surface: #2c2c2e;
  --surface-2: #3a3a3c;
  --text: #f2f2f7;
  --muted: #8e8e93;
  --accent: #0a84ff;
  --danger: #ff453a;
  --success: #32d74b;
  --border: rgba(255,255,255,0.08);
  --radius: 10px;
  color-scheme: dark;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", ui-sans-serif, system-ui, sans-serif;
  font-size: 14px;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  background: var(--bg); color: var(--text);
  min-height: 100vh; padding: 1.25rem;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
.a2ui-column { display: flex; flex-direction: column; gap: 0.75rem; }
.a2ui-row { display: flex; flex-direction: row; gap: 0.75rem; align-items: center; flex-wrap: wrap; }
.a2ui-row.space-between { justify-content: space-between; }
.a2ui-row.center { justify-content: center; }
.a2ui-row.end { justify-content: flex-end; }
.a2ui-card {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
  padding: 1.5rem;
}
.a2ui-text { line-height: 1.5; letter-spacing: -0.01em; white-space: pre-wrap; }
.a2ui-text.h1 { font-size: 1.75rem; font-weight: 700; letter-spacing: -0.02em; }
.a2ui-text.h2 { font-size: 1.35rem; font-weight: 600; letter-spacing: -0.02em; }
.a2ui-text.h3 { font-size: 1.05rem; font-weight: 600; letter-spacing: -0.01em; }
.a2ui-text.subtitle { color: var(--muted); font-size: 0.9rem; }
.a2ui-text.body { color: var(--text); }
.a2ui-text.caption { color: var(--muted); font-size: 0.8rem; line-height: 1.45; }
.a2ui-input, .a2ui-textarea, .a2ui-select {
  width: 100%; padding: 0.6rem 0.75rem;
  border: 1px solid var(--border); border-radius: 7px;
  background: var(--bg); color: var(--text);
  font: inherit; font-size: 0.925rem;
  transition: border-color 0.12s, background 0.12s;
}
.a2ui-input::placeholder, .a2ui-textarea::placeholder { color: var(--muted); }
.a2ui-input:focus, .a2ui-textarea:focus, .a2ui-select:focus {
  outline: none; border-color: var(--accent);
}
.a2ui-textarea { resize: vertical; min-height: 80px; line-height: 1.5; }
.a2ui-label { font-size: 0.8rem; color: var(--muted); margin-bottom: -0.35rem; font-weight: 500; }
.a2ui-button {
  padding: 0.55rem 1.1rem; border: 1px solid transparent; border-radius: 7px;
  font: inherit; font-size: 0.9rem; font-weight: 600; cursor: pointer;
  transition: filter 0.12s, transform 0.08s;
}
.a2ui-button:hover { filter: brightness(1.1); }
.a2ui-button:active { transform: scale(0.97); }
.a2ui-button.primary { background: var(--accent); color: #fff; }
.a2ui-button.secondary { background: var(--surface-2); color: var(--text); }
.a2ui-button.danger { background: var(--danger); color: #fff; }
.a2ui-button.success { background: var(--success); color: #1a1a1c; }
.a2ui-divider { border: none; border-top: 1px solid var(--border); margin: 0.25rem 0; }
.a2ui-select { appearance: none; background-image: url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' stroke='%238e8e93' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 0.75rem center; padding-right: 2rem; }
.a2ui-select option { background: var(--bg); color: var(--text); }
.a2ui-checkbox { display: flex; align-items: center; gap: 0.5rem; padding: 0.3rem 0; cursor: pointer; }
.a2ui-checkbox input { width: 16px; height: 16px; accent-color: var(--accent); cursor: pointer; }
.a2ui-checkbox span { font-size: 0.925rem; }
.a2ui-image { max-width: 100%; height: auto; border-radius: 8px; display: block; }
"""

let a2uiRendererJS = """
// Minimal A2UI v0.8 renderer — supports: Text, TextInput, Button, Column, Row, Card, Select, Checkbox, RadioGroup, Image, Divider
// Renders adjacency list → DOM, wires userAction → postMessage bridge

(function() {
  'use strict';
  const components = new Map();
  const dataModel = {};
  let rootId = null;

  // Resolve a dynamic string value from A2UI format
  function resolveValue(val) {
    if (!val) return '';
    if (typeof val === 'string') return val;
    if (val.literalString) return val.literalString;
    if (val.dataRef) return getDataValue(val.dataRef) || '';
    return JSON.stringify(val);
  }

  function getDataValue(path) {
    const parts = path.replace(/^\\//, '').split('/');
    let v = dataModel;
    for (const p of parts) { v = v?.[p]; }
    return v;
  }

  // Collect form data from all inputs
  function collectFormData() {
    const data = {};
    document.querySelectorAll('[data-a2ui-field]').forEach(el => {
      const name = el.dataset.a2uiField;
      if (el.type === 'checkbox') data[name] = el.checked;
      else if (el.type === 'radio') { if (el.checked) data[name] = el.value; }
      else data[name] = el.value;
    });
    return data;
  }

  // Render a component by ID
  function renderComponent(id) {
    const entry = components.get(id);
    if (!entry) return document.createTextNode('[missing: ' + id + ']');

    const comp = entry.component;
    const type = Object.keys(comp)[0];
    const props = comp[type] || {};

    switch (type) {
      case 'Column': return renderColumn(props);
      case 'Row': return renderRow(props);
      case 'Card': return renderCard(props);
      case 'Text': return renderText(props);
      case 'TextInput': return renderTextInput(props);
      case 'Button': return renderButton(props);
      case 'Select': return renderSelect(props);
      case 'Checkbox': return renderCheckbox(props);
      case 'RadioGroup': return renderRadioGroup(props);
      case 'Image': return renderImage(props);
      case 'Divider': return renderDivider();
      default:
        const fallback = document.createElement('div');
        fallback.textContent = '[unsupported: ' + type + ']';
        return fallback;
    }
  }

  function getChildren(props) {
    if (!props.children) return [];
    if (props.children.explicitList) return props.children.explicitList;
    if (Array.isArray(props.children)) return props.children;
    return [];
  }

  function renderColumn(props) {
    const el = document.createElement('div');
    el.className = 'a2ui-column';
    getChildren(props).forEach(cid => el.appendChild(renderComponent(cid)));
    return el;
  }

  function renderRow(props) {
    const el = document.createElement('div');
    el.className = 'a2ui-row';
    if (props.alignment) el.classList.add(props.alignment);
    getChildren(props).forEach(cid => el.appendChild(renderComponent(cid)));
    return el;
  }

  function renderCard(props) {
    const el = document.createElement('div');
    el.className = 'a2ui-card';
    if (props.child) el.appendChild(renderComponent(props.child));
    getChildren(props).forEach(cid => el.appendChild(renderComponent(cid)));
    return el;
  }

  function renderText(props) {
    const el = document.createElement('div');
    el.className = 'a2ui-text';
    if (props.usageHint) el.classList.add(props.usageHint);
    el.textContent = resolveValue(props.text);
    return el;
  }

  function renderTextInput(props) {
    const wrapper = document.createElement('div');
    wrapper.className = 'a2ui-column';
    if (props.label) {
      const lbl = document.createElement('label');
      lbl.className = 'a2ui-label';
      lbl.textContent = resolveValue(props.label);
      wrapper.appendChild(lbl);
    }
    const field = props.multiline
      ? document.createElement('textarea')
      : document.createElement('input');
    field.className = props.multiline ? 'a2ui-textarea' : 'a2ui-input';
    field.placeholder = resolveValue(props.placeholder) || '';
    field.value = resolveValue(props.value) || '';
    const fieldName = props.fieldName || props.label?.literalString || props.label || 'field_' + Math.random().toString(36).slice(2,6);
    field.dataset.a2uiField = fieldName;
    wrapper.appendChild(field);
    return wrapper;
  }

  function renderButton(props) {
    const el = document.createElement('button');
    el.className = 'a2ui-button ' + (props.variant || 'primary');
    el.textContent = resolveValue(props.label);
    el.addEventListener('click', () => {
      const actionName = props.action?.name || props.action || 'click';
      const formData = collectFormData();
      window.webkit.messageHandlers.complete.postMessage({
        action: actionName,
        data: formData,
        context: props.action?.context || {}
      });
    });
    return el;
  }

  function renderSelect(props) {
    const wrapper = document.createElement('div');
    wrapper.className = 'a2ui-column';
    if (props.label) {
      const lbl = document.createElement('label');
      lbl.className = 'a2ui-label';
      lbl.textContent = resolveValue(props.label);
      wrapper.appendChild(lbl);
    }
    const sel = document.createElement('select');
    sel.className = 'a2ui-select';
    const fieldName = props.fieldName || 'select_' + Math.random().toString(36).slice(2,6);
    sel.dataset.a2uiField = fieldName;
    (props.options || []).forEach(opt => {
      const o = document.createElement('option');
      o.value = typeof opt === 'string' ? opt : (opt.value || opt.label || '');
      o.textContent = typeof opt === 'string' ? opt : (opt.label || opt.value || '');
      sel.appendChild(o);
    });
    wrapper.appendChild(sel);
    return wrapper;
  }

  function renderDivider() {
    const hr = document.createElement('hr');
    hr.className = 'a2ui-divider';
    return hr;
  }

  function renderCheckbox(props) {
    const label = document.createElement('label');
    label.className = 'a2ui-checkbox';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = !!props.checked;
    const fieldName = props.fieldName || 'checkbox_' + Math.random().toString(36).slice(2,6);
    input.dataset.a2uiField = fieldName;
    const text = document.createElement('span');
    text.textContent = resolveValue(props.label);
    label.appendChild(input);
    label.appendChild(text);
    return label;
  }

  function renderRadioGroup(props) {
    const wrapper = document.createElement('div');
    wrapper.className = 'a2ui-column';
    if (props.label) {
      const lbl = document.createElement('label');
      lbl.className = 'a2ui-label';
      lbl.textContent = resolveValue(props.label);
      wrapper.appendChild(lbl);
    }
    const fieldName = props.fieldName || 'radio_' + Math.random().toString(36).slice(2,6);
    const groupName = 'g_' + Math.random().toString(36).slice(2,8);
    (props.options || []).forEach((opt, idx) => {
      const row = document.createElement('label');
      row.className = 'a2ui-checkbox';
      const input = document.createElement('input');
      input.type = 'radio';
      input.name = groupName;
      input.value = typeof opt === 'string' ? opt : (opt.value || '');
      input.dataset.a2uiField = fieldName;
      if (props.value && resolveValue(props.value) === input.value) input.checked = true;
      if (!props.value && idx === 0) input.checked = true;
      const text = document.createElement('span');
      text.textContent = typeof opt === 'string' ? opt : (opt.label || opt.value || '');
      row.appendChild(input);
      row.appendChild(text);
      wrapper.appendChild(row);
    });
    return wrapper;
  }

  function renderImage(props) {
    const img = document.createElement('img');
    img.className = 'a2ui-image';
    img.src = resolveValue(props.url);
    img.alt = resolveValue(props.alt) || '';
    if (props.width) img.style.width = props.width + 'px';
    if (props.height) img.style.height = props.height + 'px';
    return img;
  }

  function processMessages(messages) {
    for (const msg of messages) {
      if (msg.surfaceUpdate) {
        for (const c of (msg.surfaceUpdate.components || [])) {
          components.set(c.id, c);
        }
      }
      if (msg.dataModelUpdate) {
        Object.assign(dataModel, msg.dataModelUpdate.contents || {});
      }
      if (msg.beginRendering) {
        rootId = msg.beginRendering.root || 'root';
      }
    }
    render();
  }

  function render() {
    if (!rootId) return;
    const root = document.getElementById('a2ui-root');
    root.innerHTML = '';
    root.appendChild(renderComponent(rootId));
    // Signal ready
    if (window.webkit?.messageHandlers?.ready) {
      window.webkit.messageHandlers.ready.postMessage({});
    }
  }

  // Entry point called from Swift
  window.__a2uiLoad = function(jsonStr) {
    try {
      const messages = JSON.parse(jsonStr);
      processMessages(Array.isArray(messages) ? messages : [messages]);
    } catch(e) {
      document.getElementById('a2ui-root').textContent = 'A2UI parse error: ' + e.message;
    }
  };

  // Also support inline script loading for testing
  window.__a2uiProcess = processMessages;
})();
"""

// micromark@4.0.2 — bundled from jsdelivr +esm on 2026-04-17
// CommonMark parser for markdown rendering in web contexts
let micromarkJS = #"""
/**
 * Bundled by jsDelivr using Rollup v2.79.2 and Terser v5.39.0.
 * Original file: /npm/micromark@4.0.2/index.js
 *
 * Do NOT use SRI with dynamically generated files! More information: https://www.jsdelivr.com/using-sri-with-dynamic-files
 */
import{decodeNamedCharacterReference as e}from"/npm/decode-named-character-reference@1.0.2/+esm";import{push as n,splice as t}from"/npm/micromark-util-chunked@2.0.1/+esm";import{combineHtmlExtensions as i,combineExtensions as r}from"/npm/micromark-util-combine-extensions@2.0.1/+esm";import{decodeNumericCharacterReference as o}from"/npm/micromark-util-decode-numeric-character-reference@2.0.2/+esm";import{encode as c}from"/npm/micromark-util-encode@2.0.1/+esm";import{normalizeIdentifier as l}from"/npm/micromark-util-normalize-identifier@2.0.1/+esm";import{sanitizeUri as s}from"/npm/micromark-util-sanitize-uri@2.0.1/+esm";import{factorySpace as u}from"/npm/micromark-factory-space@2.0.1/+esm";import{markdownLineEnding as a}from"/npm/micromark-util-character@2.1.1/+esm";import{blankLine as f,content as d,list as p,blockQuote as h,definition as m,codeIndented as g,headingAtx as x,thematicBreak as v,setextUnderline as k,htmlFlow as b,codeFenced as S,characterReference as _,characterEscape as y,lineEnding as I,labelStartImage as w,attention as E,autolink as T,htmlText as z,labelStartLink as F,hardBreakEscape as C,labelEnd as A,codeText as D}from"/npm/micromark-core-commonmark@2.0.3/+esm";import{resolveAll as L}from"/npm/micromark-util-resolve-all@2.0.1/+esm";import{subtokenize as R}from"/npm/micromark-util-subtokenize@2.1.0/+esm";const O={}.hasOwnProperty,P=/^(https?|ircs?|mailto|xmpp)$/i,B=/^https?$/i;function H(t){const r=t||{};let u=!0;const a={},f=[[]],d=[],p=[],h=i([{enter:{blockQuote:function(){p.push(!1),E(),y("<blockquote>")},codeFenced:function(){E(),y("<pre><code"),k("fencesCount",0)},codeFencedFenceInfo:S,codeFencedFenceMeta:S,codeIndented:function(){E(),y("<pre><code>")},codeText:function(){k("inCodeText",!0),y("<code>")},content:function(){k("slurpAllLineEndings",!0)},definition:function(){S(),d.push({})},definitionDestinationString:function(){S(),k("ignoreEncode",!0)},definitionLabelString:S,definitionTitleString:S,emphasis:function(){y("<em>")},htmlFlow:function(){E(),H()},htmlText:H,image:function(){d.push({image:!0}),u=void 0},label:S,link:function(){d.push({})},listItemMarker:function(){b("expectFirstItem")?y(">"):F();E(),y("<li>"),k("expectFirstItem"),k("lastWasTag")},listItemValue:function(e){if(b("expectFirstItem")){const n=Number.parseInt(this.sliceSerialize(e),10);1!==n&&y(' start="'+T(String(n))+'"')}},listOrdered:function(e){p.push(!e._loose),E(),y("<ol"),k("expectFirstItem",!0)},listUnordered:function(e){p.push(!e._loose),E(),y("<ul"),k("expectFirstItem",!0)},paragraph:function(){p[p.length-1]||(E(),y("<p>"));k("slurpAllLineEndings")},reference:S,resource:function(){S(),d[d.length-1].destination=""},resourceDestinationString:function(){S(),k("ignoreEncode",!0)},resourceTitleString:S,setextHeading:function(){S(),k("slurpAllLineEndings")},strong:function(){y("<strong>")}},exit:{atxHeading:function(){y("</h"+b("headingRank")+">"),k("headingRank")},atxHeadingSequence:function(e){if(b("headingRank"))return;k("headingRank",this.sliceSerialize(e).length),E(),y("<h"+b("headingRank")+">")},autolinkEmail:function(e){const n=this.sliceSerialize(e);y('<a href="'+s("mailto:"+n)+'">'),I(T(n)),y("</a>")},autolinkProtocol:function(e){const n=this.sliceSerialize(e);y('<a href="'+s(n,r.allowDangerousProtocol?void 0:P)+'">'),I(T(n)),y("</a>")},blockQuote:function(){p.pop(),E(),y("</blockquote>"),k("slurpAllLineEndings")},characterEscapeValue:D,characterReferenceMarkerHexadecimal:M,characterReferenceMarkerNumeric:M,characterReferenceValue:function(n){const t=this.sliceSerialize(n);I(T(b("characterReferenceType")?o(t,"characterReferenceMarkerNumeric"===b("characterReferenceType")?10:16):e(t))),k("characterReferenceType")},codeFenced:C,codeFencedFence:function(){const e=b("fencesCount")||0;e||(y(">"),k("slurpOneLineEnding",!0));k("fencesCount",e+1)},codeFencedFenceInfo:function(){y(' class="language-'+_()+'"')},codeFencedFenceMeta:z,codeFlowValue:function(e){I(T(this.sliceSerialize(e))),k("flowCodeSeenData",!0)},codeIndented:C,codeText:function(){k("inCodeText"),y("</code>")},codeTextData:D,data:D,definition:function(){const e=d[d.length-1],n=l(e.labelId);_(),O.call(a,n)||(a[n]=d[d.length-1]);d.pop()},definitionDestinationString:function(){d[d.length-1].destination=_(),k("ignoreEncode")},definitionLabelString:function(e){_(),d[d.length-1].labelId=this.sliceSerialize(e)},definitionTitleString:function(){d[d.length-1].title=_()},emphasis:function(){y("</em>")},hardBreakEscape:L,hardBreakTrailing:L,htmlFlow:R,htmlFlowData:D,htmlText:R,htmlTextData:D,image:A,label:function(){d[d.length-1].label=_()},labelText:function(e){d[d.length-1].labelId=this.sliceSerialize(e)},lineEnding:function(e){if(b("slurpAllLineEndings"))return;if(b("slurpOneLineEnding"))return void k("slurpOneLineEnding");if(b("inCodeText"))return void I(" ");I(T(this.sliceSerialize(e)))},link:A,listOrdered:function(){F(),p.pop(),w(),y("</ol>")},listUnordered:function(){F(),p.pop(),w(),y("</ul>")},paragraph:function(){p[p.length-1]?k("slurpAllLineEndings",!0):y("</p>")},reference:z,referenceString:function(e){d[d.length-1].referenceId=this.sliceSerialize(e)},resource:z,resourceDestinationString:function(){d[d.length-1].destination=_(),k("ignoreEncode")},resourceTitleString:function(){d[d.length-1].title=_()},setextHeading:function(){const e=_();E(),y("<h"+b("headingRank")+">"),I(e),y("</h"+b("headingRank")+">"),k("slurpAllLineEndings"),k("headingRank")},setextHeadingLineSequence:function(e){k("headingRank",61===this.sliceSerialize(e).charCodeAt(0)?1:2)},setextHeadingText:function(){k("slurpAllLineEndings",!0)},strong:function(){y("</strong>")},thematicBreak:function(){E(),y("<hr />")}}},...r.htmlExtensions||[]]),m={definitions:a,tightStack:p},g={buffer:S,encode:T,getData:b,lineEndingIfNeeded:E,options:r,raw:I,resume:_,setData:k,tag:y};let x=r.defaultLineEnding;return function(e){let t=-1,i=0;const r=[];let o=[],c=[];for(;++t<e.length;)x||"lineEnding"!==e[t][1].type&&"lineEndingBlank"!==e[t][1].type||(x=e[t][2].sliceSerialize(e[t][1])),"listOrdered"!==e[t][1].type&&"listUnordered"!==e[t][1].type||("enter"===e[t][0]?r.push(t):v(e.slice(r.pop(),t))),"definition"===e[t][1].type&&("enter"===e[t][0]?(c=n(c,e.slice(i,t)),i=t):(o=n(o,e.slice(i,t+1)),i=t+1));o=n(o,c),o=n(o,e.slice(i)),t=-1;const l=o;h.enter.null&&h.enter.null.call(g);for(;++t<e.length;){const e=h[l[t][0]],n=l[t][1].type,i=e[n];O.call(e,n)&&i&&i.call({sliceSerialize:l[t][2].sliceSerialize,...g},l[t][1])}h.exit.null&&h.exit.null.call(g);return f[0].join("")};function v(e){const n=e.length;let t,i=0,r=0,o=!1;for(;++i<n;){const n=e[i];if(n[1]._container)t=void 0,"enter"===n[0]?r++:r--;else switch(n[1].type){case"listItemPrefix":"exit"===n[0]&&(t=!0);break;case"linePrefix":break;case"lineEndingBlank":"enter"!==n[0]||r||(t?t=void 0:o=!0);break;default:t=void 0}}e[0][1]._loose=o}function k(e,n){m[e]=n}function b(e){return m[e]}function S(){f.push([])}function _(){return f.pop().join("")}function y(e){u&&(k("lastWasTag",!0),f[f.length-1].push(e))}function I(e){k("lastWasTag"),f[f.length-1].push(e)}function w(){I(x||"\n")}function E(){const e=f[f.length-1],n=e[e.length-1],t=n?n.charCodeAt(n.length-1):null;10!==t&&13!==t&&null!==t&&w()}function T(e){return b("ignoreEncode")?e:c(e)}function z(){_()}function F(){b("lastWasTag")&&!b("slurpAllLineEndings")&&E(),y("</li>"),k("slurpAllLineEndings")}function C(){const e=b("fencesCount");void 0!==e&&e<2&&m.tightStack.length>0&&!b("lastWasTag")&&w(),b("flowCodeSeenData")&&E(),y("</code></pre>"),void 0!==e&&e<2&&E(),k("flowCodeSeenData"),k("fencesCount"),k("slurpOneLineEnding")}function A(){let e=d.length-1;const n=d[e],t=n.referenceId||n.labelId,i=void 0===n.destination?a[l(t)]:n;for(u=!0;e--;)if(d[e].image){u=void 0;break}n.image?(y('<img src="'+s(i.destination,r.allowDangerousProtocol?void 0:B)+'" alt="'),I(n.label),y('"')):y('<a href="'+s(i.destination,r.allowDangerousProtocol?void 0:P)+'"'),y(i.title?' title="'+i.title+'"':""),n.image?y(" />"):(y(">"),I(n.label),y("</a>")),d.pop()}function D(e){I(T(this.sliceSerialize(e)))}function L(){y("<br />")}function R(){k("ignoreEncode")}function H(){r.allowDangerousHtml&&k("ignoreEncode",!0)}function M(e){k("characterReferenceType",e.type)}}const M={tokenize:function(e){const n=e.attempt(this.parser.constructs.contentInitial,(function(t){if(null===t)return void e.consume(t);return e.enter("lineEnding"),e.consume(t),e.exit("lineEnding"),u(e,n,"linePrefix")}),(function(n){return e.enter("paragraph"),i(n)}));let t;return n;function i(n){const i=e.enter("chunkText",{contentType:"text",previous:t});return t&&(t.next=i),t=i,r(n)}function r(n){return null===n?(e.exit("chunkText"),e.exit("paragraph"),void e.consume(n)):a(n)?(e.consume(n),e.exit("chunkText"),i):(e.consume(n),r)}}};const j={tokenize:function(e){const n=this,i=[];let r,o,c,l=0;return s;function s(t){if(l<i.length){const r=i[l];return n.containerState=r[1],e.attempt(r[0].continuation,u,f)(t)}return f(t)}function u(e){if(l++,n.containerState._closeFlow){n.containerState._closeFlow=void 0,r&&b();const i=n.events.length;let o,c=i;for(;c--;)if("exit"===n.events[c][0]&&"chunkFlow"===n.events[c][1].type){o=n.events[c][1].end;break}k(l);let s=i;for(;s<n.events.length;)n.events[s][1].end={...o},s++;return t(n.events,c+1,0,n.events.slice(i)),n.events.length=s,f(e)}return s(e)}function f(t){if(l===i.length){if(!r)return h(t);if(r.currentConstruct&&r.currentConstruct.concrete)return g(t);n.interrupt=Boolean(r.currentConstruct&&!r._gfmTableDynamicInterruptHack)}return n.containerState={},e.check(W,d,p)(t)}function d(e){return r&&b(),k(l),h(e)}function p(e){return n.parser.lazy[n.now().line]=l!==i.length,c=n.now().offset,g(e)}function h(t){return n.containerState={},e.attempt(W,m,g)(t)}function m(e){return l++,i.push([n.currentConstruct,n.containerState]),h(e)}function g(t){return null===t?(r&&b(),k(0),void e.consume(t)):(r=r||n.parser.flow(n.now()),e.enter("chunkFlow",{_tokenizer:r,contentType:"flow",previous:o}),x(t))}function x(t){return null===t?(v(e.exit("chunkFlow"),!0),k(0),void e.consume(t)):a(t)?(e.consume(t),v(e.exit("chunkFlow")),l=0,n.interrupt=void 0,s):(e.consume(t),x)}function v(e,i){const s=n.sliceStream(e);if(i&&s.push(null),e.previous=o,o&&(o.next=e),o=e,r.defineSkip(e.start),r.write(s),n.parser.lazy[e.start.line]){let e=r.events.length;for(;e--;)if(r.events[e][1].start.offset<c&&(!r.events[e][1].end||r.events[e][1].end.offset>c))return;const i=n.events.length;let o,s,u=i;for(;u--;)if("exit"===n.events[u][0]&&"chunkFlow"===n.events[u][1].type){if(o){s=n.events[u][1].end;break}o=!0}for(k(l),e=i;e<n.events.length;)n.events[e][1].end={...s},e++;t(n.events,u+1,0,n.events.slice(i)),n.events.length=e}}function k(t){let r=i.length;for(;r-- >t;){const t=i[r];n.containerState=t[1],t[0].exit.call(n,e)}i.length=t}function b(){r.write([null]),o=void 0,r=void 0,n.containerState._closeFlow=void 0}}},W={tokenize:function(e,n,t){return u(e,e.attempt(this.parser.constructs.document,n,t),"linePrefix",this.parser.constructs.disable.null.includes("codeIndented")?void 0:4)}};const q={tokenize:function(e){const n=this,t=e.attempt(f,(function(i){if(null===i)return void e.consume(i);return e.enter("lineEndingBlank"),e.consume(i),e.exit("lineEndingBlank"),n.currentConstruct=void 0,t}),e.attempt(this.parser.constructs.flowInitial,i,u(e,e.attempt(this.parser.constructs.flow,i,e.attempt(d,i)),"linePrefix")));return t;function i(i){if(null!==i)return e.enter("lineEnding"),e.consume(i),e.exit("lineEnding"),n.currentConstruct=void 0,t;e.consume(i)}}};const N={resolveAll:$()},V=Q("string"),U=Q("text");function Q(e){return{resolveAll:$("text"===e?G:void 0),tokenize:function(n){const t=this,i=this.parser.constructs[e],r=n.attempt(i,o,c);return o;function o(e){return s(e)?r(e):c(e)}function c(e){if(null!==e)return n.enter("data"),n.consume(e),l;n.consume(e)}function l(e){return s(e)?(n.exit("data"),r(e)):(n.consume(e),l)}function s(e){if(null===e)return!0;const n=i[e];let r=-1;if(n)for(;++r<n.length;){const e=n[r];if(!e.previous||e.previous.call(t,t.previous))return!0}return!1}}}}function $(e){return function(n,t){let i,r=-1;for(;++r<=n.length;)void 0===i?n[r]&&"data"===n[r][1].type&&(i=r,r++):n[r]&&"data"===n[r][1].type||(r!==i+2&&(n[i][1].end=n[r-1][1].end,n.splice(i+2,r-i-2),r=i+2),i=void 0);return e?e(n,t):n}}function G(e,n){let t=0;for(;++t<=e.length;)if((t===e.length||"lineEnding"===e[t][1].type)&&"data"===e[t-1][1].type){const i=e[t-1][1],r=n.sliceStream(i);let o,c=r.length,l=-1,s=0;for(;c--;){const e=r[c];if("string"==typeof e){for(l=e.length;32===e.charCodeAt(l-1);)s++,l--;if(l)break;l=-1}else if(-2===e)o=!0,s++;else if(-1!==e){c++;break}}if(n._contentTypeTextTrailing&&t===e.length&&(s=0),s){const r={type:t===e.length||o||s<2?"lineSuffix":"hardBreakTrailing",start:{_bufferIndex:c?l:i.start._bufferIndex+l,_index:i.start._index+c,line:i.end.line,column:i.end.column-s,offset:i.end.offset-s},end:{...i.end}};i.end={...r.start},i.start.offset===i.end.offset?Object.assign(i,r):(e.splice(t,0,["enter",r,n],["exit",r,n]),t+=2)}t++}return e}const J={42:p,43:p,45:p,48:p,49:p,50:p,51:p,52:p,53:p,54:p,55:p,56:p,57:p,62:h},K={91:m},X={[-2]:g,[-1]:g,32:g},Y={35:x,42:v,45:[k,v],60:b,61:k,95:v,96:S,126:S},Z={38:_,92:y},ee={[-5]:I,[-4]:I,[-3]:I,33:w,38:_,42:E,60:[T,z],91:F,92:[C,y],93:A,95:E,96:D},ne={null:[E,N]};var te=Object.freeze({__proto__:null,document:J,contentInitial:K,flowInitial:X,flow:Y,string:Z,text:ee,insideSpan:ne,attentionMarkers:{null:[42,95]},disable:{null:[]}});function ie(e,i,r){let o={_bufferIndex:-1,_index:0,line:r&&r.line||1,column:r&&r.column||1,offset:r&&r.offset||0};const c={},l=[];let s=[],u=[];const f={attempt:k((function(e,n){b(e,n.from)})),check:k(v),consume:function(e){a(e)?(o.line++,o.column=1,o.offset+=-3===e?2:1,S()):-1!==e&&(o.column++,o.offset++);o._bufferIndex<0?o._index++:(o._bufferIndex++,o._bufferIndex===s[o._index].length&&(o._bufferIndex=-1,o._index++));d.previous=e},enter:function(e,n){const t=n||{};return t.type=e,t.start=m(),d.events.push(["enter",t,d]),u.push(t),t},exit:function(e){const n=u.pop();return n.end=m(),d.events.push(["exit",n,d]),n},interrupt:k(v,{interrupt:!0})},d={code:null,containerState:{},defineSkip:function(e){c[e.line]=e.column,S()},events:[],now:m,parser:e,previous:null,sliceSerialize:function(e,n){return function(e,n){let t=-1;const i=[];let r;for(;++t<e.length;){const o=e[t];let c;if("string"==typeof o)c=o;else switch(o){case-5:c="\r";break;case-4:c="\n";break;case-3:c="\r\n";break;case-2:c=n?" ":"\t";break;case-1:if(!n&&r)continue;c=" ";break;default:c=String.fromCharCode(o)}r=-2===o,i.push(c)}return i.join("")}(h(e),n)},sliceStream:h,write:function(e){if(s=n(s,e),g(),null!==s[s.length-1])return[];return b(i,0),d.events=L(l,d.events,d),d.events}};let p=i.tokenize.call(d,f);return i.resolveAll&&l.push(i),d;function h(e){return function(e,n){const t=n.start._index,i=n.start._bufferIndex,r=n.end._index,o=n.end._bufferIndex;let c;if(t===r)c=[e[t].slice(i,o)];else{if(c=e.slice(t,r),i>-1){const e=c[0];"string"==typeof e?c[0]=e.slice(i):c.shift()}o>0&&c.push(e[r].slice(0,o))}return c}(s,e)}function m(){const{_bufferIndex:e,_index:n,line:t,column:i,offset:r}=o;return{_bufferIndex:e,_index:n,line:t,column:i,offset:r}}function g(){let e;for(;o._index<s.length;){const n=s[o._index];if("string"==typeof n)for(e=o._index,o._bufferIndex<0&&(o._bufferIndex=0);o._index===e&&o._bufferIndex<n.length;)x(n.charCodeAt(o._bufferIndex));else x(n)}}function x(e){p=p(e)}function v(e,n){n.restore()}function k(e,n){return function(t,i,r){let c,l,s,a;return Array.isArray(t)?p(t):"tokenize"in t?p([t]):function(e){return n;function n(n){const t=null!==n&&e[n],i=null!==n&&e.null;return p([...Array.isArray(t)?t:t?[t]:[],...Array.isArray(i)?i:i?[i]:[]])(n)}}(t);function p(e){return c=e,l=0,0===e.length?r:h(e[l])}function h(e){return function(t){a=function(){const e=m(),n=d.previous,t=d.currentConstruct,i=d.events.length,r=Array.from(u);return{from:i,restore:c};function c(){o=e,d.previous=n,d.currentConstruct=t,d.events.length=i,u=r,S()}}(),s=e,e.partial||(d.currentConstruct=e);if(e.name&&d.parser.constructs.disable.null.includes(e.name))return x();return e.tokenize.call(n?Object.assign(Object.create(d),n):d,f,g,x)(t)}}function g(n){return e(s,a),i}function x(e){return a.restore(),++l<c.length?h(c[l]):r}}}function b(e,n){e.resolveAll&&!l.includes(e)&&l.push(e),e.resolve&&t(d.events,n,d.events.length-n,e.resolve(d.events.slice(n),d)),e.resolveTo&&(d.events=e.resolveTo(d.events,d))}function S(){o.line in c&&o.column<2&&(o.column=c[o.line],o.offset+=c[o.line]-1)}}function re(e){const n={constructs:r([te,...(e||{}).extensions||[]]),content:t(M),defined:[],document:t(j),flow:t(q),lazy:{},string:t(V),text:t(U)};return n;function t(e){return function(t){return ie(n,e,t)}}}function oe(e){for(;!R(e););return e}const ce=/[\0\t\n\r]/g;function le(){let e,n=1,t="",i=!0;return function(r,o,c){const l=[];let s,u,a,f,d;r=t+("string"==typeof r?r.toString():new TextDecoder(o||void 0).decode(r)),a=0,t="",i&&(65279===r.charCodeAt(0)&&a++,i=void 0);for(;a<r.length;){if(ce.lastIndex=a,s=ce.exec(r),f=s&&void 0!==s.index?s.index:r.length,d=r.charCodeAt(f),!s){t=r.slice(a);break}if(10===d&&a===f&&e)l.push(-3),e=void 0;else switch(e&&(l.push(-5),e=void 0),a<f&&(l.push(r.slice(a,f)),n+=f-a),d){case 0:l.push(65533),n++;break;case 9:for(u=4*Math.ceil(n/4),l.push(-2);n++<u;)l.push(-1);break;case 10:l.push(-4),n=1;break;default:e=!0,n=1}a=f+1}c&&(e&&l.push(-5),t&&l.push(t),l.push(null));return l}}function se(e,n,t){return"string"!=typeof n&&(t=n,n=void 0),H(t)(oe(re(t).document().write(le()(e,n,!0))))}export{H as compile,se as micromark,re as parse,oe as postprocess,le as preprocess};export default null;
//# sourceMappingURL=/sm/dac376cf36c3b3250461344b73e223540cd31b402fe6ad6d7583caf32acbc7af.map
"""#

// MARK: - Main

guard let config = parseArgs() else {
    printUsage()
    exit(3)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let coordinator = AppCoordinator(config: config)
let delegate = AppDelegate(coordinator: coordinator)
let keyMonitor = KeyEventMonitor(coordinator: coordinator)
_ = keyMonitor

app.delegate = delegate
app.run()
