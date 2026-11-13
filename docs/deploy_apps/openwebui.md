# Open WebUI 部署 (Deploy)

## 1. 简介

> Open WebUI 是支持多种大语言模型、对话和知识库的 Web 面板。

Compose 项目只部署 Open WebUI。默认保留本地 SQLite，可选连接独立部署的 PostgreSQL、Redis 或 S3 兼容对象存储。所有外部依赖由管理员管理。

## 2. 核心配置项

### settings_openwebui.conf

- `INSTANCE_NAME`：项目名、容器名和本地数据目录名；使用小写字母、数字、下划线和连字符，首位为字母或数字。
- `IMAGE`：默认 `ghcr.io/open-webui/open-webui:main`，为滚动标签；可用具体版本或 digest 固定部署。
- `OPENWEBUI_PORT` / `OPENWEBUI_PUBLISH_PORT`：宿主机端口与发布开关；容器端口为 `8080`。
- `DOCKER_NETWORK`：管理员预建的共享网络名；留空使用 Compose 私有网络。
- `WEBUI_SECRET_KEY`：初始化时生成的应用密钥，备份和恢复必须保留原值。
- `DB_HOST`：留空使用本地 SQLite；设置后启用外部 PostgreSQL。
- `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_SSLMODE`：外部数据库连接；端口默认 `5432`，TLS 模式默认 `disable`。数据库和独立账号由管理员提前创建。
- `REDIS_URL`：可选 Redis URI；URI 内密码需 URL 编码。
- `STORAGE_PROVIDER`：默认 `local`，设为 `s3` 时使用管理员准备的 bucket。
- `S3_ENDPOINT_URL` / `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` / `S3_BUCKET_NAME` / `S3_REGION_NAME`：S3 地址、专用凭证、bucket 和区域。
- `OLLAMA_BASE_URL`：默认 `http://host.docker.internal:11434`，访问宿主机 Ollama。
- `OPENAI_API_BASE_URL` / `OPENAI_API_KEY`：模型接口与密钥；复数 `OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS` 支持多源。
- `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` / `WEBUI_ADMIN_NAME`：随机生成的初始管理员，仅全新数据库生效。
- `HF_TOKEN` / `CORS_ALLOW_ORIGIN` / `USER_AGENT`：下载凭证、跨域来源和搜索 UA。
- `ENABLE_PERSISTENT_CONFIG`：默认 `True`，保留管理面板内的设置；详见第 7 节。

## 3. 备注

- 数据挂载保持 `./data/<实例名>_data:/app/backend/data`；SQLite 文件仍是其中的 `webui.db`。从 SQLite 改成 PostgreSQL 不会自动复制账户、聊天记录或上传文件，需单独按应用支持的流程迁移并核对。
- 应用命令不启停、创建或清理 PostgreSQL、Redis、S3，也不创建 bucket。`purge` 只删本地应用数据；使用外部数据库时，业务记录仍在外部库内。
- 修改 settings 后运行 `start`，Compose 会更新容器配置；应用已存入数据库的 ConfigVar 设置仍遵循应用自身的持久化规则。
- 密码在 Bash settings 中使用单引号。分字段 `DB_*` 填原值，脚本对用户名、密码、库名进行 URL 编码。密钥不会写入生成的 YAML。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。`--conf` 父目录须已存在，生成 YAML 和本地数据位于该目录，CLI 和模板仍从脚本目录读取。

## 4. 快速执行

```bash
cd deploy_apps/openwebui
bash cli.sh init
# Review settings_openwebui.conf and keep DB_HOST empty for SQLite.
bash cli.sh start
bash cli.sh update
```

可选同机 PostgreSQL 示例：管理员预先创建 `shared_services` 网络、应用专属数据库和账号，让数据库与应用都接入同一网络。

```bash
DOCKER_NETWORK="shared_services"
DB_HOST="pg-shared"
DB_PORT="5432"
DB_NAME="openwebui"
DB_USER="openwebui"
DB_PASSWORD='replace-with-dedicated-password'
```

