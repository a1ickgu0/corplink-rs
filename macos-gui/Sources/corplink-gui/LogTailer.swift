import Foundation
import AppKit

/// 当日志中出现该串时，二进制正等待用户确认扫码完成。
let scanConfirmTrigger = "请在完成扫码验证后输入 'y' 继续"

/// 连接成功的日志标记（命中任一即视为已连接）。
let connectedMarkers: [String] = ["VPN连接成功", "内网连接成功"]

/// 纯函数：判定新增的日志分片是否包含“扫码确认”触发串。单元测试入口。
/// 假设：触发串完整出现在某个分片内（0.5s 轮询通常一次读取数 KB，
/// 而该串仅约 30 字节，因此极少被截断到两次读取之间）。
func detectTrigger(in newChunk: String) -> Bool {
    return newChunk.contains(scanConfirmTrigger)
}

/// 纯函数：判定新增日志分片是否表示 VPN 已连接成功。
func detectConnected(in newChunk: String) -> Bool {
    return connectedMarkers.contains { newChunk.contains($0) }
}

/// 轮询 `/tmp/corplink_gui.log` 与 `/tmp/corplink_qr.png`，把新内容/新图片回调给上层。
final class LogTailer {
    /// 新日志分片回调（主线程派发）。上层据此追加显示文本并运行触发串检测。
    var onNewChunk: ((String) -> Void)?
    /// 二维码图片刷新回调（主线程派发）。
    var onQRChange: ((NSImage?) -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "corplink.tailer", qos: .userInitiated)

    private var logOffset: UInt64 = 0
    private var lastQRMtime: Date? = nil

    func start() {
        stop()
        logOffset = 0
        lastQRMtime = nil
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        checkLog()
        checkQR()
    }

    private func checkLog() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: VPNPaths.logPath),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            return
        }
        if size < logOffset { logOffset = 0 }   // 文件被截断/轮转：重置偏移。
        if size == logOffset { return }

        let url = URL(fileURLWithPath: VPNPaths.logPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: logOffset)
        } catch {
            return
        }
        let length = Int(size - logOffset)
        guard let data = try? handle.read(upToCount: length), !data.isEmpty else {
            return
        }
        logOffset = size
        // 优先 UTF-8；遇到不完整字节时用容错解码避免丢字。
        let chunk = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async { [weak self] in
            self?.onNewChunk?(chunk)
        }
    }

    private func checkQR() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: VPNPaths.qrPath),
              let mtime = attrs[.modificationDate] as? Date else {
            return
        }
        if mtime == lastQRMtime { return }
        lastQRMtime = mtime
        let url = URL(fileURLWithPath: VPNPaths.qrPath)
        let image = NSImage(contentsOf: url)
        DispatchQueue.main.async { [weak self] in
            self?.onQRChange?(image)
        }
    }
}
