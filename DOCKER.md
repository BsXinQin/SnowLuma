# 容器化说明（本仓库新增内容）

本仓库是 **SnowLuma v2.4.2 源码** + 一层容器化封装。容器化文件不属于上游项目，
由本仓库维护；上游目录保持原样。

## 新增与修改

| 文件 | 说明 |
|---|---|
| `Dockerfile` | 两阶段：先用 Node 24 编译出 `dist/`，再覆盖到官方运行环境镜像 |
| `docker-compose.yml` | 单服务编排，含 ptrace / seccomp / shm 必需参数 |
| `.env.example` | 环境变量模板，复制为 `.env` 后使用 |
| `.dockerignore` | 排除 `node_modules`、`dist`、本地数据目录 |
| `DOCKER.md` | 本文档 |
| `.gitignore` | 追加容器运行时产生的目录与 `.env` |
| `.github/workflows/` | **已删除**。上游工作流依赖 SnowLuma 组织自己的 secrets / vars / 私有仓库，在别处必然失败 |

## 构建

```bash
cp .env.example .env      # 改掉 VNC_PASSWD
docker compose up -d --build
docker logs -f snowluma
```

只构建镜像不启动：

```bash
docker build -t snowluma:local .
docker build -t snowluma:local --build-arg TARGET=linux-arm64 .   # ARM 服务器
docker build -t snowluma:local \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/motricseven7/snowluma:latest .
```

构建过程与上游 release 流水线一致：`pnpm install --frozen-lockfile` →
`SNOWLUMA_TARGET=<target> pnpm run build:all` → `pnpm run check:release-layout`。
产物不完整会在构建期直接失败，不会产出半成品镜像。

要求：磁盘至少 3GB 空闲，构建约 5–15 分钟（`pnpm install` 占大头）。

## 端口与目录

| 端口 | 用途 |
|---|---|
| 5099 | WebUI |
| 6081 | noVNC 远程桌面（扫码登录 QQ） |
| 3001 | OneBot v11 正向 WebSocket |
| 5900 | 原生 VNC（未映射，一般不需要） |

| 目录 | 内容 |
|---|---|
| `./data` | `config/runtime.json`、`config/onebot.json`，删掉等于重置配置 |
| `./qq-config` | QQ 登录态，删掉需要重新扫码 |
| `./qq-data` | QQ 数据 |

## 首次启动

```bash
# WebUI 临时密码，只在全新 data 目录首次启动时输出一次
docker logs snowluma 2>&1 | grep -E "临时密码|initial credentials" | tail -1

# 确认 ptrace 能力可用，正常应输出 cap_sys_ptrace=ep
docker exec snowluma getcap /usr/local/bin/node
```

1. 打开 `http://<主机>:6081/`，用 `.env` 里的 `VNC_PASSWD` 登录，扫码登录 QQ。
2. 打开 `http://<主机>:5099/` 登录 WebUI，确认账号在线。
3. 进入连接配置，把 `ws-default` 的 host 从 `127.0.0.1` 改为 `0.0.0.0`，否则
   其他容器无法接入 OneBot。本版本没有对应的环境变量，只能改配置
   （或直接改 `data/config/onebot.json`）。

## 安全

- 三个端口默认只绑定 `127.0.0.1`。`6081` 是能直接操作 QQ 的远程桌面，
  不要暴露到公网；远程访问用 SSH 隧道或反向代理 + 认证 + HTTPS。
- noVNC 走反向代理时需要 WebSocket 支持：

  ```nginx
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_read_timeout 3600s;
  ```

## 许可与分发

上游 SnowLuma 采用**源码可见的非商业许可**（见 `LICENSE`、`EULA.md`），
**不是 OSI 开源许可证**：允许查看、学习、非商业自托管和私下修改；
商业使用、以及**公开发布修改版或衍生版，需事先取得书面授权**。

因此：

- 把本仓库设为 **private** 是最稳妥的用法。
- 若要公开，建议只公开自己写的容器化部分（`Dockerfile`、`docker-compose.yml`、
  `.env.example`、本文档），不要连带分发上游源码。
- 随附的 `packages/runtime/native/*.node` 等原生组件为专有组件，
  不在源码许可范围内。
