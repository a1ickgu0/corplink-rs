#!/bin/sh
# test_controller.sh — session-controller.sh 的自验收测试
#
# 用一个 stub 二进制模拟 corplink-rs 的关键行为（写假 QR、读 stdin 的 y、
# 写日志、然后运行至被 kill），验证 controller 的启动/日志/QR/FIFO 确认/
# 停止语义。无需 root、无需真实 corplink-rs。
#
# 退出码：0 = PASS，非 0 = FAIL。
#
# 注意：controller 使用固定的 /tmp/corplink_* 路径；请勿在真实 VPN 会话运行期间执行本测试。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTROLLER="$HERE/session-controller.sh"

TMP="$(mktemp -d /tmp/corplink_test.XXXXXX)"
STUB="$TMP/stub-corplink"
CONFIG="$TMP/config.json"

LOG=/tmp/corplink_gui.log
QR=/tmp/corplink_qr.png
STOP=/tmp/corplink_stop.flag
FIFO=/tmp/corplink_stdin.fifo
CTRL_PID=""

cleanup() {
    [ -n "$CTRL_PID" ] && kill "$CTRL_PID" 2>/dev/null
    # 兜底回收可能残留的 stub / 保活 sleep
    pkill -f 'sleep 31536000' 2>/dev/null
    pkill -f "stub-corplink" 2>/dev/null
    rm -rf "$TMP" "$LOG" "$QR" "$STOP" "$FIFO"
}
trap 'cleanup' EXIT INT TERM

die() { echo "FAIL: $1"; exit 1; }

# ---- 轮询助手（每 0.2s 一次，<timeout_sec> 为秒数）----
wait_for_file_contains() {   # <file> <string> <timeout_sec>
    _f="$1"; _s="$2"; _t="$3"; _i=0
    while [ "$_i" -lt "$((_t * 5))" ]; do
        grep -Fq "$_s" "$_f" 2>/dev/null && return 0
        sleep 0.2; _i=$((_i + 1))
    done
    die "超时：等待 $_f 包含 [$_s]"
}
wait_for_file_exists() {     # <file> <timeout_sec>
    _f="$1"; _t="$2"; _i=0
    while [ "$_i" -lt "$((_t * 5))" ]; do
        [ -e "$_f" ] && return 0
        sleep 0.2; _i=$((_i + 1))
    done
    die "超时：等待文件出现 $_f"
}
wait_for_proc_gone() {       # <pid> <timeout_sec>
    _p="$1"; _t="$2"; _i=0
    while [ "$_i" -lt "$((_t * 5))" ]; do
        kill -0 "$_p" 2>/dev/null || return 0
        sleep 0.2; _i=$((_i + 1))
    done
    die "超时：等待进程 $_p 退出"
}

# ---- 准备 stub（模拟 corplink-rs）与配置 ----
cat > "$STUB" <<'STUB_EOF'
#!/bin/sh
echo "[STUB] starting qr=${CORPLINK_QR_PATH:-} viewer=${CORPLINK_NO_QR_VIEWER:-} escalate=${CORPLINK_NO_ESCALATE:-}"
[ -n "$CORPLINK_QR_PATH" ] && echo "FAKE-PNG-DATA" > "$CORPLINK_QR_PATH"
echo "[STUB] 请在完成扫码验证后输入 'y' 继续"
# 读一行 stdin（GUI 经 FIFO 写入的 y）
if IFS= read -r line; then
    echo "[STUB] received stdin: <$line>"
fi
echo "[STUB] connected; idling until killed"
while true; do sleep 1; done
STUB_EOF
chmod +x "$STUB"
echo '{}' > "$CONFIG"

# 清掉可能的历史残留（controller 启动时也会清理，这里双保险）
rm -f "$LOG" "$QR" "$STOP" "$FIFO"

# ---- 启动 controller（直接以当前用户运行；逻辑无需 root）----
sh "$CONTROLLER" "$STUB" "$CONFIG" &
CTRL_PID=$!

# 1. 日志生成且含 stub 启动行
wait_for_file_contains "$LOG" "[STUB] starting" 10
echo "  ok: 日志已生成并捕获 stub 启动"

# 2. QR 文件已写入（说明 CORPLINK_QR_PATH 注入生效）
wait_for_file_exists "$QR" 10
grep -Fq "FAKE-PNG-DATA" "$QR" || die "QR 文件内容不符"
echo "  ok: QR PNG 已生成"

# 3. 触发扫码确认：向 FIFO 写 y（与 stub 的 read 会合）
wait_for_file_exists "$FIFO" 10
( echo "y" > "$FIFO" ) &
wait_for_file_contains "$LOG" "[STUB] received stdin: <y>" 10
echo "  ok: 扫码确认已通过 FIFO 送达"

# 4. 请求停止
touch "$STOP"
wait_for_proc_gone "$CTRL_PID" 10
echo "  ok: controller 已退出"

# 5. stub 子进程已被回收
sleep 0.5
if pgrep -f "stub-corplink" >/dev/null 2>&1; then die "stub 进程仍在运行（未被 kill）"; fi
echo "  ok: stub 已被回收，无残留"

echo "PASS"
exit 0
