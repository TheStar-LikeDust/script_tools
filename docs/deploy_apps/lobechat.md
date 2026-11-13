# LobeHub 部署 (Deploy)

## 1. 简介

> LobeHub 是 AI 对话与知识库应用。本目录使用一个 Docker Compose 项目部署应用及配套 PostgreSQL、Redis、RustFS。

`init` 生成整套配置、凭证和数据目录；填写应用地址、浏览器访问的 S3 地址及真实注册邮箱后，`start` 启动整套实例。数据库由 PostgreSQL 首次启动创建，Bucket 由一次性初始化容器创建。默认配套部署暂未提供外接依赖切换开关。

## 2. 核心配置项

### settings_lobechat.conf

- `INSTANCE_NAME`：Compose 项目名及应用容器名，须符合 `[a-z0-9][a-z0-9_-]*`。配套容器使用 `_postgres`、`_redis`、`_rustfs`、`_rustfs_init` 后缀。
- `IMAGE`：应用镜像，默认 `lobehub/lobehub:latest`。
- `POSTGRES_IMAGE` / `REDIS_IMAGE`：默认 `paradedb/paradedb:latest-pg17` 和 `redis:7-alpine`。
- `RUSTFS_IMAGE` / `RUSTFS_INIT_IMAGE`：默认 `rustfs/rustfs:latest` 和 `rustfs/rc:latest`，后者只负责创建 Bucket。
- `LOBECHAT_PORT`：随机生成的应用宿主机端口，映射容器内 `3210`。
- `DOCKER_NETWORK`：默认留空，由 Compose 创建本实例私有网络；指定名称时接入已经存在的共享网络。
- `DB_HOST` / `DB_PORT`：默认 `<INSTANCE_NAME>_postgres:5432`，PostgreSQL 不发布宿主机端口。
- `DB_NAME` / `DB_USER` / `DB_PASSWORD`：配套 PostgreSQL 首次启动使用的数据库、初始化账号和密码。库名及账号默认 `lobechat`，密码由 `init` 生成并保存。
- `DB_SSLMODE`：配套 PostgreSQL 默认 `disable`。
- `APP_URL`：必填的浏览器访问地址，例如 HTTPS 反向代理后的应用地址；初始留空。
- `KEY_VAULTS_SECRET` / `AUTH_SECRET`：`init` 生成的应用密钥，后续初始化保留原值。
- `JWKS_KEY`：缺失时在 `start/update` 生成并保存，优先使用宿主机 Node.js，否则使用一次性应用容器；`init` 不启动容器。
- `AUTH_ALLOWED_EMAILS`：必填的真实注册邮箱或域名允许列表，初始留空，不生成占位邮箱。
- `REDIS_URL`：默认 `redis://<INSTANCE_NAME>_redis:6379/0`，配套 Redis 无密码且不发布宿主机端口。
- `REDIS_DATABASE` / `REDIS_PREFIX`：默认逻辑库 `0`、实例名作为前缀。URI 中的库编号应与 `REDIS_DATABASE` 一致。
- `RUSTFS_PORT` / `RUSTFS_ADMIN_PORT`：随机生成的 S3 API 和控制台宿主机端口，分别映射 `9000`、`9001`，与应用端口互不重复。
- `S3_ENDPOINT`：必填的浏览器可访问 S3 API 地址，例如 `https://s3.example.com` 或服务器地址加 `RUSTFS_PORT`；初始留空。
- `S3_INTERNAL_ENDPOINT`：默认 `http://<INSTANCE_NAME>_rustfs:9000`，供应用容器及 Bucket 初始化容器访问 RustFS。
- `S3_BUCKET`：默认 `lobechat`，启动时自动创建；每个应用实例拥有自己的 RustFS，Bucket 名可以相同。
- `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`：`init` 生成并保存，同时作为本实例 RustFS 的管理凭证和应用 S3 凭证。
- `ENABLED_OPENAI` / `OPENAI_API_KEY` / `OPENAI_PROXY_URL` / `OPENAI_MODEL_LIST`：模型供应商配置，API Key 由使用者提供。
- `COMPOSIO_API_KEY`：可选 Composio 凭证。
- `AUTH_SSO_PROVIDERS` / `AUTH_CASDOOR_ID` / `AUTH_CASDOOR_SECRET` / `AUTH_CASDOOR_ISSUER`：可选 Casdoor OIDC 配置，默认使用内置邮箱密码登录。

### settings_lobechat.compose.yaml

由 `init/start/update` 从模板生成。YAML 保存变量引用，CLI 读取 Bash settings 后导出变量供 Compose 使用。持久调整容器定义应修改 `templates/compose.yaml.tpl`。

## 3. 备注

