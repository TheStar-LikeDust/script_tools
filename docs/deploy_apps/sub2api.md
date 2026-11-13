# Sub2API 部署 (Deploy)

## 1. 简介

> Sub2API 是一个 AI 模型订阅转 API 的网关，将上游订阅账号统一聚合为标准 API，提供账号管理、密钥分发与请求转发能力。

默认通过一个 Docker Compose 项目部署 Sub2API、PostgreSQL 和 Redis。`init` 生成配套连接、数据库密码和应用密钥，`start` 一起启动整套实例，无需先部署 `deploy_services/` 中的服务。

## 2. 核心配置项

### settings_sub2api.conf

- `INSTANCE_NAME`：应用容器与 Compose 项目名；配套容器分别为 `<INSTANCE_NAME>_postgres` 和 `<INSTANCE_NAME>_redis`。
- `IMAGE`：Sub2API 镜像，默认为 `weishaw/sub2api:latest`。
- `POSTGRES_IMAGE` / `REDIS_IMAGE`：配套镜像，默认 `paradedb/paradedb:latest-pg17`、`redis:7-alpine`。
- `SUB2API_PORT`：宿主机 Web/API 端口，容器端口为 `8080`。
- `DOCKER_NETWORK`：默认留空，Compose 自动创建本实例私有网络；指定时接入管理员预先创建的 external 网络。
- `DB_HOST` / `DB_PORT`：默认 `<INSTANCE_NAME>_postgres:5432`，使用配套容器地址及内部端口。
- `DB_NAME` / `DB_USER` / `DB_PASSWORD`：库名和账号默认 `sub2api`，密码由 `init` 随机生成一次；配套 PostgreSQL 首次启动使用同一组配置创建数据库和账号。
- `DB_SSLMODE`：默认 `disable`。
- `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_DB`：默认 `<INSTANCE_NAME>_redis:6379`、空密码及逻辑库 `0`；配套 Redis 未启用认证。
- `DATABASE_MAX_OPEN_CONNS` / `DATABASE_MAX_IDLE_CONNS` / `DATABASE_CONN_MAX_LIFETIME_MINUTES` / `DATABASE_CONN_MAX_IDLE_TIME_MINUTES`：数据库连接池参数。
- `REDIS_POOL_SIZE` / `REDIS_MIN_IDLE_CONNS` / `REDIS_ENABLE_TLS`：Redis 连接参数，TLS 默认 `false`。
- `SERVER_MODE` / `RUN_MODE`：服务运行模式，默认 `release` / `standard`。
- `ADMIN_EMAIL` / `ADMIN_PASSWORD`：首次启动时用于初始化管理员账号的凭证。
- `JWT_SECRET`：会话签名密钥；首次启动后不要更改，否则已有会话失效。
- `JWT_EXPIRE_HOUR`：会话有效期小时数，默认 `24`。
- `TOTP_ENCRYPTION_KEY`：TOTP 密钥加密密钥；首次启动后不要更改，否则已存的 TOTP 配置无法解密。
- `TZ`：容器时区，默认 `Asia/Shanghai`。
- `GEMINI_*`、`ANTIGRAVITY_*`：可选的 Gemini/Antigravity OAuth 配置。
- `SECURITY_URL_ALLOWLIST_*`：URL 白名单安全策略。
- `UPDATE_PROXY_URL`：访问 GitHub 在线更新与价格数据的代理。
- `GATEWAY_*`：OpenAI 响应超时、HTTP/2 回退、图片流式输出及并发控制参数。

## 3. 备注

- 容器以 `AUTO_SETUP=true` 自动执行数据库迁移；首次启动按 `ADMIN_EMAIL` / `ADMIN_PASSWORD` 创建管理员账号。
- PostgreSQL 和 Redis 不发布宿主机端口，应用等待两者健康后启动。配套 ParadeDB 保留镜像默认预加载配置；Redis 启用 AOF 持久化。
- 每个实例拥有自己的数据库和 Redis 容器及数据目录；相同默认库名、账号不会跨实例共享数据。Redis 库编号用于区分数据，不提供账号权限隔离。
- `init` 只写本地文件和创建目录，不运行 Docker。重复执行只补齐缺失或空的默认依赖字段，保留已有非空值、数据库密码、管理员凭证及 JWT/TOTP 密钥；不自动补造已丢失的应用密钥。
- 配套 PostgreSQL 仅在数据目录为空时读取初始化账号和密码；修改 settings 中的密码不会重置已有数据库。容器重启或移除后，保留 settings 和持久化目录即可由 `start` 重建。
- 当前流程只编排默认配套依赖，修改连接字段不会自动关闭配套容器；外接依赖的切换暂不提供自动化。容器内 `localhost` 指向当前容器。
- 应用数据保存在 `data/<INSTANCE_NAME>_data`，PostgreSQL 在 `data/<INSTANCE_NAME>_postgres_data`，Redis 在 `data/<INSTANCE_NAME>_redis_data`，均相对 settings 所在目录。
- settings 是 Bash 配置。包含特殊字符的密码和密钥使用单引号并按 Bash 单引号规则转义；生成的 Compose YAML 只包含变量引用，不落入密码值。
- 应用及两个配套容器均检查 Compose 项目和服务标记，归属不符时拒绝操作。`--conf` 父目录须已存在，YAML 和整套实例数据位于该目录；CLI 和模板仍从脚本目录读取。

