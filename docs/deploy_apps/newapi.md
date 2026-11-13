# New API 部署 (Deploy)

## 1. 简介

> New API 是 AI 模型接口管理与分发网关，提供渠道、密钥、计费与请求转发能力。

本目录使用一个 Compose 项目组合 New API、ParadeDB 和 Redis。`init` 先准备三份 settings，再由两个基础服务提供自己的 Compose 片段和连接串；`start` 启动整套实例，并通过 `hooks.sh` 完成一次管理员初始化。

## 2. 核心配置项

### settings_newapi.conf

- `INSTANCE_NAME`、`IMAGE`：应用实例名和镜像；实例名决定 Compose 项目名与应用数据目录。
- `NEWAPI_PORT`、`NEWAPI_PUBLISH_PORT`：宿主机端口和发布开关；容器端口为 `3000`。
- `DOCKER_NETWORK`：留空使用 Compose 私有网络；填写时接入预先创建的共享网络。
- `PARADEDB_CONF`、`REDIS_CONF`：依赖 settings 路径。相对路径按应用 settings 所在目录解析，也可指定绝对路径。
- `TZ`、`ERROR_LOG_ENABLED`：应用时区和错误日志开关。
- `CRYPTO_SECRET`：应用加密密钥；首次启动后必须随应用数据备份。
- `NEWAPI_ADMIN_USERNAME`、`NEWAPI_ADMIN_PASSWORD`：`init` 生成的初始管理员凭证，供启动 hook 使用。

### settings_newapi_paradedb.conf

由 ParadeDB 服务 CLI 维护。数据库镜像、容器名、数据库名、账号、密码和端口只保存在该文件；New API 通过服务的 `env` 获取 `PARADEDB_DSN`，不重复保存数据库密码。

### settings_newapi_redis.conf

由 Redis 服务 CLI 维护。Redis 默认无认证，New API 通过服务的 `env --db 0` 获取 `REDIS_URL`；逻辑库编号只区分数据，不提供权限隔离。

## 3. 备注

- `init` 默认在应用 settings 同目录生成 `settings_newapi_paradedb.conf` 和 `settings_newapi_redis.conf`，并以 `${INSTANCE_NAME}_postgres`、`${INSTANCE_NAME}_redis` 作为容器名。
- 依赖服务的 `init --config-only` 只准备配置；服务片段的镜像、挂载、健康检查和凭证引用来自服务自身模板。
- New API 的总 YAML 由 `hooks.sh` 组合：ParadeDB `render --service-name postgres`、Redis `render --service-name redis` 和本目录应用片段。应用只使用 `PARADEDB_*`、`REDIS_*` 与 `NEWAPI_*` 环境变量。
- 数据库 DSN 使用 ParadeDB 服务生成的容器地址和内部端口 `5432`；Redis URL 使用 Redis 服务生成的容器地址和内部端口 `6379`。宿主机映射端口不用于容器间连接。
- 新生成的应用配置使用 `settings_newapi_paradedb.conf` 和 `settings_newapi_redis.conf`。已有 `settings_newapi.conf` 中的非空依赖路径和旧数据目录不会自动迁移；需要手动重命名依赖文件并更新 `PARADEDB_CONF`、`REDIS_CONF`。`reset` 只清理应用配置目录内明确引用的默认依赖文件，外部配置保留。
- `init`、`start`、`update` 使用明确的 settings 路径，不扫描或选择其他实例的配置和容器。组合后的容器由 New API Compose 项目统一管理。
- 首次管理员初始化要求宿主机有 `curl` 且 `NEWAPI_PUBLISH_PORT=true`。hook 等待 `/api/status` 后向 `/api/setup` 提交自用模式请求；成功标记写入应用数据目录，重复 `start` 跳过。

## 4. 快速执行

默认配置会自动准备两个依赖：

```bash
cd deploy_apps/newapi
bash cli.sh init
bash cli.sh start
# Update all three images.
bash cli.sh update
```

指定应用 settings 路径和实例名时，父目录须预先存在：

```bash
bash cli.sh init --conf /srv/newapi-main/settings_newapi.conf --name newapi_main
bash cli.sh start --conf /srv/newapi-main/settings_newapi.conf
```

默认生成的配置文件为 `/srv/newapi-main/settings_newapi.conf`、`settings_newapi_paradedb.conf` 和 `settings_newapi_redis.conf`，生成 YAML 和三个数据目录也位于该目录。

## 5. 命令解释

#### init

生成或补齐应用 settings，调用两个服务的 `init --config-only`，再组合总 Compose YAML 和三个数据目录。已有依赖 settings 的非空字段优先，数据库密码不会重置。该命令不启动容器。

#### start

读取三份 settings，调用两个服务的 `env` 和 `render` 刷新总 YAML，再执行 `docker compose up -d`。依赖容器健康后启动 New API，并运行管理员初始化 hook。服务 CLI 的输出在独立进程中处理，不覆盖应用的同名变量。

#### up

依次执行 `init` 和 `start`。

#### update

重新渲染总 YAML，拉取并应用 New API、ParadeDB 和 Redis 镜像；不调用管理员初始化 hook，配置、凭证和数据保留。

#### stop

停止本 Compose 项目的三个容器，保留 settings 和数据。

#### rm

删除本 Compose 项目的三个容器和私有网络，保留 settings 和数据；共享 external 网络不删除。

#### purge

删除应用、ParadeDB 和 Redis 三个数据目录，保留全部 settings 和生成 YAML。

#### reset

先执行 `purge`，再删除应用 settings、生成 YAML，以及默认位于应用配置目录的两个依赖 settings。通过 `PARADEDB_CONF` 或 `REDIS_CONF` 指向外部路径时，不删除外部配置。

#### network ls

只读显示配置的网络和容器，不创建、接入或删除网络。

## 6. 备份与复制恢复

备份需包含 New API CLI、`hooks.sh`、模板、三份 settings、生成 YAML，以及 `data/<INSTANCE_NAME>_data`、`data/<PARADEDB_INSTANCE_NAME>_data`、`data/<REDIS_INSTANCE_NAME>_data`。还需携带 `deploy_services/paradedb` 和 `deploy_services/redis` 的 CLI、hooks 与模板，并保留它们相对 New API 目录的位置。数据库和 Redis 正在写入时不能直接复制数据目录。恢复时保留原始 `CRYPTO_SECRET`、数据库密码和管理员 settings。
