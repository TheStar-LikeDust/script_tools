# ParadeDB 部署 (Deploy)

## 1. 简介

> ParadeDB 是基于 PostgreSQL 的关系型数据库，提供 pg_search 检索扩展，可供多个应用连接各自的专用数据库。

本目录支持独立部署，也提供可供应用组合的配置初始化、Compose 服务片段和连接串输出。`init` 生成或补齐配置；`--config-only` 只准备 settings，普通初始化还生成 YAML 和数据目录。New API 已通过这些接口组合 PostgreSQL；LobeHub、Sub2API、Casdoor 当前仍使用各自的 PostgreSQL 定义。

## 2. 核心配置项

### settings_paradedb.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `paradedb_8421`），决定容器名与数据目录。
- `DB_PORT`: 宿主机端口（容器内为 `5432`），仅在 `DB_PUBLISH_PORT=true` 时发布。
- `DB_PUBLISH_PORT`: 是否向宿主机发布 PostgreSQL 端口，默认 `true`。
- `DOCKER_NETWORK`: 可选的、预先创建的共享 Docker 网络；留空时使用 Compose 私有网络。
- `IMAGE`: Compose 使用的镜像，默认 `paradedb/paradedb:latest-pg17`。
- `DB_USER`: 数据库管理员账号（默认 `postgres`）。
- `DB_PASSWORD`: 通过 `--db-password` 注入，未提供时随机生成并保存。
- `DB_NAME`: 初始化时创建的数据库名（默认 `postgres`）。

## 3. 备注

- 本目录模板保留镜像的默认预加载配置，不再将 `shared_preload_libraries` 限制为 `pg_search`。扩展的安装与数据库内启用是两回事，所需扩展以实际镜像及应用迁移要求为准。
- 配置共享网络后，同一网络中的应用使用 `${INSTANCE_NAME}:5432` 连接。容器内的 `localhost` 指向容器自身；宿主机或远程客户端使用服务器地址和 `DB_PORT`。
- 作为共享 PostgreSQL 使用时，管理员需为每个应用预先创建独立数据库和账号，授予所需的最小权限；不要将 `DB_USER` 管理员凭证直接复用于应用。
- 共享网络由管理员提前创建，例如 `docker network create shared_services`，再将 `DOCKER_NETWORK` 设为 `shared_services`。本服务只接入网络，不创建或删除共享网络。
- `DB_USER/DB_PASSWORD/DB_NAME` 用于空数据目录的首次初始化。修改 settings 不会重置已有数据库的账号、密码或库名，已有账号变更应通过数据库管理操作完成。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。

## 4. 快速执行

```bash
cd deploy_services/paradedb

# Generate settings and YAML, then edit settings before starting.
bash cli.sh init
bash cli.sh start

# Use init + start when settings are ready.
bash cli.sh up

# Pull and apply the configured image.
bash cli.sh update

# Stop this database instance.
bash cli.sh stop

# Remove containers; keep settings and bind mount data.
bash cli.sh rm

# DANGER: permanently delete this instance's data.
bash cli.sh purge
```

## 5. 命令解释

以下代码展示 CLI 内部操作，环境变量由 CLI 读取 settings 后导出；`compose` 为使用当前项目目录、实例名和 YAML 路径的包装函数。日常操作使用 `bash cli.sh <命令>`。

#### init

若配置文件不存在则用模板生成；读取配置并补齐空字段后，组合 `services:`、服务片段和可选网络配置，生成 `paradedb.compose.yaml` 并创建数据目录，不启动容器。`--config-only` 跳过 YAML 和数据目录生成，供应用先准备全部配置后统一组合。

初始化参数适用于 `init/up`，优先级为“已有非空设置 → 本次参数 → 默认值或随机值”。再次传入不同密码不会修改已保存的密码；配置的写入使用 Bash 转义，保留特殊字符、注释及其他字段。

- `--conf PATH`：配置路径，所有命令可用；父目录须已存在。
- `--name NAME`：实例名，默认 `paradedb_<时间戳后四位>`。
- `--image IMAGE`：镜像，默认 `paradedb/paradedb:latest-pg17`。
- `--port PORT`：宿主机映射端口，默认随机 `30000–40000`；容器内仍为 `5432`。
- `--publish-port true|false`：是否发布宿主机端口，默认 `true`；应用配套初始化可传 `false`。
- `--network NAME`：已有共享网络名，留空使用 Compose 私有网络。
- `--db-name NAME`、`--db-user USER`：首启库名、管理员名，均默认 `postgres`。
- `--db-password PASSWORD`：首启密码，省略时随机生成。
- `--config-only`：仅适用于 `init`，只准备配置文件。

以下示例从仓库根目录调用服务 CLI，将配置写入已存在的应用目录，不启动数据库：

```bash
bash deploy_services/paradedb/cli.sh init \
  --conf deploy_apps/newapi/settings_paradedb.conf \
  --name newapi_demo_postgres \
  --port 35432 \
  --publish-port false \
  --db-name newapi \
  --db-user newapi \
  --config-only
```

密码只保存在 ParadeDB settings 中，DSN 由服务侧按需生成。YAML 使用 `PARADEDB_*` 变量引用，配置和数据仍位于 `--conf` 所在目录；CLI、hooks 和模板位于脚本目录。

#### render

读取配置并向标准输出写出带两空格缩进的服务片段，不包含顶层 `services:` 或 `networks:`，不修改配置、YAML、数据或容器。`--service-name` 只改变 YAML 服务键，默认 `paradedb`；容器名和数据目录继续取自 settings 的 `INSTANCE_NAME`。

