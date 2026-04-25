#!/bin/bash
PID_FILE="running/logs/nginx.pid"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/openresty/lualib:$LD_LIBRARY_PATH:lib:Linux-x86_64"

# 优先通过 nginx -s stop 优雅退出（发送 SIGTERM，等待 worker 处理完请求）
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        openresty/nginx/sbin/nginx -c conf/nginx.conf -p running/ -s stop 2>/dev/null || kill -TERM "$PID"
        # 等待进程真正退出（最多 15 秒），确保 WAL checkpoint 完成
        for i in $(seq 1 15); do
            sleep 1
            kill -0 "$PID" 2>/dev/null || { echo "nginx stopped (${i}s)"; exit 0; }
        done
        echo "WARNING: nginx did not stop gracefully after 15s, forcing..." >&2
        kill -9 "$PID" 2>/dev/null
    else
        echo "nginx is not running"
    fi
else
    # 没有 pid 文件，尝试按进程名查找
    PIDS=$(pgrep -f "nginx: master" 2>/dev/null)
    if [ -n "$PIDS" ]; then
        kill -TERM $PIDS
        sleep 3
        echo "nginx stopped"
    else
        echo "nginx is not running"
    fi
fi

