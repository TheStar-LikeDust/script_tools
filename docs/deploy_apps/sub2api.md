# Sub2API 部署 (Deploy)

## 1. 简介

> Sub2API 是一个 AI 模型订阅转 API 的网关，将上游订阅账号统一聚合为标准 API，提供账号管理、密钥分发与请求转发能力。

应用由 Docker Compose 单独管理。PostgreSQL 与 Redis 必须先独立部署；管理员为每个应用预先建立独立数据库和账号，在应用 settings 中填写地址、连接凭证和应用自身设置。

## 2. 核心配置项

### settings_sub2api.conf

- `INSTANCE_NAME`：应用容器与 Compose 项目名。
- `IMAGE`：Sub2API 镜像，默认为 `weishaw/sub2api:latest`。
- `SUB2API_PORT`：宿主机 Web/API 端口，容器端口为 `8080`。
- `DOCKER_NETWORK`：可选的预先创建的 Docker 网络。同机连接其他 Compose 部署的服务时，应用与基础服务需接入同一网络。
- `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_SSLMODE`：管理员预先创建的 Sub2API 专用数据库及账号。端口默认 `5432`，SSL 模式默认 `disable`。
- `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_DB`：独立 Redis 服务的地址、端口、可选密码和逻辑库编号。端口默认 `6379`。
- `DATABASE_MAX_OPEN_CONNS` / `DATABASE_MAX_IDLE_CONNS` / `DATABASE_CONN_MAX_LIFETIME_MINUTES` / `DATABASE_CONN_MAX_IDLE_TIME_MINUTES`：数据库连接池参数。
- `REDIS_POOL_SIZE` / `REDIS_MIN_IDLE_CONNS` / `REDIS_ENABLE_TLS`：Redis 连接参数。
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
- 多个应用共用 PostgreSQL 实例时，必须各自使用独立数据库和账号。请管理员预先建库、建号并授予最小所需权限。
- 同机容器使用共享 Docker 网络上的数据库/Redis 容器名及容器端口。应用容器内的 `localhost` 指向 Sub2API 自身；远程连接填写容器可达的 DNS 名称或 IP 与端口。
- `DOCKER_NETWORK` 为空时，应用使用自己的 Compose 网络。要访问同机基础服务，应先由管理员创建共享网络，例如 `docker network create shared_services`，然后在 PostgreSQL、Redis 和 Sub2API 的 settings 中写入 `DOCKER_NETWORK="shared_services"`。
- 当前 Redis 基础服务默认未启用认证。只有 Redis 实例已配置对应密码与访问隔离时，才在 `REDIS_PASSWORD` 填入密码；不要把无认证 Redis 暴露到不可信网络。
- `rm` 仅移除 Sub2API 容器和应用私有网络；`purge` 仅额外删除本应用目录下的 bind mount 数据；`reset` 仅额外删除当前应用 settings 和生成的 Compose YAML。以上命令都不会触及 PostgreSQL、Redis、它们的配置或数据。
- 本地 `./data/<INSTANCE_NAME>_data` 挂载到 `/app/data`；主要业务数据由外部 PostgreSQL 管理，复制应用目录不包含数据库或 Redis 数据。
- settings 是 Bash 配置。包含特殊字符的密码和密钥使用单引号并按 Bash 单引号规则转义；生成的 Compose YAML 只包含变量引用，不落入密码值。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。`--conf` 父目录须已存在，生成 YAML 和本地数据位于该目录，CLI 和模板仍从脚本目录读取。

## 4. 快速执行

```bash
cd deploy_apps/sub2api
bash cli.sh init
# Fill DB_* and REDIS_*; set DOCKER_NETWORK for same-host services.
bash cli.sh start
```

同机连接示例，`postgres_shared` 与 `redis_sub2api` 分别替换为独立服务的 `INSTANCE_NAME`：

