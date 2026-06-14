# Sub2API 部署 (Deploy)

## 1. 简介

> Sub2API 是一个 AI 模型订阅转 API 的网关，将上游订阅账号统一聚合为标准 API，提供账号管理、密钥分发与请求转发能力。

它依赖 PostgreSQL 持久化业务数据、依赖 Redis 做缓存。部署采用全捆绑模式：`init` 通过级联机制委托 `deploy/paradedb` 与 `deploy/redis` 在本目录内生成各自配置与数据落点，`start` 时动态组建专属网络将三个容器按容器名直连。容器以 `AUTO_SETUP=true` 自动完成数据库迁移，并在首次启动按 `ADMIN_EMAIL`/`ADMIN_PASSWORD` 自动创建管理员账号。

## 2. 核心配置项

### settings_sub2api.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `sub2api_8421`），决定容器名与数据目录。
- `SUB2API_PORT`: 对外暴露的 Web UI / API 端口（容器内 `8080`）。
- `TZ`: 容器时区，默认 `Asia/Shanghai`，影响数据库时间戳、统计当日边界、订阅到期与日志时间。
- `SERVER_MODE`: 运行模式，默认 `release`。
- `RUN_MODE`: 运行档位，默认 `standard`。
- `ADMIN_EMAIL`: 管理员邮箱，默认 `admin@sub2api.local`。
- `ADMIN_PASSWORD`: 管理员密码，`init` 时随机生成。
- `JWT_SECRET`: 登录会话签名密钥，`init` 时随机生成（`openssl rand -hex 32`）。首次启动后严禁更换，否则已签发会话全部失效。
- `JWT_EXPIRE_HOUR`: 会话有效期小时数，默认 `24`。
- `TOTP_ENCRYPTION_KEY`: 两步验证 (2FA) 密钥的加密密钥，`init` 时随机生成。首次启动后严禁更换，否则已配置的 TOTP 无法解密。
- `DATABASE_MAX_OPEN_CONNS` / `DATABASE_MAX_IDLE_CONNS` / `DATABASE_CONN_MAX_LIFETIME_MINUTES` / `DATABASE_CONN_MAX_IDLE_TIME_MINUTES`: 数据库连接池参数。
- `REDIS_PASSWORD`: 默认空（捆绑 redis 在隔离网络内无密码）。
- `REDIS_DB` / `REDIS_POOL_SIZE` / `REDIS_MIN_IDLE_CONNS` / `REDIS_ENABLE_TLS`: Redis 连接参数。
- `GEMINI_OAUTH_CLIENT_ID` / `GEMINI_OAUTH_CLIENT_SECRET` / `GEMINI_OAUTH_SCOPES` / `GEMINI_QUOTA_POLICY` / `GEMINI_CLI_OAUTH_CLIENT_SECRET` / `ANTIGRAVITY_OAUTH_CLIENT_SECRET` / `ANTIGRAVITY_USER_AGENT_VERSION`: Gemini 账号的 OAuth 配置，默认空。
- `SECURITY_URL_ALLOWLIST_ENABLED` / `SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP` / `SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS` / `SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS`: URL 白名单安全策略。
- `UPDATE_PROXY_URL`: 访问 GitHub（在线更新与价格数据）的代理，默认空。
- `GATEWAY_*`: 图片流式输出与并发控制等网关参数，沿用镜像默认值。

### settings_paradedb.conf

- 包含附带的 paradedb 实例的连接凭证（业务数据落在其默认 `postgres` 库）。

### settings_redis.conf

- 包含附带的 redis 实例的实例名与端口。

## 3. 备注

- 连接信息注入机制：`DATABASE_HOST/USER/PASSWORD/DBNAME` 与 `REDIS_HOST` 不落盘在 `settings_sub2api.conf`，而是每次 `start` 时从两份附带配置实时读取（host 为依赖容器名、端口为容器内部端口），经 `-e` 注入容器。修改数据库凭证只需改 `settings_paradedb.conf` 后 `rm` 再 `start`。
- 附带 redis 仅在专属隔离网络内被访问，未设密码；对外暴露的仅是 redis 自身 `settings_redis.conf` 中的随机宿主机端口，如需对外屏蔽可手动移除该端口映射。
- 数据库复用项目的 `deploy/paradedb`（PostgreSQL 兼容），默认库与用户均为 `postgres`，`DATABASE_SSLMODE` 固定 `disable`。
- 容器以 `--ulimit nofile=100000:100000` 提升文件句柄上限，适配网关的高并发连接。
- 首次启动按 `ADMIN_EMAIL`/`ADMIN_PASSWORD` 自动创建管理员账号，`start` 结束会回显该凭证。

## 4. 快速执行

```bash
cd deploy_apps/sub2api

# 常规分步拉起（推荐）：先生成配置、按需修改 settings_sub2api.conf 后再启动
bash cli.sh init
bash cli.sh start

# 一键拉起（跳过配置直接启动，会同时起 paradedb、redis 与 sub2api）
bash cli.sh up

# 停止运行
bash cli.sh stop

# 销毁容器（保留配置与 data/ 数据目录）
bash cli.sh rm

# 危险操作：彻底销毁容器，并删除挂载的 data/ 数据目录
bash cli.sh purge
```

## 5. 命令解释

#### init

