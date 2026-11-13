# LobeHub 部署 (Deploy)

## 1. 简介

> LobeHub 是 AI 对话与知识库应用。本目录使用 Docker Compose 部署 LobeHub 应用容器，并连接独立管理的 PostgreSQL、Redis 与 S3 兼容存储。

管理员先启动基础服务，创建应用专用数据库、账号、Bucket 和访问凭证，再填写 `settings_lobechat.conf`。应用保留内置邮箱密码登录；Composio 和 Casdoor 均为可选外部服务，未配置 SMTP 时不能通过邮件找回密码。

## 2. 核心配置项

### settings_lobechat.conf

- `INSTANCE_NAME`：Compose 项目名和容器名，须符合 `[a-z0-9][a-z0-9_-]*`，同机不同实例使用不同名称。
- `IMAGE`：默认 `lobehub/lobehub:latest`，为滚动标签；可填写具体版本标签或 digest。
- `LOBECHAT_PORT`：宿主机访问端口，映射容器内 `3210`。
- `DOCKER_NETWORK`：管理员预建的共享 Docker 网络；空值使用本项目私有网络。
- `DB_HOST` / `DB_PORT`：PostgreSQL 地址和端口，默认端口 `5432`。
- `DB_NAME` / `DB_USER` / `DB_PASSWORD`：预先创建的应用数据库、专用账号和密码，库名和账号默认 `lobechat`。
- `DB_SSLMODE`：PostgreSQL TLS 模式，默认 `disable`；远程连接按服务要求设置。
- `APP_URL`：浏览器访问应用的完整地址；反向代理场景使用代理后的 HTTPS 地址。
- `KEY_VAULTS_SECRET` / `AUTH_SECRET` / `JWKS_KEY`：应用加密与认证密钥，迁移和恢复时必须保留原值。
- `AUTH_ALLOWED_EMAILS`：注册邮箱或域名允许列表；将初始随机 `example.invalid` 占位邮箱替换为实际值。
- `REDIS_URL`：人工填写的 Redis URI，例如 `redis://redis_lobechat:6379/0`，TLS 使用 `rediss://`。
- `REDIS_DATABASE` / `REDIS_PREFIX`：Redis 数据库编号和键前缀；默认编号 `0`、前缀为实例名，备份恢复时保留对应值。URI 中的数据库编号应与 `REDIS_DATABASE` 一致。
- `S3_ENDPOINT` / `S3_BUCKET`：S3 API 地址与已创建的 Bucket；无默认 Bucket，脚本不会创建 Bucket。
- `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`：仅有本应用专属 Bucket 所需权限的访问凭证；共享 RustFS 时每个应用使用不同 Bucket 与凭证。
- `ENABLED_OPENAI` / `OPENAI_API_KEY` / `OPENAI_PROXY_URL` / `OPENAI_MODEL_LIST`：模型供应商设置；兼容服务填写其容器可访问的 `/v1` 地址和模型名。
- `COMPOSIO_API_KEY`：可选的 Composio API Key。
- `AUTH_SSO_PROVIDERS` / `AUTH_CASDOOR_ID` / `AUTH_CASDOOR_SECRET` / `AUTH_CASDOOR_ISSUER`：可选 Casdoor OIDC 配置；启用时将 `AUTH_SSO_PROVIDERS` 设为 `casdoor`。

### settings_lobechat.compose.yaml

`init`、`start`、`update` 从 `templates/compose.yaml.tpl` 刷新此文件。YAML 只保存变量引用；`cli.sh` 读取 Bash settings 后导出变量供 Compose 使用。持久修改容器定义应编辑模板，生成文件下次会被刷新。

## 3. 备注

- PostgreSQL 需符合所选 LobeHub 镜像的版本和扩展要求。ParadeDB 的 `pg_search` 预加载由数据库服务负责；数据库内所需扩展和权限由管理员提前准备，应用账号只管理自己的库和业务结构。
- `DB_PASSWORD` 填写原始密码，脚本会对数据库用户名、密码和库名做 URI 百分号编码后生成 `DATABASE_URL`。Bash settings 中的密钥宜用单引号；Redis URI 中的密码需按 URI 规则自行编码。
- Redis 数据库编号和键前缀用于数据区分，并不构成权限隔离。本仓库 Redis 服务当前没有认证；共享场景需另行配置认证/ACL，或为应用独立部署 Redis。
- S3 预签名链接可能由浏览器直接访问。`S3_ENDPOINT` 应使用应用容器和浏览器均可访问的稳定地址；共享网络中的容器名或私有 IP 通常不能被浏览器解析。生产环境可配置 S3 API 的 HTTPS 反向代理和所需 CORS，不能使用控制台端口替代 API。
- 容器内 `localhost` 指当前容器。数据库、Redis、模型服务和 S3 地址不能误填 `localhost`；模板里的 `INTERNAL_APP_URL=http://localhost:3210` 则明确指 LobeHub 自身。
- JWKS 优先通过宿主机 Node.js 生成；没有 Node.js 时，仅在首次生成配置时使用 LobeHub 镜像运行一次密钥生成程序。
- 本应用容器没有本地 bind mount。业务数据在 PostgreSQL、Redis 与 S3 中，`purge` 与 `rm` 均只移除应用项目。`reset` 额外删除本应用的 settings 和 YAML，因此仍需事先保存应用密钥。
- `start` 与 `update` 成功只表示 Compose 已启动容器。使用 `docker logs -f <INSTANCE_NAME>` 检查数据库迁移及就绪情况。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。`--conf` 父目录须已存在，生成 YAML 位于该目录，CLI 和模板仍从脚本目录读取。

