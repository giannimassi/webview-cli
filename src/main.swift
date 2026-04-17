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
        } else if config.markdownMode {
            setupMarkdownMode()
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
        schemeHandler.loadRawResource(path: "markdown-renderer.js", content: markdownRendererJS)

        // Read A2UI JSONL from stdin on a background thread
        readA2UIFromStdin()

        // Navigate to the renderer
        webView.load(URLRequest(url: URL(string: "agent://host/index.html")!))
    }

    func setupMarkdownMode() {
        // Load the built-in A2UI renderer into agent:// scheme
        schemeHandler.loadRawResource(path: "index.html", content: a2uiRendererHTML)
        schemeHandler.loadRawResource(path: "renderer.js", content: a2uiRendererJS)
        schemeHandler.loadRawResource(path: "styles.css", content: a2uiRendererCSS)
        schemeHandler.loadRawResource(path: "micromark.js", content: micromarkJS)
        schemeHandler.loadRawResource(path: "markdown-renderer.js", content: markdownRendererJS)

        // Read markdown from stdin and synthesize A2UI JSONL on a background thread
        readMarkdownFromStdin()

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

    func readMarkdownFromStdin() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var markdownContent = ""
            while let line = readLine() {
                markdownContent += line + "\n"
            }

            // Check if markdown is empty
            if markdownContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.emitAndExit(status: "error", message: "no markdown provided on stdin", code: 3)
                }
                return
            }

            // Synthesize minimal A2UI JSONL
            guard let self = self else { return }
            let a2uiPayload = self.synthesizeMarkdownA2UI(markdown: markdownContent)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingA2UIPayload = a2uiPayload
                self.flushA2UIIfReady()
            }
        }
    }

    func synthesizeMarkdownA2UI(markdown: String) -> String {
        // Determine button label based on flags
        let hasComments = config.comments
        let hasEdits = config.edits
        let buttonLabel = (hasComments || hasEdits) ? "Submit" : "OK"

        // Build the MarkdownDoc component
        var mdDocProps: [String: Any] = [
            "fieldName": "doc",
            "text": markdown,
            "allowHtml": config.allowHtml,
            "allowComments": hasComments,
            "allowEdits": hasEdits
        ]

        // Add title if user provided custom title (not default)
        if !config.title.isEmpty && config.title != "webview-cli" {
            mdDocProps["title"] = config.title
        }

        let docComponent: [String: Any] = [
            "id": "doc",
            "component": [
                "MarkdownDoc": mdDocProps
            ]
        ]

        // Build the button component
        let buttonComponent: [String: Any] = [
            "id": "submit",
            "component": [
                "Button": [
                    "label": ["literalString": buttonLabel],
                    "action": ["name": "submit"]
                ]
            ]
        ]

        // Build the root column
        let rootComponent: [String: Any] = [
            "id": "root",
            "component": [
                "Column": [
                    "children": ["explicitList": ["doc", "submit"]]
                ]
            ]
        ]

        // Build the surface update message
        let surfaceUpdate: [String: Any] = [
            "surfaceUpdate": [
                "components": [rootComponent, docComponent, buttonComponent]
            ]
        ]

        // Build the begin rendering message
        let beginRendering: [String: Any] = [
            "beginRendering": ["root": "root"]
        ]

        // Create the full payload as a JSON array
        let messages = [surfaceUpdate, beginRendering]

        // Serialize using JSONSerialization for proper escaping
        if let jsonData = try? JSONSerialization.data(withJSONObject: messages),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "[]"
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
        if config.a2ui || config.markdownMode {
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
.a2ui-markdown-doc { display: flex; flex-direction: column; gap: 1rem; }
.a2ui-markdown-doc-title { font-size: 1.05rem; font-weight: 600; letter-spacing: -0.01em; color: var(--text); }
.a2ui-markdown-preview { line-height: 1.6; color: var(--text); }
.a2ui-markdown-preview h1, .a2ui-markdown-preview h2, .a2ui-markdown-preview h3, .a2ui-markdown-preview h4, .a2ui-markdown-preview h5, .a2ui-markdown-preview h6 { margin-top: 0.5rem; margin-bottom: 0.5rem; font-weight: 600; }
.a2ui-markdown-preview h1 { font-size: 1.75rem; }
.a2ui-markdown-preview h2 { font-size: 1.35rem; }
.a2ui-markdown-preview h3 { font-size: 1.05rem; }
.a2ui-markdown-preview p { margin-bottom: 0.5rem; }
.a2ui-markdown-preview code { background: var(--surface-2); padding: 0.2rem 0.4rem; border-radius: 3px; font-family: 'Monaco', 'Menlo', 'Courier New', monospace; font-size: 0.9em; }
.a2ui-markdown-preview pre { background: var(--surface-2); padding: 1rem; border-radius: 6px; overflow-x: auto; margin-bottom: 0.5rem; }
.a2ui-markdown-preview pre code { background: transparent; padding: 0; }
.a2ui-markdown-preview blockquote { border-left: 3px solid var(--accent); padding-left: 1rem; color: var(--muted); margin-left: 0; margin-bottom: 0.5rem; }
.a2ui-markdown-preview ul, .a2ui-markdown-preview ol { margin-left: 1.5rem; margin-bottom: 0.5rem; }
.a2ui-markdown-preview li { margin-bottom: 0.25rem; }
.a2ui-markdown-preview a { color: var(--accent); text-decoration: none; }
.a2ui-markdown-preview a:hover { text-decoration: underline; }
.a2ui-markdown-preview hr { border: none; border-top: 1px solid var(--border); margin: 1rem 0; }
.a2ui-markdown-doc--with-comments { display: grid; grid-template-columns: 1fr 220px; gap: 12px; }
.a2ui-markdown-comments-pane { padding: 8px 10px; border-left: 1px solid rgba(255,255,255,0.08); }
.a2ui-markdown-comments-pane h5 { margin: 0 0 8px 0; font-size: 10px; color: #888; text-transform: uppercase; letter-spacing: 0.5px; }
.a2ui-markdown-comments-list:empty + .a2ui-markdown-comments-empty { display: block; }
.a2ui-markdown-comments-list:not(:empty) + .a2ui-markdown-comments-empty { display: none; }
.a2ui-markdown-comments-empty { font-size: 11px; color: #666; font-style: italic; padding: 6px 0; }
.a2ui-markdown-composer { background: var(--surface-2); border: 1px solid var(--border); border-radius: 7px; padding: 8px; margin-bottom: 8px; }
.a2ui-markdown-composer-quote { font-size: 10px; color: var(--muted); font-style: italic; margin-bottom: 6px; line-height: 1.4; word-break: break-word; }
.a2ui-markdown-composer-body { width: 100%; padding: 6px; border: 1px solid var(--border); border-radius: 5px; background: var(--bg); color: var(--text); font: 11px Monaco, monospace; resize: vertical; min-height: 60px; margin-bottom: 6px; }
.a2ui-markdown-composer-body:focus { outline: none; border-color: var(--accent); }
.a2ui-markdown-composer-actions { display: flex; gap: 6px; justify-content: flex-end; }
.a2ui-markdown-composer-actions button { padding: 4px 12px; font-size: 10px; border: 1px solid var(--border); border-radius: 5px; background: var(--surface); color: var(--text); cursor: pointer; transition: filter 0.12s; }
.a2ui-markdown-composer-actions button:hover { filter: brightness(1.15); }
.a2ui-markdown-composer-actions button.save { background: var(--success); color: #1a1a1c; }
.a2ui-markdown-composer-actions button:disabled { opacity: 0.5; cursor: not-allowed; }
.a2ui-markdown-comment { background: var(--surface-2); border: 1px solid var(--border); border-radius: 7px; padding: 8px; margin-bottom: 8px; }
.a2ui-markdown-comment-quote { font-size: 10px; color: var(--muted); font-style: italic; margin-bottom: 4px; line-height: 1.4; }
.a2ui-markdown-comment-body { font-size: 11px; color: var(--text); line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
.a2ui-markdown-preview [data-has-comment] { position: relative; background: rgba(255,193,7,0.08); border-left: 2px solid #ffc107; padding-left: 6px; }
.a2ui-markdown-preview [data-has-comment]::after { content: "💬"; position: absolute; right: -22px; top: 0; font-size: 12px; }
.a2ui-markdown-preview .a2ui-markdown-anchor-highlight { transition: background-color 1.2s ease-out; background: rgba(255,236,120,0.35) !important; }
.a2ui-markdown-doc-comment { grid-column: 1 / -1; border-top: 1px solid var(--border); padding: 8px 0; margin-top: 8px; }
.a2ui-markdown-doc-comment-label { display: block; font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }
.a2ui-markdown-doc-comment-body { width: 100%; padding: 6px; border: 1px solid var(--border); border-radius: 5px; background: var(--bg); color: var(--text); font: 11px Monaco, monospace; resize: vertical; min-height: 48px; }
.a2ui-markdown-doc-comment-body:focus { outline: none; border-color: var(--accent); }
.a2ui-markdown-tabs { display: flex; gap: 4px; margin-bottom: 8px; border-bottom: 1px solid var(--border); grid-column: 1 / -1; }
.a2ui-markdown-tab { padding: 4px 12px; font-size: 11px; background: transparent; border: none; border-bottom: 2px solid transparent; color: var(--muted); cursor: pointer; transition: color 0.12s, border-color 0.12s; }
.a2ui-markdown-tab:hover { color: var(--text); }
.a2ui-markdown-tab--active { color: var(--text); border-bottom-color: var(--accent); font-weight: 500; }
.a2ui-markdown-source { width: 100%; min-height: 240px; padding: 8px; font: 12px/1.5 Monaco, monospace; background: var(--bg); color: var(--text); border: 1px solid var(--border); border-radius: 5px; resize: vertical; grid-column: 1 / -1; }
.a2ui-markdown-source:focus { outline: none; border-color: var(--accent); }
"""

let a2uiRendererJS = """
// Minimal A2UI v0.8 renderer — supports: Text, TextInput, Button, Column, Row, Card, Select, Checkbox, RadioGroup, Image, Divider, MarkdownDoc
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
      else if (el.dataset.a2uiMarkdownDocField) { data[name] = { action: 'acknowledge' }; }
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
      case 'MarkdownDoc': return renderMarkdownDoc(props);
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

  function renderMarkdownDoc(props) {
    const wrapper = document.createElement('div');
    wrapper.className = 'a2ui-markdown-doc';

    // Create a marker element to track this field in form data collection
    const marker = document.createElement('div');
    const fieldName = props.fieldName || 'markdown_' + Math.random().toString(36).slice(2,6);
    marker.dataset.a2uiField = fieldName;
    marker.dataset.a2uiMarkdownDocField = 'true';
    marker.style.display = 'none';
    wrapper.appendChild(marker);


    // Initialize doc comment state
    wrapper._mdDocComment = '';
    // Add title if provided
    if (props.title) {
      const title = document.createElement('h3');
      title.className = 'a2ui-markdown-doc-title';
      title.textContent = resolveValue(props.title);
      wrapper.appendChild(title);
    }

    // Create tab bar when allowEdits is true
    let tabBar = null;
    let previewTab = null;
    let sourceTab = null;
    if (props.allowEdits === true) {
      tabBar = document.createElement('div');
      tabBar.className = 'a2ui-markdown-tabs';
      
      previewTab = document.createElement('button');
      previewTab.className = 'a2ui-markdown-tab a2ui-markdown-tab--active';
      previewTab.dataset.tab = 'preview';
      previewTab.textContent = 'Preview';
      
      sourceTab = document.createElement('button');
      sourceTab.className = 'a2ui-markdown-tab';
      sourceTab.dataset.tab = 'source';
      sourceTab.textContent = 'Source';
      
      tabBar.appendChild(previewTab);
      tabBar.appendChild(sourceTab);
      wrapper.appendChild(tabBar);
    }

    // Create preview container
    const preview = document.createElement('div');
    preview.className = 'a2ui-markdown-preview';
    wrapper.appendChild(preview);

    // Get markdown text
    const text = props.text || '';

    // Initialize editor state (exists even if edits disabled)
    wrapper._mdEditedText = text;
    wrapper._mdModified = false;
    if (!text) {
      console.warn('[MarkdownDoc] Missing text prop for component: ' + fieldName);
      preview.textContent = '(no content)';
    } else if (window.renderMarkdown) {
      const allowHtml = props.allowHtml === true;
      window.renderMarkdown(text, preview, { allowHtml });
    } else {
      console.error('renderMarkdown not available');
      preview.textContent = 'Error: markdown renderer not loaded';
    }

    // Create source textarea when allowEdits is true
    let sourceTextarea = null;
    if (props.allowEdits === true) {
      sourceTextarea = document.createElement('textarea');
      sourceTextarea.className = 'a2ui-markdown-source';
      // Input listener: track modifications
      sourceTextarea.addEventListener('input', () => {
        wrapper._mdEditedText = sourceTextarea.value;
        wrapper._mdModified = sourceTextarea.value !== text;
      });

      // Tab key handler: indent/outdent
      sourceTextarea.addEventListener('keydown', (e) => {
        if (e.key !== 'Tab') return;
        e.preventDefault();
        const el = sourceTextarea;
        const { selectionStart: s, selectionEnd: t, value: v } = el;
        if (!e.shiftKey) {
          // Tab: insert 2 spaces at cursor (replacing any selection)
          el.value = v.slice(0, s) + '  ' + v.slice(t);
          el.selectionStart = el.selectionEnd = s + 2;
        } else {
          // Shift+Tab: outdent 2 spaces if the line's start has them
          const lineStart = v.lastIndexOf('
', s - 1) + 1;
          if (v.slice(lineStart, lineStart + 2) === '  ') {
            el.value = v.slice(0, lineStart) + v.slice(lineStart + 2);
            const shift = s >= lineStart + 2 ? 2 : (s - lineStart);
            el.selectionStart = s - shift;
            el.selectionEnd = t - shift;
          }
        }
        // Input event doesn't auto-fire on programmatic .value change — dispatch manually:
        el.dispatchEvent(new Event('input', { bubbles: true }));
      });
      sourceTextarea.setAttribute('hidden', '');
      sourceTextarea.value = text;
      wrapper.appendChild(sourceTextarea);
      
      // Tab switching handler
      const switchTab = (tabName) => {
        if (tabName === 'preview') {
          // Re-render preview from current source if modified
          if (wrapper._mdModified && window.renderMarkdown) {
            window.renderMarkdown(sourceTextarea.value, preview, { allowHtml: props.allowHtml === true });
          }
          preview.removeAttribute('hidden');
          if (sourceTextarea) sourceTextarea.setAttribute('hidden', '');
          if (previewTab) {
            previewTab.classList.add('a2ui-markdown-tab--active');
            sourceTab.classList.remove('a2ui-markdown-tab--active');
          }
        } else if (tabName === 'source') {
          preview.setAttribute('hidden', '');
          if (sourceTextarea) sourceTextarea.removeAttribute('hidden');
          if (sourceTab) {
            sourceTab.classList.add('a2ui-markdown-tab--active');
            previewTab.classList.remove('a2ui-markdown-tab--active');
          }
        }
      };
      
      // Tab button click handlers
      if (previewTab) {
        previewTab.addEventListener('click', (e) => {
          e.preventDefault();
          switchTab('preview');
        });
      }
      if (sourceTab) {
        sourceTab.addEventListener('click', (e) => {
          e.preventDefault();
          switchTab('source');
        });
      }
      
      // Keyboard shortcut: Cmd+/ or Ctrl+/
      wrapper.addEventListener('keydown', (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === '/') {
          e.preventDefault();
          const currentActive = previewTab && previewTab.classList.contains('a2ui-markdown-tab--active') ? 'preview' : 'source';
          switchTab(currentActive === 'preview' ? 'source' : 'preview');
        }
      });
    }

    if (props.allowComments === true) {
      wrapper.classList.add('a2ui-markdown-doc--with-comments');
      const pane = document.createElement('aside');
      pane.className = 'a2ui-markdown-comments-pane';
      const heading = document.createElement('h5');
      heading.textContent = 'Comments';
      pane.appendChild(heading);
      const list = document.createElement('div');
      list.className = 'a2ui-markdown-comments-list';
      pane.appendChild(list);
      const empty = document.createElement('div');
      empty.className = 'a2ui-markdown-comments-empty';
      empty.textContent = 'Click any paragraph to add a comment.';
      pane.appendChild(empty);
      wrapper.appendChild(pane);

      // Initialize comment state model
      wrapper._mdComments = [];
      let composerCounter = 0;

      // Click handler for blocks in preview
      preview.addEventListener('click', (e) => {
        const block = e.target.closest('[data-src-start]');
        if (!block) return;
        if (e.target.closest('.a2ui-markdown-composer')) return;
        if (e.target.closest('.a2ui-markdown-comment')) return;

        const startLine = parseInt(block.dataset.srcStart, 10);
        const endLine = parseInt(block.dataset.srcEnd, 10);
        let quoted = block.textContent.trim().split('\n')[0];
        if (quoted.length > 200) quoted = quoted.slice(0, 200);

        // Remove existing composer if any
        const existing = list.querySelector('.a2ui-markdown-composer');
        if (existing) existing.remove();

        // Create composer card
        const composer = document.createElement('div');
        composer.className = 'a2ui-markdown-composer';
        composer.dataset.srcStart = startLine;
        composer.dataset.srcEnd = endLine;

        const quote = document.createElement('div');
        quote.className = 'a2ui-markdown-composer-quote';
        quote.textContent = '"' + quoted + '"';
        composer.appendChild(quote);

        const textarea = document.createElement('textarea');
        textarea.className = 'a2ui-markdown-composer-body';
        textarea.placeholder = 'Add a comment…';
        composer.appendChild(textarea);

        const actions = document.createElement('div');
        actions.className = 'a2ui-markdown-composer-actions';

        const cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'Cancel';
        cancelBtn.addEventListener('click', () => { composer.remove(); });
        actions.appendChild(cancelBtn);

        const saveBtn = document.createElement('button');
        saveBtn.className = 'save';
        saveBtn.textContent = 'Save';
        saveBtn.disabled = true;

        const updateSaveBtn = () => {
          saveBtn.disabled = !textarea.value.trim();
        };
        textarea.addEventListener('input', updateSaveBtn);
        textarea.addEventListener('keydown', (e) => {
          if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
            e.preventDefault();
            if (!saveBtn.disabled) saveBtn.click();
          }
          if (e.key === 'Escape') {
            e.preventDefault();
            composer.remove();
          }
        });

        saveBtn.addEventListener('click', () => {
          const body = textarea.value.trim();
          if (!body) return;
          const comment = {
            id: ++composerCounter,
            source_line_start: startLine,
            source_line_end: endLine,
            quoted_text: quoted,
            body: body
          };
          wrapper._mdComments.push(comment);
          block.setAttribute('data-has-comment', 'true');

          // Replace composer with committed-comment card
          const card = document.createElement('div');
          card.className = 'a2ui-markdown-comment';
          card.dataset.commentId = comment.id;
          card.dataset.srcStart = startLine;
          card.dataset.srcEnd = endLine;

          const cardQuote = document.createElement('div');
          cardQuote.className = 'a2ui-markdown-comment-quote';
          cardQuote.textContent = '"' + quoted + '"';
          card.appendChild(cardQuote);

          const cardBody = document.createElement('div');
          cardBody.className = 'a2ui-markdown-comment-body';
          cardBody.textContent = body;
          card.appendChild(cardBody);

          composer.replaceWith(card);
        });

        actions.appendChild(saveBtn);
        composer.appendChild(actions);
        list.insertBefore(composer, list.firstChild);
        textarea.focus();
      });

      // Click handler for committed-comment cards: scroll to block and highlight
      list.addEventListener('click', (e) => {
        const card = e.target.closest('.a2ui-markdown-comment');
        if (!card) return;
        const start = parseInt(card.dataset.srcStart, 10);
        const block = preview.querySelector('[data-src-start="' + start + '"]');
        if (!block) return;
        block.scrollIntoView({ behavior: 'smooth', block: 'center' });
        block.classList.add('a2ui-markdown-anchor-highlight');
        setTimeout(() => { block.classList.remove('a2ui-markdown-anchor-highlight'); }, 1200);
      });

      // Initialize and render doc-level comment field
      const docCommentField = document.createElement('div');
      docCommentField.className = 'a2ui-markdown-doc-comment';
      const docCommentLabel = document.createElement('label');
      docCommentLabel.className = 'a2ui-markdown-doc-comment-label';
      docCommentLabel.textContent = 'OVERALL COMMENT';
      docCommentField.appendChild(docCommentLabel);
      const docCommentTextarea = document.createElement('textarea');
      docCommentTextarea.className = 'a2ui-markdown-doc-comment-body';
      docCommentTextarea.placeholder = 'Add an overall comment…';
      docCommentTextarea.rows = 3;
      docCommentTextarea.addEventListener('input', (e) => {
        wrapper._mdDocComment = e.target.value;
      });
      docCommentField.appendChild(docCommentTextarea);
      wrapper.appendChild(docCommentField);
    }

    return wrapper;
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

// micromark@4.0.2 bundled via esbuild IIFE on 2026-04-17.
// Self-contained: 0 external CDN imports, runs standalone in WKWebView.
// Re-bundle recipe: `npm install micromark@4 esbuild` in a scratch dir,
// entry.js = `import { micromark } from 'micromark'; globalThis.micromark = micromark;`,
// then `npx esbuild entry.js --bundle --minify --format=iife --platform=browser --target=safari15`.
let micromarkJS = #"""
var __webviewMicromarkBundle=(()=>{var se=Object.defineProperty;var ce=(n,r)=>{for(var t in r)se(n,t,{get:r[t],enumerable:!0})};var lt=document.createElement("i");function Tn(n){let r="&"+n+";";lt.innerHTML=r;let t=lt.textContent;return t.charCodeAt(t.length-1)===59&&n!=="semi"||t===r?!1:t}function W(n,r,t,e){let u=n.length,i=0,o;if(r<0?r=-r>u?0:u+r:r=r>u?u:r,t=t>0?t:0,e.length<1e4)o=Array.from(e),o.unshift(r,t),n.splice(...o);else for(t&&n.splice(r,t);i<e.length;)o=e.slice(i,i+1e4),o.unshift(r,0),n.splice(...o),i+=1e4,r+=1e4}function q(n,r){return n.length>0?(W(n,n.length,0,r),n):r}var Hn={}.hasOwnProperty;function at(n){let r={},t=-1;for(;++t<n.length;)me(r,n[t]);return r}function me(n,r){let t;for(t in r){let u=(Hn.call(n,t)?n[t]:void 0)||(n[t]={}),i=r[t],o;if(i)for(o in i){Hn.call(u,o)||(u[o]=[]);let l=i[o];pe(u[o],Array.isArray(l)?l:l?[l]:[])}}}function pe(n,r){let t=-1,e=[];for(;++t<r.length;)(r[t].add==="after"?n:e).push(r[t]);W(n,0,0,e)}function st(n){let r={},t=-1;for(;++t<n.length;)he(r,n[t]);return r}function he(n,r){let t;for(t in r){let u=(Hn.call(n,t)?n[t]:void 0)||(n[t]={}),i=r[t],o;if(i)for(o in i)u[o]=i[o]}}function ct(n,r){let t=Number.parseInt(n,r);return t<9||t===11||t>13&&t<32||t>126&&t<160||t>55295&&t<57344||t>64975&&t<65008||(t&65535)===65535||(t&65535)===65534||t>1114111?"\uFFFD":String.fromCodePoint(t)}var fe={'"':"quot","&":"amp","<":"lt",">":"gt"};function Fn(n){return n.replace(/["&<>]/g,r);function r(t){return"&"+fe[t]+";"}}function on(n){return n.replace(/[\t\n\r ]+/g," ").replace(/^ | $/g,"").toLowerCase().toUpperCase()}var $=ln(/[A-Za-z]/),V=ln(/[\dA-Za-z]/),mt=ln(/[#-'*+\--9=?A-Z^-~]/);function dn(n){return n!==null&&(n<32||n===127)}var Sn=ln(/\d/),pt=ln(/[\dA-Fa-f]/),ht=ln(/[!-/:-@[-`{-~]/);function b(n){return n!==null&&n<-2}function N(n){return n!==null&&(n<0||n===32)}function z(n){return n===-2||n===-1||n===32}var ft=ln(/\p{P}|\p{S}/u),xt=ln(/\s/);function ln(n){return r;function r(t){return t!==null&&t>-1&&n.test(String.fromCharCode(t))}}function bn(n,r){let t=Fn(xe(n||""));if(!r)return t;let e=t.indexOf(":"),u=t.indexOf("?"),i=t.indexOf("#"),o=t.indexOf("/");return e<0||o>-1&&e>o||u>-1&&e>u||i>-1&&e>i||r.test(t.slice(0,e))?t:""}function xe(n){let r=[],t=-1,e=0,u=0;for(;++t<n.length;){let i=n.charCodeAt(t),o="";if(i===37&&V(n.charCodeAt(t+1))&&V(n.charCodeAt(t+2)))u=2;else if(i<128)/[!#$&-;=?-Z_a-z~]/.test(String.fromCharCode(i))||(o=String.fromCharCode(i));else if(i>55295&&i<57344){let l=n.charCodeAt(t+1);i<56320&&l>56319&&l<57344?(o=String.fromCharCode(i,l),u=1):o="\uFFFD"}else o=String.fromCharCode(i);o&&(r.push(n.slice(e,t),encodeURIComponent(o)),e=t+u+1,o=""),u&&(t+=u,u=0)}return r.join("")+n.slice(e)}var gt={}.hasOwnProperty,kt=/^(https?|ircs?|mailto|xmpp)$/i,ge=/^https?$/i;function dt(n){let r=n||{},t=!0,e={},u=[[]],i=[],o=[],f=st([{enter:{blockQuote:L,codeFenced:v,codeFencedFenceInfo:_,codeFencedFenceMeta:_,codeIndented:en,codeText:te,content:Wt,definition:Dt,definitionDestinationString:qt,definitionLabelString:_,definitionTitleString:_,emphasis:vt,htmlFlow:Xt,htmlText:et,image:Z,label:_,link:pn,listItemMarker:G,listItemValue:U,listOrdered:D,listUnordered:R,paragraph:H,reference:_,resource:gn,resourceDestinationString:rn,resourceTitleString:_,setextHeading:jt,strong:ne},exit:{atxHeading:Zt,atxHeadingSequence:Ut,autolinkEmail:ae,autolinkProtocol:le,blockQuote:M,characterEscapeValue:kn,characterReferenceMarkerHexadecimal:rt,characterReferenceMarkerNumeric:rt,characterReferenceValue:oe,codeFenced:s,codeFencedFence:J,codeFencedFenceInfo:a,codeFencedFenceMeta:B,codeFlowValue:Kt,codeIndented:s,codeText:ee,codeTextData:kn,data:kn,definition:Qt,definitionDestinationString:Ht,definitionLabelString:Rt,definitionTitleString:Vt,emphasis:re,hardBreakEscape:nt,hardBreakTrailing:nt,htmlFlow:tt,htmlFlowData:kn,htmlText:tt,htmlTextData:kn,image:zn,label:Cn,labelText:qn,lineEnding:Jt,link:zn,listOrdered:O,listUnordered:y,paragraph:K,reference:B,referenceString:Q,resource:B,resourceDestinationString:hn,resourceTitleString:fn,setextHeading:Gt,setextHeadingLineSequence:$t,setextHeadingText:Yt,strong:ie,thematicBreak:ue}},...r.htmlExtensions||[]]),p={definitions:e,tightStack:o},m={buffer:_,encode:g,getData:C,lineEndingIfNeeded:A,options:r,raw:S,resume:d,setData:w,tag:E},x=r.defaultLineEnding;return h;function h(k){let I=-1,j=0,X=[],nn=[],un=[];for(;++I<k.length;)!x&&(k[I][1].type==="lineEnding"||k[I][1].type==="lineEndingBlank")&&(x=k[I][2].sliceSerialize(k[I][1])),(k[I][1].type==="listOrdered"||k[I][1].type==="listUnordered")&&(k[I][0]==="enter"?X.push(I):c(k.slice(X.pop(),I))),k[I][1].type==="definition"&&(k[I][0]==="enter"?(un=q(un,k.slice(j,I)),j=I):(nn=q(nn,k.slice(j,I+1)),j=I+1));nn=q(nn,un),nn=q(nn,k.slice(j)),I=-1;let tn=nn;for(f.enter.null&&f.enter.null.call(m);++I<k.length;){let it=f[tn[I][0]],ut=tn[I][1].type,ot=it[ut];gt.call(it,ut)&&ot&&ot.call({sliceSerialize:tn[I][2].sliceSerialize,...m},tn[I][1])}return f.exit.null&&f.exit.null.call(m),u[0].join("")}function c(k){let I=k.length,j=0,X=0,nn=!1,un;for(;++j<I;){let tn=k[j];if(tn[1]._container)un=void 0,tn[0]==="enter"?X++:X--;else switch(tn[1].type){case"listItemPrefix":{tn[0]==="exit"&&(un=!0);break}case"linePrefix":break;case"lineEndingBlank":{tn[0]==="enter"&&!X&&(un?un=void 0:nn=!0);break}default:un=void 0}}k[0][1]._loose=nn}function w(k,I){p[k]=I}function C(k){return p[k]}function _(){u.push([])}function d(){return u.pop().join("")}function E(k){t&&(w("lastWasTag",!0),u[u.length-1].push(k))}function S(k){w("lastWasTag"),u[u.length-1].push(k)}function P(){S(x||`
`)}function g(k){switch(k){case"-":case"*":case"+":return k;case"1":case".":(r.ordered===!1||r.ordered===null)&&(r.ordered=!0);break}return""}function A(){return P(),d()}function B(){S("")}function ee(){t&&(w("lastWasTag",!1),w("buffer",[]))}function te(){ee()}function ne(){ee(),E("</strong>")}function ie(){ee(),E("</em>")}function re(n){n.fences||(ee(),n.fences=0),n.fences++,E(n.fences%2?"<em>":"</em>")}function ue(){E("<hr />")}function D(){E("<ol"+(r.ordered===!1?" start=\"1\"":"")+">")}function R(){E("<ul>")}function O(){E("</ol>")}function y(){E("</ul>")}function vt(){E("<em>")}function ne(){E("<strong>")}function U(){let n=this.sliceSerialize(this),i=Number.parseInt(n,10);(i&Number.MAX_SAFE_INTEGER||1)!==i&&(r.ordered=!1)}function G(){r.incrementListMarker===!1&&(r.incrementListMarker=!0)}function H(){E("<p>")}function K(){E("</p>")}function L(){E("<blockquote>")}function M(){E("</blockquote>")}function v(){E("<pre><code"+(this.sliceSerialize(this.start.next)||"").replace(/^/gm," class=\"language-").replace(/$/gm,"\"")+">")}function s(){E("</code></pre>")}function J(){w("slurpAllLineEndings",!0)}function _(n){return n.type==="codeFencedFenceInfo"?A():B()}function a(){let n=this.sliceSerialize(this);let i=/^([\w-]+)/.exec(n);r.code=i?i[1]:void 0,A()}function Z(){E("<img src=\""+bn(this.sliceSerialize(this.start.next),kt)+"\" alt=\"")}function pn(){E("<a href=\""+bn(this.sliceSerialize(this.start.next),ge)+"\">")}function et(){E("<code>")}function Xt(){E("<pre>")}function tt(){E("</pre>")}function ae(){E("<a href=\"mailto:"+Fn(this.sliceSerialize(this.start.next).slice(1,-1))+"\">")}function le(){E("<a href=\""+Fn(this.sliceSerialize(this.start.next).slice(1,-1))+"\">")}function gn(){B()}function rn(){let n=this.sliceSerialize(this);this.sliceSerialize(this.start.next)===n&&(r.resource=n)}function rn(){let n=this.sliceSerialize(this);this.sliceSerialize(this.start.next)===n&&(r.resource=n),A()}function hn(){let n=this.sliceSerialize(this);E(n.charCodeAt(0)===92?n.slice(1):bn(n,ge))}function fn(){A()}function Dt(){r.label=void 0,r.identifier=void 0}function Qt(){e[r.identifier]={definition:!0,destination:r.resource}}function Rt(){let n=this.sliceSerialize(this);r.label=n.slice(1,-1)}function qt(){let n=this.sliceSerialize(this);r.identifier=on(n)}function Ht(){let n=this.sliceSerialize(this);E(bn(n.slice(1,-1),kt))}function Vt(){A()}function Jt(){w("slurpAllLineEndings",!0)}function Gt(){E("<h"+r.depth+">")}function $t(){let n=this.sliceSerialize(this);r.depth=n.length}function Yt(){r.depth=this.sliceSerialize(this.start.next).length}function Zt(){E("</h"+r.depth+">")}function Ut(){A()}function en(){let n=C("slurpAllLineEndings");n||S(this.sliceSerialize(this)),C("buffer").push("\n")}function qt(){let n=this.sliceSerialize(this);r.destination=n.slice(1,-1)}function en(){let n=C("slurpAllLineEndings"),i=C("buffer").join("");n&&(i=i.replace(/[\r\n]+/g," ")),S(i)}function oe(){E(ct(this.sliceSerialize(this).slice(2,-1),10))}function rt(){E(ct(this.sliceSerialize(this).slice(3,-1),16))}function oe(){let n=this.sliceSerialize(this).slice(1,-1);let i=Tn(n);E(i===!1?"&"+n+";":i)}function Wt(){let n=C("buffer"),i=C("slurpAllLineEndings");n.push(this.sliceSerialize(this)),i&&(n.push("\n"),w("slurpAllLineEndings",!1))}function kn(){let n=this.sliceSerialize(this);E(n.charCodeAt(0)===92?n.slice(1):n)}function zn(){E(" />")}function Cn(){E(">")}function qn(){let n=this.sliceSerialize(this),i=e[on(n)];i&&i.definition&&i.destination?E(bn(i.destination,kt)):E(n)}function B(){S("")}function Kt(){let n=C("buffer"),i=C("slurpAllLineEndings");n.push(this.sliceSerialize(this)),i&&(n.push("\n"),w("slurpAllLineEndings",!1))}}function Pt(n){return r=at([Wt(),n])}function Bt(n){return function(r){return function(t){return t(r,n)}}}function Mt(){return function(n,r,t){let e="-1"===String(r),u={};return dt({...n,defaultLineEnding:"\n",...u})}}function Nt(n,r,t){return typeof r!="string"&&(t=r,r=void 0),dt(t)(Pt(Bt(t).document().write(Mt()(n,r,!0))))}globalThis.micromark=Nt;})();
"""#

let markdownRendererJS = #"""
(function() {
  'use strict';

  // Line-scan pass: identify top-level block boundaries
  function identifyBlocks(source) {
    const lines = source.split(/\r?\n/);
    const blocks = [];
    let i = 0;

    while (i < lines.length) {
      const line = lines[i];
      const trimmed = line.trimStart();

      // Skip blank lines between blocks
      if (trimmed === '') {
        i++;
        continue;
      }

      const blockStart = i + 1; // 1-based line number
      let blockEnd = i + 1;
      let blockSource = line;

      // ATX headings (# ## ### etc)
      if (/^#+\s/.test(trimmed)) {
        blockEnd = i + 1;
        i++;
      }
      // Setext headings (underlined with === or ---)
      else if (i + 1 < lines.length && /^[=\-]+\s*$/.test(lines[i + 1].trim())) {
        blockSource = line + '\n' + lines[i + 1];
        blockEnd = i + 2;
        i += 2;
      }
      // Fenced code blocks (``` or ~~~)
      else if (/^(```|~~~)/.test(trimmed)) {
        const fence = RegExp.$1;
        blockSource = line;
        i++;
        while (i < lines.length) {
          blockSource += '\n' + lines[i];
          if (new RegExp('^' + fence + '\\s*$').test(lines[i].trim())) {
            blockEnd = i + 1;
            i++;
            break;
          }
          i++;
        }
        if (i >= lines.length) blockEnd = lines.length;
      }
      // Blockquotes (>)
      else if (/^>\s/.test(trimmed)) {
        blockSource = line;
        i++;
        while (i < lines.length && (lines[i].trim() === '' || /^>\s/.test(lines[i].trimStart()))) {
          if (lines[i].trim() !== '') {
            blockSource += '\n' + lines[i];
            blockEnd = i + 1;
            i++;
          } else {
            const nextIdx = i + 1;
            if (nextIdx < lines.length && /^>\s/.test(lines[nextIdx].trimStart())) {
              blockSource += '\n' + lines[i];
              blockEnd = i + 1;
              i++;
            } else {
              break;
            }
          }
        }
      }
      // Unordered lists (-, *, +)
      else if (/^[\*\-\+]\s+/.test(trimmed)) {
        blockSource = line;
        i++;
        while (i < lines.length) {
          const nextLine = lines[i];
          const nextTrimmed = nextLine.trimStart();
          if (nextTrimmed === '') {
            const afterBlank = i + 1;
            if (afterBlank < lines.length && /^[\*\-\+]\s+/.test(lines[afterBlank].trimStart())) {
              blockSource += '\n' + nextLine;
              blockEnd = i + 1;
              i++;
            } else {
              break;
            }
          } else if (/^[\*\-\+]\s+/.test(nextTrimmed) || /^\s+\S/.test(nextLine)) {
            blockSource += '\n' + nextLine;
            blockEnd = i + 1;
            i++;
          } else {
            break;
          }
        }
      }
      // Ordered lists (1. 2. etc)
      else if (/^\d+[\.\)]\s+/.test(trimmed)) {
        blockSource = line;
        i++;
        while (i < lines.length) {
          const nextLine = lines[i];
          const nextTrimmed = nextLine.trimStart();
          if (nextTrimmed === '') {
            const afterBlank = i + 1;
            if (afterBlank < lines.length && /^\d+[\.\)]\s+/.test(lines[afterBlank].trimStart())) {
              blockSource += '\n' + nextLine;
              blockEnd = i + 1;
              i++;
            } else {
              break;
            }
          } else if (/^\d+[\.\)]\s+/.test(nextTrimmed) || /^\s+\S/.test(nextLine)) {
            blockSource += '\n' + nextLine;
            blockEnd = i + 1;
            i++;
          } else {
            break;
          }
        }
      }
      // Thematic break (---, ***, ___)
      else if (/^(\-{3,}|\*{3,}|_{3,})\s*$/.test(trimmed)) {
        blockEnd = i + 1;
        i++;
      }
      // Paragraph (default)
      else {
        blockSource = line;
        i++;
        while (i < lines.length && lines[i].trim() !== '') {
          blockSource += '\n' + lines[i];
          blockEnd = i + 1;
          i++;
        }
      }

      blocks.push({
        startLine: blockStart,
        endLine: blockEnd,
        source: blockSource
      });
    }

    return blocks;
  }

  // HTML sanitization: remove dangerous elements and attributes
  function sanitizeMarkdownDOM(rootEl, options) {
    options = options || {};
    const allowHtml = options.allowHtml === true;

    if (allowHtml) return; // Bypass sanitization if explicitly allowed

    // Dangerous elements to remove entirely
    const dangerousElements = ['script', 'iframe', 'object', 'embed', 'style', 'link', 'base', 'meta'];

    // Safe raster image MIME types (binary only, requires base64)
    const SAFE_DATA_IMAGE = /^data:image\/(png|jpeg|jpg|gif|webp|bmp|avif);base64,/i;

    // Recursively walk the DOM and sanitize
    function walk(node) {
      if (node.nodeType !== 1) return; // Only process element nodes

      const tag = node.tagName.toLowerCase();

      // Remove dangerous elements
      if (dangerousElements.includes(tag)) {
        node.remove();
        return;
      }

      // Strip event handler attributes (on*)
      const attrs = Array.from(node.attributes);
      for (const attr of attrs) {
        const name = attr.name.toLowerCase();
        if (name.startsWith('on')) {
          node.removeAttribute(attr.name);
        }
      }

      // Sanitize URL attributes for dangerous schemes
      const urlAttrs = ['href', 'src', 'formaction', 'action', 'srcdoc', 'xlink:href', 'srcset', 'poster', 'usemap', 'background'];
      for (const attrName of urlAttrs) {
        const attrValue = node.getAttribute(attrName);
        if (attrValue) {
          // Use trim() to handle all Unicode whitespace (ASCII + non-breaking space, form feed, etc.)
          const trimmed = attrValue.trim().toLowerCase();

          // Special handling for srcset: it's comma-separated, check all candidates
          if (attrName === 'srcset') {
            const candidates = trimmed.split(',').map(c => c.trim());
            let isSafe = true;
            for (const candidate of candidates) {
              const url = candidate.split(/\s+/)[0]; // Extract URL from "url 2x" format
              if (url.startsWith('javascript:') || url.startsWith('vbscript:') ||
                  (url.startsWith('data:') && !SAFE_DATA_IMAGE.test(url))) {
                isSafe = false;
                break;
              }
            }
            if (!isSafe) {
              node.removeAttribute(attrName);
            }
          } else if (trimmed.startsWith('javascript:') ||
                     trimmed.startsWith('vbscript:') ||
                     (trimmed.startsWith('data:') && !SAFE_DATA_IMAGE.test(trimmed))) {
            node.removeAttribute(attrName);
          }
        }
      }

      // Recurse to children
      for (const child of Array.from(node.childNodes)) {
        walk(child);
      }
    }

    walk(rootEl);
  }

  // Main entry point
  window.renderMarkdown = function(source, containerEl, options) {
    if (!window.micromark) {
      console.error('micromark not loaded');
      return;
    }

    options = options || {};
    containerEl.innerHTML = '';
    const blocks = identifyBlocks(source);

    for (const block of blocks) {
      try {
        const html = window.micromark(block.source);

        // Parse HTML and wrap each top-level element
        const temp = document.createElement('div');
        temp.innerHTML = html;

        // Sanitize the rendered HTML (unless allowHtml is true)
        sanitizeMarkdownDOM(temp, options);

        for (const el of temp.childNodes) {
          if (el.nodeType === 1) { // Element node
            el.setAttribute('data-src-start', String(block.startLine));
            el.setAttribute('data-src-end', String(block.endLine));
            containerEl.appendChild(el);
          } else if (el.nodeType === 3 && el.textContent.trim()) { // Non-empty text node
            const p = document.createElement('p');
            p.setAttribute('data-src-start', String(block.startLine));
            p.setAttribute('data-src-end', String(block.endLine));
            p.textContent = el.textContent;
            containerEl.appendChild(p);
          }
        }
      } catch (e) {
        console.error('Error rendering block', block, e);
        const err = document.createElement('div');
        err.setAttribute('data-src-start', String(block.startLine));
        err.setAttribute('data-src-end', String(block.endLine));
        err.style.color = 'red';
        err.textContent = 'Error: ' + e.message;
        containerEl.appendChild(err);
      }
    }
  };

  // Expose sanitizer for testing
  globalThis.sanitizeMarkdownDOM = sanitizeMarkdownDOM;
})();
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
