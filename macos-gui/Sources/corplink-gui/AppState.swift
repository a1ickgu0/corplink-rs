import Foundation
import AppKit

/// GUI 的有限状态机。取值与外部契约严格一致。
enum AppState: String, Equatable, CaseIterable {
    case idle
    case connecting
    case connected
    case waitingScan
    case error
}

// MARK: - 纯函数（便于单元测试）

extension AppState {
    /// 是否允许点击“连接”。
    static func canConnect(_ s: AppState) -> Bool {
        return s == .idle || s == .error
    }

    /// 是否允许点击“退出/断开”。
    static func canDisconnect(_ s: AppState) -> Bool {
        return s != .idle && s != .error
    }

    /// 状态指示灯颜色。
    static func dotColor(_ s: AppState) -> NSColor {
        switch s {
        case .idle:        return NSColor.systemGray
        case .connecting:  return NSColor.systemOrange
        case .connected:   return NSColor.systemGreen
        case .waitingScan: return NSColor.systemBlue
        case .error:       return NSColor.systemRed
        }
    }
}

/// 全局可观察模型：负责协调 VPNController 与 LogTailer，并维护 UI 状态。
///
/// 所有对 `@Published` 属性的写入都通过主线程进行（外部回调使用
/// `DispatchQueue.main.async` 派发），保证 SwiftUI 更新安全。
final class AppModel: ObservableObject {
    @Published var state: AppState = .idle
    @Published var statusMessage: String = "未连接"
    @Published var logText: String = ""
    @Published var qrImage: NSImage? = nil
    @Published var lastError: String? = nil

    let controller: VPNController
    let tailer: LogTailer

    /// 日志显示的最大字符数，超过则裁剪保留尾部，避免无界增长。
    private let maxLogChars = 200_000

    init(controller: VPNController = VPNController(),
         tailer: LogTailer = LogTailer()) {
        self.controller = controller
        self.tailer = tailer
        wireCallbacks()
    }

    private func wireCallbacks() {
        // 控制器状态回流（已由控制器派发到主线程）。
        controller.onStateChange = { [weak self] newState, message in
            self?.applyExternalState(newState, message: message)
        }

        // 新增日志分片。
        tailer.onNewChunk = { [weak self] chunk in
            guard let self = self else { return }
            self.logText.append(chunk)
            if self.logText.count > self.maxLogChars {
                self.logText = String(self.logText.suffix(self.maxLogChars / 2))
            }
            // 先检测扫码触发，再检测连接成功。
            if detectTrigger(in: chunk) {
                self.transition(to: .waitingScan, message: "等待扫码确认")
            } else if self.state == .connecting, detectConnected(in: chunk) {
                self.transition(to: .connected, message: "已连接")
            }
        }

        // 二维码图片刷新。
        tailer.onQRChange = { [weak self] image in
            self?.qrImage = image
        }
    }

    // MARK: - 对外动作

    func connect() {
        guard AppState.canConnect(state) else { return }
        // 清理上一次的运行时痕迹。
        lastError = nil
        qrImage = nil
        logText = ""
        try? FileManager.default.removeItem(atPath: VPNPaths.stopFlag)
        transition(to: .connecting, message: "正在连接…（请在系统弹窗中输入管理员密码）")
        tailer.start()
        controller.connect()
    }

    func disconnect() {
        guard AppState.canDisconnect(state) else { return }
        statusMessage = "正在断开…"
        controller.disconnect()
    }

    func confirmScan() {
        controller.confirmScan()
        if state == .waitingScan {
            transition(to: .connecting, message: "已确认，继续登录中…")
        }
    }

    // MARK: - 状态迁移

    fileprivate func transition(to newState: AppState, message: String?) {
        state = newState
        if let m = message { statusMessage = m }
        if newState == .idle || newState == .error {
            tailer.stop()
        }
    }

    /// 处理控制器上报的状态（终止、缺失文件等）。
    fileprivate func applyExternalState(_ newState: AppState, message: String?) {
        if newState == .error, let m = message { lastError = m }
        if newState == .idle { lastError = nil }
        transition(to: newState, message: message)
    }
}
