# RustFS 部署 (Deploy)

## 1. 简介

> RustFS 是一款高性能、兼容 Amazon S3 的对象存储服务器，常用于存储业务文件、用户上传的头像、知识库等大型非结构化数据。

本目录用于独立部署 RustFS，提供 S3 API 和管理控制台。`init/start` 管理独立实例；`init --config-only`、`render`、`env` 供应用组合 Compose，`resource-init` 在运行中的实例内幂等创建应用 Bucket、专用用户和 Bucket 范围策略。

## 2. 核心配置项

### settings_rustfs.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `rustfs_8421`），决定容器名与数据目录。
- `RUSTFS_PORT`: S3 API 宿主机端口（容器内为 `9000`），仅在 `RUSTFS_PUBLISH_PORTS=true` 时发布。
- `RUSTFS_ADMIN_PORT`: 控制台宿主机端口（容器内为 `9001`），仅在 `RUSTFS_PUBLISH_PORTS=true` 时发布。
- `RUSTFS_PUBLISH_PORTS`: 是否向宿主机发布两个端口，默认 `true`。
- `DOCKER_NETWORK`: 可选的、预先创建的共享 Docker 网络；留空时使用 Compose 私有网络。
- `IMAGE`: Compose 使用的镜像，默认 `rustfs/rustfs:latest`。
- `RUSTFS_ACCESS_KEY`: 自动生成的访问密钥（S3 Access Key）。
- `RUSTFS_SECRET_KEY`: 自动生成的访问私钥（S3 Secret Key）。
- `RUSTFS_INIT_IMAGE`: 资源初始化 CLI 镜像，默认 `rustfs/rc:latest`。

`init/up` 可用 `--name`、`--image`、`--init-image`、`--port`、`--admin-port`、`--publish-ports`、`--network` 注入空字段；`--access-key`、`--secret-key` 注入管理员凭证。已有非空 settings 优先，其次使用参数，再使用随机值或默认值。

## 3. 备注

- 本目录独立启动后默认没有 Bucket。组合应用通过此目录的 `resource-init` 接口使用 RustFS 管理凭证创建专用用户、Bucket 和策略；应用配置只保留应用专用凭证。已有同名资源没有本地归属标记时拒绝接管。`resource-init` 通过运行容器的 Docker 网络执行，不启动或停止 RustFS。
- `start` 会用临时容器读取镜像内 `rustfs` 用户的 UID/GID，并在数据目录属主不匹配时修正目录及已有文件的所有权。`update` 在拉取镜像后执行相同处理。部署脚本需有权限执行 `chown`，临时容器读取完成后删除。
- 配置共享网络后，同一网络中的应用使用 RustFS 实例名和容器端口 `9000` 连接 S3 API。容器内的 `localhost` 指向容器自身；宿主机或远程客户端使用服务器地址和 `RUSTFS_PORT`。`RUSTFS_PUBLISH_PORTS` 控制两个端口一起发布或关闭，单独发布须修改 Compose 模板。
- 浏览器直接使用 S3 预签名链接时，S3 API 地址必须对应用容器和浏览器同时可达，可用稳定域名及 HTTPS 反向代理；管理控制台端口 `9001` 不能代替 S3 API。
- 共享网络由管理员提前创建，例如 `docker network create shared_services`，再将 `DOCKER_NETWORK` 设为 `shared_services`。本服务只接入网络，不创建或删除共享网络。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。

## 4. 快速执行

```bash
cd deploy_services/rustfs

# Generate settings and YAML, then edit settings before starting.
bash cli.sh init
bash cli.sh start

# Use init + start when settings are ready.
bash cli.sh up

# Pull and apply the configured image.
bash cli.sh update

# Disable host ports for this invocation; persist the flag in settings if needed.
bash cli.sh start --conf /path/to/settings_rustfs.conf --internal

# Stop this RustFS instance.
bash cli.sh stop

# Remove containers; keep settings and bind mount data.
bash cli.sh rm

# DANGER: permanently delete this instance's data.
bash cli.sh purge
```

