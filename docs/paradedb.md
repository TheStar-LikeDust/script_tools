# ParadeDB 部署 (Deploy)

## 服务简介

ParadeDB 是架构中的核心关系型数据库底座，使用 `paradedb/paradedb` 镜像。它拥有标准 PostgreSQL 的全部能力，并内置向量检索扩展，深度适配 LLM、知识库与向量检索场景。单容器即可独立运行，无需任何外部组件。

## 部署特性

- 轻量独立：单容器，无需额外编排组件。
- 资产内聚：库文件全部落在 `./data/<实例名>_data`，拷贝目录即带走全部数据。
- 多开隔离：通过 `INSTANCE_NAME` 与端口隔离，同机可起多个数据库实例。
- 不依赖 docker compose：单容器直接用原生 `docker run` 管理，只需装了 `docker` 即可。`settings.conf` 是唯一配置源，由 `cli.sh` `source` 后通过 `-e VAR` 透传给容器。
- 动态认证：首次 `init` 自动分配一个高强度随机密码。
- 健康检查：容器内置 `pg_isready` 健康探测，便于判断库是否就绪。

## 核心配置项 (`settings.conf`)

执行 `bash cli.sh init` 后生成，主要变量：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `paradedb_8421`），决定容器名与数据目录。
- `DB_PORT`: 暴露给宿主机的随机端口（容器内为 `5432`）。
- `DB_USER`: 数据库管理员账号（默认 `postgres`）。
- `DB_PASSWORD`: 自动生成的强密码。
- `DB_NAME`: 默认创建的库名（默认 `postgres`）。

## 备注

- 数据本地化：库数据仅保存在本地 `./data/<实例名>_data`，迁移时与 `settings.conf` 一起打包。
- 密码持久：`DB_PASSWORD` 在首次 `init` 时随机生成并写入 `settings.conf`，`purge` 不会删除该文件，避免密码丢失。

## 快速执行

```bash
cd deploy/paradedb

# 一键拉起（init + start）
bash cli.sh up

# 或分步：先生成配置、按需改 settings.conf，再启动
bash cli.sh init
bash cli.sh start
```

## 命令解释

每条命令对应的实际执行内容如下（`INSTANCE_NAME`、`DB_PORT` 等取自 `settings.conf`，启动前已 `set -a; source settings.conf; set +a` 导出为环境变量）。

路径锚定：脚本启动时计算自身所在目录 `SCRIPT_DIR`，模板恒取自 `$SCRIPT_DIR/templates`；配置文件默认 `$SCRIPT_DIR/settings.conf`（可用 `--conf` 覆盖），**数据目录在运行时派生为「配置文件所在目录」下的 `data/<实例名>_data`**。配置里不写死任何绝对路径，因此从任意 cwd 运行、或整体移动目录后再运行都不会失效。

### `init`

若配置文件不存在则用模板渲染生成，再创建数据目录，不启动容器。`--name` 指定完整实例名（不传则自动生成 `paradedb_<时间戳>`）。

```bash
sed -e "s/{{INSTANCE_NAME}}/<--name 或 paradedb_时间戳>/g" \
    -e "s/{{DB_PORT}}/<随机端口>/g" \
    -e "s/{{DB_PASSWORD}}/<随机密码>/g" \
    -e "s/{{DB_USER}}/postgres/g" \
    -e "s/{{DB_NAME}}/postgres/g" \
    "$SCRIPT_DIR/templates/settings.conf.tpl" > "$CONF_FILE"

mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

### `start`

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
# 已存在
docker start "${INSTANCE_NAME}"

# 不存在（新建）
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

### `up`

先 `init` 再 `start`。

### `stop`

```bash
docker stop "${INSTANCE_NAME}"
```

### `rm`

删除容器，保留 `./data/` 与 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

### `purge`

删除容器并删除本地数据目录，保留 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

### `status`

```bash
docker ps -a --filter "name=^${INSTANCE_NAME}$"
```

### 无参 / 未知参数

打印 Usage 帮助。

## 作为子服务嵌入 (`--conf` / `--name`)

除了独立部署，本服务可被上层 app（如 casdoor）作为「附带数据库」调用，把配置与数据安置到上层目录里，docker run 逻辑零重复。两个可选参数：

- `--conf PATH`：指定配置文件位置（默认 `$SCRIPT_DIR/settings.conf`）。数据目录运行时派生为该文件所在目录下的 `data/<实例名>_data`。支持相对路径（相对当前 cwd 解析）。
- `--name NAME`：在 `init` 时写入的完整实例名，由调用方决定（不传则自动 `paradedb_<时间戳>`）。

约定：实例命名完全交给调用方，本服务不再使用 `APP_PREFIX` 之类的前缀拼接。上层负责生成形如 `paradedb_casdoor_8421` 的完整名再用 `--name` 传入。

样例（被调用方在 `deploy_apps/casdoor` 目录下托管一个 paradedb）：

```bash
# init：配置落到 casdoor 目录的 settings_paradedb.conf，数据落到 casdoor/data/
bash ../../deploy/paradedb/cli.sh init \
    --conf "$PWD/settings_paradedb.conf" \
    --name "paradedb_casdoor_8421"

# start / stop / rm / purge / status：同样带上 --conf 指向同一文件
bash ../../deploy/paradedb/cli.sh start --conf "$PWD/settings_paradedb.conf"
```

## 其他补充

- 镜像版本：当前固定 `paradedb/paradedb:latest-pg17`。若需可复现部署，可锁定到更具体的版本标签。
- 向量扩展：库内可按需 `CREATE EXTENSION` 启用 ParadeDB 提供的检索扩展。
