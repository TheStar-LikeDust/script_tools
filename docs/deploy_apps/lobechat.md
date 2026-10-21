# LobeHub 部署 (Deploy)

## 1. 简介

> LobeHub 是 AI 对话与知识库应用。本方案部署官方 LobeHub 镜像，并在专属 Docker 网络中管理 ParadeDB（PostgreSQL 17）和 RustFS。

使用 LobeHub 内置邮箱密码认证，并自动部署 RustFS 提供 S3 兼容存储。无需手动填写 S3 地址、访问密钥或创建 Bucket；未配置 SMTP 时不能通过邮件找回密码。Composio 和 Casdoor 都是可选的外部服务。

## 2. 核心配置项

### settings_lobechat.conf

- `INSTANCE_NAME`：LobeHub 容器名。
- `LOBECHAT_PORT`：宿主机访问端口。
- `IMAGE`：LobeHub 镜像，默认 `lobehub/lobehub:latest`。
- `APP_URL`：浏览器访问应用时使用的完整地址；反向代理场景填写代理后的 HTTPS 地址。
- `KEY_VAULTS_SECRET`、`AUTH_SECRET`、`JWKS_KEY`：应用加密与认证密钥；备份时需与数据库一并保留。
- `AUTH_ALLOWED_EMAILS`：邮箱或域名注册允许列表；`init` 默认写入一个随机的 `example.invalid` 占位邮箱，启动前需替换为实际邮箱或域名。
- `COMPOSIO_API_KEY`：可选的 Composio 服务端 API Key；不使用 Composio 时留空。
- `AUTH_SSO_PROVIDERS`：可选的 SSO 提供商列表；留空时仅使用邮箱密码登录，启用 Casdoor 时填写 `casdoor`。
- `AUTH_CASDOOR_ID`、`AUTH_CASDOOR_SECRET`、`AUTH_CASDOOR_ISSUER`：Casdoor OIDC 客户端 ID、密钥和 Issuer；仅在启用 Casdoor 时填写。
- `S3_BUCKET`：RustFS 中供 LobeHub 使用的 Bucket，默认 `lobechat`；启动时自动创建。
- `S3_ENDPOINT`、`S3_ACCESS_KEY_ID`、`S3_SECRET_ACCESS_KEY`：由启动脚本从 RustFS 配置生成并传入容器，无需手动设置。

### settings_paradedb.conf

- `INSTANCE_NAME`：PostgreSQL 容器名。
- `DB_USER`、`DB_PASSWORD`、`DB_NAME`：数据库连接凭据。
- `DB_PUBLISH_PORT`：新实例默认设为 `false`，数据库只通过专属 Docker 网络访问。
- `DB_PORT`：宿主机数据库端口；仅在启用端口发布时使用。

数据库数据保存在配置文件目录下的 `data/<数据库容器名>_data/`。

RustFS 配置保存在同目录的 `settings_rustfs.conf`，其中包含生成的访问密钥；对象数据保存在对应的 `data/<RustFS容器名>_data/`。旧版 `settings_<LobeHub实例名>_rustfs.conf` 会在首次生命周期操作时迁移为固定文件名，保留原有凭据、容器名和数据目录。

## 3. 备注

- 官方数据库部署示例使用 ParadeDB PostgreSQL 17 镜像，并在 PostgreSQL 启动时启用 `pg_search`。本脚本以容器名生成 `DATABASE_URL`，不向宿主机发布数据库端口。
- `init` 会生成应用密钥、ParadeDB 配置和 RustFS 配置。宿主机需有 Node.js 以生成 JWKS；没有 Node.js 时，脚本使用 LobeHub 镜像临时生成密钥。
- ParadeDB 与 RustFS 配置含访问凭据，脚本将其权限设为仅当前用户读写。备份时同时保留应用配置、数据库配置、RustFS 配置及二者的数据目录。
- `init` 会生成随机的 `example.invalid` 白名单邮箱；邮箱密码登录仍然开启，但在你把它改成实际邮箱前不会允许真实账户注册。
- `start` 自动启动私有 RustFS，按镜像内置用户修正数据目录所有权，并通过一次性 AWS CLI 容器创建或复用 Bucket；RustFS API 和管理端口不会发布到宿主机。
- 若已有 LobeHub 容器的 S3、Composio 或认证环境变量与配置不符，`start` 会重建应用容器，数据库和 RustFS 数据不受影响。
- `rm` 删除容器但保留数据库和 RustFS 数据；`purge` 会永久删除数据库及 RustFS 对象数据；`reset` 还会删除生成的应用、数据库和 RustFS 配置。
- 旧全栈配置中的 `USE_INTERNAL_*` / `EXTERNAL_*` 不兼容当前配置。切换方案会创建新数据库，不会迁移旧账户和聊天记录，也不会停止或删除旧 Casdoor、Redis、RustFS 容器及数据。

## 4. 快速执行

```bash
cd deploy_apps/lobechat
bash cli.sh init
# 修改 settings_lobechat.conf 中的 APP_URL
# 将 AUTH_ALLOWED_EMAILS 的 example.invalid 占位邮箱改成实际邮箱或域名
# 按需填写 COMPOSIO_API_KEY 或 Casdoor 的 AUTH_* 配置
bash cli.sh start
```

`up` 等价于依次执行 `init` 和 `start`，适合已确认配置的实例。应用启动后可通过 `docker logs -f <INSTANCE_NAME>` 查看数据库迁移和服务就绪日志。

## 5. 命令解释

#### init

生成应用密钥、ParadeDB 配置和 RustFS 配置，不启动容器。

```bash
[ ! -f "$CONF_FILE" ] && generate_settings
load_conf
hook on_init
ensure_rustfs_conf
```

