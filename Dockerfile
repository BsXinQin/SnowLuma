# syntax=docker/dockerfile:1
#
# SnowLuma 容器镜像（本仓库新增）
#
# 官方镜像 motricseven7/snowluma 已经把「Linux QQ + Xvfb + noVNC + supervisord」
# 运行环境装好了，它自己只是把发行版 tarball 解压到 /app/snowluma。所以这里用
# 官方镜像做底座，只替换产物层——真正的编译过程与官方 release 流水线一致：
#
#   pnpm install --frozen-lockfile
#   SNOWLUMA_TARGET=<target> pnpm run build:all
#   pnpm run check:release-layout
#
# 构建：
#   docker build -t snowluma:local .
#   docker build -t snowluma:local --build-arg TARGET=linux-arm64 .
#   docker build -t snowluma:local \
#     --build-arg BASE_IMAGE=docker.m.daocloud.io/motricseven7/snowluma:latest .

ARG BASE_IMAGE=motricseven7/snowluma:latest

# ---------- 阶段 1：编译 ----------
# 版本对齐 .node-version（24.22.1）；.npmrc 里 engine-strict=true，低版本装不上
FROM node:24-bookworm-slim AS builder

WORKDIR /src

RUN npm i -g pnpm@11.25.0

COPY . .

# 打包哪一套 native 产物：linux-x64 / linux-arm64
ARG TARGET=linux-x64
ENV SNOWLUMA_TARGET=${TARGET}

RUN pnpm install --frozen-lockfile \
 && pnpm run build:all \
 && pnpm run check:release-layout

# ---------- 阶段 2：运行 ----------
FROM ${BASE_IMAGE}

# 底座镜像的 Node 未必是 24.x，而 dist 是按 24 编译的；supervisord 显式调用
# /usr/local/bin/node 启动 SnowLuma，覆盖它即可保证版本一致。
COPY --from=builder /usr/local/bin/node /usr/local/bin/node

# 清掉底座自带的旧发行版，换成自己编译的
RUN rm -rf /app/snowluma && mkdir -p /app/snowluma
COPY --from=builder /src/dist/ /app/snowluma/

# 不在此处 chown：start.sh 每次启动都会按 SNOWLUMA_UID/GID 重新 chown /app，
# 在镜像层里做一次会把产物完整复制一遍，白白多几百 MB。

# 沿用底座镜像的入口（supervisord → QQ + snowluma）