```bash
DOCKER_NETWORK="shared_services"
DB_HOST="postgres_shared"
DB_PORT="5432"
DB_NAME="sub2api"
DB_USER="sub2api"
DB_PASSWORD='填写该应用数据库账号的密码'
REDIS_HOST="redis_sub2api"
REDIS_PORT="6379"
REDIS_PASSWORD='填写对应 Redis 密码；无认证实例留空'
REDIS_DB="0"
```

远程连接时可保留 `DOCKER_NETWORK=""`，例如 `DB_HOST="db.example.com"`、`DB_PORT="5432"`、`DB_SSLMODE="require"`、`REDIS_HOST="cache.example.com"`、`REDIS_PORT="6380"`、`REDIS_ENABLE_TLS="true"`；端口、SSL/TLS 与密码需匹配实际远端服务。Redis DB 编号只区分键空间，不提供权限隔离；当前无认证 Redis 模板应按应用独立部署。

更新应用镜像：

```bash
bash cli.sh update
```

`up` 等价于 `init` 后执行 `start`，适用于连接配置已就绪的实例。停止、移除或清理只作用于应用自身：

```bash
bash cli.sh stop
bash cli.sh rm
# DANGER: permanently delete this application's local data.
bash cli.sh purge
# DANGER: also delete this app's settings and YAML.
bash cli.sh reset
```

## 5. 命令解释

下列 Compose 片段表示 CLI 内部调用，变量来自 CLI 读取的 settings。日常操作使用 `bash cli.sh <命令>`；settings 不是 Compose 的 env-file。

#### init

生成缺失的 settings，刷新 Compose YAML 并预建应用数据目录，不启动容器。已有 settings 不会被覆盖或自动补字段；缺少的连接项按模板人工填写。

#### start

检查数据库、Redis 地址、管理员字段和 JWT/TOTP 密钥，刷新 Compose YAML 并启动或重建 Sub2API 容器。容器启动后的就绪情况查看日志或健康状态。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### up

依次运行 `init` 和 `start`。外部 PostgreSQL 与 Redis 必须已运行且配置可连接。

#### update

拉取 settings 指定的应用镜像，再按当前配置重建应用；保留 settings、随机密钥和本地数据。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" pull
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### stop

停止本 Compose 项目中的 Sub2API 应用容器，不停止共享基础服务。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" stop
```

#### rm

移除应用容器和项目私有网络，保留 settings 与应用数据；external 共享网络由其管理员管理。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
    --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" down
```

#### purge

危险操作：先执行 `rm`，再删除仅属于 Sub2API 的 `data/<INSTANCE_NAME>_data` 目录。共享 PostgreSQL/Redis 及其数据不受影响。

#### reset

危险操作：执行 `purge`，再删除当前 settings 文件和生成的 Compose YAML。不会用通配符删除同目录中的其他配置。

#### network ls

只读检查配置的共享网络，或未配置共享网络时的项目默认网络；不创建、连接或删除网络。

## 6. 升级、备份与复制恢复

应用镜像默认使用滚动标签 `weishaw/sub2api:latest`；可在 `IMAGE` 中指定具体版本或 digest。`update` 会拉取并应用该镜像，应用可能执行数据库结构迁移，升级前备份数据库和配置。

停止应用或完成一致性备份后，复制包含 CLI、templates、settings、生成 YAML 和 `data/<INSTANCE_NAME>_data` 的应用目录。保留 `JWT_SECRET`、`TOTP_ENCRYPTION_KEY`、管理员及 OAuth 配置；JWT 和 TOTP 密钥须与数据库备份对应，不能用 `reset` 生成替代值。

PostgreSQL 与 Redis 在各自服务目录独立备份和恢复，应用目录不包含这些数据。目标机器准备共享网络，填写数据库与 Redis 的实际地址和凭证，保持实例名与本地数据目录名对应后运行 `start`。使用外置 `--conf` 时同时携带对应 CLI 和模板。
