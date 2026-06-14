# Redis 部署 (Deploy)

## 1. 简介

> Redis 是架构中的内存键值存储，常用于缓存、会话与队列。

使用官方 `redis:7-alpine` 镜像，单容器即可独立运行，自带 `redis-cli ping` 探测探针以反馈真实服务就绪状态；启动命令已硬编码启用 RDB 快照与 AOF，开箱即提供生产级的持久化保护。并支持通过 `--conf` 和 `--name` 机制作为子组件被嵌入。

## 2. 核心配置项

### settings_redis.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `redis_8421`），决定容器名与数据目录。
- `REDIS_PORT`: 暴露给宿主机的随机端口（容器内为 `6379`）。

## 3. 备注

- 无密访问警告：为方便同级容器内网直通，默认未设置 Redis 访问密码。仅建议在隔离的自定义网络或本机信任网络内使用，若对外暴露需自行在启动命令中增加 `--requirepass`。

## 4. 快速执行

```bash
cd deploy/redis

# 常规分步拉起（推荐）：先生成配置、按需修改 settings_redis.conf 后再启动
bash cli.sh init
bash cli.sh start

# 一键拉起（跳过配置直接启动）
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

若配置文件不存在则用模板渲染生成，再创建数据目录，不启动容器。`--name` 指定完整实例名。

```bash
sed -e "s/{{INSTANCE_NAME}}/<--name 或 redis_时间戳>/g" \
    -e "s/{{REDIS_PORT}}/<随机端口>/g" \
    "$TPL_DIR/settings_redis.conf.tpl" > "$CONF_FILE"

mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### start

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
docker run -d \
    --name "${INSTANCE_NAME}" \
    -p "${REDIS_PORT}:6379" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/data" \
    --health-cmd "redis-cli ping" \
    --health-interval 5s \
    --health-timeout 3s \
    --health-retries 5 \
    --restart unless-stopped \
    redis:7-alpine \
    redis-server --save 60 1000 --appendonly yes
```

#### up

先 `init` 再 `start`。

#### stop

停止容器。

```bash
docker stop "${INSTANCE_NAME}"
```

#### rm

删除容器，保留 `./data/` 与 `settings_redis.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

#### purge

删除容器并删除本地数据目录，保留 `settings_redis.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

## 6. 其他补充

- 镜像版本：当前固定 `redis:7-alpine`。若需可复现部署，可锁定到更具体的补丁版本标签。
- 持久化策略：`--save 60 1000` 表示 60 秒内有 1000 次写入则触发 RDB 快照；`--appendonly yes` 开启 AOF，可按需调整。
