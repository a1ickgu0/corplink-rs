# CorpLink 菜单栏应用（macOS）

原生 macOS 菜单栏常驻应用，使用系统授权弹窗启动本机管理服务和 VPN 客户端。管理窗口可从菜单栏重新打开；关闭窗口会收起窗口，VPN 和菜单栏图标继续运行。

## 构建

```bash
cd macos-menubar
./build-app.sh
open dist/CorpLink.app
```

需要 macOS 13 或更新版本、Xcode Command Line Tools 和已构建的 `corplink-rs`。`build-app.sh` 会将核心程序一起打进 `.app`；也可以从状态栏菜单选择其他客户端二进制。首次启动后会显示 macOS 管理员授权弹窗，授权成功后，菜单栏图标会显示 VPN 连接状态。

菜单栏只显示状态图标：未连接是灰色斜杠盾牌，连接、等待首次握手或断开中是橙色循环箭头，确认 WireGuard 握手后才显示绿色勾选盾牌，企业内网模式是蓝色楼宇。菜单会按当前状态提供“连接 VPN”“取消连接”或“断开 VPN”，并可打开/收起管理窗口、选择默认配置、选择客户端程序和退出应用。默认配置可选择任何文件名的 JSON 配置，例如 `config/config.json.bj`；选择时会校验文件内容。配置及新增配置保存在 `~/Library/Application Support/corplink-rs/`；管理服务只监听本机回环地址。验证码可在管理窗口发送给正在等待输入的客户端。

构建 Rust 客户端前，按项目 README 的说明先构建 `libwg`。Swift 菜单栏应用不需要第三方依赖。
