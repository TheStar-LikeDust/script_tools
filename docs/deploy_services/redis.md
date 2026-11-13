# Redis 部署 (Deploy)

## 1. 简介

> Redis 是架构中的内存键值存储，常用于缓存、会话与队列。

默认使用官方 `redis:7-alpine` 镜像。支持独立部署，也提供应用组合所需的配置初始化、Compose 服务片段和连接 URL。RDB/AOF 数据保存在配置目录下的相对路径 bind mount 中。New API 已通过这些接口组合 Redis；LobeHub、Sub2API 当前仍使用各自的配套定义。

## 2. 核心配置项

### settings_redis.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `redis_8421`），决定容器名与数据目录。
- `REDIS_PORT`: 宿主机端口（容器内为 `6379`），仅在 `REDIS_PUBLISH_PORT=true` 时发布。
- `REDIS_PUBLISH_PORT`: 是否向宿主机发布 Redis 端口，默认 `true`。
- `DOCKER_NETWORK`: 可选的、预先创建的共享 Docker 网络；留空时使用 Compose 私有网络。
- `IMAGE`: Compose 使用的镜像，默认 `redis:7-alpine`。

## 3. 备注

- 默认未设置 Redis 密码，应仅在受信任的隔离网络中使用，避免发布到不受信任的主机网络。
- 当前定义未提供按应用隔离的认证配置；在补齐认证和应用级隔离策略前，不要将此 Redis 实例作为多个应用的共享服务。
- 配置共享网络后，同一网络中的应用使用 `${INSTANCE_NAME}:6379` 连接。容器内的 `localhost` 指向容器自身；宿主机或远程客户端使用服务器地址和 `REDIS_PORT`。
- 共享网络由管理员提前创建，例如 `docker network create shared_services`，再将 `DOCKER_NETWORK` 设为 `shared_services`。本服务只接入网络，不创建或删除共享网络。
- Redis DB 编号和键前缀只区分数据，不限制访问权限。模板未配置密码或 ACL；应用填写连接密码不会替 Redis 自动启用认证。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。
- `hooks.sh` 负责连接 URL 和服务片段生成，独立部署与应用组合使用同一份模板。`render`、`env` 在独立进程内读取指定配置，只向调用方输出服务片段或 `REDIS_*` 变量，不输出通用的 `INSTANCE_NAME`、`IMAGE`。

## 4. 快速执行

```bash
cd deploy_services/redis

# Generate settings and YAML, then edit settings before starting.
bash cli.sh init
bash cli.sh start

# Use init + start when settings are ready.
bash cli.sh up

# Pull and apply the configured image.
bash cli.sh update

# Stop this Redis instance.
bash cli.sh stop

# Remove containers; keep settings and bind mount data.
bash cli.sh rm

# DANGER: permanently delete this instance's data.
bash cli.sh purge
```

## 5. 命令解释

以下代码展示 CLI 内部操作，环境变量由 CLI 读取 settings 后导出；`compose` 为使用当前项目目录、实例名和 YAML 路径的包装函数。日常操作使用 `bash cli.sh <命令>`。

#### init

生成或补齐配置，随后组合 `services:` 开头、Redis 服务片段和可选顶层网络配置，生成 `settings_redis.compose.yaml` 并创建数据目录，不启动容器。

`init/up` 接受以下初始值参数：

- `--name NAME`：`INSTANCE_NAME`，未提供时生成 `redis_<时间戳后缀>`。
- `--image IMAGE`：`IMAGE`，默认 `redis:7-alpine`。
- `--port PORT`：`REDIS_PORT`，默认随机选择 `30000-40000`，表示宿主机端口。
- `--publish-port true|false`：`REDIS_PUBLISH_PORT`，默认 `true`；配套部署可传入 `false`。
- `--network NAME`：`DOCKER_NETWORK`，默认留空，使用 Compose 私有网络。

已有非空字段优先于命令参数；仅新配置或缺失、空字段采用注入值，再采用默认值。重复 `init` 不覆盖现有设置；修改已有值需编辑 settings。参数值以 Bash 转义形式保存。

`init --config-only` 仅生成或补齐 settings，不生成 YAML、不创建数据目录，便于应用先准备全部依赖配置，再构建总 YAML。此参数不用于 `up`。

生成 YAML 保留 `REDIS_*` 变量引用，`start/update` 会重新读取配置并导出变量。`--conf PATH` 的父目录须已存在，YAML 与数据保存在该目录；CLI、hooks 和模板仍位于脚本目录。配置文件继续使用 `settings_redis.conf` 的原字段名。

