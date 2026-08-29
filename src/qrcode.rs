use qrcode::QrCode;
use std::io::Write;
use terminal_graphics::Colour;
use terminal_graphics::Display;

/// 二维码 PNG 的默认落盘路径（与 open_as_png 一致，供日志提示用户手动打开）。
pub fn png_path() -> std::path::PathBuf {
    std::env::temp_dir().join("corplink_qr.png")
}

#[derive(Clone)]
pub struct TerminalQrCode {
    code: QrCode,
}

impl TerminalQrCode {
    pub fn from_bytes<D: AsRef<[u8]>>(data: D) -> TerminalQrCode {
        // 使用自动版本选择，而不是固定版本，以适应不同长度的数据
        let code = QrCode::new(data).unwrap_or_else(|_| {
            // 如果二维码生成失败，使用一个简短的占位符
            QrCode::new("QR code generation failed").unwrap()
        });
        TerminalQrCode { code }
    }

    /// 终端渲染所需的列数（模块数 + 两侧留白列）。超过终端宽度时渲染会换行，
    /// 换行即破坏二维码图形，调用方应改用图片弹窗。
    pub fn columns_needed(&self) -> usize {
        self.code.width() + 2
    }

    /// 终端渲染所需的行数（半块压缩后 + 上下留白行）。
    pub fn rows_needed(&self) -> usize {
        (self.code.width() + 1) / 2 + 2
    }

    pub fn print(&self) {
        let code = self.code.clone();
        let width = code.width();
        // half-block 渲染：横向 1 个二维码模块 = 1 个字符，纵向 2 个模块 = 1 行（用 ▀ 上下半块）。
        // 终端字符单元高宽比约 2:1，这样每个模块视觉上恰好是正方形 —— 这是终端二维码能被
        // 手机摄像头可靠扫描的唯一方案。braille(2×4)/quarter-block(2×2) 虽然更小，但前者点阵稀疏、
        // 后者模块变形，都无法识别。宽度等于模块数（此处 113）是 860 字节 URL 的固有下限。
        let new_height = (width + 1) / 2;
        let pixels = code.to_colors();
        let mut display = Display::new((width + 2) as u32, (new_height + 1) as u32);

        let colour_of = |p: &qrcode::types::Color| match p {
            qrcode::types::Color::Light => Colour::White,
            qrcode::types::Color::Dark => Colour::Black,
        };

        for gy in 0..new_height {
            for gx in 0..width {
                let top = colour_of(&pixels[gy * 2 * width + gx]);
                // 奇数宽度导致下半模块越界时按浅色处理
                let bottom = if gy * 2 + 1 < width {
                    colour_of(&pixels[(gy * 2 + 1) * width + gx])
                } else {
                    Colour::White
                };
                // ▀（上半块）：上半部分取前景色（上模块），下半部分取背景色（下模块）
                display.set_pixel(gx as isize + 1, gy as isize + 1, '▀', top, bottom);
            }
        }
        for _i in 0..((new_height + 2) as u32) {
            println!();
        }
        display.print();

        // 强制刷新输出缓冲区，确保二维码完全打印
        std::io::stdout().flush().unwrap();

        // 添加一个小延迟，确保二维码完全显示
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    /// 将二维码渲染为 PNG 写入临时文件，并用系统图片查看器弹出。
    /// 与终端半块渲染相比：模块是真正的实心正方形、尺寸可控、高对比度，手机更易扫；
    /// PNG 用系统默认图片查看器（macOS Preview / Linux 图片浏览器 / Windows 照片）通用打开。
    /// `target_size` 为目标边长像素。返回打开结果，失败时调用方可回退到 `print()`。
    pub fn open_as_png(&self, target_size: u32) -> std::io::Result<()> {
        let image = self
            .code
            .render::<image::Rgb<u8>>()
            .min_dimensions(target_size, target_size)
            .build();
        // 输出路径可被环境变量覆盖（GUI 模式下指向固定路径 /tmp/corplink_qr.png）
        let path = match std::env::var("CORPLINK_QR_PATH") {
            Ok(p) if !p.is_empty() => std::path::PathBuf::from(p),
            _ => png_path(),
        };
        // image::ImageBuffer::save 依赖 image crate 的 png 编码器（见 Cargo.toml features）
        image
            .save(&path)
            .map_err(std::io::Error::other)?;
        // GUI 模式下由窗口内显示，不弹外部查看器
        let suppress_viewer = matches!(std::env::var("CORPLINK_NO_QR_VIEWER"), Ok(v) if v == "1");
        if !suppress_viewer {
            crate::utils::open_file(&path.to_string_lossy())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 渲染冒烟测试：`cargo test -- --nocapture` 可在终端直接看到二维码效果
    #[test]
    fn print_renders_without_panic() {
        let qr = TerminalQrCode::from_bytes("https://example.com/otp?token=abc123".as_bytes());
        qr.print();
    }
}
