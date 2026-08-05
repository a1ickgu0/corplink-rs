import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    // 设置项通过 @AppStorage 与 VPNController 共享（均读写 UserDefaults.standard）。
    @AppStorage(VPNDefaultsKey.binaryPath) private var binaryPath = VPNDefaults.defaultBinaryPath()
    @AppStorage(VPNDefaultsKey.configPath) private var configPath = VPNDefaults.defaultConfigPath()
    @AppStorage(VPNDefaultsKey.controllerScriptPath) private var controllerScriptPath =
        VPNDefaults.defaultControllerScriptPath()

    @State private var showMissingBinaryAlert = false

    var body: some View {
        VStack(spacing: 12) {
            statusRow
            actionRow
            Divider()
            configRow
            if !model.controller.binaryIsUsable {
                binaryHintRow
            }
            if model.state == .waitingScan {
                Divider()
                QRView(image: model.qrImage) { model.confirmScan() }
            }
            Divider()
            LogView(text: model.logText)
        }
        .padding(16)
        .alert("二进制未找到", isPresented: $showMissingBinaryAlert) {
            Button("好") { }
        } message: {
            Text("无法执行 “\(binaryPath)”。请点击“定位二进制”选择 corplink-rs。")
        }
    }

    // MARK: - 子视图

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: AppState.dotColor(model.state)))
                .frame(width: 12, height: 12)
            Text(model.state.rawValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(model.statusMessage)
                .font(.body)
                .lineLimit(2)
            Spacer()
            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: connectTapped) {
                Label("连接", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!AppState.canConnect(model.state))

            Button(action: { model.disconnect() }) {
                Label("退出", systemImage: "stop.fill")
            }
            .disabled(!AppState.canDisconnect(model.state))

            Spacer()

            Button(action: revealConfigInFinder) {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .disabled(!FileManager.default.fileExists(atPath: resolvedConfigPath))

            if !model.controller.binaryIsUsable {
                Button(action: locateBinary) {
                    Label("定位二进制", systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var configRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("二进制").font(.caption).foregroundStyle(.secondary)
                Text(binaryPath).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            Divider().frame(height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("配置文件").font(.caption).foregroundStyle(.secondary)
                Text(configPath).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(action: chooseConfig) {
                Image(systemName: "folder.badge.plus")
            }
            .help("选择配置文件")
        }
    }

    private var binaryHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("当前二进制路径不可用，请用“定位二进制”选择 corplink-rs。")
                .font(.caption)
            Spacer()
        }
    }

    // MARK: - 动作

    private func connectTapped() {
        if !model.controller.binaryIsUsable {
            showMissingBinaryAlert = true
            return
        }
        model.connect()
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
        }
    }

    private func locateBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path
        }
    }

    private func revealConfigInFinder() {
        let path = resolvedConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 将相对配置路径解析为基于 cwd 的绝对路径。
    private var resolvedConfigPath: String {
        if (configPath as NSString).isAbsolutePath { return configPath }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(configPath)
    }
}
