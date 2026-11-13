# LobeHub 部署 (Deploy)

## 1. 简介

> LobeHub 是 AI 对话与知识库应用。本目录使用一个 Docker Compose 项目部署应用及配套 PostgreSQL、Redis、RustFS。

`init` 通过 ParadeDB、Redis、RustFS 的服务 CLI 准备依赖 settings 并组合 Compose 定义；填写应用地址、浏览器访问的 S3 地址及真实注册邮箱后，`start` 先启动依赖、调用 RustFS 初始化专属 Bucket 和凭证，再启动 LobeHub。默认使用本实例的配套依赖，外接依赖切换不属于当前流程。

## 2. 核心配置项

### settings_lobechat.conf

- `INSTANCE_NAME`：Compose 项目名及应用容器名，须符合 `[a-z0-9][a-z0-9_-]*`。配套容器使用 `_postgres`、`_redis`、`_rustfs` 后缀。
- `IMAGE`：应用镜像，默认 `lobehub/lobehub:latest`。
- `PARADEDB_CONF` / `REDIS_CONF` / `RUSTFS_CONF`：依赖 settings 路径，相对路径以应用配置文件目录为基准；默认分别为 `settings_paradedb.conf`、`settings_redis.conf`、`settings_rustfs.conf`。
- `LOBECHAT_PORT`：随机生成的应用宿主机端口，映射容器内 `3210`。
- `DOCKER_NETWORK`：默认留空，由 Compose 创建本实例私有网络；指定名称时接入已经存在的共享网络。
- PostgreSQL：ParadeDB 服务 settings 保存镜像、实例名、数据库账号和密码；应用调用其 `env` 生成内部 DSN，使用容器端口 `5432`，不发布宿主机端口。
- `APP_URL`：必填的浏览器访问地址，例如 HTTPS 反向代理后的应用地址；可由 `init/up --app-url URL` 注入，未提供时留空。
- `KEY_VAULTS_SECRET` / `AUTH_SECRET`：`init` 生成的应用密钥，后续初始化保留原值。
- `JWKS_KEY`：缺失时在 `start/update` 生成并保存，优先使用宿主机 Node.js，否则使用一次性应用容器；`init` 不启动容器。
- `AUTH_ALLOWED_EMAILS`：必填的真实注册邮箱或域名允许列表，可由 `init/up --auth-allowed-emails LIST` 注入；未提供时留空，不生成占位邮箱。
- `REDIS_DATABASE` / `REDIS_PREFIX`：默认逻辑库 `0`、实例名作为前缀；Redis CLI 生成连接 URL。配套 Redis 无密码、不发布宿主机端口。逻辑库和前缀用于区分数据，不提供账号权限隔离。
- RustFS：`RUSTFS_CONF` 指向服务 settings；服务生成的 S3 API 和控制台宿主机端口分别映射容器端口 `9000`、`9001`。
- `S3_ENDPOINT`：必填、浏览器与应用容器都可访问的 S3 API 地址，例如 `https://s3.example.com` 或服务器地址加 `RUSTFS_PORT`；可由 `init/up --s3-endpoint URL` 注入，未提供时留空。
- `S3_BUCKET`：`init` 按实例名的可读前缀和原始实例名的 SHA-256 哈希前 12 位稳定生成，支持长实例名并区分下划线与连字符；`start` 通过 RustFS `resource-init` 幂等创建。
- `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`：应用 settings 中保存的专用凭证，由 RustFS `resource-init` 创建；RustFS 管理员凭证只保存在 RustFS service settings，用于资源初始化。
- `ENABLED_OPENAI` / `OPENAI_API_KEY` / `OPENAI_PROXY_URL` / `OPENAI_MODEL_LIST`：模型供应商配置，API Key 由使用者提供。
- `COMPOSIO_API_KEY`：可选 Composio 凭证。
- `AUTH_SSO_PROVIDERS` / `AUTH_CASDOOR_ID` / `AUTH_CASDOOR_SECRET` / `AUTH_CASDOOR_ISSUER`：可选 Casdoor OIDC 配置，默认使用内置邮箱密码登录。

### 依赖 settings 与生成 Compose

`init` 分别调用 ParadeDB、Redis、RustFS 的 `init --config-only`，再通过各服务 `render/env` 生成应用总 Compose YAML。服务 settings 只由对应服务 CLI 管理，不会整体 source 到应用变量。生成 YAML 保存变量引用，持久调整 LobeHub 定义应修改 `templates/compose.yaml.tpl`。

初始化输入的优先级为已有非空配置、对应参数、默认值或留空。重复 `init` 不用新参数覆盖已经保存的地址、邮箱或凭证；需修改已有值时直接编辑 settings。

## 3. 备注

