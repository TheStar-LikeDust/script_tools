# ParadeDB (带 pgvector 扩展)

## 服务简介

ParadeDB 组件是我们架构中的核心关系型数据库底座。为了深度适配 LLM (大语言模型)、知识库和向量检索场景，默认使用 `paradedb/paradedb` 镜像。

它不仅拥有标准 PostgreSQL 的所有能力，还能存储和高效检索高维向量数据。

## 部署与隔离特性

- **多实例防冲突**：每个 ParadeDB 实例不仅拥有独立的 Docker 容器，它的网络、映射端口和挂载卷都会带有实例名称前缀。
- **数据卷持久化**：数据统一映射在所在服务目录的 `./data/<实例名>_paradedb_data` 文件夹中。
- **动态认证**：第一次初始化时，会自动分配一个高强度的随机密码。

## 核心配置项 (`settings.conf`)

执行 `bash cli.sh init` 之后会生成配置文件，其中主要变量如下：

- `INSTANCE_NAME`: 实例前缀（默认 `paradedb`）
- `DB_PORT`: 暴露给宿主机的随机端口
- `DB_USER`: 默认数据库管理员账号 (`postgres`)
- `DB_PASSWORD`: 自动生成的强密码
- `DB_NAME`: 默认创建的库名 (`postgres`)

## 常见操作

```bash
cd deploy/paradedb

# 初始化生成配置
bash cli.sh init

# 启动数据库
bash cli.sh start

# 彻底销毁包含本地文件的全套环境（危险！）
bash cli.sh purge
```
