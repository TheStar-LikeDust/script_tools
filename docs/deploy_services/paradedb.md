# ParadeDB 部署 (Deploy)

## 1. 简介

> ParadeDB 是基于 PostgreSQL 的关系型数据库，提供 pg_search 检索扩展，可供多个应用连接各自的专用数据库。

本目录用于独立部署 ParadeDB。`init` 生成密码、配置文件及 Compose YAML，数据保存在配置目录下的相对路径 bind mount 中。Casdoor、LobeHub、New API、Sub2API 默认各自携带 PostgreSQL，无需先运行本目录的 CLI；配套实例由应用 Compose 管理。

## 2. 核心配置项

### settings_paradedb.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `paradedb_8421`），决定容器名与数据目录。
- `DB_PORT`: 宿主机端口（容器内为 `5432`），仅在 `DB_PUBLISH_PORT=true` 时发布。
- `DB_PUBLISH_PORT`: 是否向宿主机发布 PostgreSQL 端口，默认 `true`。
- `DOCKER_NETWORK`: 可选的、预先创建的共享 Docker 网络；留空时使用 Compose 私有网络。
- `IMAGE`: Compose 使用的镜像，默认 `paradedb/paradedb:latest-pg17`。
- `DB_USER`: 数据库管理员账号（默认 `postgres`）。
- `DB_PASSWORD`: 自动生成的强密码。
- `DB_NAME`: 初始化时创建的数据库名（默认 `postgres`）。

## 3. 备注

- 本目录模板显式设置 `shared_preload_libraries=pg_search`。当前上游 PostgreSQL 17 镜像源码包含 pgvector，并默认预加载 `pg_search,pg_cron,pg_stat_statements`；其首次启动脚本依赖完整预加载列表。独立部署时应按实际镜像调整本目录模板；四个应用的配套模板保留镜像默认配置。扩展的安装与数据库内启用是两回事，所需扩展以实际镜像及应用迁移要求为准。
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

若配置文件不存在则用模板生成；随后读取配置、生成 `settings_paradedb.compose.yaml` 并创建数据目录，不启动容器。`--name` 指定完整实例名。

生成的 Compose YAML 通过环境变量引用配置值，密码留在 settings 文件中。`--conf PATH` 的父目录须已存在，YAML 与数据保存在该目录；CLI 和模板仍位于脚本目录。

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

停止数据库后，可以复制完整部署目录，并在目标机器使用兼容主版本和对应镜像启动；在线备份使用 PostgreSQL 的一致性备份工具，不能直接复制正在写入的数据目录。复制内容包括 CLI、templates、settings、YAML 和 `data/<INSTANCE_NAME>_data`。共享网络在目标机器提前创建，实例名与数据目录名保持对应。

逻辑备份和恢复示例（替换占位符，密码通过 psql 工具支持的凭证方式提供）：

```bash
pg_dump -h <db_host> -p <db_port> -U <app_user> -d <app_db> -Fc -f app.dump
pg_restore -h <target_host> -p <target_port> -U <app_user> -d <app_db> \
  --no-owner --no-acl --exit-on-error app.dump
```

恢复目标库和专用账号须预先创建，扩展由管理员准备。数据库备份需与应用自己的加密密钥一同保管；复制应用目录不会包含本目录独立数据库的数据。默认配套数据库位于应用配置目录的 `data/<INSTANCE_NAME>_postgres_data`，重建应用容器时保留，应用 `purge/reset` 会清理该配套数据。
