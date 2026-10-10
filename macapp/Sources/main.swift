import AppKit
import WebKit
import ServiceManagement
import Darwin

struct LimitWindow: Decodable {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        usedPercent = try values.decode(Double.self, forKey: .usedPercent)
        guard usedPercent.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .usedPercent, in: values, debugDescription: "Non-finite percentage")
        }
        if let timestamp = try? values.decode(Double.self, forKey: .resetsAt), timestamp.isFinite {
            resetsAt = Date(timeIntervalSince1970: timestamp)
        } else if let text = try? values.decode(String.self, forKey: .resetsAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        } else {
            resetsAt = nil
        }
    }
}

struct ToolLimits: Decodable {
    let windows: [LimitWindow]
    let status: String?
}

typealias Limits = [String: ToolLimits]

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKScriptMessageHandler {
    private var popover: NSPopover?
    private var popoverView: WKWebView?
    private let tools = [("claude", "Claude", "C"), ("codex", "Codex", "X"), ("gemini", "Gemini", "G")]
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var limits: Limits?
    private var timer: Timer?
    private var startupTimer: Timer?
    private var backend: Process?
    private var dashboard: NSWindow?
    private var webView: WKWebView?
    private var loginFailed = false
    private var refreshing = false
    private var fetching = false
    private var stopping = false
    private var signalSources: [DispatchSourceSignal] = []
    private var startupAttempts = 0
    private let session = URLSession(configuration: .ephemeral)
    private let port: Int = {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--port"), args.indices.contains(index + 1),
           let value = Int(args[index + 1]), (1...65535).contains(value) {
            return value
        }
        return 8765
    }()
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TT"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        menu.autoenablesItems = false
        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildMenu()
        installTerminationHandlers()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.fetchLimits() }
        probeBackend { [weak self] available in
            guard let self = self, !self.stopping else { return }
            if available {
                NSLog("TokenTracker: reusing backend on port %d", self.port)
                self.fetchLimits()
            } else {
                self.startBackend()
            }
        }
    }

    private func installTerminationHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func probeBackend(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/limits"))
        request.timeoutInterval = 3
        session.dataTask(with: request) { data, response, _ in
            let available = (response as? HTTPURLResponse)?.statusCode == 200
                && data.flatMap { try? JSONDecoder().decode(Limits.self, from: $0) } != nil
            DispatchQueue.main.async { completion(available) }
        }.resume()
    }

    private func startBackend() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            showStartupError("Python 3를 찾을 수 없습니다", detail: "/usr/bin/python3가 필요합니다. Apple Command Line Tools를 설치한 뒤 다시 실행하세요.")
            return
        }
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("app.py").path) else {
            showStartupError("백엔드 파일이 없습니다", detail: "앱을 다시 빌드해 주세요. Contents/Resources/app.py가 필요합니다.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["app.py", "--dashboard", "--no-browser", "--port", String(port)]
        process.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self = self, !self.stopping else { return }
                NSLog("TokenTracker: backend exited with status %d", ended.terminationStatus)
                self.fetchLimits()
            }
        }
        do {
            try process.run()
            backend = process
            NSLog("TokenTracker: started backend pid %d on port %d", process.processIdentifier, port)
            startupAttempts = 0
            startupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.startupAttempts += 1
                self.fetchLimits()
                if self.startupAttempts >= 120 {
                    self.startupTimer?.invalidate()
                    self.startupTimer = nil
                }
            }
            fetchLimits()
        } catch {
            showStartupError("백엔드를 실행할 수 없습니다", detail: error.localizedDescription)
        }
    }

    private func showStartupError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fetchLimits() {
        guard !fetching, !stopping else { return }
        fetching = true
        var request = URLRequest(url: baseURL.appendingPathComponent("api/limits"))
        request.timeoutInterval = 5
        session.dataTask(with: request) { [weak self] data, response, _ in
            let result: Limits? = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap { try? JSONDecoder().decode(Limits.self, from: $0) } : nil
            DispatchQueue.main.async {
                guard let self = self, !self.stopping else { return }
                self.fetching = false
                self.limits = result
                if let result = result {
                    self.startupTimer?.invalidate()
                    self.startupTimer = nil
                    let titles = self.tools.compactMap { key, _, short -> String? in
                        guard let highest = result[key]?.windows.map(\.usedPercent).max() else { return nil }
                        return "\(short) \(self.percent(highest))"
                    }
                    self.statusItem.button?.title = titles.isEmpty ? "TT" : titles.joined(separator: " · ")
                    self.statusItem.button?.toolTip = "Token Tracker · 도구별 최고 사용률"
                } else {
                    self.statusItem.button?.title = "TT"
                    self.statusItem.button?.toolTip = "Token Tracker · 백엔드 연결 실패"
                }
                self.rebuildMenu()
            }
        }.resume()
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }

    private func resetTime(_ date: Date?) -> String {
        guard let date = date else { return "리셋 시간 없음" }
        let seconds = max(0, date.timeIntervalSinceNow)
        guard seconds > 0 else { return "리셋 예정" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "리셋까지 \(minutes / 1440)일 \((minutes % 1440) / 60)시간" }
        if minutes >= 60 { return "리셋까지 \(minutes / 60)시간 \(minutes % 60)분" }
        return "리셋까지 \(minutes)분"
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = action == nil ? nil : self
        entry.isEnabled = action != nil
        menu.addItem(entry)
        return entry
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        if let limits = limits {
            for (key, name, _) in tools {
                guard let tool = limits[key] else { continue }
                if key == "gemini" && tool.windows.isEmpty { continue }
                _ = item("\(name) · \(tool.status ?? "unknown")")
                if tool.windows.isEmpty {
                    _ = item("  한도 정보 없음")
                } else {
                    for window in tool.windows {
                        _ = item("  \(window.label)  \(percent(window.usedPercent)) · \(resetTime(window.resetsAt))")
                    }
                }
                menu.addItem(.separator())
            }
        } else {
            _ = item("백엔드 연결 대기 또는 실패 · 포트 \(port)")
            menu.addItem(.separator())
        }
        _ = item("대시보드 열기", action: #selector(openDashboard))
        let refresh = item(refreshing ? "새로고침 중…" : "지금 새로고침", action: #selector(refreshNow))
        refresh.isEnabled = !refreshing
        let login = item("로그인 시 자동 실행", action: #selector(toggleLogin))
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            login.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
            login.isEnabled = !loginFailed && status != .notFound
            if status == .requiresApproval { login.toolTip = "시스템 설정 > 일반 > 로그인 항목에서 승인이 필요합니다." }
            if loginFailed { login.toolTip = "자동 실행 설정을 변경하지 못했습니다. 앱을 /Applications에 설치하고 다시 실행하세요." }
        } else {
            login.isEnabled = false
            login.toolTip = "자동 실행 설정은 macOS 13 이상에서 지원합니다."
        }
        menu.addItem(.separator())
        _ = item("종료", action: #selector(quit))
    }

    @objc private func statusClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            rebuildMenu()
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }
        if let popover = popover, popover.isShown { popover.performClose(nil); return }
        if popover == nil {
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "act")
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 640), configuration: config)
            view.setValue(false, forKey: "drawsBackground")
            let controller = NSViewController()
            controller.view = view
            let pop = NSPopover()
            pop.contentViewController = controller
            pop.contentSize = NSSize(width: 340, height: 640)
            pop.behavior = .transient
            popover = pop
            popoverView = view
        }
        popoverView?.load(URLRequest(url: baseURL.appendingPathComponent("popover")))
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.body as? String {
        case "dashboard": popover?.performClose(nil); openDashboard()
        case "refresh": refreshNow(); popoverView?.evaluateJavaScript("setTimeout(load,1500)")
        case "login": toggleLogin()
        case "quit": quit()
        default: break
        }
    }

    @objc private func openDashboard() {
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Token Tracker"
            window.minSize = NSSize(width: 480, height: 400)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let view = WKWebView(frame: window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.center()
            dashboard = window
            webView = view
        }
        webView?.load(URLRequest(url: baseURL))
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshNow() {
        guard !refreshing else { return }
        refreshing = true
        rebuildMenu()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/refresh"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self, !self.stopping else { return }
                self.refreshing = false
                if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                    self.limits = nil
                    self.statusItem.button?.title = "TT"
                    self.rebuildMenu()
                } else {
                    self.fetchLimits()
                    self.webView?.reload()
                }
            }
        }.resume()
    }

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                loginFailed = true
                NSLog("TokenTracker: login item setting failed: %@", error.localizedDescription)
            }
            rebuildMenu()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        timer?.invalidate()
        startupTimer?.invalidate()
        session.invalidateAndCancel()
        // Only the Process created by this app belongs to us; never kill a reused server.
        if let process = backend, process.isRunning {
            process.terminate()
        }
        signalSources.forEach { $0.cancel() }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
