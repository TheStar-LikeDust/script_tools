# LobeChat 全栈部署 (Deploy)

## 服务简介

LobeChat 是一个现代化的、功能强大的开源大型语言模型（LLM）用户交互客户端。
全栈编排版（Full-Stack）意味着我们不仅仅是跑起 LobeChat 的前端，而是搭建了一整套完备的生产级基础设施，包括：
1. **ParadeDB (带 pgvector)**：存储用户配置与向量数据。
2. **RustFS (S3)**：负责聊天时的附件、图片上传与存储。
3. **Casdoor**：负责多用户的注册、认证和权限管控。
4. **LobeChat 主程序**：对接上述服务，提供应用本体。

## 编排架构原理

`deploy_apps/lobechat/cli.sh` 作为总控制器，采用与 casdoor 一致的**委托式级联**机制，**不依赖 docker compose**，全程纯 `docker run`：

1. 委托初始化：调用各基础服务自己的 `cli.sh init --conf settings_X.conf --name X_${INSTANCE_NAME}`，把它们的配置（`settings_paradedb.conf` / `settings_redis.conf` / `settings_rustfs.conf`）与数据都安置在 lobechat 目录下。
2. casdoor 自带 DB：casdoor 作为同级 app 被直接调用（`../casdoor/cli.sh`），它内部自管一个独立 paradedb，配置保留在 casdoor 自己的目录。因此全量捆绑时会有两个 paradedb 容器（lobechat 主库 + casdoor 专用库），各自自洽。
3. app 级组网：`start` 时建一个 user-defined network `${INSTANCE_NAME}_net`，把所有依赖容器与 lobechat 容器都接入，容器间按名互通。不再下发 `NETWORK_NAME` 环境变量，也不再用 `APP_PREFIX` 前缀。
4. 连接解析：lobechat 自身用 `docker run` 拉起，启动时从各 `settings_X.conf` 解析 `DATABASE_URL` / `REDIS_URL` / `S3_*` / Casdoor issuer，用 `-e` 注入容器（不再渲染 compose.yml）。
5. 统一启停：`start` 按 DB → Redis → S3 → Casdoor → LobeChat 顺序拉起；`stop`/`rm`/`purge` 反向委托各依赖并清理 `${INSTANCE_NAME}_net`。

> **注意**：`start` 为非阻塞拉起，**并不会等待数据库 healthcheck 就绪**。各容器都带 `--restart unless-stopped`，应用层在依赖未就绪时会自行重启重试。若环境对就绪顺序敏感，可在 `start` 后稍等片刻再访问。

## 核心配置项 (`settings.conf`)

- `INSTANCE_NAME`: 全局业务实例名，时间戳后缀（默认如 `lobechat_8421`），决定容器名、数据目录与网络名 `${INSTANCE_NAME}_net`。
- `LOBECHAT_PORT`: 面板对外暴露的宿主机端口（容器内 `3210`）。
- `KEY_VAULTS_SECRET` / `AUTH_SECRET`: 自动生成的安全密钥。
- `CASDOOR_PUBLIC_HOST`: 构建 Casdoor SSO issuer 的浏览器可达地址，**默认 `localhost`**（仅本机端口转发访问）。需外部访问时改成公网 IP 或域名。
- `CASDOOR_CLIENT_ID` / `CASDOOR_CLIENT_SECRET`: 在 Casdoor 后台为 LobeChat 创建应用后回填；改完执行 `bash cli.sh rm && bash cli.sh start` 重建容器生效。
- `USE_INTERNAL_DB` / `USE_INTERNAL_REDIS` / `USE_INTERNAL_S3` / `USE_INTERNAL_CASDOOR`: 每个依赖是否自动捆绑；置 `false` 时改用对应的 `EXTERNAL_*` 连接信息。
- `S3_BUCKET`: 内部 rustfs 模式使用的桶名（默认 `lobechat`）。**RustFS 不自动建桶**，需在 RustFS 控制台手动创建一次。

> 网络名运行时派生为 `${INSTANCE_NAME}_net`，不写进配置文件。

## 配置与数据落点

- LobeChat 自身：`settings.conf`、`data/${INSTANCE_NAME}_data`。
- 捆绑依赖（paradedb/redis/rustfs）：`settings_paradedb.conf` / `settings_redis.conf` / `settings_rustfs.conf` 及各自 `data/` 都落在 lobechat 目录。
- Casdoor：配置在 `../casdoor/` 目录（含其自带 paradedb 的 `settings_paradedb.conf` 与数据），由 casdoor 自己管理。

## 常见操作

```bash
cd deploy_apps/lobechat

# 一键拉起整个 LobeChat 集群（自动生成各组件所需的库与密码）
bash cli.sh up

# 销毁全部容器（保留配置与 data/）
bash cli.sh rm

# 危险操作：彻底销毁全栈所有容器，并删除各自挂载的 data/ 文件夹
bash cli.sh purge
```

### SSO 首次接入流程

1. `bash cli.sh up` 拉起全栈（LobeChat 初次可能报认证错误，正常现象）。
2. 登录 Casdoor 后台，为 LobeChat 创建一个应用，拿到 Client ID / Secret。
3. 把它们填进 `settings.conf` 的 `CASDOOR_CLIENT_ID` / `CASDOOR_CLIENT_SECRET`。
4. `bash cli.sh rm && bash cli.sh start` 重建 LobeChat 容器以注入新的认证信息。
