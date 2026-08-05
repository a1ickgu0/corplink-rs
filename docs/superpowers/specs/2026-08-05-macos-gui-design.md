# macOS GUI for corplink-rs — Design

Date: 2026-08-05
Status: Approved (architecture, UI, layout)
Scope: A minimal macOS GUI wrapper around the existing `corplink-rs` CLI binary.

## Goal

A small native macOS app that drives the existing `corplink-rs` binary so the VPN can be
used without a terminal. Features (minimal, "够用就行"):

1. **Login** (connect) — starts the VPN.
2. **Display QR image** — for Lark/OIDC scan login.
3. **Logout/exit** (disconnect) — stops the VPN.
4. **Show process logs** — live tail.
5. **Reveal config file in Finder**.

The CLI continues to work standalone and is unchanged in behavior. GUI lives in a
separate `macos-gui/` directory and builds independently (no Rust↔Swift linking).

## Non-goals

Menu-bar-only mode, auto-bundling the binary into the app, a privileged launchd helper,
settings windows, theming. (Possible later; out of scope for v1.)

## Process model

```
corplink-gui (user app)
   │  osascript "...session-controller.sh <binary> <config>" with administrator privileges
   ▼
session-controller.sh (root)            corplink-rs (root, VPN)
   ├─ launches corplink-rs in background, records PID
   ├─ keeps a persistent writer on the stdin FIFO (no EOF during session)
   ├─ redirects corplink stderr → /tmp/corplink_gui.log
   └─ polls /tmp/corplink_stop.flag → kill -TERM PID → exit
```

One macOS admin password prompt per connected session. The binary's own
`escalate_if_needed()` sees it is already root and does not re-prompt.

## Shared contract (GUI + controller + binary MUST agree)

Env knobs injected by the controller when launching the binary:
- `CORPLINK_QR_PATH=/tmp/corplink_qr.png` — override QR PNG output path.
- `CORPLINK_NO_QR_VIEWER=1` — skip popping the external image viewer (GUI shows it in-window).

Fixed runtime paths (all world-readable under `/tmp`):
- `/tmp/corplink_gui.log` — log; controller redirects the binary's stderr here; GUI tails.
- `/tmp/corplink_qr.png` — QR image; binary writes it (because `CORPLINK_QR_PATH` is set); GUI watches mtime.
- `/tmp/corplink_stop.flag` — GUI touches this to request stop; controller polls → kills VPN.
- `/tmp/corplink_stdin.fifo` — named pipe; GUI writes `y\n` to confirm scan; binary reads stdin from here.

Scan-confirm: when `/tmp/corplink_gui.log` contains the line
`请在完成扫码验证后输入 'y' 继续`, the GUI shows a "已扫码，继续" button; clicking
writes `y\n` into the FIFO.

FIFO keepalive (critical): the binary calls `stdin.read_line` in a `while !confirmed`
loop. A FIFO returns EOF when **all** writers close, which would busy-loop the binary.
The controller MUST hold a persistent writer fd open on the FIFO for the whole session
so the binary never sees EOF until the controller exits.

## GUI

SwiftUI single window. State machine:
`idle → connecting → connected`, scan branch `connecting → waitingScan → connected`,
any → `error`. Buttons [连接]/[退出] are mutually exclusive by state.

Layout: status row (● colored + text), connect/disconnect buttons, config-path row +
"在 Finder 中显示" button, QR area (only in `waitingScan`) with "已扫码，继续" button,
and a scrolling monospace log view that auto-tails.

- Status: derived from `VPNController` (Process running = connected, etc.).
- Log: poll `/tmp/corplink_gui.log` every 0.5s, append new bytes; scan new text for the
  confirm trigger to flip into `waitingScan`.
- QR: poll `/tmp/corplink_qr.png` mtime; reload `NSImage` when it changes.
- Confirm: open FIFO, write `y\n`, close (controller's keepalive prevents EOF).
- Disconnect: `touch /tmp/corplink_stop.flag`; Process `terminationHandler` → `idle`.
- Reveal config: `NSWorkspace.shared.activateFileViewerSelecting([configURL])`.

Settings (UserDefaults): `binaryPath` (default `$(which corplink-rs)` or repo
`target/release/corplink-rs`), `configPath` (default `config.json`), `controllerScriptPath`
(default repo `macos-gui/scripts/session-controller.sh`). NSOpenPanel to locate if missing.

## Build / file layout

SwiftPM executable (decoupled from `cargo build`):

```
corplink-rs/
  src/qrcode.rs            # +env knobs (CORPLINK_QR_PATH / CORPLINK_NO_QR_VIEWER)
  macos-gui/
    Package.swift          # executable target "corplink-gui", macOS 13+, SwiftUI
    Sources/corplink-gui/
      CorplinkGUIApp.swift      # @main App + WindowGroup
      AppState.swift            # state enum + ObservableObject model
      VPNController.swift       # Process(osascript), stop.flag, FIFO write, path mgmt
      LogTailer.swift           # poll log file, detect confirm trigger
      ContentView.swift         # main window layout
      QRView.swift / LogView.swift
    scripts/
      session-controller.sh     # root controller
      test_controller.sh        # shell acceptance test
    README.md
```

Build/run: `cd macos-gui && swift build -c release` → `.build/release/corplink-gui`.
(A future .app/Xcode-project wrap is out of scope for v1.)

## CLI change to the Rust repo

Only `src/qrcode.rs::open_as_png`:
- QR output path honors `CORPLINK_QR_PATH` (default unchanged: temp dir).
- If `CORPLINK_NO_QR_VIEWER=1`, skip `utils::open_file` (the viewer pop).
Standalone CLI behavior is unchanged when these env vars are unset.

## Error handling

- User cancels admin prompt / binary missing → `error` state, reason in status + log.
- QR timeout, login failure → reflected in tailed logs (the binary already logs/alerts).
- Stale stop flag: controller removes it on startup.

## Testing

- `AppState` (state machine) and `LogTailer` (trigger detection) as unit-testable pure
  Swift types.
- `scripts/test_controller.sh`: exercises start → writes `y` via FIFO → stop.flag → clean
  exit, using a stub binary that mimics corplink-rs's stdin/QR/log behavior.
- Manual checklist in README (connect/disconnect, scan flow, Finder reveal, log tail).
