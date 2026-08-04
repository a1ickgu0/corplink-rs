use qrcode::QrCode;
use std::io::Write;
use terminal_graphics::Colour;
use terminal_graphics::Display;

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
}