- 配套 ParadeDB 保留镜像默认预加载配置，不将其覆盖为仅 `pg_search`；当前官方 PostgreSQL 17 镜像包含 pgvector。数据库镜像负责首次初始化，应用负责业务迁移。
- PostgreSQL 健康检查使用 TCP，避免把仅监听本地 socket 的首次初始化临时进程当作已经就绪。应用等待 PostgreSQL、Redis 就绪和 Bucket 初始化成功后启动。
- `rustfs_init` 使用 `rc alias set` 和 `rc mb --ignore-existing` 创建 Bucket，重复执行保留现有对象，不设置匿名访问策略。
- CORS 待处理：当前不自动配置 Bucket CORS，浏览器上传是否需要额外规则由实际运行反馈决定。`S3_SET_ACL=0` 避免应用对 RustFS 对象设置 ACL。
- `start/update` 从 RustFS 镜像读取运行用户 UID/GID，必要时调整本实例 RustFS 数据目录属主，执行脚本的账号需要相应权限。
- settings 是 Bash 配置；密码填写原值，数据库用户名、密码、库名由 CLI 做 URI 编码。包含特殊字符的手工值按 Bash 规则引用。
- 重复 `init` 补齐空白默认字段并保留非空值。旧配置中的 `localhost` 应用地址、`example.invalid` 邮箱不会被覆盖，应在启动前改为实际值；旧配置不会自动迁移外部数据。
- 未配置 SMTP 时，内置邮箱密码登录不能通过邮件找回密码。模型 API Key、OAuth 等外部凭证仍由使用者填写。
- `start/update` 返回后仍需根据应用日志判断业务就绪情况。

## 4. 快速执行

```bash
cd deploy_apps/lobechat
bash cli.sh init --name lobechat_main
# Fill APP_URL, S3_ENDPOINT and AUTH_ALLOWED_EMAILS in settings_lobechat.conf.
# Add model-provider credentials when needed.
bash cli.sh start
```

只需人工补充的基本内容示例：

```bash
APP_URL="https://chat.example.com"
S3_ENDPOINT="https://s3.example.com"
AUTH_ALLOWED_EMAILS="user@example.com"
```

S3 反向代理应转发到生成的 `RUSTFS_PORT`，不是控制台端口。没有反向代理时，应用地址使用服务器地址和 `LOBECHAT_PORT`，S3 地址使用服务器地址和 `RUSTFS_PORT`。容器内部 S3 地址已经自动生成。

多实例使用各自的配置文件和不同实例名，`--conf` 的父目录须预先存在：

```bash
bash cli.sh init --conf /srv/lobechat_b/settings_lobechat.conf --name lobechat_b
# Fill the required browser-facing settings in this file.
bash cli.sh start --conf /srv/lobechat_b/settings_lobechat.conf
```

## 5. 命令解释

以下命令均管理当前 `--conf` 对应的整套 Compose 项目，包含应用及配套 PostgreSQL、Redis、RustFS。

#### init

生成缺失 settings，补齐配套默认连接及凭证，刷新 YAML 并创建三个数据目录。保留非空配置和已有密钥，提示必须由使用者填写的地址和邮箱；不访问 Docker 或启动任何容器。

#### start

检查必填字段和容器归属，生成缺失 JWKS，准备数据目录与 RustFS 属主，然后执行 `docker compose up -d`。配套 PostgreSQL 在空数据目录首次启动时创建数据库和账号，RustFS 就绪后由一次性容器创建 Bucket。

#### up

依次执行 `init` 和 `start`。首次配置的三个必填外部输入仍需先填写。

#### update

拉取应用及全部配套镜像，按新 RustFS 镜像处理目录属主，再由 Compose 应用配置；保留 settings、应用密钥和全部数据。

#### stop

停止整套实例，保留容器、配置、私有网络及数据。

#### rm

移除整套实例容器及 Compose 私有网络，保留 settings、生成 YAML 和三个持久化目录。执行 `start` 可使用相同数据重建；显式接入的 external 网络不删除。

#### purge

危险操作：先执行 `rm`，再删除本实例的 `data/<INSTANCE_NAME>_postgres_data`、`data/<INSTANCE_NAME>_redis_data`、`data/<INSTANCE_NAME>_rustfs_data`，保留 settings 和密钥。

#### reset

危险操作：先执行 `purge`，再删除本实例 settings 和生成 YAML，完整清理本实例。源码、模板及其他实例的文件保留。

#### network ls

只读展示当前私有网络或配置的 external 网络，不修改网络。

## 6. 升级、备份与复制恢复

整套持久化数据都位于配置文件目录下：PostgreSQL 为 `data/<INSTANCE_NAME>_postgres_data`，Redis 为 `data/<INSTANCE_NAME>_redis_data`，RustFS 为 `data/<INSTANCE_NAME>_rustfs_data`。应用自身没有额外本地数据挂载。

重启或 `docker rm` 不删除这些 bind mount 数据；保留 settings 和密钥后重新执行 `start` 即可重建容器。`purge/reset` 才主动删除配套数据，不能用于恢复或升级。

停止整套服务或完成一致性备份后，携带 CLI、templates、settings、YAML 和三个数据目录迁移，使用原实例名及相同 PostgreSQL 主版本。运行中的数据库目录不能直接复制作为一致性备份。使用外置 `--conf` 时，同时保留 CLI 和 templates。

升级前保留数据库与应用密钥的对应备份。镜像可能执行结构迁移，镜像回退不等于数据库回滚；可在各 `*_IMAGE` 字段中使用固定版本或 digest。

官方参考：[Docker 部署](https://lobehub.com/docs/self-hosting/platform/docker)、[模型供应商环境变量](https://lobehub.com/docs/self-hosting/environment-variables/model-provider)、[认证环境变量](https://lobehub.com/docs/self-hosting/environment-variables/auth)。
