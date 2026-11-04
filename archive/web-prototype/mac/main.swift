// LED Wall Tool — native macOS shell.
// A single WKWebView serving the bundled web core over a private `ledwall://` scheme,
// plus native Save / Open / Print and JS alert/confirm.

import Cocoa
import WebKit
import UniformTypeIdentifiers

final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    static let mime: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "wasm": "application/wasm",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let type = Self.mime[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!

    func applicationDidFinishLaunching(_ n: Notification) {
        let root = Bundle.main.resourceURL!.appendingPathComponent("app")
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(BundleSchemeHandler(root: root), forURLScheme: "ledwall")
        cfg.userContentController.add(self, name: "native")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Lets the CSS switch to native-shell styling (transparent sidebar over real vibrancy).
        cfg.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('mac-native')", injectionTime: .atDocumentStart, forMainFrameOnly: true))

        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground") // transparent where the page is, so the sidebar material shows
        if #available(macOS 13.3, *) { web.isInspectable = true }

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let size = NSSize(width: min(1600, screen.width * 0.92), height: min(1000, screen.height * 0.92))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "LED Wall Tool"
        window.minSize = NSSize(width: 1000, height: 640)
        // Title bar blends into the web toolbar: same colour as CSS --chrome, no separator.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // project name is shown (and editable) in the toolbar
        if #available(macOS 11.0, *) { window.titlebarSeparatorStyle = .none }
        window.backgroundColor = NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2b / 255, green: 0x2b / 255, blue: 0x2d / 255, alpha: 1)
                : NSColor(srgbRed: 0xec / 255, green: 0xec / 255, blue: 0xec / 255, alpha: 1)
        }
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        web.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: material.leadingAnchor), web.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            web.topAnchor.constraint(equalTo: material.topAnchor), web.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        window.contentView = material
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)

        web.load(URLRequest(url: URL(string: "ledwall://app/index.html")!))
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: JS bridge
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let id = body["id"] as? Int ?? 0
        switch cmd {
        case "save":
            let panel = NSSavePanel()
            panel.nameFieldStringValue = body["name"] as? String ?? "untitled"
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { resp in
                guard resp == .OK, let url = panel.url,
                      let b64 = body["b64"] as? String, let data = Data(base64Encoded: b64) else {
                    self.reply(id, ok: false, "cancelled"); return
                }
                do { try data.write(to: url); self.reply(id, ok: true, url.path) }
                catch { self.reply(id, ok: false, error.localizedDescription) }
            }
        case "print":
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = NSSize(width: 17 * 72, height: 11 * 72)
            info.orientation = .landscape
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            let op = web.printOperation(with: info)
            op.view?.frame = web.bounds
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        case "title":
            let t = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            window.title = t.isEmpty ? "LED Wall Tool" : t
        default: break
        }
    }

    func reply(_ id: Int, ok: Bool, _ value: String) {
        let v = (try? String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)) ?? "[\"\"]"
        web.evaluateJavaScript("window.__nativeReply(\(id), \(ok), \(v)[0])")
    }

    // MARK: WKUIDelegate — file inputs, alert, confirm
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    // MARK: Menu
    @objc func jsAct(_ sender: NSMenuItem) {
        guard let act = sender.representedObject as? String else { return }
        web.evaluateJavaScript("document.querySelector('[data-act=\"\(act)\"]')?.click()")
    }
    @objc func reload(_ s: Any?) { web.reload() }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(); let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            it.submenu = m; main.addItem(it)
        }
        func js(_ t: String, _ act: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: #selector(jsAct(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.representedObject = act; i.target = self
            return i
        }
        sub("LED Wall Tool", [
            NSMenuItem(title: "About LED Wall Tool", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: "Quit LED Wall Tool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        sub("File", [
            js("New Project", "new"), js("Open…", "open", "o"), js("Save…", "save", "s"), .separator(),
            js("Print Drawings…", "print", "p"), js("Export Drawings (HTML)…", "exp-drawings-html"),
            js("Export Pixel Map…", "exp-pixelmap"), js("Export Resource Report (CSV)…", "exp-csv"),
        ])
        sub("Edit", [
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        let rl = NSMenuItem(title: "Reload", action: #selector(reload(_:)), keyEquivalent: "r"); rl.target = self
        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        sub("View", [rl, fs])
        sub("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ])
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
