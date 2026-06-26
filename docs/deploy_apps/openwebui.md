# Open WebUI 部署 (Deploy)

## 1. 简介

> Open WebUI 是一款用于大语言模型的现代化可视化交互面板，支持对接多种模型提供商并自带工具链与 RAG 能力，作为独立面板提供对话界面。

它使用内置 SQLite 存储，无需任何外部组件。作为纯体应用，启动时不创建自定义网络或嵌入任何子组件，仅在启动参数中加入 `--add-host host.docker.internal:host-gateway` 以安全穿透访问宿主机的 Ollama 接口。

## 2. 核心配置项

### settings_openwebui.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `openwebui_8421`），决定容器名与数据目录。
- `OPENWEBUI_PORT`: 面板对外暴露的宿主机端口。
- `WEBUI_SECRET_KEY`: 面板 JWT 加密密钥（自动随机生成）。
- `OLLAMA_BASE_URL`: Ollama 地址（默认 `http://host.docker.internal:11434`）。
- `OPENAI_API_BASE_URL` / `OPENAI_API_KEY`: （可选）OpenAI 或兼容服务的地址与密钥。
- `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` / `WEBUI_ADMIN_NAME`: 初始管理员的邮箱、密码和显示名称，`init` 时随机生成（用户名与邮箱本地名共用同一 4 位小写字母随机串，形如显示名 `kxqp`、邮箱 `kxqp@example.com`），仅在全新部署时生效。
- `HF_TOKEN`: （可选）HuggingFace Token，突破 RAG 模型下载限制。
- `CORS_ALLOW_ORIGIN`: 跨域来源，默认 `*`（生产环境不安全，建议收紧）。
- `USER_AGENT`: 联网搜索时伪装的浏览器 UA。

## 3. 备注

- 首次登录即管理员：Open WebUI 内部机制设定第一个注册的账户自动获得管理员权限；后续注册用户初始状态均为 Pending，需管理员手动审批。

## 4. 快速执行

```bash
cd deploy_apps/openwebui

# 常规分步拉起（推荐）：先生成配置、按需修改 settings_openwebui.conf 后再启动
bash cli.sh init
bash cli.sh start

# 一键拉起（跳过配置直接启动）
bash cli.sh up

# 停止运行
bash cli.sh stop

# 销毁容器（保留配置与 data/ 数据目录）
bash cli.sh rm

# 危险操作：彻底销毁容器，并删除挂载的 data/ 数据目录
bash cli.sh purge
```

## 5. 命令解释

#### init

若 `settings_openwebui.conf` 不存在则用模板渲染生成，再创建数据目录，不启动容器。

```bash
sed -e "s/{{INSTANCE_NAME}}/openwebui_<时间戳>/g" \
    -e "s/{{OPENWEBUI_PORT}}/<随机端口>/g" \
    -e "s/{{WEBUI_SECRET_KEY}}/<随机密钥>/g" \
    "$TPL_DIR/settings_openwebui.conf.tpl" > "$CONF_FILE"

mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### start

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
# 不存在时新建
docker run -d \
    --name "${INSTANCE_NAME}" \
    -p "${OPENWEBUI_PORT}:8080" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/app/backend/data" \
    -e WEBUI_SECRET_KEY \
    -e OLLAMA_BASE_URL \
    -e OPENAI_API_BASE_URL \
    -e OPENAI_API_KEY \
    -e WEBUI_ADMIN_EMAIL \
    -e WEBUI_ADMIN_PASSWORD \
    -e WEBUI_ADMIN_NAME \
    -e HF_TOKEN \
    -e CORS_ALLOW_ORIGIN \
    -e USER_AGENT \
    --add-host "host.docker.internal:host-gateway" \
    --restart always \
    ghcr.io/open-webui/open-webui:main
```

#### up

先 `init` 再 `start`。

#### stop

停止容器。

```bash
docker stop "${INSTANCE_NAME}"
```

#### rm

删除容器，保留 `./data/` 与 `settings_openwebui.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

#### purge

删除容器并删除本地数据目录，保留 `settings_openwebui.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

## 6. 其他补充

- 生产建议：把 `CORS_ALLOW_ORIGIN` 从 `*` 收紧为实际域名；若对外暴露，建议前置反代并启用 HTTPS。
- 镜像版本：当前固定 `ghcr.io/open-webui/open-webui:main`（滚动标签）。若需可复现部署，可改为具体版本标签。

## 7. 关键环境变量参考

`settings_openwebui.conf` 默认仅暴露最常用变量，`cli.sh` 的 `docker run` 也只透传显式列出的 `-e` 变量。启用下列任一新增变量需同时满足两步：先写入 `settings_openwebui.conf`，再在 `cli.sh` 的 `docker run` 段补一行 `-e <VAR>`。仅写进 `settings_openwebui.conf` 不会自动注入容器。完整变量清单见 `env-configuration.mdx`，下文仅列部署常用项。

### 7.1 ConfigVar 持久化机制

