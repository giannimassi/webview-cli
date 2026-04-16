import AppKit
import WebKit

// MARK: - CLI Argument Parsing

struct Config {
    var url: String = ""
    var title: String = "webview-cli"
    var width: Int = 1024
    var height: Int = 768
    var timeout: Int = 0 // 0 = no timeout
}

func parseArgs() -> Config? {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--url":
            i += 1
            guard i < args.count else { return nil }
            config.url = args[i]
        case "--title":
            i += 1
            guard i < args.count else { return nil }
            config.title = args[i]
        case "--width":
            i += 1
            guard i < args.count else { return nil }
            config.width = Int(args[i]) ?? 1024
        case "--height":
            i += 1
            guard i < args.count else { return nil }
            config.height = Int(args[i]) ?? 768
        case "--timeout":
            i += 1
            guard i < args.count else { return nil }
            config.timeout = Int(args[i]) ?? 0
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            // If no flag prefix, treat as positional URL
            if config.url.isEmpty && !args[i].hasPrefix("-") {
                config.url = args[i]
            } else {
                writeStderr("Unknown argument: \(args[i])")
                return nil
            }
        }
        i += 1
    }
    if config.url.isEmpty {
        return nil
    }
    return config
}

func printUsage() {
    let usage = """
    Usage: webview-cli --url <url> [options]

    Opens a native macOS webview. The page signals completion by calling:
      window.webkit.messageHandlers.complete.postMessage({...})

    The JSON payload is written to stdout and the process exits.

    Options:
      --url <url>        URL to open (required, or pass as first positional arg)
      --title <title>    Window title (default: "webview-cli")
      --width <px>       Window width (default: 1024)
      --height <px>      Window height (default: 768)
      --timeout <sec>    Session timeout in seconds, 0=none (default: 0)
      --help, -h         Show this help

    Exit codes:
      0  Completed (data in stdout JSON)
      1  Cancelled (user closed window or pressed Escape)
      2  Timeout
      3  Error (load failure, invalid URL)

    Stdout contract (single JSON line):
      {"status":"completed","data":{...}}
      {"status":"cancelled"}
      {"status":"timeout"}
      {"status":"error","message":"..."}
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
    if let data = data {
        result["data"] = data
    }
    if let message = message {
        result["message"] = message
    }
    if let jsonData = try? JSONSerialization.data(withJSONObject: result),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        writeStdout(jsonString)
    }
}

// MARK: - App Coordinator

class AppCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let config: Config
    var window: NSWindow!
    var webView: WKWebView!
    var hasEmitted = false
    var timeoutTimer: Timer?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func run() {
        // Configure WKWebView with message handlers
        let webConfig = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "complete")
        contentController.add(self, name: "ready")

        // Inject window.onerror handler to capture JS errors to stderr
        let errorScript = WKUserScript(
            source: """
            window.onerror = function(msg, url, line, col, error) {
                window.webkit.messageHandlers.complete.postMessage({
                    __webview_cli_error: true,
                    message: msg,
                    url: url,
                    line: line,
                    col: col
                });
                return false;
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(errorScript)
        webConfig.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = self

        // Create window
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let windowRect = NSRect(
            x: (screenFrame.width - CGFloat(config.width)) / 2 + screenFrame.origin.x,
            y: (screenFrame.height - CGFloat(config.height)) / 2 + screenFrame.origin.y,
            width: CGFloat(config.width),
            height: CGFloat(config.height)
        )

        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = config.title
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Load URL
        guard let url = URL(string: config.url), url.scheme != nil else {
            emitAndExit(status: "error", message: "Invalid URL (must include scheme like http:// or file://): \(config.url)", code: 3)
            return
        }
        webView.load(URLRequest(url: url))

        // Show window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start timeout timer if configured
        if config.timeout > 0 {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.timeout), repeats: false) { [weak self] _ in
                self?.handleTimeout()
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "complete":
            // Check if this is a JS error forwarded by our onerror handler
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

        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

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

    // MARK: - Timeout

    func handleTimeout() {
        emitAndExit(status: "timeout", code: 2)
    }

    // MARK: - Exit

    func emitAndExit(status: String, data: Any? = nil, message: String? = nil, code: Int32) {
        guard !hasEmitted else { return }
        hasEmitted = true
        timeoutTimer?.invalidate()
        emitResult(status: status, data: data, message: message)
        // Use exit() directly — NSApp.terminate calls exit(0) which loses our code
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
        // Safety net: if we're terminating without having emitted, emit cancelled
        if !coordinator.hasEmitted {
            coordinator.hasEmitted = true
            emitResult(status: "cancelled")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return false // We handle window close ourselves
    }
}

// MARK: - Escape Key Handler

class KeyEventMonitor {
    var monitor: Any?
    weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                self?.coordinator?.emitAndExit(status: "cancelled", code: 1)
                return nil
            }
            return event
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

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
_ = keyMonitor // Keep alive

app.delegate = delegate
app.run()