## 5. 命令解释

以下代码展示 CLI 内部操作，环境变量由 CLI 读取 settings 后导出；`compose` 为使用当前项目目录、实例名和 YAML 路径的包装函数。日常操作使用 `bash cli.sh <命令>`。

#### init

若配置文件不存在则用模板生成并补齐缺失项；随后生成 Compose YAML 并创建数据目录，不启动容器。`--name` 指定完整实例名。使用 `--config-only` 时只生成 settings，不生成 YAML 或数据目录，供应用先准备全部依赖配置再组合总 YAML。

生成的 Compose YAML 通过 `RUSTFS_*` 环境变量引用配置值，访问密钥留在 settings 文件中。`--conf PATH` 的父目录须已存在，YAML 与数据保存在该目录；CLI 和模板仍位于脚本目录。`--internal` 在本次命令中关闭端口发布，长期关闭应设置 `RUSTFS_PUBLISH_PORTS=false`。

#### start

按当前配置刷新 Compose YAML 并执行 `docker compose up -d`；配置变化会由 Compose 更新容器定义。项目名为 `INSTANCE_NAME`。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### up

先 `init` 再 `start`。

#### stop

执行 `docker compose ... stop`，保留容器、网络与数据。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" stop
```

#### rm

执行 `docker compose ... down`，移除本项目容器和私有网络，保留 `./data/` 与配置；外部共享网络不会删除。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" down
```

#### purge

危险操作：移除 Compose 容器并删除本地数据目录，保留 `settings_rustfs.conf`。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" down
docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
```

#### update

拉取 settings 中 `IMAGE` 对应的镜像，按该镜像处理数据属主，再由 Compose 重建服务；配置、凭证和数据目录保留。

```bash
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" pull
ensure_data_owner "$CONF_DIR/data/${INSTANCE_NAME}_data"
docker compose --env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" up -d
```

#### reset

危险操作：先执行 `purge`，再只删除当前 `--conf` 对应的 settings 和生成 YAML，其他配置保留。

```bash
do_purge
rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
```

#### render

读取 RustFS settings 并将 Compose 服务片段写入标准输出，不包含 `services:` 和顶层网络。`--service-name NAME` 可指定组合文件中的服务键，容器名仍来自 RustFS settings。

```bash
bash cli.sh render --conf /path/to/settings_rustfs.conf --service-name rustfs
```

#### env

向标准输出写入带 `RUSTFS_*` 前缀的 Bash `export` 语句及 `RUSTFS_ENDPOINT`。输出包含 RustFS 管理凭证，只能由受信任调用方读取；组合应用不得整体 source RustFS settings。

```bash
bash cli.sh env --conf /path/to/settings_rustfs.conf
```

#### resource-init

在配置明确指定的运行容器的网络命名空间中执行 RustFS 客户端，幂等创建 Bucket、专用用户和仅限该 Bucket 的策略。Bucket 使用 3–63 位小写字母、数字、连字符；专用访问键使用 3–20 位字母或数字。管理员凭证仅用于初始化，不得与应用凭证相同。归属标记保存在容器实际 `/data` 挂载源下；已有同名资源但没有标记时返回错误，不覆盖或接管。

```bash
bash cli.sh resource-init --conf /path/to/settings_rustfs.conf \
    --owner lobechat_1234 --bucket lobechat-1234 \
    --access-key 0123456789abcdef0123 --secret-key app-specific-secret \
    --endpoint http://lobechat_1234_rustfs:9000
```

此命令不启动、停止或删除 RustFS；要求容器已运行且安装 Docker CLI。组合方应检查返回状态，失败时保留已启动服务并将错误返回给调用者。

#### prepare-data

读取配置镜像的 RustFS 用户 UID/GID，创建数据目录并修正属主；不启动服务。独立 `start/update` 复用相同 hook，应用通过 CLI 指定父 Compose 项目中的实际挂载路径。

```bash
bash cli.sh prepare-data --conf /srv/lobe/settings_rustfs.conf \
    --data-dir /srv/lobe/data/lobechat_main_rustfs_data