- PostgreSQL、Redis、RustFS 服务定义和基础连接信息来自 `deploy_services/`；配置实例与本应用实例按 `${INSTANCE_NAME}_postgres`、`${INSTANCE_NAME}_redis`、`${INSTANCE_NAME}_rustfs` 命名。
- 应用复用各服务的健康检查。启动顺序为先启动三个依赖，再调用 RustFS `resource-init`，最后启动 LobeHub。
- RustFS `resource-init` 使用 RustFS 管理凭证创建本应用专用 Bucket、访问策略和凭证；重复调用保持现有资源和凭证，不把管理员凭证写入 LobeHub 配置。
- CORS 待处理：当前不自动配置 Bucket CORS，浏览器上传是否需要额外规则由实际运行反馈决定。`S3_SET_ACL=0` 避免应用对 RustFS 对象设置 ACL。
- `start/update` 通过 RustFS CLI 的 `prepare-data --conf PATH --data-dir PATH` 准备组合项目实际挂载的数据目录；UID/GID 和属主处理由 RustFS 服务目录实现，执行脚本的账号需要相应权限。
- settings 是 Bash 配置；数据库 URI 由 ParadeDB 服务接口生成和编码。包含特殊字符的手工值按 Bash 规则引用。
- 只支持新的四份 settings 编排，不提供旧版单文件配置、凭证或数据的迁移分支。
- 重复 `init` 补齐空白默认字段并保留非空值、应用密钥及专用 S3 凭证。缺失 JWKS 仅在 `start/update` 由应用 hooks 生成并保存。
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

也可在初始化时保存这三个输入：

```bash
bash cli.sh init --name lobechat_main \
  --app-url https://chat.example.com \
  --s3-endpoint https://s3.example.com \
  --auth-allowed-emails user@example.com
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

生成缺失 app settings，通过三个服务 CLI 的 `init --config-only` 准备 ParadeDB、Redis、RustFS settings，再调用服务 `render/env` 组合 YAML 并创建 data 目录。保留非空应用配置、密钥和 S3 专用凭证；`--app-url`、`--s3-endpoint`、`--auth-allowed-emails` 只补齐对应空字段，未填写的必要输入在输出中提示。初始化只生成本地文件和目录，不启动容器。

#### start

检查必填字段和容器归属，由应用 hooks 生成缺失 JWKS，并调用 RustFS `prepare-data` 准备数据目录；先启动 PostgreSQL、Redis、RustFS，再调用 RustFS CLI 的 `resource-init` 创建本实例 Bucket、策略及专用凭证，最后启动 LobeHub。PostgreSQL 在空数据目录首次启动时创建数据库和账号，任一步失败立即返回错误。

#### up

依次执行 `init` 和 `start`，支持同样的三个初始化输入参数；首次配置的必填地址和邮箱须通过参数或 settings 提供。

#### update

拉取应用及全部配套镜像，按新 RustFS 镜像处理目录属主，再由 Compose 应用配置；保留 settings、应用密钥和全部数据。

#### stop

停止整套实例，保留容器、配置、私有网络及数据。

#### rm

移除整套实例容器及 Compose 私有网络，保留 settings、生成 YAML 和应用及三个依赖的数据目录。执行 `start` 可使用相同数据重建；显式接入的 external 网络不删除。

#### purge

危险操作：先执行 `rm`，再删除本实例的 `data/<INSTANCE_NAME>_data` 及各依赖实例对应的 PostgreSQL、Redis、RustFS data 目录，保留 settings 和密钥。

#### reset

危险操作：先执行 `purge`，再删除本实例 app settings、应用配置目录内引用的依赖 settings 及对应生成 YAML。`CONF_DIR` 外的依赖 settings 及其 YAML 保留；源码、模板及其他实例文件不删除。

#### network ls

只读展示当前私有网络或配置的 external 网络，不修改网络。

## 6. 升级、备份与复制恢复

整套持久化数据都位于配置文件目录下：LobeHub 为 `data/<INSTANCE_NAME>_data`，PostgreSQL、Redis、RustFS 使用各自 service settings 中的实例名创建对应 data 目录。应用自身和三项依赖均由同一 Compose 项目管理。

重启或 `docker rm` 不删除这些 bind mount 数据；保留 settings 和密钥后重新执行 `start` 即可重建容器。`purge/reset` 才主动删除配套数据，不能用于恢复或升级。

停止整套服务或完成一致性备份后，携带 CLI、hooks、templates、应用 settings、三份服务 settings、生成 YAML 和全部数据目录迁移，使用原实例名及相同 PostgreSQL 主版本。运行中的数据库目录不能直接复制作为一致性备份。使用外置 `--conf` 时，同时保留 CLI、hooks 和 templates。

升级前保留数据库与应用密钥的对应备份。镜像可能执行结构迁移，镜像回退不等于数据库回滚；在应用和各服务 settings 的 `IMAGE` 中固定版本或 digest，RustFS 客户端使用 `RUSTFS_INIT_IMAGE`。

关键部署约定：容器端口分别为应用 `3210`、PostgreSQL `5432`、Redis `6379`、S3 `9000` 和控制台 `9001`。S3 公共地址必须能被浏览器和应用容器访问，控制台地址不能代替 S3 API；`S3_SET_ACL=0`、路径式访问和暂不自动配置 CORS 的行为保留。RustFS 的客户端命令、权限及重试依据见 [RustFS 部署文档](../deploy_services/rustfs.md#7-已核对的部署依据)，后续直接复用服务接口。

官方参考：[Docker 部署](https://lobehub.com/docs/self-hosting/platform/docker)、[模型供应商环境变量](https://lobehub.com/docs/self-hosting/environment-variables/model-provider)、[认证环境变量](https://lobehub.com/docs/self-hosting/environment-variables/auth)。