```bash
# Generate dependency settings beside the application settings.
bash cli.sh init \
  --conf /srv/newapi/settings_redis.conf \
  --name newapi_demo_redis \
  --port 36379 \
  --publish-port false \
  --config-only
```

#### start

按当前配置刷新 Compose YAML 并执行 `docker compose up -d`；配置变化会由 Compose 更新容器定义。项目名为 `INSTANCE_NAME`。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### up

先 `init` 再 `start`。

#### update

拉取 settings 中 `IMAGE` 对应的镜像，再由 Compose 按当前定义重建服务；配置和 RDB/AOF 数据保留。

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
compose down
```

#### purge

危险操作：移除 Compose 容器并删除本地数据目录，保留 `settings_redis.conf`。

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

#### render

`bash cli.sh render --conf PATH [--service-name NAME]` 向标准输出提供缩进两格的服务块，默认服务键名为 `redis`；不包含 `services:` 开头或顶层 `networks`。镜像、挂载、持久化命令和健康检查来自本目录模板；端口片段按配置追加。仅读取配置，不生成文件或启动容器，诊断写入标准错误。

#### env

`bash cli.sh env --conf PATH [--db NUMBER]` 向标准输出提供 Bash 转义后的 `export KEY=value`，供组合方在确认命令成功后导入：

- `REDIS_INSTANCE_NAME`、`REDIS_IMAGE`、`REDIS_DOCKER_NETWORK`：从配置的 `INSTANCE_NAME`、`IMAGE`、`DOCKER_NETWORK` 映射。
- `REDIS_PORT`、`REDIS_PUBLISH_PORT`：宿主机端口及是否发布。
- `REDIS_URL`：`redis://<INSTANCE_NAME>:6379/<NUMBER>`，逻辑库默认 `0`，由 hooks 派生，不重复写入 settings。

`--db` 只选择连接 URL 中的逻辑库，编号须在实际 Redis 支持范围内，不创建数据库、不提供访问隔离。该服务没有配置密码，因此 URL 不包含凭证。应用只需将 `REDIS_URL` 映射为自身环境变量，例如 New API 的 `REDIS_CONN_STRING`。

## 6. 供应用组合

以下展示组合方的调用关系；应用需先生成或读取自己及全部依赖的 settings，再获取各服务片段。每次启动时重新导入 `env` 输出，使手工修改的配置生效。

```bash
redis_cli=/path/to/script_tools/deploy_services/redis/cli.sh
redis_conf=/srv/newapi/settings_redis.conf

# Abort if either producer fails; import only successful Bash output.
redis_service="$(bash "$redis_cli" render --conf "$redis_conf")" || exit 1
redis_exports="$(bash "$redis_cli" env --conf "$redis_conf" --db 0)" || exit 1
eval "$redis_exports"

# The application adds its own and other dependency blocks under this header.
printf 'services:\n%s\n' "$redis_service"
```

服务片段使用相对挂载路径 `./data/${REDIS_INSTANCE_NAME}_data`，因此上述组合流程要求依赖配置、总 YAML 和应用配置位于同一目录，并以该目录作为 Compose 的 `--project-directory`。应用准备该数据目录、设置 `depends_on`、统一声明网络，并以自己的 Compose 项目管理整套容器。`render` 仅输出服务块，顶层网络由组合方负责。

`--service-name` 只改变 YAML 中的服务键名，不改变容器名、数据路径和导出变量前缀。同一份组合 YAML 当前只支持一份 Redis 配置。组合项目中的 Redis 不再由本目录独立 `start/stop/rm/purge/reset` 管理，独立 CLI 的归属检查会拒绝操作其他 Compose 项目的容器。

## 7. 持久化与复制恢复

默认 `redis:7-alpine` 是滚动标签；可用具体补丁版本或 digest 固定部署。`--save 60 1000` 表示 60 秒内有 1000 次写入时触发 RDB 快照，`--appendonly yes` 同时启用 AOF。

完成持久化并停止实例后，复制完整部署目录，包括 CLI、hooks.sh、templates、settings、YAML 和 `data/<INSTANCE_NAME>_data`。Redis 7 的 AOF 可能由多个文件构成，须保留完整 AOF 子目录和清单文件，不能只复制单个 dump.rdb。

目标机器使用兼容镜像，预先创建配置的共享网络，并保持实例名与数据目录名对应。应用使用的 DB 编号和键前缀应与恢复后的 Redis 一致。独立部署的数据由本服务管理；通过 `--conf` 生成到应用目录的配套配置和数据随应用一起备份，同时携带本服务的 CLI、hooks 和模板。