```

## 6. Bucket、凭证与复制恢复

默认 `rustfs/rustfs:latest` 是滚动标签，可在 settings 中指定具体版本或 digest。开启端口发布后，通过 `http://<服务器IP>:<RUSTFS_ADMIN_PORT>` 访问控制台，使用 settings 中的 Access Key / Secret Key 登录。

应用默认使用独立 RustFS 实例；组合方在启动后调用 `resource-init` 创建专用用户和 Bucket 范围策略，不把服务管理员凭证写入应用 settings。资源归属标记位于 `data/<RustFS_INSTANCE_NAME>_data/.resources/`，跟随 RustFS 数据保留或删除。应用 `rm` 保留这些数据，`purge/reset` 删除。LobeHub 浏览器 CORS 配置暂留待处理，按实际使用反馈调整。

停止对象写入及 RustFS，或完成一致性备份后，复制 CLI、hooks.sh、templates、settings、YAML 和完整数据目录，保留对象、Bucket、访问凭证及 `.resources/` 标记。目标机器准备兼容镜像、数据属主权限和配置中需要的共享网络。LobeHub 配套 RustFS 随应用配置目录及其 data 一起备份恢复。

使用 `--internal` 时本次生成的 YAML 不发布 S3 API 和控制台端口；下次未传该参数的 `start/update` 会按 settings 中的 `RUSTFS_PUBLISH_PORTS` 重新生成 YAML。

## 7. 已核对的部署依据

2026-11-13 阅读 RustFS 官方客户端资料确认以下接口；本轮没有运行镜像或服务，`latest` 标签可能变化，部署时可固定服务和客户端版本。

- 客户端源码仓库为 [rustfs/cli](https://github.com/rustfs/cli)，Docker 镜像为 `rustfs/rc:latest`，二进制为 `rc`；并非 `rustfs/rc` 源码仓库。
- [官方 README](https://github.com/rustfs/cli/blob/main/README.md) 明确列出 `rc admin user add/info`、`rc admin policy create/info/attach` 和 `rc ready local --timeout 2`。`rc admin` 使用 RustFS Admin API，不能因 S3 兼容就替换成 MinIO 管理接口。
- [官方镜像定义](https://github.com/rustfs/cli/blob/main/Dockerfile.release) 使用 Alpine，提供 `/bin/sh`、`rc`、`jq`，默认以非 root 用户运行。资源 hook 临时使用 `--user 0:0` 读取权限为 600 的策略文件、写入归属标记；RustFS 服务本身仍使用镜像默认用户。
- 官方退出码约定为：`0` 成功、`3` 网络失败、`4` 权限失败、`5` 资源不存在、`6` 冲突、`7` 不支持。资源查询只将 `5` 视为可创建，其余错误直接返回，避免把鉴权或网络失败当作资源不存在。
- 当前 hook 的顺序为等待就绪、核对同名资源、保存归属、创建缺项、绑定 Bucket 策略、用专用凭证访问 Bucket。标记包含 owner、Bucket、访问键和密码摘要；创建前落盘以支持中断续做，重复执行不修改已有用户密码。

```bash
# Commands used inside the temporary client container.
rc alias set local "$RUSTFS_ENDPOINT" "$RUSTFS_ROOT_ACCESS_KEY" "$RUSTFS_ROOT_SECRET_KEY"
rc ready local --timeout 2
rc mb "local/$RUSTFS_RESOURCE_BUCKET"
rc admin user add local "$RUSTFS_RESOURCE_ACCESS_KEY" "$RUSTFS_RESOURCE_SECRET_KEY"
rc admin policy create local "$RUSTFS_RESOURCE_POLICY" /tmp/policy.json
rc admin policy attach local "$RUSTFS_RESOURCE_POLICY" --user "$RUSTFS_RESOURCE_ACCESS_KEY"
```

以上是 hook 内部调用示意，使用者通常运行 `resource-init`。策略只授予目标 Bucket 的列举、读取、写入、删除及分片上传操作，不配置匿名访问或 CORS。
