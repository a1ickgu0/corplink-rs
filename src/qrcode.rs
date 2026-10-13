use qrcode::QrCode;
use std::io::Write;

const QUIET_ZONE_MODULES: usize = 4;
const TERMINAL_MARGIN_COLUMNS: usize = 1;
const TERMINAL_MARGIN_ROWS: usize = 1;
const TERMINAL_STATUS_ROWS: usize = 3;

/// 二维码 PNG 的默认落盘路径（与 open_as_png 一致，供日志提示用户手动打开）。
pub fn png_path() -> std::path::PathBuf {
    std::env::temp_dir().join("corplink_qr.png")
}

#[derive(Clone)]
pub struct TerminalQrCode {
    code: QrCode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QrDisplayPlan {
    pub show_terminal: bool,
    pub show_png: bool,
    pub fits_terminal: bool,
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
        self.code.width() + QUIET_ZONE_MODULES * 2 + TERMINAL_MARGIN_COLUMNS * 2
    }

    /// 终端渲染所需的行数（半块压缩后 + 上下留白行）。
    pub fn rows_needed(&self) -> usize {
        let padded_width = self.code.width() + QUIET_ZONE_MODULES * 2;
        padded_width.div_ceil(2) + TERMINAL_MARGIN_ROWS * 2
    }

    /// 根据显示模式和终端尺寸决定二维码输出方式。自动模式必须同时满足宽度和高度，
    /// 否则使用 PNG，避免二维码换行或底部被终端视口裁掉。
    pub fn display_plan(&self, mode: &str, terminal_size: Option<(usize, usize)>) -> QrDisplayPlan {
        let fits_terminal = terminal_size.is_some_and(|(cols, rows)| {
            cols >= self.columns_needed()
                && rows >= self.rows_needed().saturating_add(TERMINAL_STATUS_ROWS)
        });

        let (show_terminal, show_png) = match mode {
            "terminal" => (true, false),
            "png" => (false, true),
            "both" => (true, true),
            _ => (fits_terminal, !fits_terminal),
        };

        QrDisplayPlan {
            show_terminal,
            show_png,
            fits_terminal,
        }
    }

    /// 生成可顺序写入 stdout 的终端二维码。每一行都包含完整 ANSI 内容，不使用光标回退，
    /// 因而不会像 terminal_graphics 那样在二维码高于终端视口时静默丢失底部行。
    pub fn render_terminal(&self) -> String {
        let width = self.code.width();
        let padded_width = width + QUIET_ZONE_MODULES * 2;
        let pixels = self.code.to_colors();
        let module_is_dark = |x: usize, y: usize| {
            let data_x = x.checked_sub(QUIET_ZONE_MODULES);
            let data_y = y.checked_sub(QUIET_ZONE_MODULES);
            match (data_x, data_y) {
                (Some(data_x), Some(data_y)) if data_x < width && data_y < width => {
                    pixels[data_y * width + data_x] == qrcode::types::Color::Dark
                }
                _ => false,
            }
        };

        let mut lines = Vec::with_capacity(self.rows_needed());
        for terminal_y in 0..self.rows_needed() {
            let is_margin_row = terminal_y < TERMINAL_MARGIN_ROWS
                || terminal_y >= self.rows_needed() - TERMINAL_MARGIN_ROWS;
            let mut line = String::new();

            for terminal_x in 0..self.columns_needed() {
                let is_margin_column = terminal_x < TERMINAL_MARGIN_COLUMNS
                    || terminal_x >= self.columns_needed() - TERMINAL_MARGIN_COLUMNS;
                let (top_dark, bottom_dark) = if is_margin_row || is_margin_column {
                    (false, false)
                } else {
                    let module_x = terminal_x - TERMINAL_MARGIN_COLUMNS;
                    let module_y = (terminal_y - TERMINAL_MARGIN_ROWS) * 2;
                    let top = module_is_dark(module_x, module_y);
                    let bottom =
                        module_y + 1 < padded_width && module_is_dark(module_x, module_y + 1);
                    (top, bottom)
                };

                let foreground = if top_dark { 30 } else { 37 };
                let background = if bottom_dark { 40 } else { 47 };
                line.push_str(&format!("\x1b[{foreground};{background}m▀"));
            }
            line.push_str("\x1b[0m");
            lines.push(line);
        }

        lines.join("\n")
    }

    pub fn print(&self) {
        println!("{}", self.render_terminal());

        // 强制刷新输出缓冲区，确保二维码完全打印
        std::io::stdout().flush().unwrap();
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
        image.save(&path).map_err(std::io::Error::other)?;
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

    #[test]
    fn terminal_dimensions_include_standard_quiet_zone() {
        let data = "https://example.com/otp?token=abc123";
        let qr = TerminalQrCode::from_bytes(data.as_bytes());
        let code_width = QrCode::new(data.as_bytes()).unwrap().width();

        assert_eq!(qr.columns_needed(), code_width + 10);
        assert_eq!(qr.rows_needed(), (code_width + 8).div_ceil(2) + 2);
    }

    #[test]
    fn auto_uses_png_when_terminal_is_too_short() {
        let qr = TerminalQrCode::from_bytes("https://example.com/login".as_bytes());
        let terminal_size = Some((qr.columns_needed(), qr.rows_needed() + 2));

        assert_eq!(
            qr.display_plan("auto", terminal_size),
            QrDisplayPlan {
                show_terminal: false,
                show_png: true,
                fits_terminal: false,
            }
        );
    }

    #[test]
    fn auto_uses_terminal_only_when_width_and_height_fit() {
        let qr = TerminalQrCode::from_bytes("https://example.com/login".as_bytes());
        let terminal_size = Some((qr.columns_needed(), qr.rows_needed() + 3));

        assert_eq!(
            qr.display_plan("auto", terminal_size),
            QrDisplayPlan {
                show_terminal: true,
                show_png: false,
                fits_terminal: true,
            }
        );
    }

    #[test]
    fn terminal_render_is_complete_and_does_not_move_the_cursor() {
        let qr = TerminalQrCode::from_bytes("https://example.com/login".as_bytes());
        let rendered = qr.render_terminal();

        assert_eq!(rendered.lines().count(), qr.rows_needed());
        assert!(!rendered.contains('B'));
        assert!(!rendered.contains('D'));
        assert!(!rendered.contains('F'));
    }
}
