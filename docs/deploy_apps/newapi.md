# New API 部署 (Deploy)

## 1. 简介

> New API 是 AI 模型接口管理与分发网关，提供渠道、密钥、计费与请求转发能力。

Compose 项目仅部署 New API。PostgreSQL 与 Redis 由管理员独立启动，应用通过 settings 中的地址和凭证连接，不管理依赖的生命周期。

## 2. 核心配置项

### settings_newapi.conf

- `INSTANCE_NAME`：Compose 项目名、容器名和本地数据目录名，限定为小写字母、数字、下划线和连字符，首位为字母或数字。
- `IMAGE`：默认 `calciumion/new-api:latest`，可锁定具体版本。
- `NEWAPI_PORT` / `NEWAPI_PUBLISH_PORT`：宿主机端口和发布开关；容器端口 `3000`。
- `DOCKER_NETWORK`：管理员已创建的共享网络；留空使用 Compose 私有网络，适用于依赖都在远程的情况。
- `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD`：人工填写已创建的 PostgreSQL 数据库与专用账号，端口默认 `5432`。
- `DB_SSLMODE`：默认 `disable`；远程 TLS 服务按实际要求配置。
- `REDIS_CONN_STRING`：完整 Redis URI，例如 `redis://:密码的URL编码@redis-newapi:6379/0`。认证与隔离由管理员配置。
- `CRYPTO_SECRET`：业务敏感信息的加密密钥，初始化生成，备份和恢复时必须保留原值。
- `TZ` / `ERROR_LOG_ENABLED`：默认 `Asia/Shanghai` / `true`。

## 3. 备注

- `DB_*` 在脚本中组成 `SQL_DSN`，用户名、密码、库名会进行 URL 编码；这些字段填写原值，不预先编码。`REDIS_CONN_STRING` 是完整 URI，凭证中的 `@`、`:`、`/` 等需人工 URL 编码。
- settings 按 Bash 读取；密码用单引号，含单引号时按 Bash 规则转义。生成 YAML 只保留变量引用。修改容器配置后再次 `start` 即可由 Compose 应用。
- 业务数据主要在外部 PostgreSQL；本地 `data/<实例名>_data` 挂载至 `/data`。复制应用目录不会复制外部数据库或 Redis。
- 管理员需为 New API 预建独立数据库和账号。Redis 数据库编号仅做命名空间区分，不是权限隔离；仓库 Redis 模板没有认证，多应用共享前需配置 ACL 等隔离，或使用独立实例。
- 首次访问 Web UI 按应用提示创建管理员。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。`--conf` 父目录须已存在，生成 YAML 和本地数据位于该目录，CLI 和模板仍从脚本目录读取。

## 4. 快速执行

先独立启动基础服务、创建数据库和账号，再初始化应用：

```bash
cd deploy_apps/newapi
bash cli.sh init
# Edit settings_newapi.conf before start.
bash cli.sh start
bash cli.sh update
```

同机示例：管理员先创建 `shared_services` 网络，并让数据库、Redis 和应用加入同一网络。下面名称须替换为真实实例容器名：

```bash
DOCKER_NETWORK="shared_services"
DB_HOST="pg-shared"
DB_PORT="5432"
DB_NAME="newapi"
DB_USER="newapi"
DB_PASSWORD='replace-with-dedicated-password'
REDIS_CONN_STRING='redis://redis-newapi:6379/0'
```

上例 Redis 仅适合管理员限制网络访问的独立实例。共享且有认证时改为对应账号的 URI。连接同机容器使用内部端口，不填写随机宿主机端口，也不填写 `localhost`。

远程 PostgreSQL/Redis 示例：

```bash
DOCKER_NETWORK=""
DB_HOST="db.example.internal"
DB_PORT="5432"
DB_SSLMODE="require"
REDIS_CONN_STRING='rediss://:encoded-password@cache.example.internal:6379/2'
```

`localhost` 在应用内指当前应用容器；远程地址必须能从容器访问。网络创建由管理员执行，应用不创建共享网络。

## 5. 命令解释

以下 `compose` 指 `cli.sh` 内的包装函数：先读取 settings，再使用 `--env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE"` 调用 Docker Compose。这些代码展示实现，不是独立可执行的终端命令。

#### init

仅在 settings 缺失时生成配置与随机密钥，再生成 `settings_newapi.compose.yaml` 和本应用数据目录；允许先留空外部连接信息。

```bash
if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
load_settings
generate_compose
mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### start

检查配置及同名容器归属，刷新 YAML 后应用配置。外部服务必须已经可用。

```bash
compose up -d
```

#### up

依次执行 `init`、`start`；有必填连接项的全新配置需先人工填写。

```bash
do_init
do_start
```

#### update

拉取 settings 中 `IMAGE` 指定的镜像并应用更新，保留配置、密钥和数据。升级前备份，涉及数据库结构升级时按镜像的升级要求处理。

```bash
compose pull
compose up -d
```

#### stop

仅停止本应用。

```bash
compose stop
```

#### rm

删除本项目容器与 Compose 私有网络；保留 settings、本地数据及外部共享网络。

```bash
compose down
```

#### purge

危险操作：先执行 `rm`，再删除本应用的 `data/${INSTANCE_NAME}_data`。settings、外部 PostgreSQL 和 Redis 数据保留。

```bash
do_rm
if [ -d "$CONF_DIR/data/${INSTANCE_NAME}_data" ]; then
    docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
fi
```

#### reset

危险操作：先 `purge`，再仅删除当前 `--conf` 对应的 settings 和 YAML。不会匹配删除其他配置文件；删除密钥后不能直接复用已有外部加密数据。

```bash
do_purge
rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
```

#### network ls

只读显示配置的共享网络或 Compose 私有网络，不创建、接入或删除网络。

```bash
bash cli.sh network ls
```

## 6. 备份与复制恢复

停止应用写入或完成一致性备份后，复制包含 CLI、templates、settings、生成 YAML 和 `data/<INSTANCE_NAME>_data` 的应用目录。保留原 `CRYPTO_SECRET`，否则数据库内的加密信息可能无法解密。

PostgreSQL 和 Redis 从各自服务目录单独备份和恢复。目标机器准备共享网络，保持实例名与本地数据目录名对应，填写实际数据库、Redis 地址和凭证后运行 `start`。需要调整部署位置时，外置 `--conf` 目录须与对应 CLI、templates 一同保存。

`init` 不覆盖配置或自动补字段。恢复时保留应用密钥，按模板补齐连接设置；`reset` 用于清理，不能用于恢复或升级。默认 `latest` 是滚动标签，可在 `IMAGE` 中用具体版本或 digest 固定部署。
