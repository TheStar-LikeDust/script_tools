# New API 部署 (Deploy)

## 1. 简介

> New API 是 AI 模型接口管理与分发网关，提供渠道、密钥、计费与请求转发能力。

一个 Compose 项目包含 New API、配套 PostgreSQL 和 Redis。`init` 生成连接配置、随机凭证及本地数据目录，`start` 启动整套实例；数据库和账号由配套 PostgreSQL 在空数据目录首次启动时创建。

## 2. 核心配置项

### settings_newapi.conf

- `INSTANCE_NAME`：Compose 项目名、容器名和本地数据目录名，限定为小写字母、数字、下划线和连字符，首位为字母或数字。
- `IMAGE`：默认 `calciumion/new-api:latest`，可锁定具体版本。
- `POSTGRES_IMAGE` / `REDIS_IMAGE`：配套依赖镜像，默认 `paradedb/paradedb:latest-pg17` / `redis:7-alpine`。
- `NEWAPI_PORT` / `NEWAPI_PUBLISH_PORT`：宿主机端口和发布开关；容器端口 `3000`。
- `DOCKER_NETWORK`：默认留空，由 Compose 为整套实例创建私有网络；填写时接入管理员预先创建的共享网络。
- `DB_HOST` / `DB_PORT`：默认 `<INSTANCE_NAME>_postgres:5432`，使用配套容器名和容器端口。
- `DB_NAME` / `DB_USER` / `DB_PASSWORD`：配套 PostgreSQL 首次启动使用的数据库名、账号和密码；库名及账号默认 `newapi`，密码在 `init` 时随机生成并保存。
- `DB_SSLMODE`：默认 `disable`，对应配套 PostgreSQL 的私有网络连接。
- `REDIS_CONN_STRING`：默认 `redis://<INSTANCE_NAME>_redis:6379/0`。配套 Redis 未启用认证，不生成 Redis 密码。
- `CRYPTO_SECRET`：业务敏感信息的加密密钥，初始化生成，备份和恢复时必须保留原值。
- `TZ` / `ERROR_LOG_ENABLED`：默认 `Asia/Shanghai` / `true`。

## 3. 备注

- `DB_*` 在脚本中组成 `SQL_DSN`，用户名、密码、库名会进行 URL 编码；这些字段填写原值，不预先编码。`REDIS_CONN_STRING` 是完整 URI，凭证中的 `@`、`:`、`/` 等需人工 URL 编码。
- settings 按 Bash 读取；密码用单引号，含单引号时按 Bash 规则转义。生成 YAML 只保留变量引用。修改容器配置后再次 `start` 即可由 Compose 应用。
- 数据保存在 settings 所在目录下：`data/<INSTANCE_NAME>_data` 为应用数据，`data/<INSTANCE_NAME>_postgres_data` 为数据库，`data/<INSTANCE_NAME>_redis_data` 为 Redis。重启宿主机、删除容器或执行 `rm` 后，使用原 settings 再次 `start` 会挂回这些目录。
- 每个应用实例带有自己的 PostgreSQL 和 Redis 容器，数据库、Redis 不发布宿主机端口。Redis 使用 AOF 持久化；逻辑库编号不代表权限隔离。
- PostgreSQL 保留镜像默认的扩展预加载设置。Compose 等待数据库和 Redis 健康后启动 New API；首次建库只发生在数据库数据目录为空时，修改 settings 不会重置已有数据库密码。
- `init` 为旧配置补齐缺失或空的默认连接项，保留已有非空值、数据库密码和 `CRYPTO_SECRET`。配置文件与持久化数据应一起保留。
- 首次访问 Web UI 按应用提示创建管理员。
- CLI 检查应用、PostgreSQL、Redis 三个容器名的 Compose 项目和服务归属；冲突时拒绝操作。不同部署使用唯一实例名。`--conf` 父目录须已存在，生成 YAML 和本地数据位于该目录，CLI 和模板仍从脚本目录读取。

## 4. 快速执行

默认配置自带 PostgreSQL 和 Redis，可直接初始化并启动：

