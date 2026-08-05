import SwiftUI
import AppKit

/// 二维码显示区：展示 NSImage 并提供“已扫码，继续”按钮。
struct QRView: View {
    let image: NSImage?
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .background(Color.white)
                    .cornerRadius(4)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 220, height: 220)
                    .overlay(
                        VStack(spacing: 6) {
                            ProgressView()
                            Text("等待二维码…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
            Text("请使用飞连 App 扫描上方二维码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onConfirm) {
                Label("已扫码，继续", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
    }
}