容器之间使用实际基础服务容器名与内部端口。远程数据库改用容器可访问的地址：

```bash
DOCKER_NETWORK=""
DB_HOST="db.example.internal"
DB_PORT="5432"
DB_SSLMODE="require"
```

容器内 `localhost` 指 Open WebUI 自身；宿主机 Ollama 使用 `host.docker.internal:host-gateway` 映射，并须监听容器能访问的宿主机地址，不能仅监听宿主机回环地址。Redis 可用独立实例或管理员配置的认证/隔离方案；仓库无认证 Redis 模板不适合直接供多个应用共享。S3 bucket 与专用凭证需提前准备。

## 5. 命令解释

以下 `compose` 指 `cli.sh` 内的包装函数：先读取 settings，再使用 `--env-file /dev/null --project-directory "$CONF_DIR" --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE"` 调用 Docker Compose。这些代码展示实现，不是独立可执行的终端命令。

#### init

仅在 settings 缺失时生成配置与随机密钥，再生成 `openwebui.compose.yaml` 和本应用数据目录；允许先留空外部连接信息。

```bash
if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
load_settings
generate_compose
mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### start

检查配置及同名容器归属，刷新 YAML 后应用配置。使用 SQLite 不要求外部数据库；配置了外部服务时，相关服务须已可用。

```bash
compose up -d
```

#### up

依次执行 `init`、`start`；默认 SQLite 可直接使用。选择外部数据库或 S3 时须先补齐连接项。

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

危险操作：先执行 `rm`，再删除本应用的 `data/${INSTANCE_NAME}_data`，其中默认包含 SQLite、上传文件和本地索引。settings 及外部 PostgreSQL、Redis、S3 数据保留。

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

停止应用后复制完整目录，或完成 SQLite 与上传文件的一致性备份。保存 CLI、templates、settings、生成 YAML、原 `WEBUI_SECRET_KEY`、管理员配置及整个 `data/<INSTANCE_NAME>_data`，其中包含 SQLite、上传文件和本地索引。

恢复 SQLite 部署时保持 `DB_HOST` 为空，使用兼容镜像并保持实例名与数据目录名对应后运行 `start`。设置外部 PostgreSQL 地址不会自动转换 SQLite 数据；切换数据库类型须按应用支持的方式搬迁数据。

外部数据库、Redis、对象存储或向量库单独备份和恢复，应用目录复制不包含这些外部数据。目标机器准备配置中指定的共享网络；使用外置 `--conf` 时同时携带对应 CLI 和模板。

## 7. 关键环境变量参考

容器只接收 `templates/compose.yaml.tpl` 的 `environment` 显式列出的变量。DB、Redis、S3 和 `ENABLE_PERSISTENT_CONFIG` 已接入；其他高级变量需同时在 settings 中赋值、在 Compose 模板中增加引用，再运行 `start`。下文为常用变量说明，不表示所有参数已透传。

### 7.1 ConfigVar 持久化机制

支持持久化的配置（如模型连接设置）通常优先读取数据库内已有值，未保存时才使用环境变量。修改这类设置应使用管理面板，或设置 `ENABLE_PERSISTENT_CONFIG=False` 后重新启动；具体变量是否持久化以所用镜像版本为准。管理员初始化变量只在全新数据库生效，不能用它们修改已存在账号。

- `ENABLE_PERSISTENT_CONFIG`：本模板默认 `True`。设为 `False` 时，支持该机制的配置在启动时采用环境变量值。
- `ENABLE_DB_MIGRATIONS`：用于控制应用数据库结构迁移，未接入本模板。只有明确所用镜像的迁移流程时再扩展该变量。

### 7.2 自动创建管理员

模板为全新数据库生成管理员邮箱、密码和显示名，由应用首次启动时初始化账号；已有数据库不通过这些变量重置管理员。账号创建后的注册策略由应用管理面板配置。

- `WEBUI_ADMIN_EMAIL`：管理员邮箱。
- `WEBUI_ADMIN_PASSWORD`：管理员密码，按与手动注册相同的机制哈希后存储。
- `WEBUI_ADMIN_NAME`：管理员显示名，`init` 时随机生成（4 位小写字母，与邮箱本地名同串）。

### 7.3 外部数据库与状态存储

本部署默认单应用容器和本地 SQLite。外部 PostgreSQL 可通过 `DB_*` 接入；向量库和多副本架构需要按所用应用版本另行配置。

- `DATABASE_URL`：由 CLI 从 `DB_*` 构造并注入的 SQLAlchemy 连接串；`DB_HOST` 留空时使用本地 SQLite。不要在 settings 中单独设置 `DATABASE_URL`，它会由 CLI 重新计算。
- `VECTOR_DB`：向量库类型，默认 `chroma`，多副本场景建议 `pgvector`。
- `PGVECTOR_DB_URL`：启用 pgvector 时的连接串；与 `VECTOR_DB` 均未接入本模板，需扩展模板并准备所需扩展。
- `REDIS_URL`：可选外部 Redis 地址，示例 `redis://:password@host:6379/0`；填写地址不等于已经完成多 worker 或多节点的全部状态共享配置。