## 4. 快速执行

```bash
cd deploy_apps/sub2api
bash cli.sh init
bash cli.sh start
```

多实例使用各自配置路径和唯一名称，父目录须已存在：

```bash
bash cli.sh init --conf /srv/sub2api-main/settings_sub2api.conf --name sub2api_main
bash cli.sh start --conf /srv/sub2api-main/settings_sub2api.conf
```

初始管理员邮箱和密码保存在当前 settings；启动后按日志或健康状态确认应用就绪。更新应用和配套镜像：

```bash
bash cli.sh update
```

`up` 等价于 `init` 后执行 `start`。停止、移除或清理均作用于本实例整套服务：

```bash
bash cli.sh stop
bash cli.sh rm
# DANGER: delete this instance's application, PostgreSQL and Redis data.
bash cli.sh purge
# DANGER: also delete this instance's settings and YAML.
bash cli.sh reset
```

## 5. 命令解释

下列 Compose 片段表示 CLI 内部调用，变量来自 CLI 读取的 settings。日常操作使用 `bash cli.sh <命令>`；settings 不是 Compose 的 env-file。

#### init

生成缺失的 settings 和应用凭证，补齐缺失或空的默认数据库、Redis 连接及配套镜像字段，保留已有非空配置和密钥；刷新 Compose YAML 并创建三个持久化目录，不启动容器。补值在原赋值位置写回，字段不存在时才追加。已有配置缺少管理员、端口或 JWT/TOTP 密钥时提示填写或恢复，不自动重建应用密钥。

#### start

检查配套镜像、数据库、Redis、管理员字段和 JWT/TOTP 密钥，刷新 YAML 并启动整套实例；Sub2API 等待 PostgreSQL、Redis 健康后启动。容器启动后的就绪情况查看日志或健康状态。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### up

依次运行 `init` 和 `start`，生成默认配套配置并启动本实例全部服务。

#### update

拉取 settings 指定的应用、PostgreSQL 和 Redis 镜像，再按当前配置应用更新；保留 settings、密钥和全部持久化数据。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" pull
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### stop

停止本 Compose 项目中的 Sub2API、PostgreSQL 和 Redis，保留容器、配置和数据。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" stop
```

#### rm

移除本实例全部容器和项目私有网络，保留 settings 与三个持久化目录；external 网络保留。再次 `start` 可重建并继续使用原数据。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" down
```

#### purge

危险操作：先执行 `rm`，再按明确路径删除本实例的 `data/<INSTANCE_NAME>_data`、`data/<INSTANCE_NAME>_postgres_data` 和 `data/<INSTANCE_NAME>_redis_data`，保留 settings。

#### reset

危险操作：执行 `purge` 删除整套实例数据，再删除当前 settings 文件和生成的 Compose YAML；源码、模板、其他实例和独立基础服务不受影响。

#### network ls

只读检查配置的共享网络，或未配置共享网络时的项目默认网络；不创建、连接或删除网络。

## 6. 升级、备份与复制恢复

应用和配套镜像均可在 settings 中指定版本或 digest。`update` 会拉取并应用全部镜像，应用可能执行数据库结构迁移，升级前备份数据库和配置。PostgreSQL 默认固定 17 主版本，脚本不执行跨主版本迁移。

停止整套实例或完成一致性备份后，复制 CLI、templates、settings、生成 YAML 和本实例三个持久化目录。物理复制 PostgreSQL 数据目录前必须停止数据库，并在目标机器使用兼容主版本。保留数据库密码、`JWT_SECRET`、`TOTP_ENCRYPTION_KEY`、管理员及 OAuth 配置；应用密钥须与数据库备份对应，不能用 `reset` 生成替代值。

配套 PostgreSQL 和 Redis 数据已包含在应用配置目录下，不依赖 `deploy_services/` 的数据目录。目标机器保留实例名与目录对应关系后运行 `start`；仅设置了 `DOCKER_NETWORK` 时需要预建对应网络。使用外置 `--conf` 时同时携带对应 CLI 和模板。
