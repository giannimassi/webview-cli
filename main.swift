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
    // In a2ui mode, URL is optional (uses agent://host/index.html)
    if !config.a2ui && config.url.isEmpty { return nil }
    return config
}

func printUsage() {
    let usage = """
    Usage: webview-cli [--url <url>] [--a2ui] [options]

    Opens a native macOS webview. The page signals completion by calling:
      window.webkit.messageHandlers.complete.postMessage({...})

    Modes:
      --url <url>        Open a URL (http/https/file/agent)
      --a2ui             A2UI mode: reads A2UI JSONL from stdin, renders UI,
                         returns userAction on stdout

    Options:
      --title <title>    Window title (default: "webview-cli")
      --width <px>       Window width (default: 1024)
      --height <px>      Window height (default: 768)
      --timeout <sec>    Session timeout, 0=none (default: 0)

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

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let windowRect = NSRect(
            x: (screenFrame.width - CGFloat(config.width)) / 2 + screenFrame.origin.x,
            y: (screenFrame.height - CGFloat(config.height)) / 2 + screenFrame.origin.y,
            width: CGFloat(config.width), height: CGFloat(config.height)
        )

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
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  background: #1a1a2e; color: #e0e0e0;
  min-height: 100vh; padding: 1.5rem;
}
.a2ui-column { display: flex; flex-direction: column; gap: 0.75rem; }
.a2ui-row { display: flex; flex-direction: row; gap: 0.75rem; align-items: center; }
.a2ui-row.space-between { justify-content: space-between; }
.a2ui-row.center { justify-content: center; }
.a2ui-row.end { justify-content: flex-end; }
.a2ui-card {
  background: #16213e; border-radius: 12px; padding: 1.5rem;
  box-shadow: 0 4px 24px rgba(0,0,0,0.2);
}
.a2ui-text { line-height: 1.5; }
.a2ui-text.h1 { font-size: 1.6rem; font-weight: 700; color: #fff; }
.a2ui-text.h2 { font-size: 1.3rem; font-weight: 600; color: #fff; }
.a2ui-text.h3 { font-size: 1.1rem; font-weight: 600; color: #fff; }
.a2ui-text.subtitle { color: #8892b0; font-size: 0.9rem; }
.a2ui-text.body { color: #c0c0d0; }
.a2ui-text.caption { color: #6a6a8a; font-size: 0.8rem; }
.a2ui-input, .a2ui-textarea, .a2ui-select {
  width: 100%; padding: 0.6rem 0.8rem;
  border: 1px solid #2a2a4a; border-radius: 6px;
  background: #0f0f23; color: #e0e0e0;
  font-family: inherit; font-size: 0.9rem;
  transition: border-color 0.15s;
}
.a2ui-input:focus, .a2ui-textarea:focus, .a2ui-select:focus {
  outline: none; border-color: #4a6cf7;
}
.a2ui-textarea { resize: vertical; min-height: 80px; }
.a2ui-label { font-size: 0.85rem; color: #a0a0c0; margin-bottom: -0.4rem; }
.a2ui-button {
  padding: 0.6rem 1.2rem; border: none; border-radius: 6px;
  font-size: 0.9rem; font-weight: 600; cursor: pointer;
  transition: opacity 0.15s, transform 0.1s;
}
.a2ui-button:hover { opacity: 0.85; }
.a2ui-button:active { transform: scale(0.97); }
.a2ui-button.primary { background: #4a6cf7; color: #fff; }
.a2ui-button.secondary { background: #2a2a4a; color: #a0a0c0; }
.a2ui-button.danger { background: #e74c3c; color: #fff; }
.a2ui-button.success { background: #27ae60; color: #fff; }
.a2ui-divider { border: none; border-top: 1px solid #2a2a4a; margin: 0.5rem 0; }
.a2ui-select option { background: #0f0f23; }
"""

let a2uiRendererJS = """
// Minimal A2UI v0.8 renderer — supports: Text, TextInput, Button, Column, Row, Card, Select, Divider
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
    return document.createElement('hr');
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
