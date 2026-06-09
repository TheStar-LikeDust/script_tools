# LobeChat 全栈部署 (Deploy)

## 1. 简介

> LobeChat 是一个现代化的、功能强大的开源大型语言模型（LLM）用户交互客户端，全栈版包含了前端以及存储、S3、多用户认证等完备的生产级基础设施。

全栈部署通过级联模式动态组网整合了 ParadeDB、RustFS 与 Casdoor，提供完整闭环体验。系统采用非阻塞机制直接拉起所有依赖，利用容器内建重试度过数据库初始化阶段；其中 LobeChat 与 Casdoor 分别拥有互不干扰的独立 ParadeDB 实例以确保数据完全隔离。

## 2. 核心配置项

### settings.conf

- `INSTANCE_NAME`: 全局业务实例名，时间戳后缀（默认如 `lobechat_8421`），决定容器名、数据目录与网络名 `${INSTANCE_NAME}_net`。
- `LOBECHAT_PORT`: 面板对外暴露的宿主机端口（容器内 `3210`）。
- `KEY_VAULTS_SECRET` / `AUTH_SECRET`: 自动生成的安全密钥。
- `CASDOOR_PUBLIC_HOST`: 构建 Casdoor SSO issuer 的浏览器可达地址，默认 `localhost`（仅本机端口转发访问）。需外部访问时改成公网 IP 或域名。
- `CASDOOR_CLIENT_ID` / `CASDOOR_CLIENT_SECRET`: 在 Casdoor 后台为 LobeChat 创建应用后回填。
- `USE_INTERNAL_DB` / `USE_INTERNAL_REDIS` / `USE_INTERNAL_S3` / `USE_INTERNAL_CASDOOR`: 每个依赖是否自动捆绑；置 `false` 时改用对应的 `EXTERNAL_*` 连接信息。
- `S3_BUCKET`: 内部 rustfs 模式使用的桶名（默认 `lobechat`）。

### 附带组件配置

- `settings_paradedb.conf`: 包含 ParadeDB 的端口与验证凭证。
- `settings_redis.conf`: 包含 Redis 的暴露端口配置。
- `settings_rustfs.conf`: 包含 RustFS 的端口及管理凭证。

## 3. 备注

- S3 存储桶预建：内部部署的 RustFS 默认不自动建桶，需在全栈首次启动后，登录 RustFS 控制台手动创建 `lobechat` 桶。
- SSO 首次接入流程：首次 `up` 拉起后，需登录 Casdoor 后台为 LobeChat 手动创建应用获取 Client ID/Secret，填入 `settings.conf` 后执行 `bash cli.sh rm && bash cli.sh start` 重建容器使其生效。

## 4. 快速执行

```bash
cd deploy_apps/lobechat

# 常规分步拉起（推荐）：先生成配置、按需修改 settings.conf 后再启动
bash cli.sh init
bash cli.sh start

# 一键拉起整个 LobeChat 集群（跳过配置直接启动）
bash cli.sh up

# 停止运行
bash cli.sh stop

# 销毁全栈所有容器（保留配置与 data/ 数据目录）
bash cli.sh rm

# 危险操作：彻底销毁全栈所有容器，并删除各自挂载的 data/ 数据目录
bash cli.sh purge
```

## 5. 命令解释

#### init

生成 `settings.conf`；按需调用基础服务 `init` 准备 `settings_*.conf`。不启动容器。

```bash
# 级联 init 依赖
deploy_paradedb init --name "paradedb_${INSTANCE_NAME}"
deploy_redis init --name "redis_${INSTANCE_NAME}"
deploy_rustfs init --name "rustfs_${INSTANCE_NAME}"
deploy_casdoor init
```

#### start

按需启动依赖服务并连接网络，随后拼接连接串启动 lobechat 主体。

```bash
# 启动依赖服务并接入网络
docker network create "${INSTANCE_NAME}_net"
deploy_paradedb start
docker network connect "${INSTANCE_NAME}_net" "paradedb_${INSTANCE_NAME}"

# 拉起 LobeChat 主体
docker run -d \
    --name "${INSTANCE_NAME}" \
    --network "${INSTANCE_NAME}_net" \
    -p "${LOBECHAT_PORT}:3210" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/app/data" \
    -e "DATABASE_URL=${db_url}" \
    -e "REDIS_URL=${redis_url}" \
    lobehub/lobehub:latest
```

#### up

先 `init` 再 `start`。

#### stop

停止 LobeChat 及内部依赖容器。

```bash
docker stop "${INSTANCE_NAME}"
deploy_casdoor stop
deploy_rustfs stop
deploy_redis stop
deploy_paradedb stop
```

#### rm

删除容器，保留配置与数据目录。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
deploy_casdoor rm
docker network rm "${INSTANCE_NAME}_net"
```

#### purge

删除容器并清理数据目录，保留配置。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
deploy_casdoor purge
docker network rm "${INSTANCE_NAME}_net"
```

## 6. 其他补充

- 镜像版本：当前固定 `lobehub/lobehub:latest`，需可复现可锁定具体标签。
