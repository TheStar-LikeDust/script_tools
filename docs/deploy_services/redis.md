# Redis 部署 (Deploy)

## 1. 简介

> Redis 是架构中的内存键值存储，常用于缓存、会话与队列。

使用官方 `redis:7-alpine` 镜像独立运行。init 生成配置文件和 Compose YAML，RDB/AOF 数据保存在配置目录下的相对路径 bind mount 中。

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

若配置文件不存在则用模板生成；随后读取配置、生成 `settings_redis.compose.yaml` 并创建数据目录，不启动容器。`--name` 指定完整实例名。

生成的 Compose YAML 通过环境变量引用配置值。`--conf PATH` 的父目录须已存在，YAML 与数据保存在该目录；CLI 和模板仍位于脚本目录。

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

## 6. 持久化与复制恢复

默认 `redis:7-alpine` 是滚动标签；可用具体补丁版本或 digest 固定部署。`--save 60 1000` 表示 60 秒内有 1000 次写入时触发 RDB 快照，`--appendonly yes` 同时启用 AOF。

完成持久化并停止实例后，复制完整部署目录，包括 CLI、templates、settings、YAML 和 `data/<INSTANCE_NAME>_data`。Redis 7 的 AOF 可能由多个文件构成，须保留完整 AOF 子目录和清单文件，不能只复制单个 dump.rdb。

目标机器使用兼容镜像，预先创建配置的共享网络，并保持实例名与数据目录名对应。应用使用的 DB 编号、键前缀和认证设置应与恢复后的 Redis 一致；数据由此服务目录管理，不随应用目录复制。
