#!/usr/bin/env bash
# SnowLuma 一键部署脚本（宝塔面板 / 通用 Linux 服务器）
#
# 用法：
#   sudo bash install.sh
#   sudo TARGET=linux-arm64 bash install.sh          # ARM 服务器
#   sudo BASE_IMAGE=docker.m.daocloud.io/motricseven7/snowluma:latest bash install.sh
#
# 做的事情：检查环境 → 生成 .env（随机 VNC 密码 + 当前用户 UID/GID）
#           → 建数据目录 → 构建镜像（底座拉取失败自动换镜像源）→ 启动 → 打印后续步骤
#
# 重复执行是安全的：已有的 .env 不会被覆盖，已有数据目录不会动。

set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-motricseven7/snowluma:latest}"
MIRROR_IMAGE="${MIRROR_IMAGE:-docker.m.daocloud.io/motricseven7/snowluma:latest}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

WEBUI_PORT="${WEBUI_PORT:-5099}"
NOVNC_PORT="${NOVNC_PORT:-6081}"
ONEBOT_PORT="${ONEBOT_PORT:-3001}"

info() { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

echo "=============================================="
echo " SnowLuma 一键部署"
echo "=============================================="

# ---------- 1. 环境检查 ----------
[ -f "$APP_DIR/Dockerfile" ] || die "在 $APP_DIR 找不到 Dockerfile，请在仓库根目录运行本脚本"

command -v docker >/dev/null 2>&1 || die "未安装 Docker。宝塔：软件商店 → Docker；或 apt install docker.io"

docker info >/dev/null 2>&1 || die "无法连接 Docker 服务（权限或未启动）。试试 sudo，或 systemctl start docker"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
    warn "使用的是旧版 docker-compose，建议升级到 compose v2 插件"
else
    die "缺少 compose。apt install docker-compose-plugin 后重试"
fi
ok "Docker 与 compose 可用（$DC）"

# 架构 → 打包目标
if [ -z "${TARGET:-}" ]; then
    case "$(uname -m)" in
        x86_64|amd64)  TARGET="linux-x64" ;;
        aarch64|arm64) TARGET="linux-arm64" ;;
        *) die "无法识别的架构 $(uname -m)，请手动指定 TARGET=linux-x64 或 linux-arm64" ;;
    esac
fi
info "目标平台：$TARGET"

# 内存提醒
mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
has_swap=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${mem_mb:-0}" -lt 1900 ] && [ "${has_swap:-0}" -eq 0 ]; then
    warn "内存 ${mem_mb}MB 且没有 swap，pnpm install 很可能被 OOM 杀掉"
    warn "建议先执行：fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
fi

# ---------- 2. 生成 .env ----------
cd "$APP_DIR"

# 容器内的运行用户：优先取 sudo 调用者，避免以 root(0) 运行 QQ
host_uid="${SUDO_UID:-$(id -u)}"
host_gid="${SUDO_GID:-$(id -g)}"
if [ "$host_uid" = "0" ]; then
    host_uid=1000
    host_gid=1000
fi

if [ -f .env ]; then
    info "已存在 .env，保留不动"
else
    [ -f .env.example ] || die "缺少 .env.example"
    if command -v openssl >/dev/null 2>&1; then
        vnc_pass=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)
    else
        vnc_pass=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-14)
    fi
    sed -e "s|^VNC_PASSWD=.*|VNC_PASSWD=${vnc_pass}|" \
        -e "s|^SNOWLUMA_UID=.*|SNOWLUMA_UID=${host_uid}|" \
        -e "s|^SNOWLUMA_GID=.*|SNOWLUMA_GID=${host_gid}|" \
        .env.example > .env
    chmod 600 .env
    ok "已生成 .env（VNC 密码：${vnc_pass}）"
fi

# ---------- 3. 数据目录 ----------
mkdir -p data qq-config qq-data
chown -R "${host_uid}:${host_gid}" data qq-config qq-data 2>/dev/null || warn "目录 chown 失败，容器内可能写不进配置"
ok "数据目录就绪：$APP_DIR/{data,qq-config,qq-data}（属主 ${host_uid}:${host_gid}）"

# ---------- 4. 构建 ----------
info "开始构建镜像，首次需要 5-15 分钟（pnpm install 占大头）…"
if $DC build --build-arg TARGET="$TARGET" --build-arg BASE_IMAGE="$BASE_IMAGE" ; then
    ok "镜像构建完成（底座：$BASE_IMAGE）"
else
    warn "构建失败，改用镜像源重试：$MIRROR_IMAGE"
    $DC build --build-arg TARGET="$TARGET" --build-arg BASE_IMAGE="$MIRROR_IMAGE" \
        || die "构建仍然失败，请把上面的错误贴出来"
    ok "镜像构建完成（底座：$MIRROR_IMAGE）"
fi

# ---------- 5. 启动 ----------
$DC up -d
ok "容器已启动"

info "等待 WebUI 就绪…"
for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:${WEBUI_PORT}/" 2>/dev/null; then
        ok "WebUI 已响应 http://127.0.0.1:${WEBUI_PORT}/"
        break
    fi
    sleep 2
done

# ---------- 6. 输出凭据 ----------
echo
echo "=============================================="
echo " 部署完成"
echo "=============================================="
echo " WebUI 端口     : ${WEBUI_PORT}"
echo " noVNC 端口     : ${NOVNC_PORT}  （扫码登录 QQ）"
echo " OneBot WS 端口 : ${ONEBOT_PORT}"
echo " 数据目录       : ${APP_DIR}"
echo
echo " VNC 密码（.env）:"
grep '^VNC_PASSWD=' .env | cut -d= -f2- | sed 's/^/   /'
echo
echo " WebUI 临时密码："
$DC logs --no-color 2>&1 | grep -E "临时密码|initial credentials" | tail -1 | sed 's/^/   /' \
    || echo "   （未找到，可能不是首次启动；可查 data/config 或重置 data 目录）"
echo
echo " 下一步："
echo "   1) 本地建隧道： ssh -L ${WEBUI_PORT}:127.0.0.1:${WEBUI_PORT} -L ${NOVNC_PORT}:127.0.0.1:${NOVNC_PORT} 用户@本机IP"
echo "   2) 打开 http://127.0.0.1:${NOVNC_PORT}/ 扫码登录 QQ"
echo "   3) 打开 http://127.0.0.1:${WEBUI_PORT}/ 登录，把 OneBot 的 ws-default host 改成 0.0.0.0"
echo
echo " 排查：$DC logs -f snowluma"
echo "=============================================="
