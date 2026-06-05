# LobeChat 全栈部署 (Deploy)

## 1. 简介

> LobeChat 是一个现代化的、功能强大的开源大型语言模型（LLM）用户交互客户端，全栈版包含了前端以及存储、S3、多用户认证等完备的生产级基础设施。

全栈部署不仅提供 LobeChat 主程序，还通过级联模式整合了 ParadeDB（带 pgvector 存储）、RustFS（S3 附件存储）与 Casdoor（SSO 与权限），提供完整的闭环体验。

## 2. 部署特性

- 委托初始化：调用各基础服务自己的 `cli.sh init --conf settings_X.conf --name X_${INSTANCE_NAME}`，把它们的配置（`settings_paradedb.conf` / `settings_redis.conf` / `settings_rustfs.conf`）与数据都安置在 lobechat 目录下。
- casdoor 独立 DB：casdoor 作为同级 app 被直接调用，它内部自管一个独立 paradedb，配置保留在 casdoor 自己的目录。因此全量捆绑时会有两个 paradedb 容器（lobechat 主库 + casdoor 专用库），各自自洽。
- 统一启停：`start` 按 DB → Redis → S3 → Casdoor → LobeChat 顺序拉起；`stop`/`rm`/`purge` 反向委托各依赖。
- 非阻塞拉起：`start` 为非阻塞拉起，并不会等待数据库 healthcheck 就绪。各容器都带 `--restart unless-stopped`，应用层在依赖未就绪时会自行重启重试。若环境对就绪顺序敏感，可在 `start` 后稍等片刻再访问。

## 3. 核心配置项 (settings.conf)

- `INSTANCE_NAME`: 全局业务实例名，时间戳后缀（默认如 `lobechat_8421`），决定容器名、数据目录与网络名 `${INSTANCE_NAME}_net`。
- `LOBECHAT_PORT`: 面板对外暴露的宿主机端口（容器内 `3210`）。
- `KEY_VAULTS_SECRET` / `AUTH_SECRET`: 自动生成的安全密钥。
- `CASDOOR_PUBLIC_HOST`: 构建 Casdoor SSO issuer 的浏览器可达地址，默认 `localhost`（仅本机端口转发访问）。需外部访问时改成公网 IP 或域名。
- `CASDOOR_CLIENT_ID` / `CASDOOR_CLIENT_SECRET`: 在 Casdoor 后台为 LobeChat 创建应用后回填。
- `USE_INTERNAL_DB` / `USE_INTERNAL_REDIS` / `USE_INTERNAL_S3` / `USE_INTERNAL_CASDOOR`: 每个依赖是否自动捆绑；置 `false` 时改用对应的 `EXTERNAL_*` 连接信息。
- `S3_BUCKET`: 内部 rustfs 模式使用的桶名（默认 `lobechat`）。

## 4. 备注

- 配置与数据落点：
  - LobeChat 自身：`settings.conf`、`data/${INSTANCE_NAME}_data`。
  - 捆绑依赖（paradedb/redis/rustfs）：`settings_paradedb.conf` / `settings_redis.conf` / `settings_rustfs.conf` 及各自 `data/` 都落在 lobechat 目录。
  - Casdoor：配置在 `../casdoor/` 目录（含其自带 paradedb 的 `settings_paradedb.conf` 与数据），由 casdoor 自己管理。
- S3 存储桶：内部 rustfs 模式下，RustFS 不自动建桶，需在 RustFS 控制台手动创建一次。
- SSO 首次接入流程：
  1. `bash cli.sh up` 拉起全栈（LobeChat 初次可能报认证错误，正常现象）。
  2. 登录 Casdoor 后台，为 LobeChat 创建一个应用，拿到 Client ID / Secret。
  3. 把它们填进 `settings.conf` 的 `CASDOOR_CLIENT_ID` / `CASDOOR_CLIENT_SECRET`。
  4. 执行 `bash cli.sh rm && bash cli.sh start` 重建 LobeChat 容器以注入新的认证信息。

## 5. 快速执行

```bash
cd deploy_apps/lobechat

# 一键拉起整个 LobeChat 集群（自动生成各组件所需的库与密码）
bash cli.sh up

# 或分步
bash cli.sh init
bash cli.sh start
```

## 6. 命令解释

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
    -v "$SCRIPT_DIR/data/${INSTANCE_NAME}_data:/app/data" \
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
rm -rf "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
deploy_casdoor purge
docker network rm "${INSTANCE_NAME}_net"
```

#### status

显示所有依赖与主体的运行状态。

## 7. 其他补充

- 镜像版本：当前固定 `lobehub/lobehub:latest`，需可复现可锁定具体标签。