## 4. 快速执行

先由管理员创建共享网络，并在需要连接的基础服务 settings 中配置相同的 `DOCKER_NETWORK` 后启动基础服务：

```bash
docker network create shared_services
cd deploy_apps/lobechat
bash cli.sh init
# Fill connections, APP_URL, AUTH_ALLOWED_EMAILS and model settings.
bash cli.sh start
```

同机连接示例，合并到生成的 settings，保留原有应用密钥：

```bash
DOCKER_NETWORK="shared_services"
DB_HOST="paradedb_shared"
DB_PORT="5432"
DB_NAME="lobechat"
DB_USER="lobechat"
DB_PASSWORD='管理员提供的原始密码'
DB_SSLMODE="disable"
REDIS_URL='redis://redis_lobechat:6379/0'
REDIS_DATABASE="0"
REDIS_PREFIX="lobechat_main"
S3_ENDPOINT="https://s3.example.com"
S3_BUCKET="lobechat"
S3_ACCESS_KEY_ID='应用专用访问密钥'
S3_SECRET_ACCESS_KEY='应用专用访问密码'
APP_URL="https://chat.example.com"
AUTH_ALLOWED_EMAILS="user@example.com"
```

`paradedb_shared`、`redis_lobechat` 是基础服务的明确实例容器名；使用容器端口 `5432`、`6379`。S3 示例通过固定域名接入同机反向代理，保证浏览器也能访问。

远程服务示例：

```bash
DOCKER_NETWORK=""
DB_HOST="db.example.com"
DB_PORT="5432"
DB_SSLMODE="require"
REDIS_URL='rediss://lobechat:percent-encoded-password@redis.example.com:6380/1'
REDIS_DATABASE="1"
S3_ENDPOINT="https://s3.example.com"
```

远程场景继续填写独立数据库、账号和 S3 凭证，端口使用远程实际开放端口。认证服务的 Issuer 和模型 API 地址同样须从容器可达。

```bash
# Use init + start when settings are ready.
bash cli.sh up

# Update this application's image.
bash cli.sh update

# Stop or remove the app while keeping settings.
bash cli.sh stop
bash cli.sh rm

# No local app data; external service data is preserved.
bash cli.sh purge

# DANGER: also delete this app's settings and keys.
bash cli.sh reset
```

## 5. 命令解释

以下 `compose` 指 `cli.sh` 内部包装函数，固定传入当前配置目录、项目名、生成的 YAML 和 `--env-file /dev/null`；日常操作使用 `bash cli.sh <命令>`。

#### init

只在缺失时生成应用 settings 和密钥，再刷新 Compose YAML。JWKS 优先用宿主机 Node.js 生成，否则运行一次性应用容器；不启动常驻服务，不创建业务数据库或 Bucket。

```bash
bash cli.sh init
```

#### start

校验连接字段，刷新 YAML 并启动应用；Compose 根据配置变化重新创建所需容器。

```bash
compose up -d
```

#### up

先生成缺失配置，再启动应用；外部连接字段为空时明确报错，需先人工配置。

```bash
bash cli.sh up
```

#### update

拉取当前 `IMAGE` 指定的镜像，再应用配置，保留 settings、密钥和外部数据。

```bash
compose pull
compose up -d
```

#### stop

只停止 LobeHub 应用容器。

```bash
compose stop
```

#### rm

移除应用项目的容器及私有网络，保留 settings；共享外部网络和基础服务不受影响。

```bash
compose down
```

#### purge

本应用没有本地 bind mount，因此仅执行 `rm`，保留 settings 和所有外部数据。

```bash
bash cli.sh purge
```

#### reset

先移除应用项目，再仅删除当前 `--conf` 指定的 settings 和对应 YAML；不匹配或删除任何其他配置文件。

```bash
bash cli.sh reset
```

#### network ls

只读展示 `DOCKER_NETWORK` 指定的共享网络，或本项目的私有网络。

```bash
bash cli.sh network ls
```

## 6. 升级、备份与复制恢复

镜像升级使用 `update`。镜像可能自动迁移数据库结构，因此升级前按镜像发布说明备份数据库，并记录对应镜像版本；镜像回退不等于数据库回滚。

应用没有本地数据挂载。复制应用目录时携带 CLI、templates、settings 和生成 YAML，保留 `KEY_VAULTS_SECRET`、`AUTH_SECRET`、`JWKS_KEY`、模型和认证配置。settings 中的密钥须与数据库备份对应，不能通过 `reset` 重新生成替代密钥。

停止写入或完成一致性备份后，PostgreSQL、Redis 和 S3 数据由各自基础服务目录分别备份和恢复。保持 Redis 编号、键前缀、S3 Bucket 与凭证对应；仅复制应用目录不会带走聊天记录和附件。

目标机器准备共享网络，填写可达的依赖地址、应用 URL 与认证回调地址后运行 `start`。S3 地址仍需对浏览器和应用容器同时可达。使用外置 `--conf` 时同时携带对应 CLI 和模板。

官方参考：[Docker 数据库版部署](https://lobehub.com/docs/self-hosting/platform/docker)、[模型供应商环境变量](https://lobehub.com/docs/self-hosting/environment-variables/model-provider)、[认证环境变量](https://lobehub.com/docs/self-hosting/environment-variables/auth)。
