# RustFS 部署 (Deploy)

## 1. 简介

> RustFS 是一款高性能、兼容 Amazon S3 的对象存储服务器，常用于存储业务文件、用户上传的头像、知识库等大型非结构化数据。

本目录用于独立部署 RustFS，提供 S3 API 和管理控制台。init 生成配置文件和 Compose YAML，数据保存在配置目录下的相对路径 bind mount 中；两个端口可选择是否发布到宿主机。LobeHub 默认自带 RustFS，由应用 Compose 管理，无需先运行本目录的 CLI。

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

## 3. 备注

- 本目录独立启动后默认没有 Bucket，手工对接时需通过控制台或管理工具准备 Bucket 和凭证。LobeHub 默认配套部署使用自己的 RustFS，由应用启动阶段的一次性初始化服务创建缺失 Bucket，不操作本目录的独立实例。
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

若配置文件不存在则用模板生成；随后读取配置、生成 `settings_rustfs.compose.yaml` 并创建数据目录，不启动容器。`--name` 指定完整实例名。

生成的 Compose YAML 通过环境变量引用配置值，访问密钥留在 settings 文件中。`--conf PATH` 的父目录须已存在，YAML 与数据保存在该目录；CLI 和模板仍位于脚本目录。`--internal` 在本次命令中关闭端口发布，长期关闭应设置 `RUSTFS_PUBLISH_PORTS=false`。

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

## 6. Bucket、凭证与复制恢复

默认 `rustfs/rustfs:latest` 是滚动标签，可在 settings 中指定具体版本或 digest。开启端口发布后，通过 `http://<服务器IP>:<RUSTFS_ADMIN_PORT>` 访问控制台，使用 settings 中的 Access Key / Secret Key 登录。

共享本目录的独立实例时，管理员为各应用准备独立 Bucket 和仅有该 Bucket 所需权限的凭证；共享账号、策略管理不由本 CLI 自动化。LobeHub 默认使用仅属于本应用实例的 RustFS 和初始化凭证，Bucket 由 `rustfs_init` 创建。其数据位于应用配置目录的 `data/<INSTANCE_NAME>_rustfs_data`，应用 `rm` 保留，`purge/reset` 删除。LobeHub 浏览器 CORS 配置暂留待处理，按实际使用反馈调整。

停止对象写入及 RustFS，或完成一致性备份后，复制包含 CLI、templates、settings、YAML 和完整数据目录的部署目录，保留对象、Bucket 和访问凭证。目标机器准备共享网络、兼容镜像和数据属主权限，再按原实例名启动。此处说明独立部署的恢复；LobeHub 配套 RustFS 随应用配置目录及其完整 data 一起迁移。

使用 `--internal` 时本次生成的 YAML 不发布 S3 API 和控制台端口；下次未传该参数的 `start/update` 会按 settings 中的 `RUSTFS_PUBLISH_PORTS` 重新生成 YAML。
