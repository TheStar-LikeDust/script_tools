# Open WebUI 部署 (Deploy)

## 服务简介

Open WebUI 是一款用于大语言模型的现代化可视化交互面板。它支持连接多种外部模型提供商（如 OpenAI, Ollama, Anthropic 等），以及强大的工具链和 RAG（检索增强生成）特性。因为其自带轻量级的 SQLite 存储系统，因此它无需额外连接独立的数据库即可完整运行。

## 部署与隔离特性

- **轻量独立**：无需依赖额外的 PostgreSQL 或 Redis 等外部组件。
- **数据内聚**：所有的用户数据、对话记录、以及上传的文件都会安全地隔离保存在宿主机的 `./data/<实例名>_openwebui_data` 目录中。
- **动态端口**：通过修改配置文件可以方便地改变访问端口，支持在单台机器上多开多个面板实例。
- **Ollama 互通**：内置了 `extra_hosts` 以支持直连宿主机 (`host.docker.internal`) 上的 Ollama 本地模型服务。

## 核心配置项 (`settings.conf`)

执行 `bash cli.sh init` 之后会生成配置文件 `settings.conf`，主要变量如下：

- `INSTANCE_NAME`: 实例前缀（默认 `openwebui`）
- `OPENWEBUI_PORT`: 访问面板暴露给外部的宿主机网络端口
- `WEBUI_SECRET_KEY`: 用于面板 JWT Token 加密的随机密钥（自动生成）
- `OLLAMA_BASE_URL`: Ollama 接口地址（默认为 `http://host.docker.internal:11434` 支持直连宿主机部署的 Ollama）
- `OPENAI_API_KEY`: (可选) 你的 OpenAI 密钥或兼容 OpenAI 的服务密钥
- `OPENAI_API_BASE_URL`: (可选) 你的 OpenAI 代理/兼容服务接口地址

## 首次运行须知

:::tip First Login
- **Admin account:** 首次注册的账户将自动获得 **管理员 (Administrator)** 权限，并可以控制所有后续的新用户审批及系统设置。
- **New sign-ups:** 之后注册的新用户账号初始状态均为 **Pending**，需要等待管理员在后台审批通过。
- **Privacy:** 所有的聊天数据、密码默认情况下均保存在你的本地 `./data/` 目录中，不会向外传输。
:::

## 常见操作

```bash
cd deploy_apps/openwebui

# 一键拉起 Open WebUI 实例
bash cli.sh up

# 停止容器并删除实例（保留本地数据与对话记录）
bash cli.sh rm

# 【危险操作】彻底销毁实例容器，并删除挂载的 ./data/ 文件夹内所有对话数据和上传文件！
bash cli.sh purge
```