生成 `settings_sub2api.conf`（仅首次）；委托 paradedb 与 redis 生成 `settings_paradedb.conf` / `settings_redis.conf` 及各自数据目录，并预建 sub2api 数据目录。不启动容器。

```bash
# 1) sub2api 自身配置（仅首次）
sed -e "s/{{INSTANCE_NAME}}/sub2api_<时间戳>/g" \
    -e "s/{{SUB2API_PORT}}/<随机端口>/g" \
    -e "s/{{ADMIN_PASSWORD}}/<随机密码>/g" \
    -e "s/{{JWT_SECRET}}/<随机密钥>/g" \
    -e "s/{{TOTP_ENCRYPTION_KEY}}/<随机密钥>/g" \
    "$SCRIPT_DIR/templates/settings_sub2api.conf.tpl" > settings_sub2api.conf

# 2) 委托 paradedb 与 redis——配置与数据都落在 sub2api 目录
bash ../../deploy/paradedb/cli.sh init \
    --conf "$CONF_DIR/settings_paradedb.conf" \
    --name "sub2api_<时间戳>_paradedb"
bash ../../deploy/redis/cli.sh init \
    --conf "$CONF_DIR/settings_redis.conf" \
    --name "sub2api_<时间戳>_redis"
```

#### start

先起 paradedb 与 redis 并接入专属网络，等数据库健康后读取连接信息，再起 sub2api。

```bash
# 建网络 -> 起依赖 -> 接入网络 -> 等 DB 健康
docker network inspect "${INSTANCE_NAME}_net" >/dev/null 2>&1 || docker network create "${INSTANCE_NAME}_net"
bash ../../deploy/paradedb/cli.sh start --conf "$CONF_DIR/settings_paradedb.conf"
bash ../../deploy/redis/cli.sh start --conf "$CONF_DIR/settings_redis.conf"
docker network connect "${INSTANCE_NAME}_net" "${INSTANCE_NAME}_paradedb"
docker network connect "${INSTANCE_NAME}_net" "${INSTANCE_NAME}_redis"

# 起 sub2api（已存在则仅 docker start）
docker run -d \
    --name "${INSTANCE_NAME}" \
    --network "${INSTANCE_NAME}_net" \
    --ulimit nofile=100000:100000 \
    -p "${SUB2API_PORT}:8080" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/app/data" \
    -e AUTO_SETUP="true" \
    -e SERVER_HOST="0.0.0.0" -e SERVER_PORT="8080" \
    -e DATABASE_HOST="${INSTANCE_NAME}_paradedb" -e DATABASE_PORT="5432" \
    -e DATABASE_USER="postgres" -e DATABASE_PASSWORD="<随机密码>" \
    -e DATABASE_DBNAME="postgres" -e DATABASE_SSLMODE="disable" \
    -e REDIS_HOST="${INSTANCE_NAME}_redis" -e REDIS_PORT="6379" \
    -e ADMIN_EMAIL="admin@sub2api.local" -e ADMIN_PASSWORD="<随机密码>" \
    -e JWT_SECRET="<随机密钥>" -e TOTP_ENCRYPTION_KEY="<随机密钥>" \
    -e TZ="Asia/Shanghai" \
    # ... 其余 settings_sub2api.conf 中的可选参数经 -e 透传 ...
    --health-cmd "wget -q -T 5 -O /dev/null http://localhost:8080/health || exit 1" \
    --restart unless-stopped \
    weishaw/sub2api:latest
```

#### up

先 `init` 再 `start`。

#### stop

停止 sub2api，再停 paradedb 与 redis。

```bash
docker stop "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh stop --conf "$CONF_DIR/settings_paradedb.conf"
bash ../../deploy/redis/cli.sh stop --conf "$CONF_DIR/settings_redis.conf"
```

#### rm

删除三个容器与 app 网络，保留数据与配置。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh rm --conf "$CONF_DIR/settings_paradedb.conf"
bash ../../deploy/redis/cli.sh rm --conf "$CONF_DIR/settings_redis.conf"
docker network rm "${INSTANCE_NAME}_net"
```

#### purge

删除容器并删除本地数据目录，保留配置；连带 `purge` paradedb 与 redis（各自删数据保留配置）并删除 app 网络。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
bash ../../deploy/paradedb/cli.sh purge --conf "$CONF_DIR/settings_paradedb.conf"
bash ../../deploy/redis/cli.sh purge --conf "$CONF_DIR/settings_redis.conf"
docker network rm "${INSTANCE_NAME}_net"
```

#### network ls

经 `lib/network.sh` 展示该实例的专属网络及已连接的容器。

#### 无参 / 未知参数

打印 Usage 帮助。

## 6. 其他补充

- 镜像版本：当前固定 `weishaw/sub2api:latest`，需可复现可锁定具体标签。
- 数据库选型：官方 compose 使用 `postgres:18-alpine`，本项目复用 `deploy/paradedb`（PostgreSQL 兼容）以统一依赖；如需严格对齐官方镜像，可另行替换底层依赖。
- 环境变量：`settings_sub2api.conf` 收录了较完整的可选项（Gemini OAuth、URL 白名单、网关并发等），默认值与官方 compose 一致，无需即可保持默认。
- 依赖 repo 结构：通过相对路径 `../../deploy/paradedb`、`../../deploy/redis` 与 `../../lib/network.sh` 定位共享脚本；sub2api 目录里的配置与数据是可随目录迁移的资产，整体搬迁请连同 repo 一起。