```bash
cd deploy_apps/newapi
bash cli.sh init
bash cli.sh start
# Update the app and its bundled dependencies.
bash cli.sh update
```

指定独立配置目录和实例名时，父目录须预先存在：

```bash
bash cli.sh init --conf /srv/newapi-main/settings_newapi.conf --name newapi_main
bash cli.sh start --conf /srv/newapi-main/settings_newapi.conf
```

该实例的三个容器分别为 `newapi_main`、`newapi_main_postgres` 和 `newapi_main_redis`，共享本项目私有网络。默认数据库地址为 `newapi_main_postgres:5432`，Redis 地址为 `redis://newapi_main_redis:6379/0`。

保留数据重建整套实例：

```bash
bash cli.sh rm --conf /srv/newapi-main/settings_newapi.conf
bash cli.sh start --conf /srv/newapi-main/settings_newapi.conf
```

本次部署流程覆盖默认配套模式。容器内 `localhost` 只指当前容器，应用连接配套服务时使用生成的容器名。

## 5. 命令解释

以下 `compose` 指 `cli.sh` 内的包装函数：先读取 settings，再使用 `--env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE"` 调用 Docker Compose。这些代码展示实现，不是独立可执行的终端命令。

#### init

生成缺失的 settings 与随机密钥，补齐空的配套连接项，再生成 `settings_newapi.compose.yaml` 及应用、PostgreSQL、Redis 三个数据目录。只操作本地文件和目录，不连接或启动容器；重复执行保留已有非空值和凭证。

```bash
bash cli.sh init
```

#### start

检查配套配置及三个容器名的归属，刷新 YAML 后启动整套实例。配套 PostgreSQL 和 Redis 健康后才启动 New API，应用迁移及就绪情况可通过日志查看。

```bash
compose up -d
```

#### up

依次执行 `init`、`start`，使用默认配套配置启动整套实例。

```bash
do_init
do_start
```

#### update

拉取 settings 中 `IMAGE`、`POSTGRES_IMAGE`、`REDIS_IMAGE` 指定的镜像并应用更新，保留配置、密钥和数据。升级前备份，涉及数据库结构升级时按镜像的升级要求处理；该命令不执行 PostgreSQL 跨主版本数据迁移。

```bash
compose pull
compose up -d
```

#### stop

停止本实例的 New API、PostgreSQL 和 Redis，保留容器、配置与数据。

```bash
compose stop
```

#### rm

删除本实例三个容器与 Compose 私有网络；保留 settings、应用数据、数据库和 Redis 数据。已配置的 external 共享网络仍保留。

```bash
compose down
```

#### purge

危险操作：先执行 `rm`，再删除本实例的 `data/<INSTANCE_NAME>_data`、`data/<INSTANCE_NAME>_postgres_data`、`data/<INSTANCE_NAME>_redis_data`，保留 settings 和生成的 YAML。

```bash
bash cli.sh purge
```

#### reset

危险操作：先 `purge`，再删除当前 `--conf` 对应的 settings 和 YAML，完整清理本实例的容器、持久化数据及生成配置。源码、模板和其他实例文件保留。

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

停止整套实例后，复制 CLI、templates、settings、生成 YAML，以及 `data/<INSTANCE_NAME>_data`、`data/<INSTANCE_NAME>_postgres_data`、`data/<INSTANCE_NAME>_redis_data`。在线备份需使用数据库及 Redis 各自的一致性备份方式，不能直接复制运行中的数据库目录。保留原数据库密码和 `CRYPTO_SECRET`。

目标机器使用兼容的 PostgreSQL 主版本及镜像，保持实例名与数据目录名对应后运行 `start`。默认私有网络由 Compose 创建；若配置了共享网络，则提前准备该网络。使用外置 `--conf` 时，配置与数据目录须与 CLI、templates 一起保存。

`init` 只补齐缺失或空的默认字段，不重置已有非空凭证；`reset` 用于完整清理，不能用于恢复或升级。默认镜像使用滚动标签，可在对应的镜像配置项中指定具体版本或 digest。