#### start

先启动 ParadeDB 和 RustFS 并接入专属网络，等待健康检查后自动创建 Bucket，再创建或启动 LobeHub。

```bash
net_ensure "$net"
deploy_paradedb start
net_connect "$net" "$db_name"
wait_healthy "database" "$db_name"

ensure_rustfs_conf
rustfs_conf="$(rustfs_conf_path)"
rustfs_name="$(conf_val "$rustfs_conf" INSTANCE_NAME)"
deploy_rustfs start --internal
net_connect "$net" "$rustfs_name"
wait_healthy "RustFS" "$rustfs_name"
access_key="$(conf_val "$rustfs_conf" RUSTFS_ACCESS_KEY)"
secret_key="$(conf_val "$rustfs_conf" RUSTFS_SECRET_KEY)"
rustfs_ip="$(docker inspect --format "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$rustfs_name")"
S3_ENDPOINT="http://${rustfs_ip}:9000"
S3_BUCKET="${S3_BUCKET:-lobechat}"
S3_ACCESS_KEY_ID="$access_key"
S3_SECRET_ACCESS_KEY="$secret_key"
ensure_s3_bucket "$net" "$S3_ENDPOINT" "$S3_BUCKET" "$access_key" "$secret_key"
HOOK_RUN_ARGS=(--network "$net")

db_url="postgres://$(conf_val "$PG_CONF" DB_USER):$(conf_val "$PG_CONF" DB_PASSWORD)@$(conf_val "$PG_CONF" INSTANCE_NAME):5432/$(conf_val "$PG_CONF" DB_NAME)"

docker run -d \
    --name "$INSTANCE_NAME" \
    "${HOOK_RUN_ARGS[@]}" \
    -p "${LOBECHAT_PORT}:3210" \
    -e "DATABASE_URL=${db_url}" \
    -e "APP_URL=${APP_URL}" \
    -e "INTERNAL_APP_URL=http://localhost:3210" \
    -e "KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET}" \
    -e "AUTH_SECRET=${AUTH_SECRET}" \
    -e "JWKS_KEY=${JWKS_KEY}" \
    -e "AUTH_SSO_PROVIDERS=${AUTH_SSO_PROVIDERS:-}" \
    -e "AUTH_CASDOOR_ID=${AUTH_CASDOOR_ID:-}" \
    -e "AUTH_CASDOOR_SECRET=${AUTH_CASDOOR_SECRET:-}" \
    -e "AUTH_CASDOOR_ISSUER=${AUTH_CASDOOR_ISSUER:-}" \
    -e "AUTH_DISABLE_EMAIL_PASSWORD=0" \
    -e "AUTH_EMAIL_VERIFICATION=0" \
    -e "AUTH_ALLOWED_EMAILS=${AUTH_ALLOWED_EMAILS:-}" \
    -e "COMPOSIO_API_KEY=${COMPOSIO_API_KEY:-}" \
    -e "S3_ENDPOINT=${S3_ENDPOINT}" \
    -e "S3_BUCKET=${S3_BUCKET}" \
    -e "S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}" \
    -e "S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}" \
    -e "S3_ENABLE_PATH_STYLE=1" \
    --restart unless-stopped \
    "$IMAGE"
```

#### up

初始化配置后启动应用、数据库和 RustFS。

```bash
do_init
do_start
```

#### stop

停止 LobeHub、ParadeDB 和 RustFS 容器，保留配置与数据。

```bash
docker stop "$INSTANCE_NAME" 2>/dev/null || true
deploy_paradedb stop
deploy_rustfs stop
```

#### rm

删除应用、数据库和 RustFS 容器及专属网络，保留配置与数据。

```bash
docker stop "$INSTANCE_NAME" 2>/dev/null || true
docker rm "$INSTANCE_NAME" 2>/dev/null || true
deploy_paradedb rm
deploy_rustfs rm
net_rm "${INSTANCE_NAME}_net"
```

#### purge

危险操作：删除应用、数据库和 RustFS 容器及其数据，保留配置文件。

```bash
docker stop "$INSTANCE_NAME" 2>/dev/null || true
docker rm "$INSTANCE_NAME" 2>/dev/null || true
data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
if [ -d "$data_dir" ]; then
    docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
fi
deploy_paradedb purge
deploy_rustfs purge
net_rm "${INSTANCE_NAME}_net"
```

#### reset

危险操作：先执行 `purge`，再删除应用、ParadeDB 和 RustFS 配置文件。

```bash
do_purge
rm -f "$CONF_FILE" "$PG_CONF" "$(rustfs_conf_path)"
```

## 6. 升级与旧实例迁移

更新应用环境变量或镜像前，先备份数据库。按需拉取新镜像，然后删除应用容器并重新执行 `start`；不要用 `purge` 或 `reset` 作为升级命令。

```bash
source settings_lobechat.conf
docker pull "$IMAGE"
docker stop "$INSTANCE_NAME"
docker rm "$INSTANCE_NAME"
bash cli.sh start
```

旧版全栈实例应先使用独立的 `--conf` 路径试运行。新实例拥有独立数据库，账户与聊天记录不会自动迁移。

```bash
mkdir -p minimal
bash cli.sh init --conf "$PWD/minimal/settings_lobechat.conf" --name lobechat_minimal
bash cli.sh start --conf "$PWD/minimal/settings_lobechat.conf"
```

使用 `bash cli.sh network` 可查看应用专属网络及已连接容器。

官方参考：[Docker 数据库版部署](https://lobehub.com/docs/self-hosting/platform/docker)、[认证环境变量](https://lobehub.com/docs/self-hosting/environment-variables/auth)。
