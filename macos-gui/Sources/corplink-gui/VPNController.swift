import Foundation
import Darwin

/// 固定的运行时文件路径（与 session-controller.sh 共享）。
enum VPNPaths {
    /// 二进制完整日志流（tail 此文件）。
    static let logPath = "/tmp/corplink_gui.log"
    /// 二维码图片（按 mtime 轮询，变更后重新加载）。
    static let qrPath = "/tmp/corplink_qr.png"
    /// 创建该文件以请求断开。
    static let stopFlag = "/tmp/corplink_stop.flag"
    /// 向该 FIFO 写入 `y\n` 以确认扫码。
    static let fifoPath = "/tmp/corplink_stdin.fifo"
}

/// UserDefaults 键。
enum VPNDefaultsKey {
    static let binaryPath = "binaryPath"
    static let configPath = "configPath"
    static let controllerScriptPath = "controllerScriptPath"
}

/// 计算配置项的默认值并探测仓库根目录。
enum VPNDefaults {
    /// 默认二进制路径：优先 `which corplink-rs`，否则仓库内 `target/release/corplink-rs`。
    static func defaultBinaryPath() -> String {
        if let which = runWhich("corplink-rs"),
           FileManager.default.isExecutableFile(atPath: which) {
            return which
        }
        if let repo = repoRoot() {
            let p = (repo as NSString).appendingPathComponent("target/release/corplink-rs")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "target/release/corplink-rs"
    }

    /// 默认配置路径：仓库内存在 config/config.json 则使用之，否则 `config.json`。
    static func defaultConfigPath() -> String {
        if let repo = repoRoot() {
            let p = (repo as NSString).appendingPathComponent("config/config.json")
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "config.json"
    }

    /// 默认控制器脚本路径：`<repo>/macos-gui/scripts/session-controller.sh`。
    static func defaultControllerScriptPath() -> String {
        if let repo = repoRoot() {
            return (repo as NSString).appendingPathComponent("macos-gui/scripts/session-controller.sh")
        }
        return "macos-gui/scripts/session-controller.sh"
    }

    /// 从 cwd 与可执行文件所在目录向上查找，返回同时包含 `Cargo.toml` 与 `macos-gui` 的目录。
    static func repoRoot() -> String? {
        let fm = FileManager.default
        var starts: [String] = []
        starts.append(fm.currentDirectoryPath)
        if let arg0 = CommandLine.arguments.first {
            starts.append((arg0 as NSString).standardizingPath)
        }
        // Bundle.main.bundleURL：裸可执行文件场景下指向其所在目录。
        starts.append(Bundle.main.bundleURL.path)

        for start in starts {
            var url = URL(fileURLWithPath: start).standardizedFileURL
            for _ in 0..<32 {
                let cargo = url.appendingPathComponent("Cargo.toml").path
                let gui = url.appendingPathComponent("macos-gui").path
                if fm.fileExists(atPath: cargo), fm.fileExists(atPath: gui) {
                    return url.path
                }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break } // 到达根目录
                url = parent
            }
        }
        return nil
    }

    /// 执行 `/usr/bin/which <name>`，返回去空白后的结果。
    private static func runWhich(_ name: String) -> String? {
        let p = Process()
        p.launchPath = "/usr/bin/which"
        p.arguments = [name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}

/// 以子进程方式驱动 `session-controller.sh`（经 osascript 提权）。
/// 所有 `onStateChange` 回调均在主线程派发。
final class VPNController {
    /// 状态回流：`(newState, optional message)`。
    var onStateChange: ((AppState, String?) -> Void)?

    private var process: Process?
    private var userRequestedStop = false

    // MARK: - 设置（来自 UserDefaults，带默认值）

    var binaryPath: String {
        if let s = UserDefaults.standard.string(forKey: VPNDefaultsKey.binaryPath),
           !s.isEmpty {
            return s
        }
        return VPNDefaults.defaultBinaryPath()
    }

    var configPath: String {
        if let s = UserDefaults.standard.string(forKey: VPNDefaultsKey.configPath),
           !s.isEmpty {
            return s
        }
        return VPNDefaults.defaultConfigPath()
    }

    var controllerScriptPath: String {
        if let s = UserDefaults.standard.string(forKey: VPNDefaultsKey.controllerScriptPath),
           !s.isEmpty {
            return s
        }
        return VPNDefaults.defaultControllerScriptPath()
    }

    /// 二进制是否可执行。
    var binaryIsUsable: Bool {
        return FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    // MARK: - 动作

    /// 启动 osascript 提权运行控制器脚本。
    func connect() {
        guard process == nil else {
            emit(.connecting, "已在运行中")
            return
        }

        // 校验必要文件。
        guard FileManager.default.fileExists(atPath: controllerScriptPath) else {
            emit(.error, "找不到控制器脚本：\(controllerScriptPath)")
            return
        }
        guard binaryIsUsable else {
            emit(.error, "找不到或无法执行二进制：\(binaryPath)")
            return
        }
        if !FileManager.default.fileExists(atPath: configPath) {
            // 配置缺失仅告警，不阻断（交由二进制报错）。
            emit(.connecting, "配置文件不存在：\(configPath)，仍尝试启动…")
        }

        userRequestedStop = false
        try? FileManager.default.removeItem(atPath: VPNPaths.stopFlag)

        // 构造 osascript 命令：
        //   osascript -e 'do shell script "<script> <binary> <config>" with administrator privileges'
        let shellCommand = "'\(escapeForShell(controllerScriptPath))' "
            + "'\(escapeForShell(binaryPath))' "
            + "'\(escapeForShell(configPath))'"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"

        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", appleScript]
        // 丢弃 osascript 自身输出（实际日志走 /tmp/corplink_gui.log）。
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                if self.userRequestedStop {
                    self.emit(.idle, "已断开")
                } else if code == 0 {
                    self.emit(.idle, "已断开")
                } else {
                    self.emit(.error, "VPN 进程已退出（code \(code)）")
                }
            }
        }

        do {
            try p.run()
            process = p
            if !FileManager.default.fileExists(atPath: configPath) {
                // 保留之前的告警文案。
            } else {
                emit(.connecting, "正在连接…")
            }
        } catch {
            emit(.error, "无法启动 osascript：\(error.localizedDescription)")
        }
    }

    /// 请求断开：创建 stop 标志文件，等待控制器读取后退出。
    func disconnect() {
        userRequestedStop = true
        touchStopFlag()
    }

    /// 确认扫码：向 FIFO 写入 `y\n`。
    func confirmScan() {
        let path = VPNPaths.fifoPath
        // 在后台队列执行，避免打开 FIFO 时可能阻塞主线程。
        DispatchQueue.global(qos: .userInitiated).async {
            self.writeToFIFO(path: path, payload: Data("y\n".utf8))
        }
    }

    // MARK: - 辅助

    private func emit(_ state: AppState, _ message: String?) {
        onStateChange?(state, message)
    }

    private func touchStopFlag() {
        FileManager.default.createFile(
            atPath: VPNPaths.stopFlag,
            contents: Data(),
            attributes: nil
        )
    }

    /// 使用 O_NONBLOCK 打开 FIFO 并写入，避免无读者时永久阻塞。
    private func writeToFIFO(path: String, payload: Data) {
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            if let base = raw.baseAddress, raw.count > 0 {
                return Darwin.write(fd, base, raw.count)
            }
            return 0
        }
    }

    /// 对 shell 单引号包裹内的路径做最小转义：把 `'` 替换为 `'\''`。
    private func escapeForShell(_ s: String) -> String {
        return s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
