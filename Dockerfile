# syntax=docker/dockerfile:1
#
# SnowLuma 自包含镜像（本仓库新增）
#
# 官方预构建镜像 motricseven7/snowluma 已从 Docker Hub 下架，因此这里不再依赖它，
# 而是把运行环境完整装进本镜像：Linux QQ + Xvfb + x11vnc + noVNC(websockify) + supervisord。
#
# 构建：
#   docker build -t snowluma:local .
#   docker build -t snowluma:local --build-arg TARGET=linux-arm64 .
#   docker build -t snowluma:local --build-arg QQ_DEB_URL=<完整 deb 链接> .
#
# QQ 安装包：腾讯会不定期改文件名，下方按候选地址依次尝试；全都失效时用
# QQ_DEB_URL 直接指定。链接可从 https://im.qq.com/linuxqq/index.html 复制。

ARG NODE_VERSION=24
ARG QQ_DEB_URL=

# ---------- 阶段 1：编译 SnowLuma ----------
FROM node:${NODE_VERSION}-bookworm-slim AS builder

WORKDIR /src

RUN npm i -g pnpm@11.25.0

COPY . .

ARG TARGET=linux-x64
ENV SNOWLUMA_TARGET=${TARGET}

RUN pnpm install --frozen-lockfile \
 && pnpm run build:all \
 && pnpm run check:release-layout

# ---------- 阶段 2：运行环境 ----------
FROM node:${NODE_VERSION}-bookworm-slim

ARG TARGETARCH
ARG QQ_DEB_URL

ENV DEBIAN_FRONTEND=noninteractive \
    VNC_PASSWD=vncpasswd \
    TZ=Asia/Shanghai \
    SNOWLUMA_HOME=/app/snowluma \
    SNOWLUMA_DATA=/app/snowluma-data \
    SNOWLUMA_WEBUI_PORT=5099 \
    SNOWLUMA_UID=1000 \
    SNOWLUMA_GID=1000 \
    SNOWLUMA_LOG_LEVEL=info \
    SNOWLUMA_SCREEN=1920x1080x16 \
    SNOWLUMA_HOOK_AUTOLOAD=1 \
    DISPLAY=:1

# 若某个发行版缺少 novnc / websockify 软件包，可用下面的方式替代：
#   git clone --depth=1 https://github.com/novnc/noVNC.git /usr/share/novnc
#   git clone --depth=1 https://github.com/novnc/websockify.git /usr/share/novnc/utils/websockify
# 并把 docker/start.sh 里的 `websockify --web=...` 换成 /usr/share/novnc/utils/novnc_proxy
RUN apt-get update && apt-get install -y --no-install-recommends \
      aria2 \
      ca-certificates \
      curl \
      dbus-user-session \
      ffmpeg \
      fluxbox \
      fonts-wqy-zenhei \
      git \
      libasound2 \
      libatspi2.0-0 \
      libgbm1 \
      libgtk-3-0 \
      libnotify4 \
      libnss3 \
      libsecret-1-0 \
      novnc \
      procps \
      supervisor \
      tzdata \
      unzip \
      websockify \
      x11vnc \
      xdg-utils \
      xorg \
      xvfb \
    && ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 安装 Linux QQ：按候选地址依次尝试，全部失败则报错提示手动指定
RUN set -eux; \
    qq_arch="$(dpkg --print-architecture)"; \
    case "${qq_arch}" in \
      amd64|arm64) ;; \
      *) echo "不支持的架构: ${qq_arch}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    base="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux"; \
    cand1="${base}/QQ_3.2.27_260401_${qq_arch}_01.deb"; \
    cand2="${base}/linuxqq_3.2.27-47256_${qq_arch}.deb"; \
    cand3="${base}/linuxqq_3.2.28-48517_${qq_arch}.deb"; \
    got=""; \
    for u in "${QQ_DEB_URL}" "${cand1}" "${cand2}" "${cand3}"; do \
      [ -n "${u}" ] || continue; \
      echo ">>> 尝试下载 ${u}"; \
      if aria2c --check-certificate=false -x16 -s16 --allow-overwrite=true \
           -o /tmp/linuxqq.deb "${u}"; then got="${u}"; break; fi; \
      rm -f /tmp/linuxqq.deb; \
    done; \
    [ -n "${got}" ] || { \
      echo "QQ 安装包下载失败：候选地址均不可用。" >&2; \
      echo "请到 https://im.qq.com/linuxqq/index.html 复制当前 deb 链接，然后：" >&2; \
      echo "  docker compose build --build-arg QQ_DEB_URL=<完整链接>" >&2; \
      exit 1; \
    }; \
    echo ">>> 使用 ${got}"; \
    (dpkg -i /tmp/linuxqq.deb || apt-get -f install -y --no-install-recommends); \
    rm -f /tmp/linuxqq.deb; \
    chmod 777 /opt/QQ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# 运行用户与目录骨架
RUN groupadd --gid 1001 snowluma \
 && useradd --no-log-init --uid 1001 --gid 1001 --home-dir /app --shell /bin/bash snowluma \
 && mkdir -p "${SNOWLUMA_HOME}" "${SNOWLUMA_DATA}" /app/.cache /app/.config /app/.local/share

# SnowLuma 产物（vite 构建后的 dist 就是发行版根目录）
COPY --from=builder /src/dist/ /app/snowluma/

COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/start.sh /root/start.sh

RUN chmod +x /root/start.sh \
 && case "$(dpkg --print-architecture)" in \
      amd64) native_arch="x64" ;; \
      arm64) native_arch="arm64" ;; \
      *) echo "不支持的架构" >&2; exit 1 ;; \
    esac \
 && test -f "${SNOWLUMA_HOME}/index.mjs" \
 && test -f "${SNOWLUMA_HOME}/native/snowluma-linux-${native_arch}.node" \
 && test -f "${SNOWLUMA_HOME}/native/snowluma-linux-${native_arch}.so" \
 && test -f "${SNOWLUMA_HOME}/native/websocket-linux-${native_arch}.node" \
 && chown -R snowluma:snowluma /app /opt/QQ

WORKDIR /app/snowluma-data

EXPOSE 5900 6081 5099 3000 3001

VOLUME ["/app/snowluma-data", "/app/.config", "/app/.local/share"]

CMD ["/root/start.sh"]
