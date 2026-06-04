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
    var folderMode: Bool = false
    var folderPath: String? = nil
    var editorMode: Bool = false
    var editorRoot: String = ""
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
        case "--editor":
            config.editorMode = true
            // Consume the next token as the path only if it's not another flag.
            // A missing path is reported by validation ("--editor requires a path").
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                i += 1
                config.editorRoot = args[i]
            }
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
        case "--folder":
            config.folderMode = true
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                i += 1
                config.folderPath = args[i]
            }
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

    // Validate mutual exclusion
    let modeCount = [config.a2ui, config.markdownMode, config.folderMode, config.editorMode].filter { $0 }.count
    if modeCount > 1 {
        writeStderr("Error: --a2ui, --markdown, --folder, and --editor are mutually exclusive")
        return nil
    }

    if config.editorMode && config.editorRoot.isEmpty {
        writeStderr("Error: --editor requires a path")
        return nil
    }

    if !config.a2ui && !config.markdownMode && !config.folderMode && !config.editorMode && config.url.isEmpty { return nil }
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
      --folder [path]    Folder browser mode: browse files in a directory.
                         Opens path if given, otherwise shows a folder picker.
                         Markdown files render inline; other files open externally.
      --editor <path>    Text editor mode: opens a file or directory with a file
                         tree, syntax highlighting, markdown preview + link
                         following. Edits save to disk in place.

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

// MARK: - File Service (editor mode)

/// Filesystem access scoped to a single root directory. Every path is resolved
/// against `root` and rejected if it escapes (via `..` or a symlink pointing
/// outside). Used by both the `fileOp` JS bridge and the `fileop` stdin test seam.
struct FileService {
    let root: URL
    static let maxReadBytes = 4 * 1024 * 1024  // 4MB cap on readFile

    /// `rootPath` may be a directory (opened directly) or a file (its parent
    /// directory becomes the root, and the file is the initial selection).
    init?(rootPath: String) {
        let expanded = (rootPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        self.root = isDir.boolValue ? url : url.deletingLastPathComponent()
    }

    /// Resolve a relative (or absolute) path to a URL guaranteed to live under
    /// `root`. Returns nil on any escape — both the lexical (`..`) and the
    /// symlink-resolved forms must stay inside the root.
    func resolve(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let base: URL = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : root.appendingPathComponent(trimmed)
        let lexical = base.standardizedFileURL
        let symlinkResolved = base.resolvingSymlinksInPath().standardizedFileURL
        for candidate in [lexical, symlinkResolved] {
            let p = candidate.path
            if p != root.path && !p.hasPrefix(root.path + "/") { return nil }
        }
        return lexical
    }

    /// Path of `url` relative to `root` ("" for the root itself).
    func relPath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        if p == root.path { return "" }
        if p.hasPrefix(root.path + "/") { return String(p.dropFirst(root.path.count + 1)) }
        return url.lastPathComponent
    }

