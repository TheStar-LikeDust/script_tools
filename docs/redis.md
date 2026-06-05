# Redis 部署 (Deploy)

## 1. 简介

> Redis 是架构中的内存键值存储，常用于缓存、会话与队列。

使用官方 `redis:7-alpine` 镜像，默认开启 AOF 与 RDB 持久化，单容器即可独立运行，无需任何外部组件。

## 2. 部署特性

- 持久化默认开启：启动命令带 `--save 60 1000 --appendonly yes`，同时启用 RDB 快照与 AOF。
- 健康检查：容器内置 `redis-cli ping` 健康探测。
- 作为子服务嵌入：支持通过 `--conf` 和 `--name` 参数被上层应用（如 LobeChat）像调用函数一样嵌入，将配置与数据托管至上层目录。

## 3. 核心配置项 (settings.conf)

执行 `bash cli.sh init` 后生成，主要变量：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `redis_8421`），决定容器名与数据目录。
- `REDIS_PORT`: 暴露给宿主机的随机端口（容器内为 `6379`）。

## 4. 备注

- 无密码：默认不设访问密码，仅适合本机或受信网络。对外暴露时建议自行加 `--requirepass` 或前置网络隔离。
- 数据本地化：持久化文件仅保存在本地 `./data/<实例名>_data`，迁移时与 `settings.conf` 一起打包。

## 5. 快速执行

```bash
cd deploy/redis

# 一键拉起（init + start）
bash cli.sh up

# 或分步：先生成配置、按需改 settings.conf，再启动
bash cli.sh init
bash cli.sh start
```

## 6. 命令解释

#### init

若配置文件不存在则用模板渲染生成，再创建数据目录，不启动容器。`--name` 指定完整实例名。

```bash
sed -e "s/{{INSTANCE_NAME}}/<--name 或 redis_时间戳>/g" \
    -e "s/{{REDIS_PORT}}/<随机端口>/g" \
    "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"

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

删除容器，保留 `./data/` 与 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

#### purge

删除容器并删除本地数据目录，保留 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### status

显示容器状态。

```bash
docker ps -a --filter "name=^${INSTANCE_NAME}$"
```

## 7. 其他补充

- 镜像版本：当前固定 `redis:7-alpine`。若需可复现部署，可锁定到更具体的补丁版本标签。
- 持久化策略：`--save 60 1000` 表示 60 秒内有 1000 次写入则触发 RDB 快照；`--appendonly yes` 开启 AOF，可按需调整。
