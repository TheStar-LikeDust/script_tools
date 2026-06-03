# LobeChat 全栈部署 (Deploy)

## 服务简介

LobeChat 是一个现代化的、功能强大的开源大型语言模型（LLM）用户交互客户端。
全栈编排版（Full-Stack）意味着我们不仅仅是跑起 LobeChat 的前端，而是搭建了一整套完备的生产级基础设施，包括：
1. **ParadeDB (带 pgvector)**：存储用户配置与向量数据。
2. **RustFS (S3)**：负责聊天时的附件、图片上传与存储。
3. **Casdoor**：负责多用户的注册、认证和权限管控。
4. **LobeChat 主程序**：对接上述服务，提供应用本体。

## 编排架构原理

`deploy_apps/lobechat/cli.sh` 作为总控制器，使用了一套**向下级联调度**的机制：

1. **依赖收集**：它首先去调用 `deploy/paradedb` 生成专属的数据库实例，拿到随机生成的数据库密码。
2. **配置组装**：它把拿到的数据库密码、网络名称，自动组装并注入到 Casdoor 的配置文件中，确保服务间可以顺畅通信。
3. **网络连通**：通过统一下发 `NETWORK_NAME` 环境变量，所有的底层服务都被织入了同一个自定义 Docker 网络。
4. **统一启停**：管理所有底层容器的启动顺序（防止 Casdoor 启动时数据库还没准备好）。

## 核心配置项 (`settings.conf`)

栈级别的 `settings.conf` 通常决定了全局的隔离前缀和网络名称：

- `INSTANCE_NAME`: 全局业务实例名前缀（默认 `lobechat`）
- `NETWORK_NAME`: 全局通信网络名称（默认 `lobechat_network`）

## 常见操作

```bash
cd deploy_apps/lobechat

# 一键拉起整个 LobeChat 集群！(自动生成各组件所需的库与密码)
bash cli.sh up

# 销毁全部容器
bash cli.sh rm

# 危险操作：彻底销毁全栈所有容器，并删除各自挂载的 data/ 文件夹！
bash cli.sh purge
```
