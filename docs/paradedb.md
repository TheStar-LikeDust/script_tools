# ParadeDB 部署 (Deploy)

## 1. 简介

> ParadeDB 是架构中的核心关系型数据库底座，基于 PostgreSQL 并内置向量检索扩展，深度适配 LLM、知识库与向量检索场景。

单容器即可独立运行，无需任何外部组件。

## 2. 功能

- 动态随机高强认证
  - 问题：数据库默认密码易受扫描攻击，手动设置又非常繁琐。
  - 方案：首次 `init` 初始化时会自动通过 `openssl` 分配一个高强度的随机密码并固化，兼顾了安全性与使用的便利性。
- 健康探测就绪反馈
  - 问题：数据库启动通常较慢，其他组件如何知道它已经可以接受连接。
  - 方案：容器内置了 `pg_isready` 健康探测，上层应用或运维人员可以通过容器状态实时了解数据库是否进入就绪状态。
- 全局通用功能支持
  - 子组件嵌入：支持通过 `--conf` 和 `--name` 参数被上层应用像调用函数一样嵌入执行部署，实现下沉组件数据的干净沙箱化（详情参见 `docs/design/core.md`）。

## 3. 核心配置项

### settings.conf

数据库主配置：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `paradedb_8421`），决定容器名与数据目录。
- `DB_PORT`: 暴露给宿主机的随机端口（容器内为 `5432`）。
- `DB_USER`: 数据库管理员账号（默认 `postgres`）。
- `DB_PASSWORD`: 自动生成的强密码。
- `DB_NAME`: 默认创建的库名（默认 `postgres`）。

## 4. 备注

- 向量扩展按需启用：容器虽已内置并编译了 pgvector 等专用插件，但默认库内并未激活，需在目标库中通过 `CREATE EXTENSION vector;` 按需启用后方可使用。

## 5. 快速执行

```bash
cd deploy/paradedb

# 常规分步拉起（推荐）：先生成配置、按需修改 settings.conf 后再启动
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
