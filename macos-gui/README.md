# corplink-gui (macOS)

极简 macOS GUI 外壳，通过调用 `corplink-rs` 二进制来使用 VPN，无需终端。
与 CLI 并存：GUI 不链接任何 Rust 代码，只以子进程方式启动二进制。

功能：连接（登录）/ 显示扫码二维码 / 退出 / 实时日志 / 在 Finder 中定位配置文件。

## 前置：先构建 corplink-rs 二进制

GUI 需要 `corplink-rs` 可执行文件（需要 root 起 TUN，与 CLI 一致）。在仓库根目录：

```bash
cd libwg && ./build.sh && cd ..        # 先编 libwg（一次性）
cargo build --release                  # 产出 target/release/corplink-rs
```

可选：把二进制放进 PATH（`install -m755 target/release/corplink-rs /usr/local/bin/`），
否则首次运行 GUI 时用「定位二进制」按钮选中它。

## 构建 GUI

```bash
cd macos-gui
swift build -c release        # 产物：.build/release/corplink-gui
```

> 需 Xcode 命令行工具（`swift` 工具链）。无第三方依赖，仅用 SwiftUI/AppKit。

## 运行

```bash
.build/release/corplink-gui
```

首次运行：
- **二进制路径**：默认取 `which corplink-rs`，否则回退到仓库 `target/release/corplink-rs`；
  找不到时界面会出现「定位二进制」按钮（NSOpenPanel）。
- **配置文件**：默认 `config.json`（或仓库 `config/config.json`）；可用「选择配置文件」更换。
- **控制器脚本**：默认 `macos-gui/scripts/session-controller.sh`，由可执行文件/cwd 向上
  查找含 `Cargo.toml` + `macos-gui/` 的仓库根自动定位。从仓库外启动时请在 UserDefaults 设置。

点「连接」会弹出**一次**系统管理员密码框（`osascript ... with administrator privileges`），
随后整次会话不再重复输密码。

## 工作原理（与 CLI 的契约）

GUI 用 osascript 以 root 启动 `session-controller.sh`，控制器负责：
- 后台启动 `corplink-rs <config>`，注入 `CORPLINK_QR_PATH=/tmp/corplink_qr.png`
  与 `CORPLINK_NO_QR_VIEWER=1`（让二维码写进固定文件、由窗口内显示，不弹外部查看器）；
- 把二进制 stderr/stdout 重定向到 `/tmp/corplink_gui.log`（GUI 实时 tail）；
- 对 stdin 命名管道 `/tmp/corplink_stdin.fifo` 持有保活写端（防止二进制 `read_line` 收到 EOF 忙循环）；
- 轮询 `/tmp/corplink_stop.flag`，出现则 `kill` 二进制并退出。

GUI 侧：
- 日志里出现 `请在完成扫码验证后输入 'y' 继续` → 进入待扫码态，显示二维码与「已扫码，继续」
  按钮（点击向 FIFO 写 `y\n`）；
- 日志里出现 `VPN连接成功` / `内网连接成功` → 切到「已连接」态；
- 「退出」= `touch /tmp/corplink_stop.flag`。

固定运行时文件（均在 `/tmp`，世界可读）：`corplink_gui.log`、`corplink_qr.png`、
`corplink_stop.flag`、`corplink_stdin.fifo`。

## 开发 / 测试

```bash
swift test                                   # 状态机与日志触发检测单元测试
sh scripts/test_controller.sh                # 控制器启停/FIFO/停止语义自验收（无需 root）
```

## 已知限制（v1）

- SwiftPM 可执行文件，不是 `.app` 包：没有代码签名 / 特权 launchd 助手 / 菜单栏常驻。
  连接每次会话输一次管理员密码（见上）。如需零密码，后续可包成带 SMAppService 助手的 .app。
- 控制器脚本需有可执行位（仓库中已 `chmod +x`）。