    func listDir(_ path: String) -> [String: Any] {
        guard let dir = resolve(path) else { return ["ok": false, "error": "path escapes root"] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return ["ok": false, "error": "not a directory"]
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return ["ok": false, "error": "cannot read directory"]
        }
        var entries: [[String: Any]] = []
        for name in names {
            if name.hasPrefix(".") { continue }  // hide dotfiles by default
            let child = dir.appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDir)
            entries.append([
                "name": name,
                "path": relPath(child),
                "type": childIsDir.boolValue ? "dir" : "file"
            ])
        }
        // Directories first, then alphabetical (case-insensitive).
        entries.sort {
            let ad = ($0["type"] as? String) == "dir"
            let bd = ($1["type"] as? String) == "dir"
            if ad != bd { return ad }
            return ($0["name"] as? String ?? "").lowercased() < ($1["name"] as? String ?? "").lowercased()
        }
        return ["ok": true, "path": relPath(dir), "entries": entries]
    }

    func readFile(_ path: String) -> [String: Any] {
        guard let file = resolve(path) else { return ["ok": false, "error": "path escapes root"] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            return ["ok": false, "error": "not a file"]
        }
        guard let data = try? Data(contentsOf: file) else { return ["ok": false, "error": "cannot read file"] }
        if data.count > FileService.maxReadBytes {
            return ["ok": false, "error": "file too large (>\(FileService.maxReadBytes / (1024*1024))MB)", "binary": true]
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "not a UTF-8 text file", "binary": true]
        }
        return ["ok": true, "path": relPath(file), "content": content]
    }

    func writeFile(_ path: String, content: String) -> [String: Any] {
        guard let file = resolve(path) else { return ["ok": false, "error": "path escapes root"] }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            return ["ok": false, "error": "is a directory"]
        }
        do {
            try content.data(using: .utf8)?.write(to: file, options: .atomic)
            return ["ok": true, "path": relPath(file)]
        } catch {
            return ["ok": false, "error": "write failed: \(error.localizedDescription)"]
        }
    }

    /// Dispatch a parsed operation dict to the right method.
    func perform(op: String, path: String, content: String?) -> [String: Any] {
        switch op {
        case "listDir": return listDir(path)
        case "readFile": return readFile(path)
        case "writeFile": return writeFile(path, content: content ?? "")
        default: return ["ok": false, "error": "unknown op: \(op)"]
        }
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
    // Folder browser state
    var currentFolderPath: String? = nil
    static let recentFoldersKey = "webview-cli.recentFolders"
    static let maxRecentFolders = 10

    // Editor mode state
    var fileService: FileService?
    var stdinReader: StdinReader?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func run() {
        let webConfig = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "complete")
        contentController.add(self, name: "ready")
        contentController.add(self, name: "navigate")
        contentController.add(self, name: "fileOp")
        contentController.add(self, name: "openExternal")

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
        } else if config.folderMode {
            setupFolderMode()
        } else if config.editorMode {
            setupEditorMode()
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

    func setupEditorMode() {
        // Initialize the scoped file service. Bail early with a clear error if
        // the root path doesn't exist.
        guard let fs = FileService(rootPath: config.editorRoot) else {
            emitAndExit(status: "error", message: "editor root not found: \(config.editorRoot)", code: 3)
            return
        }
        fileService = fs

        // Load the editor renderer + shared markdown stack + highlighter.
        schemeHandler.loadRawResource(path: "index.html", content: editorHTML)
        schemeHandler.loadRawResource(path: "editor.js", content: editorJS)
        schemeHandler.loadRawResource(path: "editor.css", content: editorCSS)
        schemeHandler.loadRawResource(path: "styles.css", content: a2uiRendererCSS)
        schemeHandler.loadRawResource(path: "micromark.js", content: micromarkJS)
        schemeHandler.loadRawResource(path: "markdown-renderer.js", content: markdownRendererJS)
        schemeHandler.loadRawResource(path: "highlight.js", content: highlightJS)

        // Start the stdin command reader (powers the `fileop` test seam and `close`).
        stdinReader = StdinReader(coordinator: self)
        stdinReader?.start()

        webView.load(URLRequest(url: URL(string: "agent://host/index.html")!))
    }

    /// Tell the editor JS what root + initial selection to boot with. Called
    /// once the renderer signals ready.
    func bootstrapEditor() {
        guard let fs = fileService else { return }
        // If the user passed a file path, select it; otherwise just open the root.
        let expanded = (config.editorRoot as NSString).expandingTildeInPath
        let target = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        let initialFile = isDir.boolValue ? "" : fs.relPath(target)
        let info: [String: Any] = [
            "root": fs.root.lastPathComponent,
            "initialFile": initialFile,
            "comments": config.comments
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info),
           let json = String(data: data, encoding: .utf8) {
            let b64 = Data(json.utf8).base64EncodedString()
            let js = "window.__editorBoot && window.__editorBoot(new TextDecoder('utf-8').decode(Uint8Array.from(atob('\(b64)'), c => c.charCodeAt(0))))"
            webView.evaluateJavaScript(js) { _, err in
                if let err = err { writeStderr("[editor] boot JS error: \(err)") }
            }
        }
    }

    /// Run a file operation and return the JSON-serializable result dict.
    func runFileOp(op: String, path: String, content: String?) -> [String: Any] {
        guard let fs = fileService else { return ["ok": false, "error": "no file service"] }
        return fs.perform(op: op, path: path, content: content)
    }

    /// Reply to a `fileOp` JS request by calling window.__fileOpReply(id, json).
    func replyFileOp(id: Any, result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else { return }
        let b64 = Data(json.utf8).base64EncodedString()
        let idLiteral: String
        if let n = id as? Int { idLiteral = String(n) }
        else if let s = id as? String { idLiteral = "\"\(s)\"" }
        else { idLiteral = "0" }
        let js = "window.__fileOpReply && window.__fileOpReply(\(idLiteral), new TextDecoder('utf-8').decode(Uint8Array.from(atob('\(b64)'), c => c.charCodeAt(0))))"
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { writeStderr("[editor] fileOp reply error: \(err)") }
        }
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

    func handleStdinCommand(_ chunk: String) {
        // A single read may contain multiple newline-delimited commands.
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            handleStdinLine(String(line).trimmingCharacters(in: .whitespaces))
        }
    }

    private func handleStdinLine(_ line: String) {
        guard !line.isEmpty else { return }
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
        case "fileop":
            // Test/debug seam: run a file op and emit the result on stdout, then exit.
            // The GUI path uses the `fileOp` message handler instead.
            let op = json["op"] as? String ?? ""
            let path = json["path"] as? String ?? ""
            let content = json["content"] as? String
            let result = runFileOp(op: op, path: path, content: content)
            emitAndExit(status: "fileop", data: result, code: 0)
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
        case "navigate":
            if let body = message.body as? [String: Any],
               let path = body["path"] as? String {
                handleNavigation(to: path)
            }
        case "fileOp":
            guard let body = message.body as? [String: Any] else { return }
            let id = body["id"] ?? 0
            let op = body["op"] as? String ?? ""
            let path = body["path"] as? String ?? ""
            let content = body["content"] as? String
            let result = runFileOp(op: op, path: path, content: content)
            replyFileOp(id: id, result: result)
        case "openExternal":
            if let body = message.body as? [String: Any],
               let urlStr = body["url"] as? String,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if config.a2ui || config.markdownMode {
            // A2UI renderer JS is loaded — safe to inject data now
            rendererReady = true
            flushA2UIIfReady()
        } else if config.editorMode {
            rendererReady = true
            bootstrapEditor()
        }
    }

    // MARK: - Navigation policy (editor mode link guard)

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard config.editorMode, let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // Allow ONLY the initial renderer document (agent://host/index.html) and
        // about: pages. Subresources (editor.js, styles.css, ...) load as
        // subresource requests and never reach this navigation hook, so they're
        // unaffected. Critically, we do NOT blanket-allow agent:// — a relative
        // markdown link that slipped past the JS click handler would resolve to
        // agent://host/<file>, 404 in the scheme handler, and fail-navigate the
        // whole editor closed. Cancelling it keeps the editor alive; the JS
        // handleLink path is what actually opens internal links.
        if scheme == "about" || (scheme == "agent" && (url.path == "/index.html" || url.path == "/" || url.path.isEmpty)) {
            decisionHandler(.allow); return
        }
        // Everything else must NOT navigate the webview. External links open in
        // the system browser; internal links are handled by the JS openFile path.
        if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emitAndExit(status: "error", message: "Navigation failed: \(error.localizedDescription)", code: 3)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitAndExit(status: "error", message: "Failed to load: \(error.localizedDescription)", code: 3)
    }

    // MARK: - Folder Browser

    func setupFolderMode() {
        schemeHandler.loadRawResource(path: "micromark.js", content: micromarkJS)
        schemeHandler.loadRawResource(path: "markdown-renderer.js", content: markdownRendererJS)
        schemeHandler.loadRawResource(path: "styles.css", content: a2uiRendererCSS)

        if let path = config.folderPath, !path.isEmpty {
            openFolder(path)
        } else {
            showFolderPicker()
        }
    }

    func showFolderPicker() {
        let isInitialLaunch = currentFolderPath == nil && !config.a2ui && !config.markdownMode && config.url.isEmpty
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to browse"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                if isInitialLaunch { self?.emitAndExit(status: "cancelled", code: 1) }
                return
            }
            self?.openFolder(url.path)
        }
    }

    func openFolder(_ path: String) {
        let resolvedPath = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
            writeStderr("[folder] Not a directory: \(resolvedPath)")
            return
        }
        currentFolderPath = resolvedPath
        window.title = (resolvedPath as NSString).lastPathComponent
        addToRecentFolders(resolvedPath)

        let html = generateFolderListingHTML(path: resolvedPath)
        schemeHandler.loadRawResource(path: "folder.html", content: html)
        webView.load(URLRequest(url: URL(string: "agent://host/folder.html")!))
    }

    func handleNavigation(to path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            writeStderr("[navigate] Path not found: \(path)")
            return
        }
        if isDir.boolValue {
            openFolder(path)
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                openMarkdownFile(path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    func openMarkdownFile(_ path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            writeStderr("[folder] Cannot read file: \(path)")
            return
        }
        let parentDir = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        window.title = fileName

        let b64Content = Data(content.utf8).base64EncodedString()
        let escapedFileName = escapeHTML(fileName)
        let escapedFolderName = escapeHTML((parentDir as NSString).lastPathComponent)

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="agent://host/styles.css">
        <style>
        .back-bar {
          position: sticky; top: 0; z-index: 10;
          background: var(--bg); border-bottom: 1px solid var(--border);
          padding: 8px 16px; display: flex; align-items: center; gap: 8px;
        }
        .back-btn {
          color: var(--accent); cursor: pointer; font-size: 13px;
          background: none; border: none; font-family: inherit; padding: 4px 0;
        }
        .back-btn:hover { text-decoration: underline; }
        .file-title { color: var(--muted); font-size: 13px; }
        .md-content { padding: 1.25rem; max-width: 800px; }
        </style>
        </head>
        <body>
        <div class="back-bar" data-path="\(escapeHTML(parentDir))">
          <button class="back-btn">‹ \(escapedFolderName)</button>
          <span class="file-title">\(escapedFileName)</span>
        </div>
        <div class="md-content" id="md-root"></div>
        <script src="agent://host/micromark.js"></script>
        <script src="agent://host/markdown-renderer.js"></script>
        <script>
        function nav(p){window.webkit.messageHandlers.navigate.postMessage({path:p});}
        document.querySelector('.back-bar').addEventListener('click',function(){nav(this.dataset.path);});
        var md=new TextDecoder('utf-8').decode(Uint8Array.from(atob('\(b64Content)'),function(c){return c.charCodeAt(0);}));
        window.renderMarkdown(md,document.getElementById('md-root'),{allowHtml:false});
        </script>
        </body>
        </html>
        """
        schemeHandler.loadRawResource(path: "file-view.html", content: html)
        webView.load(URLRequest(url: URL(string: "agent://host/file-view.html")!))
    }

    func generateFolderListingHTML(path: String) -> String {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []

        struct Entry {
            let name: String
            let isDir: Bool
            let size: Int64
            let modified: Date?
        }

        var entries: [Entry] = []
        for name in contents {
            if name.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = (attrs?[.size] as? Int64) ?? 0
            let modified = attrs?[.modificationDate] as? Date
            entries.append(Entry(name: name, isDir: isDir.boolValue, size: size, modified: modified))
        }
        entries.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        let breadcrumb = generateBreadcrumb(for: path)

        var rows = ""
        if path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            rows += "<div class=\"item\" data-path=\"\(escapeHTML(parent))\">"
            rows += "<span class=\"icon\">📁</span>"
            rows += "<span class=\"name dir\">..</span>"
            rows += "<span class=\"meta\"></span>"
            rows += "</div>\n"
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d, yyyy HH:mm"

        for entry in entries {
            let fullPath = (path as NSString).appendingPathComponent(entry.name)
            let icon = entry.isDir ? "📁" : fileIcon(for: entry.name)
            let nameClass = entry.isDir ? "name dir" : "name"
            let meta: String
            if entry.isDir {
                let count = ((try? fm.contentsOfDirectory(atPath: fullPath))?.filter { !$0.hasPrefix(".") }.count) ?? 0
                meta = "\(count) item\(count == 1 ? "" : "s")"
            } else {
                var parts: [String] = [formatFileSize(entry.size)]
                if let mod = entry.modified { parts.append(dateFmt.string(from: mod)) }
                meta = parts.joined(separator: " · ")
            }
            rows += "<div class=\"item\" data-path=\"\(escapeHTML(fullPath))\">"
            rows += "<span class=\"icon\">\(icon)</span>"
            rows += "<span class=\"\(nameClass)\">\(escapeHTML(entry.name))</span>"
            rows += "<span class=\"meta\">\(escapeHTML(meta))</span>"
            rows += "</div>\n"
        }

        if entries.isEmpty {
            rows = "<div class=\"empty\">This folder is empty</div>"
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <style>
        :root {
          --bg: #1c1c1e; --surface: #2c2c2e; --text: #f2f2f7;
          --muted: #8e8e93; --accent: #0a84ff; --border: rgba(255,255,255,0.08);
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          background: var(--bg); color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          font-size: 14px; -webkit-font-smoothing: antialiased;
        }
        .header {
          position: sticky; top: 0; z-index: 10; background: var(--bg);
          border-bottom: 1px solid var(--border); padding: 12px 16px;
        }
        .breadcrumb {
          display: flex; align-items: center; gap: 2px;
          font-size: 13px; color: var(--muted); overflow-x: auto; white-space: nowrap;
        }
        .breadcrumb a { color: var(--accent); text-decoration: none; cursor: pointer; padding: 2px 4px; border-radius: 4px; }
        .breadcrumb a:hover { background: var(--surface); }
        .breadcrumb .sep { color: var(--muted); margin: 0 1px; }
        .breadcrumb .current { color: var(--text); font-weight: 500; padding: 2px 4px; }
        .listing { padding: 4px 0; }
        .item {
          display: flex; align-items: center; gap: 10px;
          padding: 7px 16px; cursor: pointer; transition: background 0.1s;
        }
        .item:hover { background: var(--surface); }
        .item .icon { font-size: 16px; width: 24px; text-align: center; flex-shrink: 0; }
        .item .name { flex: 1; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .item .name.dir { color: var(--accent); }
        .item .meta { font-size: 12px; color: var(--muted); flex-shrink: 0; white-space: nowrap; }
        .empty { padding: 40px 16px; text-align: center; color: var(--muted); font-size: 13px; }
        </style>
        </head>
        <body>
        <div class="header"><div class="breadcrumb">\(breadcrumb)</div></div>
        <div class="listing">\(rows)</div>
        <script>
        function nav(p){window.webkit.messageHandlers.navigate.postMessage({path:p});}
        document.addEventListener('click',function(e){var t=e.target.closest('[data-path]');if(t)nav(t.dataset.path);});
        </script>
        </body>
        </html>
        """
    }

    func generateBreadcrumb(for path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var html = "<a data-path=\"/\">/</a>"
        var current = ""
        for (i, comp) in components.enumerated() {
            current += "/\(comp)"
            html += "<span class=\"sep\">›</span>"
            if i == components.count - 1 {
                html += "<span class=\"current\">\(escapeHTML(String(comp)))</span>"
            } else {
                html += "<a data-path=\"\(escapeHTML(current))\">\(escapeHTML(String(comp)))</a>"
            }
        }
        return html
    }

    func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "📝"
        case "swift": return "🔶"
        case "py": return "🐍"
        case "js", "ts", "jsx", "tsx": return "📜"
        case "json", "yaml", "yml", "toml": return "⚙️"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "🖼️"
        case "pdf": return "📕"
        case "txt", "log": return "📄"
        case "sh", "bash", "zsh": return "⚡"
        case "go": return "🔵"
        case "rs": return "🦀"
        case "html", "css": return "🌐"
        default: return "📄"
        }
    }

    func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func escapeJSString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Recent Folders

    func addToRecentFolders(_ path: String) {
        var recent = UserDefaults.standard.stringArray(forKey: AppCoordinator.recentFoldersKey) ?? []
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > AppCoordinator.maxRecentFolders { recent = Array(recent.prefix(AppCoordinator.maxRecentFolders)) }
        UserDefaults.standard.set(recent, forKey: AppCoordinator.recentFoldersKey)
    }

    static func recentFolders() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentFoldersKey) ?? []
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
        setupMenus()
        coordinator.run()
    }

    private func setupMenus() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolderAction), keyEquivalent: "o")

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        rebuildRecentMenu(recentMenu)
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",       action: Selector(("undo:")),      keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",      action: Selector(("redo:")),      keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",        action: Selector(("cut:")),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: Selector(("copy:")),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: Selector(("paste:")),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func openFolderAction() {
        coordinator.showFolderPicker()
    }

    @objc func openRecentFolderAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        coordinator.openFolder(path)
    }

    func rebuildRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = AppCoordinator.recentFolders()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for path in recent {
                let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecentFolderAction(_:)), keyEquivalent: "")
                item.representedObject = path
                item.toolTip = path
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear Recent", action: #selector(clearRecentFolders), keyEquivalent: "")
        }
    }

    @objc func clearRecentFolders() {
        UserDefaults.standard.removeObject(forKey: AppCoordinator.recentFoldersKey)
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
<script src="agent://host/micromark.js"></script>
<script src="agent://host/markdown-renderer.js"></script>
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
/* <pre> has overflow-x: auto, and tables can overflow: clip the margin pin. Anchor inside. */
.a2ui-markdown-preview pre[data-has-comment]::after,
.a2ui-markdown-preview table[data-has-comment]::after { right: 8px; top: 6px; }
/* GFM tables: marked emits unstyled <table>. Give it real structure. */
.a2ui-markdown-preview table { border-collapse: collapse; width: 100%; margin: 0.5rem 0; font-size: 0.92rem; }
.a2ui-markdown-preview th,
.a2ui-markdown-preview td { padding: 6px 10px; border: 1px solid var(--border); text-align: left; vertical-align: top; }
.a2ui-markdown-preview th { background: var(--surface-2); font-weight: 600; }
.a2ui-markdown-preview tbody tr:nth-child(even) td { background: rgba(255,255,255,0.025); }
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
      else if (el.dataset.a2uiMarkdownDocField) {
        const wrapper = el.closest('.a2ui-markdown-doc');
        if (!wrapper) { data[name] = { action: 'acknowledge' }; }
        else {
          const hasComments = wrapper._allowComments === true;
          const hasEdits = wrapper._allowEdits === true;
          const payload = {};
          if (hasComments) { payload.comments = wrapper._mdComments || []; payload.doc_comment = wrapper._mdDocComment || ''; }
          if (hasEdits) { payload.edited_text = wrapper._mdEditedText || ''; payload.modified = !!wrapper._mdModified; }
          if (!hasComments && !hasEdits) { payload.action = 'acknowledge'; }
          data[name] = payload;
        }
      }
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
    const originalLabel = resolveValue(props.label);
    el.textContent = originalLabel;
    el.addEventListener('click', () => {
      // action.copy: copy literal text to clipboard + flash 'Copied ✓'.
      // Composable with a normal action.name — agent still gets the postMessage.
      const toCopy = props.action?.copy;
      if (toCopy && navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(toCopy).then(() => {
          el.textContent = 'Copied ✓';
          el.disabled = true;
          setTimeout(() => { el.textContent = originalLabel; el.disabled = false; }, 1200);
        }).catch(() => {
          // clipboard write can fail if the page lacks focus; swallow and keep going
        });
      }
      // Fire the normal action (form submission) unless this is copy-only (no name).
      const actionName = props.action?.name || (typeof props.action === 'string' ? props.action : null);
      if (actionName) {
        const formData = collectFormData();
        window.webkit.messageHandlers.complete.postMessage({
          action: actionName,
          data: formData,
          context: props.action?.context || {}
        });
      }
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


    // Store allow flags for form data collection
    wrapper._allowComments = props.allowComments === true;
    wrapper._allowEdits = props.allowEdits === true;
    // Initialize doc comment state
    wrapper._mdDocComment = '';
    // Add title if provided
    if (props.title) {
      const title = document.createElement('h3');
      title.className = 'a2ui-markdown-doc-title';
      title.textContent = resolveValue(props.title);
      wrapper.appendChild(title);
    }

    // Create toolbar row. Always present (hosts Copy button), optionally includes tabs.
    const tabBar = document.createElement('div');
    tabBar.className = 'a2ui-markdown-tabs';
    let previewTab = null;
    let sourceTab = null;
    if (props.allowEdits === true) {
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
    }

    // Right-aligned Copy-source button — always present, dynamically copies the current source.
    const tbSpacer = document.createElement('div');
    tbSpacer.style.flex = '1';
    tabBar.appendChild(tbSpacer);

    const copyBtn = document.createElement('button');
    copyBtn.className = 'a2ui-markdown-tab';
    copyBtn.type = 'button';
    copyBtn.title = 'Copy the current markdown source to the clipboard';
    const copyDefault = '📋 Copy source';
    copyBtn.textContent = copyDefault;
    copyBtn.addEventListener('click', (e) => {
      e.preventDefault();
      // Pull from _mdEditedText (kept live by the source textarea) falling back to the original.
      const payload = (typeof wrapper._mdEditedText === 'string' && wrapper._mdEditedText.length > 0)
        ? wrapper._mdEditedText
        : (props.text || '');
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(payload).then(() => {
          copyBtn.textContent = 'Copied ✓';
          copyBtn.disabled = true;
          setTimeout(() => { copyBtn.textContent = copyDefault; copyBtn.disabled = false; }, 1200);
        }).catch(() => {
          copyBtn.textContent = 'Copy failed';
          setTimeout(() => { copyBtn.textContent = copyDefault; }, 1200);
        });
      }
    });
    tabBar.appendChild(copyBtn);

    wrapper.appendChild(tabBar);

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
          const lineStart = v.lastIndexOf('\\n', s - 1) + 1;
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
        // If the user just finished a text selection, don't hijack the mouseup
        // into opening a composer — let them copy what they selected.
        const sel = window.getSelection && window.getSelection();
        if (sel && !sel.isCollapsed && sel.toString().trim().length > 0) return;
        const block = e.target.closest('[data-src-start]');
        if (!block) return;
        if (e.target.closest('.a2ui-markdown-composer')) return;
        if (e.target.closest('.a2ui-markdown-comment')) return;

        const startLine = parseInt(block.dataset.srcStart, 10);
        const endLine = parseInt(block.dataset.srcEnd, 10);
        let quoted = block.textContent.trim().split('\\n')[0];
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
    // Setup window-wide Cmd+Enter handler for submit button
    setupWindowKeyboardHandlers();
  }

  function setupWindowKeyboardHandlers() {
    // Remove any previous handler to avoid duplicates
    document.removeEventListener('keydown', windowKeydownHandler);
    // Add the new handler
    document.addEventListener('keydown', windowKeydownHandler);
  }

  function windowKeydownHandler(e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      // Only fire if NOT inside a textarea/input (except the composer textarea has its own handler)
      const activeElement = document.activeElement;
      if (activeElement && (activeElement.tagName === 'TEXTAREA' || activeElement.tagName === 'INPUT')) {
        // Check if this is the composer textarea
        if (activeElement.classList.contains('a2ui-markdown-composer-body')) {
          // Let the composer's own handler deal with it
          return;
        }
        // It's some other textarea/input, don't fire the window handler
        return;
      }
      e.preventDefault();
      // Find and click the primary button
      const primaryBtn = document.querySelector('.a2ui-button.primary');
      if (primaryBtn) {
        primaryBtn.click();
      }
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
/**
 * marked v12.0.2 - a markdown parser
 * Copyright (c) 2011-2024, Christopher Jeffrey. (MIT Licensed)
 * https://github.com/markedjs/marked
 */
!function(e,t){"object"==typeof exports&&"undefined"!=typeof module?t(exports):"function"==typeof define&&define.amd?define(["exports"],t):t((e="undefined"!=typeof globalThis?globalThis:e||self).marked={})}(this,(function(e){"use strict";function t(){return{async:!1,breaks:!1,extensions:null,gfm:!0,hooks:null,pedantic:!1,renderer:null,silent:!1,tokenizer:null,walkTokens:null}}function n(t){e.defaults=t}e.defaults={async:!1,breaks:!1,extensions:null,gfm:!0,hooks:null,pedantic:!1,renderer:null,silent:!1,tokenizer:null,walkTokens:null};const s=/[&<>"']/,r=new RegExp(s.source,"g"),i=/[<>"']|&(?!(#\d{1,7}|#[Xx][a-fA-F0-9]{1,6}|\w+);)/,l=new RegExp(i.source,"g"),o={"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"},a=e=>o[e];function c(e,t){if(t){if(s.test(e))return e.replace(r,a)}else if(i.test(e))return e.replace(l,a);return e}const h=/&(#(?:\d+)|(?:#x[0-9A-Fa-f]+)|(?:\w+));?/gi;function p(e){return e.replace(h,((e,t)=>"colon"===(t=t.toLowerCase())?":":"#"===t.charAt(0)?"x"===t.charAt(1)?String.fromCharCode(parseInt(t.substring(2),16)):String.fromCharCode(+t.substring(1)):""))}const u=/(^|[^\[])\^/g;function k(e,t){let n="string"==typeof e?e:e.source;t=t||"";const s={replace:(e,t)=>{let r="string"==typeof t?t:t.source;return r=r.replace(u,"$1"),n=n.replace(e,r),s},getRegex:()=>new RegExp(n,t)};return s}function g(e){try{e=encodeURI(e).replace(/%25/g,"%")}catch(e){return null}return e}const f={exec:()=>null};function d(e,t){const n=e.replace(/\|/g,((e,t,n)=>{let s=!1,r=t;for(;--r>=0&&"\\"===n[r];)s=!s;return s?"|":" |"})).split(/ \|/);let s=0;if(n[0].trim()||n.shift(),n.length>0&&!n[n.length-1].trim()&&n.pop(),t)if(n.length>t)n.splice(t);else for(;n.length<t;)n.push("");for(;s<n.length;s++)n[s]=n[s].trim().replace(/\\\|/g,"|");return n}function x(e,t,n){const s=e.length;if(0===s)return"";let r=0;for(;r<s;){const i=e.charAt(s-r-1);if(i!==t||n){if(i===t||!n)break;r++}else r++}return e.slice(0,s-r)}function b(e,t,n,s){const r=t.href,i=t.title?c(t.title):null,l=e[1].replace(/\\([\[\]])/g,"$1");if("!"!==e[0].charAt(0)){s.state.inLink=!0;const e={type:"link",raw:n,href:r,title:i,text:l,tokens:s.inlineTokens(l)};return s.state.inLink=!1,e}return{type:"image",raw:n,href:r,title:i,text:c(l)}}class w{options;rules;lexer;constructor(t){this.options=t||e.defaults}space(e){const t=this.rules.block.newline.exec(e);if(t&&t[0].length>0)return{type:"space",raw:t[0]}}code(e){const t=this.rules.block.code.exec(e);if(t){const e=t[0].replace(/^ {1,4}/gm,"");return{type:"code",raw:t[0],codeBlockStyle:"indented",text:this.options.pedantic?e:x(e,"\n")}}}fences(e){const t=this.rules.block.fences.exec(e);if(t){const e=t[0],n=function(e,t){const n=e.match(/^(\s+)(?:```)/);if(null===n)return t;const s=n[1];return t.split("\n").map((e=>{const t=e.match(/^\s+/);if(null===t)return e;const[n]=t;return n.length>=s.length?e.slice(s.length):e})).join("\n")}(e,t[3]||"");return{type:"code",raw:e,lang:t[2]?t[2].trim().replace(this.rules.inline.anyPunctuation,"$1"):t[2],text:n}}}heading(e){const t=this.rules.block.heading.exec(e);if(t){let e=t[2].trim();if(/#$/.test(e)){const t=x(e,"#");this.options.pedantic?e=t.trim():t&&!/ $/.test(t)||(e=t.trim())}return{type:"heading",raw:t[0],depth:t[1].length,text:e,tokens:this.lexer.inline(e)}}}hr(e){const t=this.rules.block.hr.exec(e);if(t)return{type:"hr",raw:t[0]}}blockquote(e){const t=this.rules.block.blockquote.exec(e);if(t){let e=t[0].replace(/\n {0,3}((?:=+|-+) *)(?=\n|$)/g,"\n    $1");e=x(e.replace(/^ *>[ \t]?/gm,""),"\n");const n=this.lexer.state.top;this.lexer.state.top=!0;const s=this.lexer.blockTokens(e);return this.lexer.state.top=n,{type:"blockquote",raw:t[0],tokens:s,text:e}}}list(e){let t=this.rules.block.list.exec(e);if(t){let n=t[1].trim();const s=n.length>1,r={type:"list",raw:"",ordered:s,start:s?+n.slice(0,-1):"",loose:!1,items:[]};n=s?`\\d{1,9}\\${n.slice(-1)}`:`\\${n}`,this.options.pedantic&&(n=s?n:"[*+-]");const i=new RegExp(`^( {0,3}${n})((?:[\t ][^\\n]*)?(?:\\n|$))`);let l="",o="",a=!1;for(;e;){let n=!1;if(!(t=i.exec(e)))break;if(this.rules.block.hr.test(e))break;l=t[0],e=e.substring(l.length);let s=t[2].split("\n",1)[0].replace(/^\t+/,(e=>" ".repeat(3*e.length))),c=e.split("\n",1)[0],h=0;this.options.pedantic?(h=2,o=s.trimStart()):(h=t[2].search(/[^ ]/),h=h>4?1:h,o=s.slice(h),h+=t[1].length);let p=!1;if(!s&&/^ *$/.test(c)&&(l+=c+"\n",e=e.substring(c.length+1),n=!0),!n){const t=new RegExp(`^ {0,${Math.min(3,h-1)}}(?:[*+-]|\\d{1,9}[.)])((?:[ \t][^\\n]*)?(?:\\n|$))`),n=new RegExp(`^ {0,${Math.min(3,h-1)}}((?:- *){3,}|(?:_ *){3,}|(?:\\* *){3,})(?:\\n+|$)`),r=new RegExp(`^ {0,${Math.min(3,h-1)}}(?:\`\`\`|~~~)`),i=new RegExp(`^ {0,${Math.min(3,h-1)}}#`);for(;e;){const a=e.split("\n",1)[0];if(c=a,this.options.pedantic&&(c=c.replace(/^ {1,4}(?=( {4})*[^ ])/g,"  ")),r.test(c))break;if(i.test(c))break;if(t.test(c))break;if(n.test(e))break;if(c.search(/[^ ]/)>=h||!c.trim())o+="\n"+c.slice(h);else{if(p)break;if(s.search(/[^ ]/)>=4)break;if(r.test(s))break;if(i.test(s))break;if(n.test(s))break;o+="\n"+c}p||c.trim()||(p=!0),l+=a+"\n",e=e.substring(a.length+1),s=c.slice(h)}}r.loose||(a?r.loose=!0:/\n *\n *$/.test(l)&&(a=!0));let u,k=null;this.options.gfm&&(k=/^\[[ xX]\] /.exec(o),k&&(u="[ ] "!==k[0],o=o.replace(/^\[[ xX]\] +/,""))),r.items.push({type:"list_item",raw:l,task:!!k,checked:u,loose:!1,text:o,tokens:[]}),r.raw+=l}r.items[r.items.length-1].raw=l.trimEnd(),r.items[r.items.length-1].text=o.trimEnd(),r.raw=r.raw.trimEnd();for(let e=0;e<r.items.length;e++)if(this.lexer.state.top=!1,r.items[e].tokens=this.lexer.blockTokens(r.items[e].text,[]),!r.loose){const t=r.items[e].tokens.filter((e=>"space"===e.type)),n=t.length>0&&t.some((e=>/\n.*\n/.test(e.raw)));r.loose=n}if(r.loose)for(let e=0;e<r.items.length;e++)r.items[e].loose=!0;return r}}html(e){const t=this.rules.block.html.exec(e);if(t){return{type:"html",block:!0,raw:t[0],pre:"pre"===t[1]||"script"===t[1]||"style"===t[1],text:t[0]}}}def(e){const t=this.rules.block.def.exec(e);if(t){const e=t[1].toLowerCase().replace(/\s+/g," "),n=t[2]?t[2].replace(/^<(.*)>$/,"$1").replace(this.rules.inline.anyPunctuation,"$1"):"",s=t[3]?t[3].substring(1,t[3].length-1).replace(this.rules.inline.anyPunctuation,"$1"):t[3];return{type:"def",tag:e,raw:t[0],href:n,title:s}}}table(e){const t=this.rules.block.table.exec(e);if(!t)return;if(!/[:|]/.test(t[2]))return;const n=d(t[1]),s=t[2].replace(/^\||\| *$/g,"").split("|"),r=t[3]&&t[3].trim()?t[3].replace(/\n[ \t]*$/,"").split("\n"):[],i={type:"table",raw:t[0],header:[],align:[],rows:[]};if(n.length===s.length){for(const e of s)/^ *-+: *$/.test(e)?i.align.push("right"):/^ *:-+: *$/.test(e)?i.align.push("center"):/^ *:-+ *$/.test(e)?i.align.push("left"):i.align.push(null);for(const e of n)i.header.push({text:e,tokens:this.lexer.inline(e)});for(const e of r)i.rows.push(d(e,i.header.length).map((e=>({text:e,tokens:this.lexer.inline(e)}))));return i}}lheading(e){const t=this.rules.block.lheading.exec(e);if(t)return{type:"heading",raw:t[0],depth:"="===t[2].charAt(0)?1:2,text:t[1],tokens:this.lexer.inline(t[1])}}paragraph(e){const t=this.rules.block.paragraph.exec(e);if(t){const e="\n"===t[1].charAt(t[1].length-1)?t[1].slice(0,-1):t[1];return{type:"paragraph",raw:t[0],text:e,tokens:this.lexer.inline(e)}}}text(e){const t=this.rules.block.text.exec(e);if(t)return{type:"text",raw:t[0],text:t[0],tokens:this.lexer.inline(t[0])}}escape(e){const t=this.rules.inline.escape.exec(e);if(t)return{type:"escape",raw:t[0],text:c(t[1])}}tag(e){const t=this.rules.inline.tag.exec(e);if(t)return!this.lexer.state.inLink&&/^<a /i.test(t[0])?this.lexer.state.inLink=!0:this.lexer.state.inLink&&/^<\/a>/i.test(t[0])&&(this.lexer.state.inLink=!1),!this.lexer.state.inRawBlock&&/^<(pre|code|kbd|script)(\s|>)/i.test(t[0])?this.lexer.state.inRawBlock=!0:this.lexer.state.inRawBlock&&/^<\/(pre|code|kbd|script)(\s|>)/i.test(t[0])&&(this.lexer.state.inRawBlock=!1),{type:"html",raw:t[0],inLink:this.lexer.state.inLink,inRawBlock:this.lexer.state.inRawBlock,block:!1,text:t[0]}}link(e){const t=this.rules.inline.link.exec(e);if(t){const e=t[2].trim();if(!this.options.pedantic&&/^</.test(e)){if(!/>$/.test(e))return;const t=x(e.slice(0,-1),"\\");if((e.length-t.length)%2==0)return}else{const e=function(e,t){if(-1===e.indexOf(t[1]))return-1;let n=0;for(let s=0;s<e.length;s++)if("\\"===e[s])s++;else if(e[s]===t[0])n++;else if(e[s]===t[1]&&(n--,n<0))return s;return-1}(t[2],"()");if(e>-1){const n=(0===t[0].indexOf("!")?5:4)+t[1].length+e;t[2]=t[2].substring(0,e),t[0]=t[0].substring(0,n).trim(),t[3]=""}}let n=t[2],s="";if(this.options.pedantic){const e=/^([^'"]*[^\s])\s+(['"])(.*)\2/.exec(n);e&&(n=e[1],s=e[3])}else s=t[3]?t[3].slice(1,-1):"";return n=n.trim(),/^</.test(n)&&(n=this.options.pedantic&&!/>$/.test(e)?n.slice(1):n.slice(1,-1)),b(t,{href:n?n.replace(this.rules.inline.anyPunctuation,"$1"):n,title:s?s.replace(this.rules.inline.anyPunctuation,"$1"):s},t[0],this.lexer)}}reflink(e,t){let n;if((n=this.rules.inline.reflink.exec(e))||(n=this.rules.inline.nolink.exec(e))){const e=t[(n[2]||n[1]).replace(/\s+/g," ").toLowerCase()];if(!e){const e=n[0].charAt(0);return{type:"text",raw:e,text:e}}return b(n,e,n[0],this.lexer)}}emStrong(e,t,n=""){let s=this.rules.inline.emStrongLDelim.exec(e);if(!s)return;if(s[3]&&n.match(/[\p{L}\p{N}]/u))return;if(!(s[1]||s[2]||"")||!n||this.rules.inline.punctuation.exec(n)){const n=[...s[0]].length-1;let r,i,l=n,o=0;const a="*"===s[0][0]?this.rules.inline.emStrongRDelimAst:this.rules.inline.emStrongRDelimUnd;for(a.lastIndex=0,t=t.slice(-1*e.length+n);null!=(s=a.exec(t));){if(r=s[1]||s[2]||s[3]||s[4]||s[5]||s[6],!r)continue;if(i=[...r].length,s[3]||s[4]){l+=i;continue}if((s[5]||s[6])&&n%3&&!((n+i)%3)){o+=i;continue}if(l-=i,l>0)continue;i=Math.min(i,i+l+o);const t=[...s[0]][0].length,a=e.slice(0,n+s.index+t+i);if(Math.min(n,i)%2){const e=a.slice(1,-1);return{type:"em",raw:a,text:e,tokens:this.lexer.inlineTokens(e)}}const c=a.slice(2,-2);return{type:"strong",raw:a,text:c,tokens:this.lexer.inlineTokens(c)}}}}codespan(e){const t=this.rules.inline.code.exec(e);if(t){let e=t[2].replace(/\n/g," ");const n=/[^ ]/.test(e),s=/^ /.test(e)&&/ $/.test(e);return n&&s&&(e=e.substring(1,e.length-1)),e=c(e,!0),{type:"codespan",raw:t[0],text:e}}}br(e){const t=this.rules.inline.br.exec(e);if(t)return{type:"br",raw:t[0]}}del(e){const t=this.rules.inline.del.exec(e);if(t)return{type:"del",raw:t[0],text:t[2],tokens:this.lexer.inlineTokens(t[2])}}autolink(e){const t=this.rules.inline.autolink.exec(e);if(t){let e,n;return"@"===t[2]?(e=c(t[1]),n="mailto:"+e):(e=c(t[1]),n=e),{type:"link",raw:t[0],text:e,href:n,tokens:[{type:"text",raw:e,text:e}]}}}url(e){let t;if(t=this.rules.inline.url.exec(e)){let e,n;if("@"===t[2])e=c(t[0]),n="mailto:"+e;else{let s;do{s=t[0],t[0]=this.rules.inline._backpedal.exec(t[0])?.[0]??""}while(s!==t[0]);e=c(t[0]),n="www."===t[1]?"http://"+t[0]:t[0]}return{type:"link",raw:t[0],text:e,href:n,tokens:[{type:"text",raw:e,text:e}]}}}inlineText(e){const t=this.rules.inline.text.exec(e);if(t){let e;return e=this.lexer.state.inRawBlock?t[0]:c(t[0]),{type:"text",raw:t[0],text:e}}}}const m=/^ {0,3}((?:-[\t ]*){3,}|(?:_[ \t]*){3,}|(?:\*[ \t]*){3,})(?:\n+|$)/,y=/(?:[*+-]|\d{1,9}[.)])/,$=k(/^(?!bull |blockCode|fences|blockquote|heading|html)((?:.|\n(?!\s*?\n|bull |blockCode|fences|blockquote|heading|html))+?)\n {0,3}(=+|-+) *(?:\n+|$)/).replace(/bull/g,y).replace(/blockCode/g,/ {4}/).replace(/fences/g,/ {0,3}(?:`{3,}|~{3,})/).replace(/blockquote/g,/ {0,3}>/).replace(/heading/g,/ {0,3}#{1,6}/).replace(/html/g,/ {0,3}<[^\n>]+>\n/).getRegex(),z=/^([^\n]+(?:\n(?!hr|heading|lheading|blockquote|fences|list|html|table| +\n)[^\n]+)*)/,T=/(?!\s*\])(?:\\.|[^\[\]\\])+/,R=k(/^ {0,3}\[(label)\]: *(?:\n *)?([^<\s][^\s]*|<.*?>)(?:(?: +(?:\n *)?| *\n *)(title))? *(?:\n+|$)/).replace("label",T).replace("title",/(?:"(?:\\"?|[^"\\])*"|'[^'\n]*(?:\n[^'\n]+)*\n?'|\([^()]*\))/).getRegex(),_=k(/^( {0,3}bull)([ \t][^\n]+?)?(?:\n|$)/).replace(/bull/g,y).getRegex(),A="address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|meta|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul",S=/<!--(?:-?>|[\s\S]*?(?:-->|$))/,I=k("^ {0,3}(?:<(script|pre|style|textarea)[\\s>][\\s\\S]*?(?:</\\1>[^\\n]*\\n+|$)|comment[^\\n]*(\\n+|$)|<\\?[\\s\\S]*?(?:\\?>\\n*|$)|<![A-Z][\\s\\S]*?(?:>\\n*|$)|<!\\[CDATA\\[[\\s\\S]*?(?:\\]\\]>\\n*|$)|</?(tag)(?: +|\\n|/?>)[\\s\\S]*?(?:(?:\\n *)+\\n|$)|<(?!script|pre|style|textarea)([a-z][\\w-]*)(?:attribute)*? */?>(?=[ \\t]*(?:\\n|$))[\\s\\S]*?(?:(?:\\n *)+\\n|$)|</(?!script|pre|style|textarea)[a-z][\\w-]*\\s*>(?=[ \\t]*(?:\\n|$))[\\s\\S]*?(?:(?:\\n *)+\\n|$))","i").replace("comment",S).replace("tag",A).replace("attribute",/ +[a-zA-Z:_][\w.:-]*(?: *= *"[^"\n]*"| *= *'[^'\n]*'| *= *[^\s"'=<>`]+)?/).getRegex(),E=k(z).replace("hr",m).replace("heading"," {0,3}#{1,6}(?:\\s|$)").replace("|lheading","").replace("|table","").replace("blockquote"," {0,3}>").replace("fences"," {0,3}(?:`{3,}(?=[^`\\n]*\\n)|~{3,})[^\\n]*\\n").replace("list"," {0,3}(?:[*+-]|1[.)]) ").replace("html","</?(?:tag)(?: +|\\n|/?>)|<(?:script|pre|style|textarea|!--)").replace("tag",A).getRegex(),q={blockquote:k(/^( {0,3}> ?(paragraph|[^\n]*)(?:\n|$))+/).replace("paragraph",E).getRegex(),code:/^( {4}[^\n]+(?:\n(?: *(?:\n|$))*)?)+/,def:R,fences:/^ {0,3}(`{3,}(?=[^`\n]*(?:\n|$))|~{3,})([^\n]*)(?:\n|$)(?:|([\s\S]*?)(?:\n|$))(?: {0,3}\1[~`]* *(?=\n|$)|$)/,heading:/^ {0,3}(#{1,6})(?=\s|$)(.*)(?:\n+|$)/,hr:m,html:I,lheading:$,list:_,newline:/^(?: *(?:\n|$))+/,paragraph:E,table:f,text:/^[^\n]+/},Z=k("^ *([^\\n ].*)\\n {0,3}((?:\\| *)?:?-+:? *(?:\\| *:?-+:? *)*(?:\\| *)?)(?:\\n((?:(?! *\\n|hr|heading|blockquote|code|fences|list|html).*(?:\\n|$))*)\\n*|$)").replace("hr",m).replace("heading"," {0,3}#{1,6}(?:\\s|$)").replace("blockquote"," {0,3}>").replace("code"," {4}[^\\n]").replace("fences"," {0,3}(?:`{3,}(?=[^`\\n]*\\n)|~{3,})[^\\n]*\\n").replace("list"," {0,3}(?:[*+-]|1[.)]) ").replace("html","</?(?:tag)(?: +|\\n|/?>)|<(?:script|pre|style|textarea|!--)").replace("tag",A).getRegex(),L={...q,table:Z,paragraph:k(z).replace("hr",m).replace("heading"," {0,3}#{1,6}(?:\\s|$)").replace("|lheading","").replace("table",Z).replace("blockquote"," {0,3}>").replace("fences"," {0,3}(?:`{3,}(?=[^`\\n]*\\n)|~{3,})[^\\n]*\\n").replace("list"," {0,3}(?:[*+-]|1[.)]) ").replace("html","</?(?:tag)(?: +|\\n|/?>)|<(?:script|pre|style|textarea|!--)").replace("tag",A).getRegex()},P={...q,html:k("^ *(?:comment *(?:\\n|\\s*$)|<(tag)[\\s\\S]+?</\\1> *(?:\\n{2,}|\\s*$)|<tag(?:\"[^\"]*\"|'[^']*'|\\s[^'\"/>\\s]*)*?/?> *(?:\\n{2,}|\\s*$))").replace("comment",S).replace(/tag/g,"(?!(?:a|em|strong|small|s|cite|q|dfn|abbr|data|time|code|var|samp|kbd|sub|sup|i|b|u|mark|ruby|rt|rp|bdi|bdo|span|br|wbr|ins|del|img)\\b)\\w+(?!:|[^\\w\\s@]*@)\\b").getRegex(),def:/^ *\[([^\]]+)\]: *<?([^\s>]+)>?(?: +(["(][^\n]+[")]))? *(?:\n+|$)/,heading:/^(#{1,6})(.*)(?:\n+|$)/,fences:f,lheading:/^(.+?)\n {0,3}(=+|-+) *(?:\n+|$)/,paragraph:k(z).replace("hr",m).replace("heading"," *#{1,6} *[^\n]").replace("lheading",$).replace("|table","").replace("blockquote"," {0,3}>").replace("|fences","").replace("|list","").replace("|html","").replace("|tag","").getRegex()},Q=/^\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])/,v=/^( {2,}|\\)\n(?!\s*$)/,B="\\p{P}\\p{S}",C=k(/^((?![*_])[\spunctuation])/,"u").replace(/punctuation/g,B).getRegex(),M=k(/^(?:\*+(?:((?!\*)[punct])|[^\s*]))|^_+(?:((?!_)[punct])|([^\s_]))/,"u").replace(/punct/g,B).getRegex(),O=k("^[^_*]*?__[^_*]*?\\*[^_*]*?(?=__)|[^*]+(?=[^*])|(?!\\*)[punct](\\*+)(?=[\\s]|$)|[^punct\\s](\\*+)(?!\\*)(?=[punct\\s]|$)|(?!\\*)[punct\\s](\\*+)(?=[^punct\\s])|[\\s](\\*+)(?!\\*)(?=[punct])|(?!\\*)[punct](\\*+)(?!\\*)(?=[punct])|[^punct\\s](\\*+)(?=[^punct\\s])","gu").replace(/punct/g,B).getRegex(),D=k("^[^_*]*?\\*\\*[^_*]*?_[^_*]*?(?=\\*\\*)|[^_]+(?=[^_])|(?!_)[punct](_+)(?=[\\s]|$)|[^punct\\s](_+)(?!_)(?=[punct\\s]|$)|(?!_)[punct\\s](_+)(?=[^punct\\s])|[\\s](_+)(?!_)(?=[punct])|(?!_)[punct](_+)(?!_)(?=[punct])","gu").replace(/punct/g,B).getRegex(),j=k(/\\([punct])/,"gu").replace(/punct/g,B).getRegex(),H=k(/^<(scheme:[^\s\x00-\x1f<>]*|email)>/).replace("scheme",/[a-zA-Z][a-zA-Z0-9+.-]{1,31}/).replace("email",/[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+(@)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?![-_])/).getRegex(),U=k(S).replace("(?:--\x3e|$)","--\x3e").getRegex(),X=k("^comment|^</[a-zA-Z][\\w:-]*\\s*>|^<[a-zA-Z][\\w-]*(?:attribute)*?\\s*/?>|^<\\?[\\s\\S]*?\\?>|^<![a-zA-Z]+\\s[\\s\\S]*?>|^<!\\[CDATA\\[[\\s\\S]*?\\]\\]>").replace("comment",U).replace("attribute",/\s+[a-zA-Z:_][\w.:-]*(?:\s*=\s*"[^"]*"|\s*=\s*'[^']*'|\s*=\s*[^\s"'=<>`]+)?/).getRegex(),F=/(?:\[(?:\\.|[^\[\]\\])*\]|\\.|`[^`]*`|[^\[\]\\`])*?/,N=k(/^!?\[(label)\]\(\s*(href)(?:\s+(title))?\s*\)/).replace("label",F).replace("href",/<(?:\\.|[^\n<>\\])+>|[^\s\x00-\x1f]*/).replace("title",/"(?:\\"?|[^"\\])*"|'(?:\\'?|[^'\\])*'|\((?:\\\)?|[^)\\])*\)/).getRegex(),G=k(/^!?\[(label)\]\[(ref)\]/).replace("label",F).replace("ref",T).getRegex(),J=k(/^!?\[(ref)\](?:\[\])?/).replace("ref",T).getRegex(),K={_backpedal:f,anyPunctuation:j,autolink:H,blockSkip:/\[[^[\]]*?\]\([^\(\)]*?\)|`[^`]*?`|<[^<>]*?>/g,br:v,code:/^(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/,del:f,emStrongLDelim:M,emStrongRDelimAst:O,emStrongRDelimUnd:D,escape:Q,link:N,nolink:J,punctuation:C,reflink:G,reflinkSearch:k("reflink|nolink(?!\\()","g").replace("reflink",G).replace("nolink",J).getRegex(),tag:X,text:/^(`+|[^`])(?:(?= {2,}\n)|[\s\S]*?(?:(?=[\\<!\[`*_]|\b_|$)|[^ ](?= {2,}\n)))/,url:f},V={...K,link:k(/^!?\[(label)\]\((.*?)\)/).replace("label",F).getRegex(),reflink:k(/^!?\[(label)\]\s*\[([^\]]*)\]/).replace("label",F).getRegex()},W={...K,escape:k(Q).replace("])","~|])").getRegex(),url:k(/^((?:ftp|https?):\/\/|www\.)(?:[a-zA-Z0-9\-]+\.?)+[^\s<]*|^email/,"i").replace("email",/[A-Za-z0-9._+-]+(@)[a-zA-Z0-9-_]+(?:\.[a-zA-Z0-9-_]*[a-zA-Z0-9])+(?![-_])/).getRegex(),_backpedal:/(?:[^?!.,:;*_'"~()&]+|\([^)]*\)|&(?![a-zA-Z0-9]+;$)|[?!.,:;*_'"~)]+(?!$))+/,del:/^(~~?)(?=[^\s~])([\s\S]*?[^\s~])\1(?=[^~]|$)/,text:/^([`~]+|[^`~])(?:(?= {2,}\n)|(?=[a-zA-Z0-9.!#$%&'*+\/=?_`{\|}~-]+@)|[\s\S]*?(?:(?=[\\<!\[`*~_]|\b_|https?:\/\/|ftp:\/\/|www\.|$)|[^ ](?= {2,}\n)|[^a-zA-Z0-9.!#$%&'*+\/=?_`{\|}~-](?=[a-zA-Z0-9.!#$%&'*+\/=?_`{\|}~-]+@)))/},Y={...W,br:k(v).replace("{2,}","*").getRegex(),text:k(W.text).replace("\\b_","\\b_| {2,}\\n").replace(/\{2,\}/g,"*").getRegex()},ee={normal:q,gfm:L,pedantic:P},te={normal:K,gfm:W,breaks:Y,pedantic:V};class ne{tokens;options;state;tokenizer;inlineQueue;constructor(t){this.tokens=[],this.tokens.links=Object.create(null),this.options=t||e.defaults,this.options.tokenizer=this.options.tokenizer||new w,this.tokenizer=this.options.tokenizer,this.tokenizer.options=this.options,this.tokenizer.lexer=this,this.inlineQueue=[],this.state={inLink:!1,inRawBlock:!1,top:!0};const n={block:ee.normal,inline:te.normal};this.options.pedantic?(n.block=ee.pedantic,n.inline=te.pedantic):this.options.gfm&&(n.block=ee.gfm,this.options.breaks?n.inline=te.breaks:n.inline=te.gfm),this.tokenizer.rules=n}static get rules(){return{block:ee,inline:te}}static lex(e,t){return new ne(t).lex(e)}static lexInline(e,t){return new ne(t).inlineTokens(e)}lex(e){e=e.replace(/\r\n|\r/g,"\n"),this.blockTokens(e,this.tokens);for(let e=0;e<this.inlineQueue.length;e++){const t=this.inlineQueue[e];this.inlineTokens(t.src,t.tokens)}return this.inlineQueue=[],this.tokens}blockTokens(e,t=[]){let n,s,r,i;for(e=this.options.pedantic?e.replace(/\t/g,"    ").replace(/^ +$/gm,""):e.replace(/^( *)(\t+)/gm,((e,t,n)=>t+"    ".repeat(n.length)));e;)if(!(this.options.extensions&&this.options.extensions.block&&this.options.extensions.block.some((s=>!!(n=s.call({lexer:this},e,t))&&(e=e.substring(n.raw.length),t.push(n),!0)))))if(n=this.tokenizer.space(e))e=e.substring(n.raw.length),1===n.raw.length&&t.length>0?t[t.length-1].raw+="\n":t.push(n);else if(n=this.tokenizer.code(e))e=e.substring(n.raw.length),s=t[t.length-1],!s||"paragraph"!==s.type&&"text"!==s.type?t.push(n):(s.raw+="\n"+n.raw,s.text+="\n"+n.text,this.inlineQueue[this.inlineQueue.length-1].src=s.text);else if(n=this.tokenizer.fences(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.heading(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.hr(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.blockquote(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.list(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.html(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.def(e))e=e.substring(n.raw.length),s=t[t.length-1],!s||"paragraph"!==s.type&&"text"!==s.type?this.tokens.links[n.tag]||(this.tokens.links[n.tag]={href:n.href,title:n.title}):(s.raw+="\n"+n.raw,s.text+="\n"+n.raw,this.inlineQueue[this.inlineQueue.length-1].src=s.text);else if(n=this.tokenizer.table(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.lheading(e))e=e.substring(n.raw.length),t.push(n);else{if(r=e,this.options.extensions&&this.options.extensions.startBlock){let t=1/0;const n=e.slice(1);let s;this.options.extensions.startBlock.forEach((e=>{s=e.call({lexer:this},n),"number"==typeof s&&s>=0&&(t=Math.min(t,s))})),t<1/0&&t>=0&&(r=e.substring(0,t+1))}if(this.state.top&&(n=this.tokenizer.paragraph(r)))s=t[t.length-1],i&&"paragraph"===s.type?(s.raw+="\n"+n.raw,s.text+="\n"+n.text,this.inlineQueue.pop(),this.inlineQueue[this.inlineQueue.length-1].src=s.text):t.push(n),i=r.length!==e.length,e=e.substring(n.raw.length);else if(n=this.tokenizer.text(e))e=e.substring(n.raw.length),s=t[t.length-1],s&&"text"===s.type?(s.raw+="\n"+n.raw,s.text+="\n"+n.text,this.inlineQueue.pop(),this.inlineQueue[this.inlineQueue.length-1].src=s.text):t.push(n);else if(e){const t="Infinite loop on byte: "+e.charCodeAt(0);if(this.options.silent){console.error(t);break}throw new Error(t)}}return this.state.top=!0,t}inline(e,t=[]){return this.inlineQueue.push({src:e,tokens:t}),t}inlineTokens(e,t=[]){let n,s,r,i,l,o,a=e;if(this.tokens.links){const e=Object.keys(this.tokens.links);if(e.length>0)for(;null!=(i=this.tokenizer.rules.inline.reflinkSearch.exec(a));)e.includes(i[0].slice(i[0].lastIndexOf("[")+1,-1))&&(a=a.slice(0,i.index)+"["+"a".repeat(i[0].length-2)+"]"+a.slice(this.tokenizer.rules.inline.reflinkSearch.lastIndex))}for(;null!=(i=this.tokenizer.rules.inline.blockSkip.exec(a));)a=a.slice(0,i.index)+"["+"a".repeat(i[0].length-2)+"]"+a.slice(this.tokenizer.rules.inline.blockSkip.lastIndex);for(;null!=(i=this.tokenizer.rules.inline.anyPunctuation.exec(a));)a=a.slice(0,i.index)+"++"+a.slice(this.tokenizer.rules.inline.anyPunctuation.lastIndex);for(;e;)if(l||(o=""),l=!1,!(this.options.extensions&&this.options.extensions.inline&&this.options.extensions.inline.some((s=>!!(n=s.call({lexer:this},e,t))&&(e=e.substring(n.raw.length),t.push(n),!0)))))if(n=this.tokenizer.escape(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.tag(e))e=e.substring(n.raw.length),s=t[t.length-1],s&&"text"===n.type&&"text"===s.type?(s.raw+=n.raw,s.text+=n.text):t.push(n);else if(n=this.tokenizer.link(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.reflink(e,this.tokens.links))e=e.substring(n.raw.length),s=t[t.length-1],s&&"text"===n.type&&"text"===s.type?(s.raw+=n.raw,s.text+=n.text):t.push(n);else if(n=this.tokenizer.emStrong(e,a,o))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.codespan(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.br(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.del(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.autolink(e))e=e.substring(n.raw.length),t.push(n);else if(this.state.inLink||!(n=this.tokenizer.url(e))){if(r=e,this.options.extensions&&this.options.extensions.startInline){let t=1/0;const n=e.slice(1);let s;this.options.extensions.startInline.forEach((e=>{s=e.call({lexer:this},n),"number"==typeof s&&s>=0&&(t=Math.min(t,s))})),t<1/0&&t>=0&&(r=e.substring(0,t+1))}if(n=this.tokenizer.inlineText(r))e=e.substring(n.raw.length),"_"!==n.raw.slice(-1)&&(o=n.raw.slice(-1)),l=!0,s=t[t.length-1],s&&"text"===s.type?(s.raw+=n.raw,s.text+=n.text):t.push(n);else if(e){const t="Infinite loop on byte: "+e.charCodeAt(0);if(this.options.silent){console.error(t);break}throw new Error(t)}}else e=e.substring(n.raw.length),t.push(n);return t}}class se{options;constructor(t){this.options=t||e.defaults}code(e,t,n){const s=(t||"").match(/^\S*/)?.[0];return e=e.replace(/\n$/,"")+"\n",s?'<pre><code class="language-'+c(s)+'">'+(n?e:c(e,!0))+"</code></pre>\n":"<pre><code>"+(n?e:c(e,!0))+"</code></pre>\n"}blockquote(e){return`<blockquote>\n${e}</blockquote>\n`}html(e,t){return e}heading(e,t,n){return`<h${t}>${e}</h${t}>\n`}hr(){return"<hr>\n"}list(e,t,n){const s=t?"ol":"ul";return"<"+s+(t&&1!==n?' start="'+n+'"':"")+">\n"+e+"</"+s+">\n"}listitem(e,t,n){return`<li>${e}</li>\n`}checkbox(e){return"<input "+(e?'checked="" ':"")+'disabled="" type="checkbox">'}paragraph(e){return`<p>${e}</p>\n`}table(e,t){return t&&(t=`<tbody>${t}</tbody>`),"<table>\n<thead>\n"+e+"</thead>\n"+t+"</table>\n"}tablerow(e){return`<tr>\n${e}</tr>\n`}tablecell(e,t){const n=t.header?"th":"td";return(t.align?`<${n} align="${t.align}">`:`<${n}>`)+e+`</${n}>\n`}strong(e){return`<strong>${e}</strong>`}em(e){return`<em>${e}</em>`}codespan(e){return`<code>${e}</code>`}br(){return"<br>"}del(e){return`<del>${e}</del>`}link(e,t,n){const s=g(e);if(null===s)return n;let r='<a href="'+(e=s)+'"';return t&&(r+=' title="'+t+'"'),r+=">"+n+"</a>",r}image(e,t,n){const s=g(e);if(null===s)return n;let r=`<img src="${e=s}" alt="${n}"`;return t&&(r+=` title="${t}"`),r+=">",r}text(e){return e}}class re{strong(e){return e}em(e){return e}codespan(e){return e}del(e){return e}html(e){return e}text(e){return e}link(e,t,n){return""+n}image(e,t,n){return""+n}br(){return""}}class ie{options;renderer;textRenderer;constructor(t){this.options=t||e.defaults,this.options.renderer=this.options.renderer||new se,this.renderer=this.options.renderer,this.renderer.options=this.options,this.textRenderer=new re}static parse(e,t){return new ie(t).parse(e)}static parseInline(e,t){return new ie(t).parseInline(e)}parse(e,t=!0){let n="";for(let s=0;s<e.length;s++){const r=e[s];if(this.options.extensions&&this.options.extensions.renderers&&this.options.extensions.renderers[r.type]){const e=r,t=this.options.extensions.renderers[e.type].call({parser:this},e);if(!1!==t||!["space","hr","heading","code","table","blockquote","list","html","paragraph","text"].includes(e.type)){n+=t||"";continue}}switch(r.type){case"space":continue;case"hr":n+=this.renderer.hr();continue;case"heading":{const e=r;n+=this.renderer.heading(this.parseInline(e.tokens),e.depth,p(this.parseInline(e.tokens,this.textRenderer)));continue}case"code":{const e=r;n+=this.renderer.code(e.text,e.lang,!!e.escaped);continue}case"table":{const e=r;let t="",s="";for(let t=0;t<e.header.length;t++)s+=this.renderer.tablecell(this.parseInline(e.header[t].tokens),{header:!0,align:e.align[t]});t+=this.renderer.tablerow(s);let i="";for(let t=0;t<e.rows.length;t++){const n=e.rows[t];s="";for(let t=0;t<n.length;t++)s+=this.renderer.tablecell(this.parseInline(n[t].tokens),{header:!1,align:e.align[t]});i+=this.renderer.tablerow(s)}n+=this.renderer.table(t,i);continue}case"blockquote":{const e=r,t=this.parse(e.tokens);n+=this.renderer.blockquote(t);continue}case"list":{const e=r,t=e.ordered,s=e.start,i=e.loose;let l="";for(let t=0;t<e.items.length;t++){const n=e.items[t],s=n.checked,r=n.task;let o="";if(n.task){const e=this.renderer.checkbox(!!s);i?n.tokens.length>0&&"paragraph"===n.tokens[0].type?(n.tokens[0].text=e+" "+n.tokens[0].text,n.tokens[0].tokens&&n.tokens[0].tokens.length>0&&"text"===n.tokens[0].tokens[0].type&&(n.tokens[0].tokens[0].text=e+" "+n.tokens[0].tokens[0].text)):n.tokens.unshift({type:"text",text:e+" "}):o+=e+" "}o+=this.parse(n.tokens,i),l+=this.renderer.listitem(o,r,!!s)}n+=this.renderer.list(l,t,s);continue}case"html":{const e=r;n+=this.renderer.html(e.text,e.block);continue}case"paragraph":{const e=r;n+=this.renderer.paragraph(this.parseInline(e.tokens));continue}case"text":{let i=r,l=i.tokens?this.parseInline(i.tokens):i.text;for(;s+1<e.length&&"text"===e[s+1].type;)i=e[++s],l+="\n"+(i.tokens?this.parseInline(i.tokens):i.text);n+=t?this.renderer.paragraph(l):l;continue}default:{const e='Token with "'+r.type+'" type was not found.';if(this.options.silent)return console.error(e),"";throw new Error(e)}}}return n}parseInline(e,t){t=t||this.renderer;let n="";for(let s=0;s<e.length;s++){const r=e[s];if(this.options.extensions&&this.options.extensions.renderers&&this.options.extensions.renderers[r.type]){const e=this.options.extensions.renderers[r.type].call({parser:this},r);if(!1!==e||!["escape","html","link","image","strong","em","codespan","br","del","text"].includes(r.type)){n+=e||"";continue}}switch(r.type){case"escape":{const e=r;n+=t.text(e.text);break}case"html":{const e=r;n+=t.html(e.text);break}case"link":{const e=r;n+=t.link(e.href,e.title,this.parseInline(e.tokens,t));break}case"image":{const e=r;n+=t.image(e.href,e.title,e.text);break}case"strong":{const e=r;n+=t.strong(this.parseInline(e.tokens,t));break}case"em":{const e=r;n+=t.em(this.parseInline(e.tokens,t));break}case"codespan":{const e=r;n+=t.codespan(e.text);break}case"br":n+=t.br();break;case"del":{const e=r;n+=t.del(this.parseInline(e.tokens,t));break}case"text":{const e=r;n+=t.text(e.text);break}default:{const e='Token with "'+r.type+'" type was not found.';if(this.options.silent)return console.error(e),"";throw new Error(e)}}}return n}}class le{options;constructor(t){this.options=t||e.defaults}static passThroughHooks=new Set(["preprocess","postprocess","processAllTokens"]);preprocess(e){return e}postprocess(e){return e}processAllTokens(e){return e}}class oe{defaults={async:!1,breaks:!1,extensions:null,gfm:!0,hooks:null,pedantic:!1,renderer:null,silent:!1,tokenizer:null,walkTokens:null};options=this.setOptions;parse=this.#e(ne.lex,ie.parse);parseInline=this.#e(ne.lexInline,ie.parseInline);Parser=ie;Renderer=se;TextRenderer=re;Lexer=ne;Tokenizer=w;Hooks=le;constructor(...e){this.use(...e)}walkTokens(e,t){let n=[];for(const s of e)switch(n=n.concat(t.call(this,s)),s.type){case"table":{const e=s;for(const s of e.header)n=n.concat(this.walkTokens(s.tokens,t));for(const s of e.rows)for(const e of s)n=n.concat(this.walkTokens(e.tokens,t));break}case"list":{const e=s;n=n.concat(this.walkTokens(e.items,t));break}default:{const e=s;this.defaults.extensions?.childTokens?.[e.type]?this.defaults.extensions.childTokens[e.type].forEach((s=>{const r=e[s].flat(1/0);n=n.concat(this.walkTokens(r,t))})):e.tokens&&(n=n.concat(this.walkTokens(e.tokens,t)))}}return n}use(...e){const t=this.defaults.extensions||{renderers:{},childTokens:{}};return e.forEach((e=>{const n={...e};if(n.async=this.defaults.async||n.async||!1,e.extensions&&(e.extensions.forEach((e=>{if(!e.name)throw new Error("extension name required");if("renderer"in e){const n=t.renderers[e.name];t.renderers[e.name]=n?function(...t){let s=e.renderer.apply(this,t);return!1===s&&(s=n.apply(this,t)),s}:e.renderer}if("tokenizer"in e){if(!e.level||"block"!==e.level&&"inline"!==e.level)throw new Error("extension level must be 'block' or 'inline'");const n=t[e.level];n?n.unshift(e.tokenizer):t[e.level]=[e.tokenizer],e.start&&("block"===e.level?t.startBlock?t.startBlock.push(e.start):t.startBlock=[e.start]:"inline"===e.level&&(t.startInline?t.startInline.push(e.start):t.startInline=[e.start]))}"childTokens"in e&&e.childTokens&&(t.childTokens[e.name]=e.childTokens)})),n.extensions=t),e.renderer){const t=this.defaults.renderer||new se(this.defaults);for(const n in e.renderer){if(!(n in t))throw new Error(`renderer '${n}' does not exist`);if("options"===n)continue;const s=n,r=e.renderer[s],i=t[s];t[s]=(...e)=>{let n=r.apply(t,e);return!1===n&&(n=i.apply(t,e)),n||""}}n.renderer=t}if(e.tokenizer){const t=this.defaults.tokenizer||new w(this.defaults);for(const n in e.tokenizer){if(!(n in t))throw new Error(`tokenizer '${n}' does not exist`);if(["options","rules","lexer"].includes(n))continue;const s=n,r=e.tokenizer[s],i=t[s];t[s]=(...e)=>{let n=r.apply(t,e);return!1===n&&(n=i.apply(t,e)),n}}n.tokenizer=t}if(e.hooks){const t=this.defaults.hooks||new le;for(const n in e.hooks){if(!(n in t))throw new Error(`hook '${n}' does not exist`);if("options"===n)continue;const s=n,r=e.hooks[s],i=t[s];le.passThroughHooks.has(n)?t[s]=e=>{if(this.defaults.async)return Promise.resolve(r.call(t,e)).then((e=>i.call(t,e)));const n=r.call(t,e);return i.call(t,n)}:t[s]=(...e)=>{let n=r.apply(t,e);return!1===n&&(n=i.apply(t,e)),n}}n.hooks=t}if(e.walkTokens){const t=this.defaults.walkTokens,s=e.walkTokens;n.walkTokens=function(e){let n=[];return n.push(s.call(this,e)),t&&(n=n.concat(t.call(this,e))),n}}this.defaults={...this.defaults,...n}})),this}setOptions(e){return this.defaults={...this.defaults,...e},this}lexer(e,t){return ne.lex(e,t??this.defaults)}parser(e,t){return ie.parse(e,t??this.defaults)}#e(e,t){return(n,s)=>{const r={...s},i={...this.defaults,...r};!0===this.defaults.async&&!1===r.async&&(i.silent||console.warn("marked(): The async option was set to true by an extension. The async: false option sent to parse will be ignored."),i.async=!0);const l=this.#t(!!i.silent,!!i.async);if(null==n)return l(new Error("marked(): input parameter is undefined or null"));if("string"!=typeof n)return l(new Error("marked(): input parameter is of type "+Object.prototype.toString.call(n)+", string expected"));if(i.hooks&&(i.hooks.options=i),i.async)return Promise.resolve(i.hooks?i.hooks.preprocess(n):n).then((t=>e(t,i))).then((e=>i.hooks?i.hooks.processAllTokens(e):e)).then((e=>i.walkTokens?Promise.all(this.walkTokens(e,i.walkTokens)).then((()=>e)):e)).then((e=>t(e,i))).then((e=>i.hooks?i.hooks.postprocess(e):e)).catch(l);try{i.hooks&&(n=i.hooks.preprocess(n));let s=e(n,i);i.hooks&&(s=i.hooks.processAllTokens(s)),i.walkTokens&&this.walkTokens(s,i.walkTokens);let r=t(s,i);return i.hooks&&(r=i.hooks.postprocess(r)),r}catch(e){return l(e)}}}#t(e,t){return n=>{if(n.message+="\nPlease report this to https://github.com/markedjs/marked.",e){const e="<p>An error occurred:</p><pre>"+c(n.message+"",!0)+"</pre>";return t?Promise.resolve(e):e}if(t)return Promise.reject(n);throw n}}}const ae=new oe;function ce(e,t){return ae.parse(e,t)}ce.options=ce.setOptions=function(e){return ae.setOptions(e),ce.defaults=ae.defaults,n(ce.defaults),ce},ce.getDefaults=t,ce.defaults=e.defaults,ce.use=function(...e){return ae.use(...e),ce.defaults=ae.defaults,n(ce.defaults),ce},ce.walkTokens=function(e,t){return ae.walkTokens(e,t)},ce.parseInline=ae.parseInline,ce.Parser=ie,ce.parser=ie.parse,ce.Renderer=se,ce.TextRenderer=re,ce.Lexer=ne,ce.lexer=ne.lex,ce.Tokenizer=w,ce.Hooks=le,ce.parse=ce;const he=ce.options,pe=ce.setOptions,ue=ce.use,ke=ce.walkTokens,ge=ce.parseInline,fe=ce,de=ie.parse,xe=ne.lex;e.Hooks=le,e.Lexer=ne,e.Marked=oe,e.Parser=ie,e.Renderer=se,e.TextRenderer=re,e.Tokenizer=w,e.getDefaults=t,e.lexer=xe,e.marked=ce,e.options=he,e.parse=fe,e.parseInline=ge,e.parser=de,e.setOptions=pe,e.use=ue,e.walkTokens=ke}));

// Compat shim: old code calls window.micromark(src). Delegate to marked.
window.micromark = function(src){ return window.marked.parse(src); };

"""#

let markdownRendererJS = #"""
(function(){"use strict";function w(d){const s=d.split(/\r?\n/),c=[0];let f=0;for(let e=0;e<s.length-1;e++)f+=s[e].length+1,c.push(f);function l(e){let t=0,o=c.length;for(;t<o;){const r=Math.floor((t+o)/2);c[r]<=e?t=r+1:o=r}return t}return{lineStarts:c,offsetToLine:l}}function g(d,s){if(s=s||{},s.allowHtml===!0)return;const f=["script","iframe","object","embed","style","link","base","meta"],l=/^data:image\/(png|jpeg|jpg|gif|webp|bmp|avif);base64,/i;function e(t){if(t.nodeType!==1)return;const o=t.tagName.toLowerCase();if(f.includes(o)){t.remove();return}const r=Array.from(t.attributes);for(const n of r)n.name.toLowerCase().startsWith("on")&&t.removeAttribute(n.name);const m=["href","src","formaction","action","srcdoc","xlink:href","srcset","poster","usemap","background"];for(const n of m){const a=t.getAttribute(n);if(a){const i=a.trim().toLowerCase();if(n==="srcset"){const b=i.split(",").map(h=>h.trim());let p=!0;for(const h of b){const u=h.split(/\s+/)[0];if(u.startsWith("javascript:")||u.startsWith("vbscript:")||u.startsWith("data:")&&!l.test(u)){p=!1;break}}p||t.removeAttribute(n)}else(i.startsWith("javascript:")||i.startsWith("vbscript:")||i.startsWith("data:")&&!l.test(i))&&t.removeAttribute(n)}}for(const n of Array.from(t.childNodes))e(n)}e(d)}window.renderMarkdown=function(d,s,c){if(!window.marked){console.error("marked not loaded");return}c=c||{},s.innerHTML="";const fm=/^---\r?\n[\s\S]*?\r?\n---(\r?\n|$)/.exec(d),fmLen=fm?fm[0].length:0,body=fmLen?d.slice(fmLen):d;const f=window.marked.lexer(body),{offsetToLine:l}=w(d);let e=fmLen;for(const t of f){if(t.type==="space"){e+=t.raw.length;continue}try{const o=window.marked.parser([t]),r=document.createElement("div");r.innerHTML=o,g(r,c);const m=l(e),n=l(e+t.raw.length);for(const a of r.childNodes)if(a.nodeType===1)a.setAttribute("data-src-start",String(m)),a.setAttribute("data-src-end",String(n)),s.appendChild(a);else if(a.nodeType===3&&a.textContent.trim()){const i=document.createElement("p");i.setAttribute("data-src-start",String(m)),i.setAttribute("data-src-end",String(n)),i.textContent=a.textContent,s.appendChild(i)}e+=t.raw.length}catch(o){console.error("Error rendering token",t,o);const r=document.createElement("div"),m=l(e),n=l(e+t.raw.length);r.setAttribute("data-src-start",String(m)),r.setAttribute("data-src-end",String(n)),r.style.color="red",r.textContent="Error: "+o.message,s.appendChild(r),e+=t.raw.length}}},globalThis.sanitizeMarkdownDOM=g})();

"""#


// MARK: - Embedded Editor (--editor mode)

let editorHTML = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Editor</title>
<link rel="stylesheet" href="agent://host/styles.css">
<link rel="stylesheet" href="agent://host/editor.css">
</head>
<body>
<div id="editor-app">
  <aside id="editor-sidebar">
    <div id="editor-root-name" class="editor-root-name"></div>
    <div id="editor-tree" class="editor-tree"></div>
  </aside>
  <main id="editor-main">
    <div id="editor-tabbar" class="editor-tabbar"></div>
    <div id="editor-content" class="editor-content"></div>
  </main>
</div>
<script src="agent://host/micromark.js"></script>
<script src="agent://host/markdown-renderer.js"></script>
<script src="agent://host/highlight.js"></script>
<script src="agent://host/editor.js"></script>
</body>
</html>
"""#

let editorCSS = #"""
html, body { height: 100%; padding: 0; margin: 0; overflow: hidden; }
#editor-app { display: flex; flex-direction: row; height: 100vh; width: 100vw; }
#editor-sidebar {
  width: 240px; min-width: 160px; max-width: 420px; flex: 0 0 auto;
  background: var(--surface); border-right: 1px solid var(--border);
  display: flex; flex-direction: column; overflow: hidden;
}
.editor-root-name {
  padding: 10px 12px; font-size: 11px; font-weight: 700; text-transform: uppercase;
  letter-spacing: 0.6px; color: var(--muted); border-bottom: 1px solid var(--border);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.editor-tree { flex: 1; overflow-y: auto; padding: 4px 0; font-size: 13px; }
.editor-tree-row {
  display: flex; align-items: center; gap: 6px; padding: 3px 8px;
  cursor: pointer; white-space: nowrap; user-select: none; border-radius: 4px;
}
.editor-tree-row:hover { background: var(--surface-2); }
.editor-tree-row.active { background: var(--accent); color: #fff; }
.editor-tree-icon { width: 12px; display: inline-block; color: var(--muted); font-size: 10px; flex: 0 0 auto; }
.editor-tree-row.active .editor-tree-icon { color: #fff; }
.editor-tree-label { overflow: hidden; text-overflow: ellipsis; }
.editor-tree-error { padding: 6px 12px; color: var(--danger); font-size: 11px; }
.editor-tree-children { }
#editor-main { flex: 1; display: flex; flex-direction: column; overflow: hidden; background: var(--bg); }
.editor-tabbar {
  display: flex; align-items: center; gap: 8px; padding: 6px 12px;
  border-bottom: 1px solid var(--border); min-height: 36px;
}
.editor-tab-name { font-size: 12px; color: var(--text); font-weight: 600; }
.editor-tab-btn {
  padding: 4px 12px; font-size: 11px; border: 1px solid var(--border); border-radius: 5px;
  background: var(--surface); color: var(--text); cursor: pointer;
}
.editor-tab-btn:hover:not(:disabled) { filter: brightness(1.15); }
.editor-tab-btn:disabled { opacity: 0.4; cursor: default; }
.editor-tab-btn.save-active { background: var(--success); color: #1a1a1c; border-color: transparent; }
.editor-content { flex: 1; overflow: auto; padding: 16px 20px; display: flex; flex-direction: column; }
.editor-empty { color: var(--muted); font-size: 13px; font-style: italic; }
.editor-source {
  flex: 1; width: 100%; min-height: 200px; padding: 10px 12px;
  font: 13px/1.6 'SF Mono', Monaco, Menlo, 'Courier New', monospace;
  background: var(--bg); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; resize: none; tab-size: 4;
}
.editor-source:focus { outline: none; border-color: var(--accent); }
.editor-md-tabs { display: flex; gap: 4px; margin-bottom: 10px; border-bottom: 1px solid var(--border); }
.editor-md-tab {
  padding: 5px 12px; font-size: 11px; background: transparent; border: none;
  border-bottom: 2px solid transparent; color: var(--muted); cursor: pointer;
}
.editor-md-tab:hover { color: var(--text); }
.editor-md-tab.active { color: var(--text); border-bottom-color: var(--accent); font-weight: 600; }
.editor-md-preview { flex: 1; overflow: auto; }

/* syntax highlight tokens (shared by code editor + fenced markdown blocks) */
.hl-kw { color: #ff7ab2; }
.hl-str { color: #9ee37d; }
.hl-num { color: #d0a0ff; }
.hl-com { color: #6d7686; font-style: italic; }

/* code editor: a highlighted <pre> behind a transparent-text <textarea> */
.editor-code { position: relative; flex: 1; min-height: 200px; overflow: hidden; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); }
.editor-code-hl, .editor-code-input {
  margin: 0; padding: 10px 12px; border: 0;
  font: 13px/1.6 'SF Mono', Monaco, Menlo, 'Courier New', monospace;
  tab-size: 4; white-space: pre; word-wrap: normal;
  position: absolute; inset: 0; overflow: auto;
}
.editor-code-hl { color: var(--text); pointer-events: none; z-index: 1; }
.editor-code-hl code { font: inherit; }
.editor-code-input {
  z-index: 2; resize: none; background: transparent; color: transparent;
  caret-color: var(--text); -webkit-text-fill-color: transparent;
}
.editor-code-input:focus { outline: none; }

/* frontmatter metadata block */
.editor-md-frontmatter {
  border: 1px solid var(--border); border-radius: 6px; background: var(--surface);
  padding: 8px 12px; margin-bottom: 14px; font-size: 12px;
}
.editor-fm-row { display: flex; gap: 8px; padding: 2px 0; }
.editor-fm-key { color: var(--muted); font-weight: 600; min-width: 90px; }
.editor-fm-val { color: var(--text); word-break: break-word; }

/* submit button + comment composer */
.editor-tab-btn.submit-btn { background: var(--accent); color: #fff; border-color: transparent; }
.a2ui-markdown-preview [data-has-comment], .editor-md-preview [data-has-comment] {
  background: rgba(255,193,7,0.08); border-left: 2px solid #ffc107; padding-left: 6px;
}
.editor-comment-composer {
  background: var(--surface-2); border: 1px solid var(--border); border-radius: 7px;
  padding: 8px; margin: 6px 0;
}
.editor-comment-body {
  width: 100%; padding: 6px; border: 1px solid var(--border); border-radius: 5px;
  background: var(--bg); color: var(--text); font: 12px/1.5 Monaco, monospace;
  resize: vertical; min-height: 54px; margin-bottom: 6px;
}
.editor-comment-body:focus { outline: none; border-color: var(--accent); }
.editor-comment-actions { display: flex; gap: 6px; justify-content: flex-end; }
.editor-comment-actions button {
  padding: 4px 12px; font-size: 11px; border: 1px solid var(--border); border-radius: 5px;
  background: var(--surface); color: var(--text); cursor: pointer;
}
.editor-comment-actions button.save { background: var(--success); color: #1a1a1c; border-color: transparent; }
.editor-comment-actions button:disabled { opacity: 0.5; cursor: not-allowed; }
"""#

// Compact, dependency-free syntax highlighter. A single generic scanner is
// driven by a per-language config (keyword set, comment delimiters, string
// quotes). Returns an HTML string of escaped text with <span class="hl-*">
// wrappers, or null for an unknown language (caller falls back to plain text).
// Kept deliberately small to protect the tiny-binary identity — this is not a
// full grammar engine, just enough to make code readable.
let highlightJS = #"""
(function(){
  'use strict';

  // Shared keyword groups.
  var JS = "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set null undefined true false NaN Infinity";
  var configs = {
    javascript: { kw: JS + " implements interface enum type namespace declare readonly public private protected as is keyof infer", line: "//", block: ["/*", "*/"], strings: ["'", '"', "`"] },
    python:     { kw: "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self print", line: "#", block: null, strings: ["'", '"'] },
    go:         { kw: "break default func interface select case defer go map struct chan else goto package switch const fallthrough if range type continue for import return var nil true false iota string int int64 bool byte rune error", line: "//", block: ["/*", "*/"], strings: ['"', "`"] },
    rust:       { kw: "as break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while async await dyn", line: "//", block: ["/*", "*/"], strings: ['"'] },
    swift:      { kw: "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as catch is nil super self throw throws try true false weak unowned lazy", line: "//", block: ["/*", "*/"], strings: ['"'] },
    clike:      { kw: "auto break case char const continue default do double else enum extern float for goto if int long register return short signed sizeof static struct switch typedef union unsigned void volatile while class public private protected virtual override new delete this true false nullptr namespace template typename using bool string", line: "//", block: ["/*", "*/"], strings: ['"', "'"] },
    json:       { kw: "true false null", line: null, block: null, strings: ['"'] },
    yaml:       { kw: "true false null yes no on off", line: "#", block: null, strings: ['"', "'"] },
    bash:       { kw: "if then else elif fi case esac for while do done in function return local export readonly declare echo cd exit source set unset trap", line: "#", block: null, strings: ['"', "'"] },
    sql:        { kw: "SELECT FROM WHERE INSERT UPDATE DELETE CREATE DROP ALTER TABLE INDEX VIEW JOIN LEFT RIGHT INNER OUTER ON AS AND OR NOT NULL IS IN LIKE BETWEEN GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT COUNT SUM AVG MIN MAX INTO VALUES SET PRIMARY KEY FOREIGN REFERENCES DEFAULT", line: "--", block: ["/*", "*/"], strings: ["'"] },
    css:        { kw: "important inherit initial unset none auto flex grid block inline absolute relative fixed sticky", line: null, block: ["/*", "*/"], strings: ['"', "'"] }
  };

  var EXT = {
    js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript",
    ts: "javascript", tsx: "javascript", py: "python", go: "go", rs: "rust",
    swift: "swift", json: "json", yml: "yaml", yaml: "yaml", sh: "bash",
    bash: "bash", zsh: "bash", c: "clike", h: "clike", cpp: "clike", cc: "clike",
    cxx: "clike", hpp: "clike", java: "clike", cs: "clike", kt: "clike",
    css: "css", scss: "css", sql: "sql", toml: "yaml", ini: "yaml"
  };

  function esc(s){ return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function span(cls, txt){ return '<span class="hl-' + cls + '">' + esc(txt) + '</span>'; }
  function isWordStart(c){ return /[A-Za-z_$]/.test(c); }
  function isWord(c){ return /[A-Za-z0-9_$]/.test(c); }

  function resolveLang(lang){
    if (!lang) return null;
    var key = String(lang).toLowerCase();
    if (configs[key]) return key;
    if (EXT[key]) return EXT[key];
    return null;
  }

  // lang may be a language name OR a filename — both are resolved.
  window.highlightCode = function(code, lang){
    var key = resolveLang(lang);
    if (!key) {
      // Maybe `lang` is a filename — try its extension.
      var dot = String(lang || "").lastIndexOf(".");
      if (dot >= 0) key = resolveLang(String(lang).slice(dot + 1));
    }
    var cfg = key && configs[key];
    if (!cfg) return null;
    var kwset = new Set(cfg.kw.split(/\s+/));
    var out = "";
    var i = 0;
    var n = code.length;
    var prevWord = false;
    while (i < n) {
      var c = code[i];
      if (cfg.line && code.startsWith(cfg.line, i)) {
        var j = code.indexOf("\n", i); if (j < 0) j = n;
        out += span("com", code.slice(i, j)); i = j; prevWord = false; continue;
      }
      if (cfg.block && code.startsWith(cfg.block[0], i)) {
        var k = code.indexOf(cfg.block[1], i + cfg.block[0].length);
        k = k < 0 ? n : k + cfg.block[1].length;
        out += span("com", code.slice(i, k)); i = k; prevWord = false; continue;
      }
      if (cfg.strings && cfg.strings.indexOf(c) >= 0) {
        var q = c; var p = i + 1;
        while (p < n) { if (code[p] === "\\") { p += 2; continue; } if (code[p] === q) { p++; break; } p++; }
        out += span("str", code.slice(i, p)); i = p; prevWord = false; continue;
      }
      if (/[0-9]/.test(c) && !prevWord) {
        var m = i; while (m < n && /[0-9a-fA-FxXoObB._]/.test(code[m])) m++;
        out += span("num", code.slice(i, m)); i = m; prevWord = false; continue;
      }
      if (isWordStart(c)) {
        var w = i; while (w < n && isWord(code[w])) w++;
        var word = code.slice(i, w);
        out += kwset.has(word) ? span("kw", word) : esc(word);
        i = w; prevWord = true; continue;
      }
      out += esc(c); i++; prevWord = isWord(c);
    }
    return out;
  };

  // Map a filename/extension to a language name (or null).
  window.highlightLangFor = function(name){ return resolveLang(name) || (function(){
    var dot = String(name || "").lastIndexOf("."); return dot >= 0 ? resolveLang(String(name).slice(dot + 1)) : null;
  })(); };

  // Highlight fenced code blocks (<pre><code class="language-x">) inside a
  // rendered markdown container, in place.
  window.highlightCodeBlocks = function(container){
    var blocks = container.querySelectorAll("pre > code");
    for (var b = 0; b < blocks.length; b++) {
      var codeEl = blocks[b];
      var cls = codeEl.className || "";
      var match = /language-([\w+-]+)/.exec(cls);
      var lang = match ? match[1] : null;
      var html = window.highlightCode(codeEl.textContent, lang);
      if (html != null) { codeEl.innerHTML = html; codeEl.classList.add("hl"); }
    }
  };
})();
"""#

let editorJS = #"""
(function(){
  'use strict';
  let ROOT = '';
  let opSeq = 0;
  const opCb = new Map();

  // ---- fileOp bridge (JS -> Swift -> __fileOpReply) ----
  function fileOp(op, path, content){
    return new Promise((resolve) => {
      const id = ++opSeq;
      const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fileOp;
      if (mh) {
        opCb.set(id, resolve);
        mh.postMessage({ id: id, op: op, path: path, content: content == null ? null : content });
      } else if (window.__fileOpMock) {
        // jsdom / test path: a mock services the request synchronously or via promise.
        Promise.resolve(window.__fileOpMock(op, path, content)).then(resolve);
      } else {
        resolve({ ok: false, error: 'no bridge' });
      }
    });
  }
  window.__fileOpReply = function(id, json){
    const cb = opCb.get(id);
    if (!cb) return;
    opCb.delete(id);
    let r;
    try { r = JSON.parse(json); } catch(e) { r = { ok: false, error: 'bad reply json' }; }
    cb(r);
  };
  window.__editorFileOp = fileOp;  // exposed for tests

  function el(tag, cls, txt){
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (txt != null) e.textContent = txt;
    return e;
  }

  // ---- link handling ----
  function openExternal(url){
    const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.openExternal;
    if (mh) mh.postMessage({ url: url });
    else if (window.__openExternalMock) window.__openExternalMock(url);
  }

  // Resolve a relative href against the directory of `fromFile` (POSIX-style,
  // collapsing . and ..). The Swift FileService re-checks scoping, so an
  // escaping result simply fails to open rather than reaching outside root.
  function resolvePath(fromFile, rel){
    const baseParts = (fromFile || '').split('/');
    baseParts.pop();  // drop the filename, keep the directory
    if (rel.charAt(0) === '/') { baseParts.length = 0; rel = rel.slice(1); }  // root-relative
    for (const p of rel.split('/')) {
      if (p === '' || p === '.') continue;
      if (p === '..') { if (baseParts.length) baseParts.pop(); }
      else baseParts.push(p);
    }
    return baseParts.join('/');
  }
  window.__editorResolvePath = resolvePath;  // exposed for tests

  function handleLink(href, fromFile){
    if (!href) return;
    if (href.charAt(0) === '#') return;  // in-page anchor — let the browser handle
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) {
      // Has a scheme → external. Only http(s) are opened in the system browser.
      const scheme = href.slice(0, href.indexOf(':')).toLowerCase();
      if (scheme === 'http' || scheme === 'https') openExternal(href);
      return;
    }
    // Relative path → open in the editor (strip any #fragment / ?query first).
    const clean = href.split('#')[0].split('?')[0];
    if (clean) openFile(resolvePath(fromFile, clean));
  }
  window.__editorHandleLink = handleLink;  // exposed for tests

  // ---- frontmatter (rendered as a metadata block, not vanished) ----
  // renderMarkdown strips the YAML frontmatter from the preview body; we
  // surface it here as a key/value block pinned to the top of the preview.
  function renderFrontmatterInto(text, preview){
    const m = /^---\r?\n([\s\S]*?)\r?\n---(\r?\n|$)/.exec(text);
    if (!m) return;
    const box = el('div', 'editor-md-frontmatter');
    for (const line of m[1].split(/\r?\n/)) {
      const idx = line.indexOf(':');
      if (idx < 0) continue;
      const key = line.slice(0, idx).trim();
      if (!key) continue;
      const row = el('div', 'editor-fm-row');
      row.appendChild(el('span', 'editor-fm-key', key));
      row.appendChild(el('span', 'editor-fm-val', line.slice(idx + 1).trim()));
      box.appendChild(row);
    }
    if (box.children.length) preview.insertBefore(box, preview.firstChild);
  }
  window.__editorRenderFrontmatter = renderFrontmatterInto;  // exposed for tests

  // ---- comments + submit (preserves the markdown-review return-to-Claude flow) ----
  let COMMENTS = false;
  const fileComments = {};  // path -> [ {source_line_start, source_line_end, quoted_text, body} ]
  function commentsFor(path){ return fileComments[path] || (fileComments[path] = []); }
  function allComments(){
    const out = [];
    for (const p in fileComments) for (const c of fileComments[p]) out.push(Object.assign({ file: p }, c));
    return out;
  }
  window.__editorAllComments = allComments;  // exposed for tests

  function openComposer(block, path, preview){
    if (preview.querySelector('.editor-comment-composer')) preview.querySelector('.editor-comment-composer').remove();
    const startLine = parseInt(block.dataset.srcStart, 10);
    const endLine = parseInt(block.dataset.srcEnd, 10);
    let quoted = (block.textContent || '').trim().split('\n')[0];
    if (quoted.length > 200) quoted = quoted.slice(0, 200);
    const composer = el('div', 'editor-comment-composer');
    const ta = el('textarea', 'editor-comment-body'); ta.placeholder = 'Add a comment…';
    composer.appendChild(ta);
    const actions = el('div', 'editor-comment-actions');
    const cancel = el('button', null, 'Cancel');
    cancel.addEventListener('click', () => composer.remove());
    const save = el('button', 'save', 'Save'); save.disabled = true;
    ta.addEventListener('input', () => { save.disabled = !ta.value.trim(); });
    ta.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); composer.remove(); }
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !save.disabled) { e.preventDefault(); save.click(); }
    });
    save.addEventListener('click', () => {
      const body = ta.value.trim(); if (!body) return;
      commentsFor(path).push({ source_line_start: startLine, source_line_end: endLine, quoted_text: quoted, body: body });
      block.setAttribute('data-has-comment', 'true');
      composer.remove();
      renderTabbar(current.path, current.dirty);  // refresh Submit count
    });
    actions.appendChild(cancel); actions.appendChild(save);
    composer.appendChild(actions);
    block.insertAdjacentElement('afterend', composer);
    ta.focus();
  }
  window.__editorOpenComposer = openComposer;  // exposed for tests

  function attachComments(preview, path){
    preview.addEventListener('click', (e) => {
      if (e.target.closest('a')) return;                       // links win
      if (e.target.closest('.editor-comment-composer')) return;
      const sel = window.getSelection && window.getSelection();
      if (sel && !sel.isCollapsed && sel.toString().trim()) return;  // don't hijack selection
      const block = e.target.closest('[data-src-start]');
      if (block) openComposer(block, path, preview);
    });
  }

  function submitToClaude(){
    const payload = {
      action: 'submit',
      file: current.path,
      edited_text: current.getText ? current.getText() : '',
      comments: allComments()
    };
    const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.complete;
    if (mh) mh.postMessage(payload);
    else if (window.__completeMock) window.__completeMock(payload);
  }
  window.__editorSubmit = submitToClaude;  // exposed for tests

  // ---- file tree (lazy-expanding) ----
  const expanded = new Set();
  async function buildTreeLevel(path, container, depth){
    const res = await fileOp('listDir', path);
    if (!res || !res.ok) {
      container.appendChild(el('div', 'editor-tree-error', '! ' + ((res && res.error) || 'error')));
      return;
    }
    for (const entry of res.entries) {
      const row = el('div', 'editor-tree-row ' + (entry.type === 'dir' ? 'is-dir' : 'is-file'));
      row.style.paddingLeft = (depth * 12 + 8) + 'px';
      row.dataset.path = entry.path;
      row.dataset.type = entry.type;
      const icon = el('span', 'editor-tree-icon', entry.type === 'dir' ? '▸' : '·');
      row.appendChild(icon);
      row.appendChild(el('span', 'editor-tree-label', entry.name));
      container.appendChild(row);
      if (entry.type === 'dir') {
        const kids = el('div', 'editor-tree-children');
        kids.style.display = 'none';
        container.appendChild(kids);
        row.addEventListener('click', async (e) => {
          e.stopPropagation();
          if (expanded.has(entry.path)) {
            expanded.delete(entry.path); kids.style.display = 'none'; icon.textContent = '▸';
          } else {
            expanded.add(entry.path); kids.style.display = ''; icon.textContent = '▾';
            if (!kids.dataset.loaded) { kids.dataset.loaded = '1'; await buildTreeLevel(entry.path, kids, depth + 1); }
          }
        });
      } else {
        row.addEventListener('click', (e) => { e.stopPropagation(); openFile(entry.path); });
      }
    }
  }
  async function renderTree(){
    const tree = document.getElementById('editor-tree');
    tree.innerHTML = '';
    await buildTreeLevel('', tree, 0);
  }
  window.__editorRenderTree = renderTree;  // exposed for tests

  // ---- open / edit / save ----
  const MD_EXT = /\.(md|markdown|mdown|mkd|mdx)$/i;
  let current = { path: null, original: '', dirty: false, getText: null };

  function markActive(path){
    document.querySelectorAll('.editor-tree-row.is-file').forEach(r => {
      r.classList.toggle('active', r.dataset.path === path);
    });
  }

  function renderTabbar(path, dirty){
    const bar = document.getElementById('editor-tabbar');
    bar.innerHTML = '';
    if (!path) return;
    const name = path.split('/').pop();
    bar.appendChild(el('span', 'editor-tab-name', (dirty ? '● ' : '') + name));
    const spacer = el('span', 'editor-tab-spacer'); spacer.style.flex = '1'; bar.appendChild(spacer);
    const save = el('button', 'editor-tab-btn' + (dirty ? ' save-active' : ''), 'Save');
    save.title = 'Save (⌘S)';
    save.disabled = !dirty;
    save.addEventListener('click', saveCurrent);
    bar.appendChild(save);
    if (COMMENTS) {
      const n = allComments().length;
      const submit = el('button', 'editor-tab-btn submit-btn', 'Submit' + (n ? ' (' + n + ')' : ''));
      submit.title = 'Submit comments to Claude and close (⌘↵)';
      submit.addEventListener('click', submitToClaude);
      bar.appendChild(submit);
    }
  }

  function setDirty(d){ current.dirty = d; renderTabbar(current.path, d); }

  async function saveCurrent(){
    if (!current.path || !current.dirty) return;
    const text = current.getText ? current.getText() : current.original;
    const res = await fileOp('writeFile', current.path, text);
    if (res && res.ok) { current.original = text; setDirty(false); }
    else { console.error('save failed', res); }
  }
  window.__editorSave = saveCurrent;  // exposed for tests

  function openText(path, text, content){
    const ta = el('textarea', 'editor-source');
    ta.value = text; ta.spellcheck = false;
    ta.addEventListener('input', () => setDirty(ta.value !== current.original));
    current.getText = () => ta.value;
    content.appendChild(ta);
    renderTabbar(path, false);
    ta.focus();
  }

  // Highlighted code editor: a read-painted <pre> sits behind a transparent
  // <textarea> so editing stays native while tokens are colored live.
  function openCode(path, text, content, lang){
    const wrap = el('div', 'editor-code');
    const pre = el('pre', 'editor-code-hl'); pre.setAttribute('aria-hidden', 'true');
    const codeEl = el('code');
    pre.appendChild(codeEl);
    const ta = el('textarea', 'editor-code-input'); ta.value = text; ta.spellcheck = false;
    function escapeHtml(s){ return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
    function paint(){
      const html = window.highlightCode ? window.highlightCode(ta.value, lang) : null;
      // Trailing newline keeps the last line scroll-aligned with the textarea.
      codeEl.innerHTML = (html != null ? html : escapeHtml(ta.value)) + '\n';
    }
    paint();
    ta.addEventListener('input', () => { paint(); setDirty(ta.value !== current.original); });
    ta.addEventListener('scroll', () => { pre.scrollTop = ta.scrollTop; pre.scrollLeft = ta.scrollLeft; });
    current.getText = () => ta.value;
    wrap.appendChild(pre); wrap.appendChild(ta);
    content.appendChild(wrap);
    renderTabbar(path, false);
    ta.focus();
  }

  function openMarkdown(path, text, content){
    const tabs = el('div', 'editor-md-tabs');
    const tPrev = el('button', 'editor-md-tab active', 'Preview'); tPrev.dataset.tab = 'preview';
    const tSrc = el('button', 'editor-md-tab', 'Source'); tSrc.dataset.tab = 'source';
    tabs.appendChild(tPrev); tabs.appendChild(tSrc);
    content.appendChild(tabs);
    const preview = el('div', 'editor-md-preview a2ui-markdown-preview');
    const ta = el('textarea', 'editor-source'); ta.value = text; ta.spellcheck = false; ta.style.display = 'none';
    content.appendChild(preview); content.appendChild(ta);
    // Intercept link clicks: external → system browser, internal → open in editor.
    // Without this, a relative href resolves to agent://host/... and WKWebView
    // would try to navigate, blowing away the renderer.
    preview.addEventListener('click', (e) => {
      const a = e.target.closest('a');
      if (!a) return;
      e.preventDefault();
      handleLink(a.getAttribute('href') || '', path);
    });
    function rerender(){
      if (window.renderMarkdown) window.renderMarkdown(ta.value, preview, {});
      if (window.highlightCodeBlocks) window.highlightCodeBlocks(preview);
      renderFrontmatterInto(ta.value, preview);
    }
    rerender();
    if (COMMENTS) attachComments(preview, path);
    ta.addEventListener('input', () => setDirty(ta.value !== current.original));
    current.getText = () => ta.value;
    function switchTab(name){
      if (name === 'preview') {
        rerender();
        preview.style.display = ''; ta.style.display = 'none';
        tPrev.classList.add('active'); tSrc.classList.remove('active');
      } else {
        preview.style.display = 'none'; ta.style.display = '';
        tSrc.classList.add('active'); tPrev.classList.remove('active');
      }
    }
    tPrev.addEventListener('click', () => switchTab('preview'));
    tSrc.addEventListener('click', () => switchTab('source'));
    renderTabbar(path, false);
  }

  async function openFile(path){
    const res = await fileOp('readFile', path);
    const content = document.getElementById('editor-content');
    content.innerHTML = '';
    if (!res || !res.ok) {
      content.appendChild(el('div', 'editor-empty',
        ((res && res.binary) ? 'Binary or oversized file: ' : 'Cannot open: ') + ((res && res.error) || path)));
      current = { path: null, original: '', dirty: false, getText: null };
      renderTabbar(null, false);
      return;
    }
    current = { path: path, original: res.content, dirty: false, getText: null };
    markActive(path);
    if (MD_EXT.test(path)) {
      openMarkdown(path, res.content, content);
    } else {
      const lang = window.highlightLangFor ? window.highlightLangFor(path) : null;
      if (lang) openCode(path, res.content, content, lang);
      else openText(path, res.content, content);
    }
  }
  window.__editorOpenFile = openFile;  // exposed for tests
  window.__editorCurrent = () => current;  // exposed for tests

  // ---- boot ----
  window.__editorBoot = function(json){
    let info;
    try { info = JSON.parse(json); } catch(e) { info = {}; }
    ROOT = info.root || '';
    COMMENTS = info.comments === true;
    const rn = document.getElementById('editor-root-name');
    if (rn) rn.textContent = ROOT || '/';
    renderTree().then(() => { if (info.initialFile) openFile(info.initialFile); });
  };

  // Global Cmd/Ctrl+S to save; Cmd/Ctrl+Enter to submit (comments mode).
  document.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
      e.preventDefault();
      saveCurrent();
    }
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && COMMENTS) {
      // Let an open comment composer handle its own Cmd+Enter (save comment).
      if (document.activeElement && document.activeElement.classList.contains('editor-comment-body')) return;
      e.preventDefault();
      submitToClaude();
    }
  });
})();
"""#


// MARK: - Main

guard let config = parseArgs() else {
    printUsage()
    exit(3)
}

func makeAppIcon() -> NSImage {
    let size: CGFloat = 256
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    // Folder body
    let folderColor = NSColor(red: 0.35, green: 0.60, blue: 1.0, alpha: 1.0)
    let folderDark = NSColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1.0)

    // Tab
    ctx.setFillColor(folderColor.cgColor)
    let tab = CGMutablePath()
    tab.move(to: CGPoint(x: 24, y: 200))
    tab.addLine(to: CGPoint(x: 24, y: 218))
    tab.addQuadCurve(to: CGPoint(x: 36, y: 228), control: CGPoint(x: 24, y: 228))
    tab.addLine(to: CGPoint(x: 100, y: 228))
    tab.addLine(to: CGPoint(x: 116, y: 210))
    tab.addLine(to: CGPoint(x: 24, y: 210))
    tab.closeSubpath()
    ctx.addPath(tab)
    ctx.fillPath()

    // Body
    let body = CGRect(x: 24, y: 56, width: 208, height: 160)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.setFillColor(folderColor.cgColor)
    ctx.addPath(bodyPath)
    ctx.fillPath()

    // Inner shade
    let inner = CGRect(x: 24, y: 56, width: 208, height: 120)
    let innerPath = CGPath(roundedRect: inner, cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.setFillColor(folderDark.cgColor)
    ctx.addPath(innerPath)
    ctx.fillPath()

    // Eye/lens — a circle with a small handle
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(10)
    ctx.strokeEllipse(in: CGRect(x: 84, y: 98, width: 72, height: 72))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 146, y: 108))
    ctx.addLine(to: CGPoint(x: 170, y: 82))
    ctx.strokePath()

    // Small dot highlight on lens
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
    ctx.fillEllipse(in: CGRect(x: 100, y: 146, width: 14, height: 14))

    img.unlockFocus()
    return img
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.applicationIconImage = makeAppIcon()

let coordinator = AppCoordinator(config: config)
let delegate = AppDelegate(coordinator: coordinator)
let keyMonitor = KeyEventMonitor(coordinator: coordinator)
_ = keyMonitor

app.delegate = delegate
app.run()
