# Open WebUI 部署 (Deploy)

## 1. 简介

> Open WebUI 是一款用于大语言模型的现代化可视化交互面板，支持对接多种模型提供商并自带工具链与 RAG 能力，作为独立面板提供对话界面。

它使用内置 SQLite 存储，无需任何外部数据库即可独立运行。

## 2. 部署特性

- 轻量独立：单容器架构，不被任何上层应用嵌入，因此不支持委托级联参数。
- Ollama 互通：容器内置了 `host-gateway` 的附加路由，以便直连宿主机上的本地 Ollama 实例。

## 3. 核心配置项 (settings.conf)

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `openwebui_8421`），决定容器名与数据目录。
- `OPENWEBUI_PORT`: 面板对外暴露的宿主机端口。
- `WEBUI_SECRET_KEY`: 面板 JWT 加密密钥（自动随机生成）。
- `OLLAMA_BASE_URL`: Ollama 地址（默认 `http://host.docker.internal:11434`）。
- `OPENAI_API_BASE_URL` / `OPENAI_API_KEY`: （可选）OpenAI 或兼容服务的地址与密钥。
- `HF_TOKEN`: （可选）HuggingFace Token，突破 RAG 模型下载限制。
- `CORS_ALLOW_ORIGIN`: 跨域来源，默认 `*`（生产环境不安全，建议收紧）。
- `USER_AGENT`: 联网搜索时伪装的浏览器 UA。

## 4. 备注

- 首次登录即管理员：第一个注册的账户自动获得管理员权限；之后注册的用户初始为 Pending，需管理员审批。
- 数据本地化：聊天记录与密码默认仅保存在本地 `./data/` 目录，不外传。

## 5. 快速执行

```bash
cd deploy_apps/openwebui

# 一键拉起（init + start）
bash cli.sh up

# 或分步：先生成配置、按需改 settings.conf，再启动
bash cli.sh init
bash cli.sh start
```

## 6. 命令解释

#### init

若 `settings.conf` 不存在则用模板渲染生成，再创建数据目录，不启动容器。

```bash
sed -e "s/{{INSTANCE_NAME}}/openwebui_<时间戳>/g" \
    -e "s/{{OPENWEBUI_PORT}}/<随机端口>/g" \
    -e "s/{{WEBUI_SECRET_KEY}}/<随机密钥>/g" \
    "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"

mkdir -p "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
```

#### start

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
# 不存在时新建
docker run -d \
    --name "${INSTANCE_NAME}" \
    -p "${OPENWEBUI_PORT}:8080" \
    -v "$SCRIPT_DIR/data/${INSTANCE_NAME}_data:/app/backend/data" \
    -e WEBUI_SECRET_KEY \
    -e OLLAMA_BASE_URL \
    -e OPENAI_API_BASE_URL \
    -e OPENAI_API_KEY \
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

删除容器，保留 `./data/` 与 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

#### purge

删除容器并删除本地数据目录，保留 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
```

#### status

显示容器状态。

```bash
docker ps -a --filter "name=^${INSTANCE_NAME}$"
```

## 7. 其他补充

- 生产建议：把 `CORS_ALLOW_ORIGIN` 从 `*` 收紧为实际域名；若对外暴露，建议前置反代并启用 HTTPS。
- 镜像版本：当前固定 `ghcr.io/open-webui/open-webui:main`（滚动标签）。若需可复现部署，可改为具体版本标签。