部分变量被标记为 `ConfigVar`（如 `WEBUI_URL`、`ENABLE_SIGNUP`、`ENABLE_OPENAI_API`、`OPENAI_API_BASE_URL`、`DEFAULT_MODELS` 等）。这类变量仅在首次启动时读取环境变量并写入内部数据库，此后重启只读数据库内的值，外部环境变量的修改不再生效；后续应在管理面板内修改，或临时关闭持久化。非 `ConfigVar` 变量（如 `WEBUI_ADMIN_*`、`DATABASE_URL`、`REDIS_URL`、`S3_*`）每次重启均按环境变量生效。

- `ENABLE_PERSISTENT_CONFIG`：默认 `True`。置为 `False` 时强制始终读取环境变量、忽略数据库，但管理面板内改动将不再持久化。
- `ENABLE_DB_MIGRATIONS`：默认 `True`。多副本/多进程部署时仅在一个主节点设为 `True`，其余设 `False`，避免迁移竞态。

### 7.2 自动创建管理员

用于免交互/容器化首次部署，仅在数据库无任何用户（全新部署）时生效；管理员创建后 `ENABLE_SIGNUP` 会被自动关闭。

注意：**必须同时填写邮箱、密码和显示名三项参数**，且不能为空值（`""`），否则自动创建将不会触发，仍需手动注册。

- `WEBUI_ADMIN_EMAIL`：管理员邮箱。
- `WEBUI_ADMIN_PASSWORD`：管理员密码，按与手动注册相同的机制哈希后存储。
- `WEBUI_ADMIN_NAME`：管理员显示名，`init` 时随机生成（4 位小写字母，与邮箱本地名同串）。

### 7.3 外部数据库与状态存储

默认使用内置 SQLite，单实例本地磁盘即可。多副本、多 worker 或数据目录位于网络存储时必须切换为外部 PostgreSQL。

- `DATABASE_URL`：完整的 SQLAlchemy 连接串，优先级最高，示例 `postgresql://user:password@host:5432/openwebui`；密码含特殊字符需 URL 编码（`@` 写作 `%40`）。
- `VECTOR_DB`：向量库类型，默认 `chroma`，多副本场景建议 `pgvector`。
- `PGVECTOR_DB_URL`：`pgvector` 连接串，默认回退到 `DATABASE_URL`，即与主库共用同一 PostgreSQL。
- `REDIS_URL`：外部 Redis 地址，示例 `redis://:password@host:6379/0`。单实例非必需，多 worker/多节点必须配置，否则会话与 WebSocket 状态无法跨实例共享。

### 7.4 对象存储 (S3 / RustFS / MinIO)

将上传文件外置到对象存储，对应本项目的 `deploy_services/rustfs`。

- `STORAGE_PROVIDER`：留空为 `local`，置为 `s3` 启用 S3 兼容存储。
- `S3_ENDPOINT_URL`：S3 兼容端点地址。
- `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`：访问凭证。
- `S3_BUCKET_NAME`：存储桶名称。
- `S3_REGION_NAME`：区域名称，部分自建服务可填任意占位值。
- 自签私有 CA 端点用 `AWS_CA_BUNDLE` 指定 PEM；Cloudflare R2 须设 `S3_ENABLE_TAGGING=False`。

## 8. 对接代理转发的 OpenAI 或第三方大模型源

任何提供 OpenAI 兼容接口的上游（自建代理、LiteLLM、one-api/new-api、或其他大模型服务）均通过 `OPENAI_API_BASE_URL` 系列变量对接，Open WebUI 将其统称为 "OpenAI API Connections"。

- `ENABLE_OPENAI_API`：默认 `True`，关闭则停用全部 OpenAI 兼容接口。

### 方式一：覆盖/单一源

如果只需要一个源（或者只用聚合网关），使用单数变量：
- `OPENAI_API_BASE_URL`：上游兼容端点，需带 `/v1` 后缀。
- `OPENAI_API_KEY`：上游鉴权密钥。

### 方式二：保留官方源并追加多个源（复数变量）

如果不想修改原有的官方 OpenAI，同时还要挂载代理或其他大模型源，使用复数变量。用分号 `;` 将多个地址与密钥拼接（顺序必须一一对应）：
- `OPENAI_API_BASE_URLS`：示例 `https://api.openai.com/v1;https://api.b.ai/v1`
- `OPENAI_API_KEYS`：示例 `sk-official-xxx;sk-proxy-xxx`

`settings_openwebui.conf` 完整配置示例：

```ini
# 单数（单一源）
OPENAI_API_BASE_URL="https://your-proxy.example.com/v1"
OPENAI_API_KEY="sk-xxxxxxxx"

# 复数（多源拼接，保留官方源并追加自定义源）
OPENAI_API_BASE_URLS="https://api.openai.com/v1;https://api.b.ai/v1"
OPENAI_API_KEYS="sk-official-key;sk-proxy-key"
```

这些变量属于 ConfigVar，首次启动后写入数据库，之后修改 `settings_openwebui.conf` 不再生效（参见 7.2）。若需变更，建议在管理面板 `Settings > Connections` 中直接添加，或临时设 `ENABLE_PERSISTENT_CONFIG=False` 后清空容器重建使环境变量重新生效。
