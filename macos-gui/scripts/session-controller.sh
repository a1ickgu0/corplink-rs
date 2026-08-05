#!/bin/sh
# session-controller.sh
# 由 macOS GUI（SwiftUI 应用）通过 osascript ... with administrator privileges
# 以 root 身份启动。负责启动 corplink-rs 二进制并管理整个会话的生命周期。
#
# 用法: session-controller.sh <binary> <config.json>
#   $1  corplink-rs 二进制的绝对路径
#   $2  配置 json 的绝对路径
#
# 与 GUI / 二进制的契约（不可更改）：
#   - 环境变量 CORPLINK_QR_PATH       指定二维码 PNG 输出路径
#   - 环境变量 CORPLINK_NO_QR_VIEWER=1 抑制外部查看器弹窗
#   - 二进制 stderr/stdout -> /tmp/corplink_gui.log （GUI tail 此文件）
#   - 二进制将二维码写入 /tmp/corplink_qr.png
#   - GUI touch /tmp/corplink_stop.flag 请求停止 -> 控制器 kill 二进制后退出
#   - GUI 经 /tmp/corplink_stdin.fifo 写入 y\n 确认扫码

set -u
# 注意：故意不使用 set -e —— kill/wait 在正常流程里也可能返回非零，需显式忽略。

# ---- 运行时固定路径（GUI 与二进制共同依赖，全部位于 /tmp）----
LOG=/tmp/corplink_gui.log           # 二进制的 stderr/stdout 重定向到此
QR=/tmp/corplink_qr.png             # 二进制写入二维码 PNG
STOP_FLAG=/tmp/corplink_stop.flag    # GUI touch 该文件以请求停止
FIFO=/tmp/corplink_stdin.fifo        # 命名管道；GUI 写入 y\n 以确认扫码

# 子进程 PID（提前初始化，便于退出清理在任意阶段都安全）
PID=""
KEEPALIVE_PID=""

# ---- 1. 参数校验 ----
if [ "$#" -ne 2 ]; then
    echo "usage: $0 <binary> <config.json>" >&2
    exit 2
fi
BIN_PATH=$1
CONFIG_PATH=$2
if [ ! -x "$BIN_PATH" ]; then
    echo "error: 二进制不存在或不可执行: $BIN_PATH" >&2
    exit 2
fi
if [ ! -r "$CONFIG_PATH" ]; then
    echo "error: 配置文件不可读: $CONFIG_PATH" >&2
    exit 2
fi

# ---- 2. 清理上一次运行的残留，保证干净启动 ----
# 控制器以 root 运行、GUI 以普通用户运行：共享文件必须对其他用户可读写，
# 否则 GUI 无法 tail 日志/读 QR，更无法向 FIFO 写 'y'。故把 umask 置 0，
# 使后续创建的 log/FIFO/QR（含二进制继承的 umask）权限为 666。
umask 0
# 保证单实例：杀掉任何残留的 corplink-rs（多次连接 / GUI 异常退出留下的孤儿）。
# 多实例共用同一 cookie/config 会互相破坏 session，导致 OTP 403 死循环。
# 仅匹配以本二进制为 argv[0] 的进程；controller(osascript/sh) 的 argv[0] 不是它，不受影响。
pkill -TERM -f "^$BIN_PATH" 2>/dev/null || true
sleep 0.3
pkill -KILL -f "^$BIN_PATH" 2>/dev/null || true
rm -f "$STOP_FLAG" "$QR"
: > "$LOG"                           # 截断日志

# ---- 3. 重建 FIFO ----
# 总是删除后重建：清除上次可能残留、权限不对（如旧版 root 留下的 644）的 FIFO；
# umask 0 下新建为 666，保证 GUI（普通用户）可写。
rm -f "$FIFO"
mkfifo "$FIFO" || { echo "error: 无法创建 FIFO: $FIFO" >&2; exit 2; }

# ---- 退出清理：避免泄漏 root 启动的 VPN / 保活进程 ----
# 正常退出路径里会先把 PID/KEEPALIVE_PID 清空，故此处对已清空的变量为空操作；
# 异常路径（被信号杀掉）才会真正用到，确保子进程被回收。
cleanup() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null
}
trap 'cleanup' EXIT
trap 'exit 0' INT TERM               # 收到信号 -> exit 0 -> 触发 EXIT 清理

# ---- 4. FIFO 保活（关键！）必须在启动二进制之前完成 ----
# 二进制在 while !confirmed 循环里调用 stdin.read_line。FIFO 仅在【所有写端】
# 都关闭后才向读端返回 EOF；GUI 写完 y 并关闭其写端后，若无其它写端存在，
# 二进制会立刻收到 EOF 并在 read_line 上忙循环（返回 0 字节）。
# 因此控制器必须在整个会话期间持有一个写端 fd。
#
# 做法：后台启动一个 `sleep` 并把它的 stdout 绑定到 FIFO（即以写方式打开 FIFO）。
# 关键时序：以 O_WRONLY 打开 FIFO 会阻塞，直到出现读端。所以必须【先】启动
# 保活写端（它阻塞在 open 上），【再】启动二进制（以读方式打开 FIFO）——
# 二进制的 open 会同时解除保活写端的阻塞。此后只要该 sleep 不退出，写端就一直
# 在，二进制在确认前不会 EOF，确认后也不会因 GUI 关闭而 EOF。会话结束时由
# 控制器主动 kill 该 sleep。
sleep 31536000 > "$FIFO" &           # ~1 年；远大于任何正常会话时长
KEEPALIVE_PID=$!

# ---- 5. 后台启动二进制 ----
# 注入环境变量；stdin 读自 FIFO；stderr/stdout 追加到日志。
export CORPLINK_QR_PATH="$QR"        # 覆盖二维码 PNG 输出路径
export CORPLINK_NO_QR_VIEWER=1       # 抑制外部查看器弹窗
export CORPLINK_NO_ESCALATE=1        # 控制器已以 root 运行（osascript 提权）；
                                     # 告知二进制不要再 sudo 重 exec 自身，否则
                                     # 控制器持有的 PID 会失效、无法停止 VPN。
echo "[controller] start uid=$(id -u) binary=$BIN_PATH config=$CONFIG_PATH" >> "$LOG"
"$BIN_PATH" "$CONFIG_PATH" < "$FIFO" >> "$LOG" 2>&1 &
PID=$!
echo "[controller] launched corplink-rs PID=$PID" >> "$LOG"

# ---- 6. 轮询：约每 0.3s 检查一次停止标志 ----
# 二进制若自行退出（kill -0 失败）也跳出循环。
while kill -0 "$PID" 2>/dev/null; do
    if [ -e "$STOP_FLAG" ]; then
        rm -f "$STOP_FLAG"
        echo "[controller] stop flag detected, terminating PID=$PID" >> "$LOG"
        # 先 TERM；二进制在重试退避期可能吞掉 TERM，故等待 ~3s 后强杀兜底
        kill -TERM "$PID" 2>/dev/null || true
        _i=0
        while [ "$_i" -lt 15 ] && kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
            _i=$((_i + 1))
        done
        kill -KILL "$PID" 2>/dev/null || true
        break
    fi
    sleep 0.3
done

# ---- 7. 收尾 ----
wait "$PID" 2>/dev/null || true      # 回收二进制（尽力而为，忽略错误）
kill "$KEEPALIVE_PID" 2>/dev/null || true   # 关闭保活写端 -> 二进制看到 EOF 并退出
# 清空 PID 以防 EXIT trap 误杀（避免 PID 被系统重用后杀到无关进程）
PID=""
KEEPALIVE_PID=""
exit 0
