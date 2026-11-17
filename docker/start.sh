#!/usr/bin/env bash
# 容器入口：准备运行环境后交给 supervisord 管理 QQ 与 SnowLuma
# 移植自 SnowLuma.Docker.Framework，改为使用 Debian 软件包里的 noVNC / websockify

set -euo pipefail

: "${VNC_PASSWD:=vncpasswd}"
: "${SNOWLUMA_UID:=1000}"
: "${SNOWLUMA_GID:=1000}"
: "${SNOWLUMA_HOME:=/app/snowluma}"
: "${SNOWLUMA_DATA:=/app/snowluma-data}"
: "${SNOWLUMA_WEBUI_PORT:=5099}"
: "${SNOWLUMA_LOG_LEVEL:=info}"
: "${SNOWLUMA_SCREEN:=1920x1080x16}"
: "${SNOWLUMA_HOOK_AUTOLOAD:=1}"

export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/snowluma-${SNOWLUMA_UID}}"
export SNOWLUMA_HOOK_RUNTIME_DIR="${SNOWLUMA_HOOK_RUNTIME_DIR:-${XDG_RUNTIME_DIR}}"
export SNOWLUMA_LOG_LEVEL SNOWLUMA_HOOK_AUTOLOAD

DISPLAY_NUM="${DISPLAY#:}"
DISPLAY_NUM="${DISPLAY_NUM%%.*}"

chmod 1777 /tmp || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix || true
rm -f /run/dbus/pid "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" || true

mkdir -p /var/run/dbus /root/.vnc "${XDG_RUNTIME_DIR}" "${SNOWLUMA_DATA}/config" \
         /app/.cache /app/.config /app/.local/share

groupmod -o -g "${SNOWLUMA_GID}" snowluma
usermod -o -u "${SNOWLUMA_UID}" -g "${SNOWLUMA_GID}" snowluma

chown -R "${SNOWLUMA_UID}:${SNOWLUMA_GID}" /app /opt/QQ "${XDG_RUNTIME_DIR}" || true
chmod 700 "${XDG_RUNTIME_DIR}"

# 容器重启会残留失效的 AF_UNIX socket，先清掉，避免 pid 复用被误判为已注入
find "${XDG_RUNTIME_DIR}" -maxdepth 1 -type s -name 'mojo.*.*.sock' -delete 2>/dev/null || true

# 把 WebUI 端口写进 runtime.json（环境变量优先，不落盘覆盖其它字段）
node <<'NODE'
const fs = require('fs');
const path = require('path');

const dataDir = process.env.SNOWLUMA_DATA || '/app/snowluma-data';
const configDir = path.join(dataDir, 'config');
const runtimeConfigPath = path.join(configDir, 'runtime.json');
const requestedPort = Number(process.env.SNOWLUMA_WEBUI_PORT || 5099);
const webuiPort = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535
    ? requestedPort
    : 5099;

fs.mkdirSync(configDir, { recursive: true });

let runtimeConfig = {};
try {
    runtimeConfig = JSON.parse(fs.readFileSync(runtimeConfigPath, 'utf8'));
} catch {
    runtimeConfig = {};
}

runtimeConfig.webuiPort = webuiPort;
fs.writeFileSync(runtimeConfigPath, `${JSON.stringify(runtimeConfig, null, 2)}\n`, 'utf8');
NODE

x11vnc -storepasswd "${VNC_PASSWD}" /root/.vnc/passwd >/dev/null

dbus-daemon --config-file=/usr/share/dbus-1/system.conf --print-address &
Xvfb "${DISPLAY}" -screen 0 "${SNOWLUMA_SCREEN}" &
XVFB_PID=$!

for _ in $(seq 1 200); do
    if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
        break
    fi
    if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
        echo "Xvfb 在显示 ${DISPLAY} 就绪前退出" >&2
        exit 1
    fi
    sleep 0.1
done

fluxbox &
x11vnc -display "${DISPLAY}" -noxrecord -noxfixes -noxdamage -forever -rfbauth /root/.vnc/passwd &
sleep 0.5

nohup websockify --web=/usr/share/novnc 6081 localhost:5900 >/var/log/novnc.log 2>&1 &

exec supervisord -c /etc/supervisord.conf
