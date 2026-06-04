# Casdoor

## 服务简介

Casdoor 是一个支持 OAuth 2.0 / OIDC / SAML / CAS 的 UI 优先型身份与访问管理（IAM）平台。在我们的微服务或全栈架构中，它承担着统一用户认证、单点登录（SSO）以及权限中心的角色。

## 外部依赖

与其他基础服务不同，Casdoor **本身不存储数据**，它强依赖于关系型数据库。
在默认的模板配置中，我们指定其连接并依赖于同一虚拟网络下的 ParadeDB 实例。

> **关于 `casdoor` 数据库**：Casdoor 使用一个与业务库相互隔离的独立数据库（默认库名 `casdoor`，由 `config/app.conf` 的 `dataSourceName` / `dbName` 指定），首次启动时会自动初始化所需表结构。它与应用自身的业务库（例如 LobeChat 的 `postgres` 库）不是同一个库。

> **独立部署提示**：单独在 `deploy/casdoor` 下 `init` 时，由于无法预知随机生成的 ParadeDB 容器名，`CASDOOR_DB_HOST` 默认渲染为占位符 `<UPDATE_ME_DB_HOST>`，必须手动改成目标数据库的容器名或 IP。通过 `deploy_apps` 级联拉起时，该值会由上层自动注入，无需手改。

## 部署与隔离特性

- **数据层解耦**：配置文件中将 Casdoor 与所依赖的 ParadeDB 分离配置，可通过修改 `settings.conf` 随时将其连接指向外部的云数据库。
- **支持外部反代**：支持在 Docker 外层嵌套 Nginx 以实现域名和 HTTPS 支持。

## 核心配置项 (`settings.conf`)

执行 `bash cli.sh init` 之后会生成配置文件，其中主要变量如下：

- `INSTANCE_NAME`: 实例名，时间戳后缀规则（独立部署如 `casdoor_8421`）
- `CASDOOR_PORT`: 对外暴露的 Web UI / API 端口
- `CASDOOR_DB_HOST`: ParadeDB 的容器地址或外部 IP（独立部署默认占位符 `<UPDATE_ME_DB_HOST>`，需手填）
- `CASDOOR_DB_USER`: 数据库连接账户
- `CASDOOR_DB_PASSWORD`: 数据库连接密码

## 常见操作

```bash
cd deploy/casdoor

# 提示：由于 Casdoor 强依赖 DB，建议通过部署层 (Deploy) 来启动它
bash cli.sh init
bash cli.sh start
```
