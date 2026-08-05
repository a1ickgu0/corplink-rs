# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`corplink-rs` is a Rust client for **飞连 (CorpLink)**, a corporate VPN built on a modified fork of `wireguard-go`. It logs into the CorpLink REST API (password / email / LDAP / Lark-Feishu-OIDC, with TOTP 2FA), selects a VPN server by latency, fetches a WireGuard config, then starts the embedded `libwg` and configures it over UAPI. Supports Linux, Windows 10, and macOS. This is a **privately customized fork** ("纯定制不建议他人使用") — not intended for general use.

Code comments are in **Chinese**. The README is the authoritative reference for config-file semantics.

## Build & run

`libwg` is a git submodule and must be compiled to a C archive **before** `cargo build`, because `build.rs` runs `bindgen` on `libwg/libwg.h` and links `libwg.a`:

```bash
# 1. build libwg (Go toolchain + git submodule required)
cd libwg && ./build.sh        # Linux/macOS  (runs: git submodule update --init --recursive; make libwg)
cd libwg && ./build.ps1       # Windows
# produces libwg/libwg.a + libwg/libwg.h (both gitignored)

# 2. build the binary
cd .. && cargo build --release   # -> target/release/corplink-rs

# 3. run (needs root / admin to start the TUN device)
sudo ./target/release/corplink-rs config.json
```

- If `cargo build` fails to link, `libwg/libwg.a` was not built (the committed root-level `libwg.a`/`libwg.h` are stale; build.rs reads from `libwg/`).
- CI (`.github/workflows/release.yml`, `test.yml`) does exactly this: setup Go → `cd libwg && ./build.sh|ps1` → `cargo build --release`.
- `cargo test`: there are **no unit/integration tests**; only a doc-test in `src/template.rs`. `cargo clippy` is the main lint.
- Arch packaging: `pack/PKGBUILD`; systemd units in `systemd/`.
- Debug via `.vscode/launch.json` (lldb, runs `target/debug/corplink-rs /tmp/config.json`).

## Runtime config files

- **Main config** (path is the CLI arg, default `config.json`): the `Config` struct in `src/config.rs`. `Config::from_file` **auto-populates and rewrites the file**: generates a WireGuard keypair if absent, derives `public_key` from `private_key`, computes `device_id` as md5 of `device_name`, and fills default `interface_name`/`device_name`. Notable keys: `platform` (`feilian`/`ldap`/`lark`/`OIDC`), `code` (TOTP secret), `vpn_select_strategy` (`latency`|`default`), `vpn_server_name`, `protocol_mode` (0=UDP, 1=TCP; forces the mode over the server's), `intranet_domain` (skip-VPN mode), `vpn_server_ip_bypass`, `origin_dns`, `performance`, `use_vpn_dns` (macOS), `log_directory`, `log_level`, `qr_image_size` (tps 扫码二维码以 PNG 图片弹窗的目标边长 px，缺省 640；无图形环境时自动回退终端渲染).
- **check_config.json** (`check_config_path`, hardcoded default `/Users/luantu/corplink/check_config.json`): the `CheckConfig` struct — Feishu webhook URL, a Clash `config.yaml` path, proxy name, SVN credentials, and whether to notify on disconnect. This drives the company-specific Feishu notifications and config.yaml auto-update.
- **Cookies**: persisted as `{interface_name}_cookies.json` next to the main config file (per-interface, so different configs don't share sessions). `Client::new` restores them, `save_cookie()` writes them back whenever a `Set-Cookie` header appears.

## Architecture

The runtime is a **single long-lived process** with a reconnect loop in `src/main.rs`:

1. Parse config → init logger → read `check_config` → install panic hook (sends Feishu alert) → check privileges.
2. If `server` is unset, resolve the company's server URL via the `corplink.volcengine.cn/api/match` endpoint (`client::get_company_url`) and persist it.
3. Outer loop: repeatedly run `login → connect_vpn → start/configure wg → keep alive`, with exponential backoff (5s→10s) and Feishu failure notifications. On any terminal error it rebuilds the `Client` and retries forever.
4. In-flight loop uses `tokio::select!` over: SIGINT/SIGTERM, `keep_alive_vpn` failure, and `uapi.check_wg_connection()` (handshake timeout). On exit: `stop_wg_go` → `disconnect_vpn` → (macOS) restore DNS.

Key modules:

- `src/client.rs` — the `Client` struct (heart of the app): all API calls, login method dispatch, TOTP 2FA, VPN selection (`latency` pings each candidate incl. `backup_ips`, honoring `vpn_server_ip_bypass`), intranet detection, keep-alive, disconnect. Login order comes from the server (`login_orders`), falling back through tps (third-party, QR-based) → corplink → ldap. Errors containing `"logout"` flip the persisted state back to `Init` to force re-login.
- `src/api.rs` — every endpoint is a `{{url}}/{{os}}/{{version}}` template rendered by `Template` (`src/template.rs`). Two URL params exist: `user_param` (the company server) and `vpn_param` (the per-VPN-server address, swapped in during `ping_single_ip`/`connect_vpn`). **Adding an endpoint means adding it to both the `ApiName` enum and `ApiUrl::new`/`get_api_url`.**
- `src/wg.rs` — FFI to `libwg` (Go wireguard). `start_wg_go(name, protocol, with_log)` starts the interface; `UAPIClient::config_wg` serializes a full wg config (keys, endpoint, allowed_ips, routes, MTU, keepalive) into a uapi command string; `check_wg_connection` polls `last_handshake_time_sec` and returns to trigger a reconnect after 5 min without a handshake. `set_performance_config` is exposed when `performance` is set in config.
- `src/config.rs` — `Config` / `WgConf` / `PerformanceConfig` / `CheckConfig` structs and platform/strategy constants.
- `src/yaml.rs` — after a successful connect, updates the `server` field of a named proxy in a Clash `config.yaml` and runs `svn update`/`svn commit` on it (company workflow for pointing an internal proxy at the VPN-assigned IP).
- `src/dns.rs` — macOS only: save/restore per-service DNS via `networksetup`.
- `src/utils.rs` — x25519 key generation, base32/base64/base64→hex, Feishu webhook sender, shell helpers (`ifconfig`, `route`, `dig`, `ping`), privilege check, stdin read.
- Small helpers: `src/totp.rs` (TOTP), `src/qrcode.rs` (terminal QR for tps login), `src/state.rs` (login `State`, persisted in config), `src/resp.rs` (API response DTOs wrapped in `Resp<T>{code,message,data}`), `src/performance.rs` (unused metrics scaffold).

## Platform-specific gotchas

- **Privileges**: `sudo::escalate_if_needed` on Unix / `is_elevated` on Windows — the process must run as root/admin. `utils::check_privilege` gates startup.
- **macOS**: the TUN interface name must match `utun[0-9]*` with the number ≤ 32767 (see README #46). `use_vpn_dns: true` sets VPN DNS via `networksetup` and restores it on clean exit (not on crash).
- **Windows**: requires `wintun.dll` next to the binary (or in PATH); uses the `stable-x86_64-pc-windows-gnu` toolchain in CI.
- **Interface name**: default differs by context — `config.rs` defaults to `corplink`, `main.rs`'s `DEFAULT_INTERFACE_NAME` is `wg-corplink`. The interface name also names the cookie file, so changing it invalidates the session.

## Logging

`flexi_logger` writes `corplink.log` (level from `log_level` config key or `RUST_LOG`), duplicating to stderr. `initialize_logger` in `main.rs` tries config dir → cwd → temp dir → stdout as fallbacks. `debug_wg: true` enables verbose libwg logs.
