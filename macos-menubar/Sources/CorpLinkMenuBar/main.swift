import AppKit
import UniformTypeIdentifiers
import WebKit

enum VPNState: String {
    case disconnected, connecting, verifying, connected, intranet, stopping
    case unavailable
}

@main
enum CorpLinkMenuBar {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var webView: WKWebView?
    private let backend = BackendController()
    private var toggleItem: NSMenuItem!
    private var refreshTimer: Timer?
    private var vpnState: VPNState = .unavailable
    private var refreshSequence = 0
    private var actionInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        backend.onReady = { [weak self] in
            self?.openWindow()
            self?.refreshStatus()
        }
        backend.onError = { [weak self] message in
            self?.showMessage(message)
        }
        backend.startIfPossible()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        backend.shutdown()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = ""
            button.image = NSImage(systemSymbolName: "xmark.shield", accessibilityDescription: "CorpLink VPN")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "CorpLink · 服务不可用"
        }

        let menu = NSMenu()
        menu.delegate = self
        let openItem = NSMenuItem(title: "打开管理窗口", action: #selector(openClicked), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        toggleItem = NSMenuItem(title: "VPN 服务不可用", action: #selector(toggleVPNClicked), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = false
        menu.addItem(toggleItem)
        let configItem = NSMenuItem(title: "选择默认配置…", action: #selector(chooseConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())
        let chooseItem = NSMenuItem(title: "选择 corplink-rs 程序…", action: #selector(chooseBinary), keyEquivalent: "")
        chooseItem.target = self
        menu.addItem(chooseItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 CorpLink", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openClicked() { openWindow() }

    @objc private func toggleVPNClicked() {
        guard !actionInFlight else { return }
        let action: String
        let body: [String: String]
        switch vpnState {
        case .disconnected:
            action = "start"
            body = ["name": "default"]
        case .connecting, .verifying, .connected, .intranet:
            action = "stop"
            body = [:]
        case .stopping, .unavailable:
            return
        }
        actionInFlight = true
        refreshSequence += 1
        applyStatus(action == "start" ? .connecting : .stopping)
        backend.perform(action, body: body) { [weak self] result in
            DispatchQueue.main.async {
                self?.actionInFlight = false
                if case .failure(let error) = result { self?.showMessage(error.localizedDescription) }
                self?.refreshStatus()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }

    @objc private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = "选择 CorpLink 客户端程序"
        panel.message = "选择已编译的 corplink-rs 可执行文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backend.setExecutable(url)
            backend.startIfPossible()
        }
    }

    @objc private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.title = "选择 CorpLink 配置文件"
        panel.message = "选择 JSON 格式的配置文件，也支持 config.json.bj 等文件名。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard let data = try? Data(contentsOf: url),
                  let content = try? JSONSerialization.jsonObject(with: data),
                  content is [String: Any] else {
                showMessage("配置文件必须是可读取的 JSON 对象。")
                return
            }
            backend.setConfig(url)
            backend.restart()
        }
    }

    @objc private func quitClicked() {
        backend.perform("shutdown") { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
    }

    private func openWindow() {
        guard let url = backend.url else {
            showMessage("正在启动本机管理服务，请稍候。")
            return
        }
        if window == nil {
            let configuration = WKWebViewConfiguration()
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.uiDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "CorpLink"
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 780, height: 620)
            window.center()
            window.contentView = view
            window.delegate = self
            self.webView = view
            self.window = window
        }
        if webView?.url?.absoluteString != url.absoluteString {
            webView?.load(URLRequest(url: url))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.alertStyle = .informational
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: defaultText ?? "")
        input.placeholderString = "英文、数字、- 或 _"
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(input.stringValue)
        } else {
            completionHandler(nil)
        }
    }

    private func refreshStatus() {
        guard !actionInFlight else { return }
        refreshSequence += 1
        let sequence = refreshSequence
        backend.readState { [weak self] state, ready in
            DispatchQueue.main.async {
                guard let self, sequence == self.refreshSequence else { return }
                self.applyStatus(ready ? state : .unavailable)
            }
        }
    }

    private func applyStatus(_ state: VPNState) {
        vpnState = state
        guard let button = statusItem.button else { return }
        let symbolName: String
        switch state {
        case .disconnected:
            symbolName = "shield.slash"
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "CorpLink · VPN 未连接"
            toggleItem.title = "连接 VPN"
            toggleItem.isEnabled = true
        case .connecting:
            symbolName = "arrow.triangle.2.circlepath"
            button.contentTintColor = .systemOrange
            button.toolTip = "CorpLink · VPN 连接中"
            toggleItem.title = "取消连接"
            toggleItem.isEnabled = true
        case .verifying:
            symbolName = "arrow.triangle.2.circlepath"
            button.contentTintColor = .systemOrange
            button.toolTip = "CorpLink · 等待 VPN 握手"
            toggleItem.title = "取消连接"
            toggleItem.isEnabled = true
        case .connected:
            symbolName = "checkmark.shield.fill"
            button.contentTintColor = .systemGreen
            button.toolTip = "CorpLink · VPN 已连接"
            toggleItem.title = "断开 VPN"
            toggleItem.isEnabled = true
        case .intranet:
            symbolName = "building.2"
            button.contentTintColor = .systemBlue
            button.toolTip = "CorpLink · 企业内网模式"
            toggleItem.title = "断开连接"
            toggleItem.isEnabled = true
        case .stopping:
            symbolName = "arrow.triangle.2.circlepath"
            button.contentTintColor = .systemOrange
            button.toolTip = "CorpLink · 正在断开"
            toggleItem.title = "正在断开…"
            toggleItem.isEnabled = false
        case .unavailable:
            symbolName = "xmark.shield"
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "CorpLink · 服务不可用"
            toggleItem.title = "VPN 服务不可用"
            toggleItem.isEnabled = false
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.toolTip)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: button.toolTip)
        button.image?.isTemplate = true
        if actionInFlight { toggleItem.isEnabled = false }
    }

    private func showMessage(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "CorpLink"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}