```bash
bash deploy_services/paradedb/cli.sh render \
  --conf deploy_apps/newapi/settings_paradedb.conf \
  --service-name postgres
```

应用可在总 YAML 的 `services:` 下组合此输出，并补充自己的服务和 `depends_on`。服务模板维护镜像、挂载、启动参数、健康检查及可选端口；顶层网络由应用统一定义。生成 YAML 的项目目录应与这份配置所在目录一致，使 `./data/<INSTANCE_NAME>_data` 指向正确位置。

#### env

读取配置并向标准输出写出可供 Bash 读取的 `export KEY=value`，值经过 Bash 转义，不修改文件或连接数据库。错误信息写入标准错误。导出的字段为 `PARADEDB_INSTANCE_NAME`、`PARADEDB_IMAGE`、`PARADEDB_DB_PORT`、`PARADEDB_DB_PUBLISH_PORT`、`PARADEDB_DOCKER_NETWORK`、`PARADEDB_DB_USER`、`PARADEDB_DB_PASSWORD`、`PARADEDB_DB_NAME`、`PARADEDB_DSN`。

```bash
# Import only this service's prefixed variables; stop if the command fails.
paradedb_env="$(bash deploy_services/paradedb/cli.sh env \
  --conf deploy_apps/newapi/settings_paradedb.conf)" || exit
eval "$paradedb_env"
```

只读取可信配置和本项目 CLI 输出。原始凭证和派生 DSN 出现在此输出中，调用方应直接接收，避免打印或另存副本。`PARADEDB_DSN` 格式为 `postgresql://<user>:<password>@<INSTANCE_NAME>:5432/<db>?sslmode=disable`，账号、密码和库名按 URL 规则编码，使用容器端口，与宿主机 `DB_PORT` 无关。New API 可映射到 `SQL_DSN`，LobeHub 可映射到 `DATABASE_URL`，无需在应用中重复拼接。

`hooks.sh` 的 `render_service`、`export_compose_env`、`build_connection_string` 承担片段、变量及连接串生成；独立生命周期与应用复用共用这些入口。应用通过独立 CLI 进程读取依赖配置，避免覆盖自身的 `INSTANCE_NAME`、`IMAGE` 等字段。固定前缀用于一套 Compose 中的一个 ParadeDB 实例，多实例通过不同配置目录和 Compose 项目隔离。

#### start

按当前配置刷新 Compose YAML 并执行 `docker compose up -d`；配置变化会由 Compose 更新容器定义。项目名为 `INSTANCE_NAME`。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### up

先 `init` 再 `start`。

#### update

拉取 settings 中 `IMAGE` 对应的镜像，再由 Compose 按当前定义重建服务；配置、凭证和 bind mount 数据保留。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" pull
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### stop

执行 `docker compose ... stop`，保留容器、网络与数据。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" stop
```

#### rm

执行 `docker compose ... down`，移除本项目容器和私有网络，保留 `./data/` 与配置；外部共享网络不会删除。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" down
```

#### purge

危险操作：移除 Compose 容器并删除本地数据目录，保留 `settings_paradedb.conf`。

```bash
compose down
docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
```

#### reset

危险操作：先执行 `purge`，再只删除当前 `--conf` 对应的 settings 和生成 YAML，其他配置保留。

```bash
do_purge
rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
```

## 6. 为应用创建数据库和账号

以下仅适用于管理员手工对接本目录的独立数据库，默认配套应用不需要这些操作。由管理员在 psql 中执行，以下以 New API 为例；每个应用分别使用自己的名称和密码：

```sql
CREATE ROLE newapi LOGIN;
\password newapi
CREATE DATABASE newapi OWNER newapi;
REVOKE CONNECT, TEMPORARY ON DATABASE newapi FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE newapi TO newapi;
```

对每个应用数据库分别设置 PUBLIC 连接权限，应用账号只管理自己的业务库，不授予超级用户或创建其他数据库的权限。所需扩展由管理员提前安装和启用，再将连接地址、库名和专用凭证填写到应用 settings。

## 7. 升级、备份与复制恢复

默认 `paradedb/paradedb:latest-pg17` 是固定 PostgreSQL 主版本的滚动标签；可用具体版本标签或 digest 固定部署版本。`update` 不执行 PostgreSQL 跨主版本数据迁移。

停止数据库后，可以复制完整部署目录，并在目标机器使用兼容主版本和对应镜像启动；在线备份使用 PostgreSQL 的一致性备份工具，不能直接复制正在写入的数据目录。复制内容包括 CLI、hooks.sh、templates、settings、YAML 和 `data/<INSTANCE_NAME>_data`。共享网络在目标机器提前创建，实例名与数据目录名保持对应。使用应用组合接口时还需携带服务的 CLI、hooks 和模板；仅复制应用目录不能替代这些源文件。

逻辑备份和恢复示例（替换占位符，密码通过 psql 工具支持的凭证方式提供）：

```bash
pg_dump -h <db_host> -p <db_port> -U <app_user> -d <app_db> -Fc -f app.dump
pg_restore -h <target_host> -p <target_port> -U <app_user> -d <app_db> \
  --no-owner --no-acl --exit-on-error app.dump
```

恢复目标库和专用账号须预先创建，扩展由管理员准备。数据库备份需与应用自己的加密密钥一同保管；复制应用目录不会包含本目录独立数据库的数据。默认配套数据库位于应用配置目录的 `data/<INSTANCE_NAME>_postgres_data`，重建应用容器时保留，应用 `purge/reset` 会清理该配套数据。
