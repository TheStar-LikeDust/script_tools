# ParadeDB 部署 (Deploy)

## 1. 简介

> ParadeDB 是架构中的核心关系型数据库底座，基于 PostgreSQL 并内置向量检索扩展，深度适配 LLM、知识库与向量检索场景。

单容器即可独立运行，无需任何外部组件。

## 2. 部署特性

- 动态认证：首次 `init` 自动分配一个高强度随机密码。
- 健康检查：容器内置 `pg_isready` 健康探测，便于上层应用判断库是否就绪。
- 作为子服务嵌入：支持通过 `--conf` 和 `--name` 参数被上层应用（如 Casdoor、LobeChat）像调用函数一样嵌入，将配置与数据托管至上层目录，避免逻辑重复。

## 3. 核心配置项 (settings.conf)

执行 `bash cli.sh init` 后生成，主要变量：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `paradedb_8421`），决定容器名与数据目录。
- `DB_PORT`: 暴露给宿主机的随机端口（容器内为 `5432`）。
- `DB_USER`: 数据库管理员账号（默认 `postgres`）。
- `DB_PASSWORD`: 自动生成的强密码。
- `DB_NAME`: 默认创建的库名（默认 `postgres`）。

## 4. 备注

- 密码持久：`DB_PASSWORD` 在首次 `init` 时随机生成并写入 `settings.conf`，`purge` 不会删除该文件，避免密码丢失。

## 5. 快速执行

```bash
cd deploy/paradedb

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
sed -e "s/{{INSTANCE_NAME}}/<--name 或 paradedb_时间戳>/g" \
    -e "s/{{DB_PORT}}/<随机端口>/g" \
    -e "s/{{DB_PASSWORD}}/<随机密码>/g" \
    -e "s/{{DB_USER}}/postgres/g" \
    -e "s/{{DB_NAME}}/postgres/g" \
    "$SCRIPT_DIR/templates/settings.conf.tpl" > "$CONF_FILE"

mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### start

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
docker run -d \
    --name "${INSTANCE_NAME}" \
    -p "${DB_PORT}:5432" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/var/lib/postgresql/data" \
    -e POSTGRES_USER="${DB_USER}" \
    -e POSTGRES_PASSWORD="${DB_PASSWORD}" \
    -e POSTGRES_DB="${DB_NAME}" \
    --health-cmd "pg_isready -U ${DB_USER}" \
    --health-interval 5s \
    --health-timeout 5s \
    --health-retries 5 \
    --restart unless-stopped \
    paradedb/paradedb:latest-pg17
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

- 镜像版本：当前固定 `paradedb/paradedb:latest-pg17`。若需可复现部署，可锁定到更具体的版本标签。
- 向量扩展：库内可按需 `CREATE EXTENSION` 启用 ParadeDB 提供的检索扩展。