final class BackendController {
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var url: URL?
    private var process: Process?
    private var executableURL: URL?

    func setExecutable(_ url: URL) {
        executableURL = url
        UserDefaults.standard.set(url.path, forKey: "corplinkExecutable")
    }

    func setConfig(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "corplinkConfig")
    }

    func restart() {
        perform("shutdown") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.process?.terminate()
                self?.process = nil
                self?.url = nil
                self?.startIfPossible()
            }
        }
    }

    func startIfPossible() {
        guard process == nil else { return }
        guard let executable = locateExecutable() else {
            onError?("未找到 corplink-rs。请先构建 Rust 客户端，再从状态栏菜单选择可执行文件。")
            return
        }

        let port = Int.random(in: 49_152...65_000)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profileRoot = home.appendingPathComponent("Library/Application Support/corplink-rs", isDirectory: true)
        var command = "CORPLINK_GUI_HOME=\(shellQuote(profileRoot.path)) CORPLINK_GUI_PORT=\(port) CORPLINK_GUI_TOKEN=\(shellQuote(token)) CORPLINK_NO_ESCALATE=1 \(shellQuote(executable.path)) --gui"
        if let config = UserDefaults.standard.string(forKey: "corplinkConfig"), !config.isEmpty {
            command += " \(shellQuote(config))"
        }
        let appleScriptCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(appleScriptCommand)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.url = URL(string: "http://127.0.0.1:\(port)/?token=\(token)")
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.url = nil
                self?.process = nil
                if process.terminationStatus != 0 {
                    self?.onError?("管理员授权未完成，或本机管理服务已退出（状态码 \(process.terminationStatus)）。请重新打开状态栏菜单启动。")
                }
            }
        }
        do {
            try process.run()
            self.process = process
            waitUntilReady()
        } catch {
            onError?("启动 corplink-rs 失败：\(error.localizedDescription)")
        }
    }

    func perform(_ action: String, body: [String: String] = [:], completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let base = url, let token = URLComponents(url: base, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value else {
            completion?(.failure(BackendError.notReady))
            return
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/api/\(action)"
        components.query = nil
        guard let endpoint = components.url else { completion?(.failure(BackendError.badURL)); return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { completion?(.failure(error)); return }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                completion?(.failure(BackendError.requestFailed))
                return
            }
            completion?(.success(()))
        }.resume()
    }

    func readState(completion: @escaping (VPNState, Bool) -> Void) {
        guard let base = url, let token = URLComponents(url: base, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value else {
            completion(.unavailable, false)
            return
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/api/state"
        components.query = nil
        guard let endpoint = components.url else { completion(.unavailable, false); return }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data,
                  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawStatus = payload["status"] as? String,
                  let status = VPNState(rawValue: rawStatus) else {
                completion(.unavailable, false)
                return
            }
            completion(status, true)
        }.resume()
    }

    private func waitUntilReady(_ attempts: Int = 60) {
        guard attempts > 0, process?.isRunning == true else { return }
        readState { [weak self] _, ready in
            guard let self else { return }
            if ready {
                DispatchQueue.main.async { self.onReady?() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitUntilReady(attempts - 1) }
            }
        }
    }

    func shutdown() {
        guard process != nil else { return }
        perform("shutdown") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if self?.process?.isRunning == true { self?.process?.terminate() }
            }
        }
    }

    private func locateExecutable() -> URL? {
        if let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) { return executableURL }
        if let configured = UserDefaults.standard.string(forKey: "corplinkExecutable"), FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        if let env = ProcessInfo.processInfo.environment["CORPLINK_BIN"], FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("corplink-rs"), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let candidates = ["/opt/homebrew/bin/corplink-rs", "/usr/local/bin/corplink-rs", "/usr/bin/corplink-rs"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: path) }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["corplink-rs"]
        let output = Pipe()
        which.standardOutput = output
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        } catch {}
        return nil
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum BackendError: LocalizedError {
    case notReady, badURL, requestFailed
    var errorDescription: String? {
        switch self {
        case .notReady: return "管理服务尚未启动。"
        case .badURL: return "管理服务地址无效。"
        case .requestFailed: return "管理服务请求失败。"
        }
    }
}
