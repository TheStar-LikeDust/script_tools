# New API 部署 (Deploy)

## 1. 简介

> New API 是一个 AI 模型接口管理与分发网关，统一聚合多家上游模型供应商，提供密钥管理、额度计费与请求转发能力。

它依赖 PostgreSQL 持久化业务数据、依赖 Redis 做缓存。部署采用全捆绑模式：`init` 通过级联机制委托 `deploy/paradedb` 与 `deploy/redis` 在本目录内生成各自配置与数据落点，`start` 时动态组建专属网络将三个容器按容器名直连。

## 2. 核心配置项

### settings_newapi.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `newapi_8421`），决定容器名与数据目录。
- `NEWAPI_PORT`: 对外暴露的 Web UI / API 端口（容器内 `3000`）。
- `TZ`: 容器时区，默认 `Asia/Shanghai`。
- `ERROR_LOG_ENABLED`: 记录错误日志并在 Web 控制台展示，默认 `true`。
- `CRYPTO_SECRET`: 数据库敏感内容（如渠道密钥）的加密密钥，`init` 时随机生成。首次启动后严禁更换，否则已加密数据无法解密。

### settings_paradedb.conf

- 包含附带的 paradedb 实例的连接凭证（业务数据落在其默认 `postgres` 库）。

### settings_redis.conf

- 包含附带的 redis 实例的实例名与端口。

## 3. 备注

- 连接串注入机制：`SQL_DSN` 与 `REDIS_CONN_STRING` 不落盘在 `settings_newapi.conf`，而是每次 `start` 时从两份附带配置实时拼装（host 为依赖容器名、端口为容器内部端口），经 `-e` 注入容器。修改数据库凭证只需改 `settings_paradedb.conf` 后 `rm` 再 `start`。
- 附带 redis 仅在专属隔离网络内被访问，未设密码；对外暴露的仅是 redis 自身 `settings_redis.conf` 中的随机宿主机端口，如需对外屏蔽可手动移除该端口映射。
- 首次访问 Web UI 会引导设置管理员账号密码，仅首次安装需要。

## 4. 快速执行

```bash
cd deploy_apps/newapi

# 常规分步拉起（推荐）：先生成配置、按需修改 settings_newapi.conf 后再启动
bash cli.sh init
bash cli.sh start

# 一键拉起（跳过配置直接启动，会同时起 paradedb、redis 与 new-api）
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

生成 `settings_newapi.conf`（仅首次）；委托 paradedb 与 redis 生成 `settings_paradedb.conf` / `settings_redis.conf` 及各自数据目录，并预建 new-api 数据目录。不启动容器。

```bash
# 1) new-api 自身配置（仅首次）
sed -e "s/{{INSTANCE_NAME}}/newapi_<时间戳>/g" \
    -e "s/{{NEWAPI_PORT}}/<随机端口>/g" \
    -e "s/{{CRYPTO_SECRET}}/<随机密钥>/g" \
    "$SCRIPT_DIR/templates/settings_newapi.conf.tpl" > settings_newapi.conf

# 2) 委托 paradedb 与 redis——配置与数据都落在 newapi 目录
bash ../../deploy/paradedb/cli.sh init \
    --conf "$CONF_DIR/settings_paradedb.conf" \
    --name "newapi_<时间戳>_paradedb"
bash ../../deploy/redis/cli.sh init \
    --conf "$CONF_DIR/settings_redis.conf" \
    --name "newapi_<时间戳>_redis"
```

#### start

先起 paradedb 与 redis 并接入专属网络，等数据库健康后拼装连接串，再起 new-api。

```bash
# 建网络 -> 起依赖 -> 接入网络 -> 等 DB 健康
docker network inspect "${INSTANCE_NAME}_net" >/dev/null 2>&1 || docker network create "${INSTANCE_NAME}_net"
bash ../../deploy/paradedb/cli.sh start --conf "$CONF_DIR/settings_paradedb.conf"
bash ../../deploy/redis/cli.sh start --conf "$CONF_DIR/settings_redis.conf"
docker network connect "${INSTANCE_NAME}_net" "${INSTANCE_NAME}_paradedb"
docker network connect "${INSTANCE_NAME}_net" "${INSTANCE_NAME}_redis"

# 起 new-api（已存在则仅 docker start）
docker run -d \
    --name "${INSTANCE_NAME}" \
    --network "${INSTANCE_NAME}_net" \
    -p "${NEWAPI_PORT}:3000" \
    -e SQL_DSN="postgresql://postgres:<随机密码>@${INSTANCE_NAME}_paradedb:5432/postgres" \
    -e REDIS_CONN_STRING="redis://${INSTANCE_NAME}_redis:6379" \
    -e TZ="Asia/Shanghai" \
    -e ERROR_LOG_ENABLED="true" \
    -e CRYPTO_SECRET="<随机密钥>" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/data" \
    --health-cmd "wget -qO- http://localhost:3000/api/status >/dev/null || exit 1" \
    --restart unless-stopped \
    calciumion/new-api:latest
```

#### up

先 `init` 再 `start`。

#### stop

停止 new-api，再停 paradedb 与 redis。

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

- 镜像版本：当前固定 `calciumion/new-api:latest`，需可复现可锁定具体标签。
- 多节点 / 高级参数：`SESSION_SECRET`、`NODE_NAME`、`STREAMING_TIMEOUT` 等官方可选环境变量未收录，单机部署不需要；如有需求可在 `cli.sh` 的 `docker run` 中追加 `-e` 项。
- 依赖 repo 结构：通过相对路径 `../../deploy/paradedb`、`../../deploy/redis` 与 `../../lib/network.sh` 定位共享脚本；newapi 目录里的配置与数据是可随目录迁移的资产，整体搬迁请连同 repo 一起。