### 7.4 对象存储 (S3 / RustFS / MinIO)

将上传文件外置到对象存储，对应本项目的 `deploy_services/rustfs`。

- `STORAGE_PROVIDER`：留空为 `local`，置为 `s3` 启用 S3 兼容存储。
- `S3_ENDPOINT_URL`：S3 兼容端点地址。
- `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`：访问凭证。
- `S3_BUCKET_NAME`：存储桶名称。
- `S3_REGION_NAME`：区域名称，本模板默认 `us-east-1`，按目标服务要求填写。
- 私有 CA 可通过 `AWS_CA_BUNDLE` 指定证书；需要关闭对象标签时可扩展 `S3_ENABLE_TAGGING`。这些变量未接入本模板，证书文件也需显式挂载。

## 8. 对接代理转发的 OpenAI 或第三方大模型源

任何提供 OpenAI 兼容接口的上游（自建代理、LiteLLM、one-api/new-api、或其他大模型服务）均通过 `OPENAI_API_BASE_URL` 系列变量对接，Open WebUI 将其统称为 "OpenAI API Connections"。

- `ENABLE_OPENAI_API`：控制 OpenAI 兼容接口，未接入本模板；需要环境变量控制时须扩展模板，也可使用管理面板。

### 方式一：覆盖/单一源

如果只需要一个源（或者只用聚合网关），使用单数变量：

- `OPENAI_API_BASE_URL`：上游兼容端点，需带 `/v1` 后缀。
- `OPENAI_API_KEY`：上游鉴权密钥。

### 方式二：多个源（复数变量）

复数变量用分号 `;` 分隔地址和密钥，顺序必须一一对应。需要保留官方 OpenAI 时，将它也明确写入列表：

- `OPENAI_API_BASE_URLS`：示例 `https://api.openai.com/v1;https://api.b.ai/v1`
- `OPENAI_API_KEYS`：示例 `sk-official-xxx;sk-proxy-xxx`

以下两种模型连接配置择一使用，填入 `settings_openwebui.conf` 的对应字段：

```bash
# Single endpoint.
OPENAI_API_BASE_URL="https://your-proxy.example.com/v1"
OPENAI_API_KEY="sk-xxxxxxxx"

# Multiple endpoints and corresponding keys.
OPENAI_API_BASE_URLS="https://api.openai.com/v1;https://api.b.ai/v1"
OPENAI_API_KEYS="sk-official-key;sk-proxy-key"
```

模型连接设置可能已有数据库持久化值（参见 7.1）。若需变更，可在管理面板 `Settings > Connections` 中修改，或设置 `ENABLE_PERSISTENT_CONFIG=False` 后运行 `start` 采用环境变量；无需删除数据。
