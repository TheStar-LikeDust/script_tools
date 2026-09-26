# LobeHub 最小数据库版部署

使用官方 `lobehub/lobehub:latest` 镜像，保留目录名 `lobechat`。常驻容器只有两个：LobeHub 和同机自动管理的 ParadeDB（PostgreSQL 17）。

当前 LobeHub 2.x 只支持 Server DB，官方镜像没有可替代 PostgreSQL 的内置 SQLite/PGlite。本方案无需自行准备远程数据库，但 PostgreSQL 仍是一个独立容器。

不启动 Casdoor、Redis、RustFS，不配置 S3。使用 Better Auth 自带的邮箱密码注册/登录，不启用邮箱验证，无需 SMTP。未配置 SMTP 时不能通过邮件找回密码。

此配置用于先跑通文字聊天。文件/图片上传、知识库附件和其他依赖对象存储的功能暂不可用；不会自动改用 `/app/data` 存储附件。模型服务商及 API Key 在登录后配置。

## 快速启动

要求 Linux Docker 环境及 Bash、OpenSSL 等常见命令。生成 JWKS 使用 Node.js 内置 crypto；宿主机没有 Node.js 时，脚本会临时运行同一个 LobeHub 镜像生成密钥，完成后自动删除该临时容器，不增加常驻服务。

```bash
cd deploy_apps/lobechat
bash cli.sh init
# 编辑 settings_lobechat.conf，将 APP_URL 设为浏览器实际使用的完整地址
# 例如 http://服务器IP:生成的端口，或反向代理后的 https://chat.example.com
bash cli.sh start
```

默认 `APP_URL=http://localhost:随机端口` 适合本机访问或同端口 SSH 转发。公网使用前可将 `AUTH_ALLOWED_EMAILS` 填为自己的邮箱，限制注册；为空时允许所有邮箱注册。首次打开页面自行注册邮箱密码账户，不会预建管理员。

`bash cli.sh up` 等于依次执行 `init` 和 `start`，适合已配置好地址的实例。

启动命令返回只表示容器已启动；用 `docker logs -f <INSTANCE_NAME>` 确认数据库迁移通过和应用就绪，再验证注册、登录及文字聊天。数据库健康检查超时会中止应用启动。

## 配置与数据

- `settings_lobechat.conf`：实例名、宿主机端口、`IMAGE`、`APP_URL`、`KEY_VAULTS_SECRET`、`AUTH_SECRET`、`JWKS_KEY`、可选 `AUTH_ALLOWED_EMAILS`。
- `settings_paradedb.conf`：随应用生成的本地数据库配置；新实例设置 `DB_PUBLISH_PORT=false`，不暴露数据库宿主机端口。
- `data/<数据库实例名>_data/`：PostgreSQL 持久化数据，保存用户、聊天记录等。

重复 `init` 保留已有配置和密钥。备份应同时保留数据库与配置，尤其不要重新生成已有实例的 `KEY_VAULTS_SECRET`。LobeHub 应用容器本身不挂载无实际用途的 `/app/data`。

ParadeDB 启动时显式传入 `-c shared_preload_libraries=pg_search`，应用通过专属 Docker 网络连接它。

## 生命周期

```bash
bash cli.sh stop     # 停止应用和数据库
bash cli.sh start    # 启动现有容器；不应用新环境变量，也不自动拉取镜像
bash cli.sh rm       # 删除应用和数据库容器，保留配置与数据库数据
bash cli.sh network  # 查看专属网络
bash cli.sh purge    # 危险：删除应用、数据库容器及其数据，保留配置
bash cli.sh reset    # 危险：purge 后再删除这两个服务的配置
```

修改应用环境变量后，仅重建应用即可：

```bash
source settings_lobechat.conf
# 若还需要更新应用镜像，先备份数据库，再按需执行：docker pull "$IMAGE"
docker stop "$INSTANCE_NAME"
docker rm "$INSTANCE_NAME"
bash cli.sh start
```

`IMAGE` 可以改成经过验证的固定版本标签。单独拉取镜像不会更新已有容器。不要把 `purge` 或 `reset` 当作升级命令。

## 已有旧版全栈实例

旧版 `USE_INTERNAL_*` / `EXTERNAL_*` 配置不能直接用于这个最小方案，脚本会报错，避免将旧 SSO 账户和外部数据库悄悄切换为新实例。

先使用独立目录试跑，不覆盖原配置或数据：

```bash
mkdir -p minimal
bash cli.sh init --conf "$PWD/minimal/settings_lobechat.conf" --name lobechat_minimal
# 编辑 minimal/settings_lobechat.conf 中的 APP_URL
bash cli.sh start --conf "$PWD/minimal/settings_lobechat.conf"
```

这会创建一个全新的数据库，不迁移旧账户和聊天记录。旧 Casdoor、Redis、RustFS 的容器与数据不会被新脚本自动停止或删除。需要保留旧数据时，应另行备份和规划数据库/认证迁移。

参考：[官方 Docker 部署](https://lobehub.com/docs/self-hosting/platform/docker)、[V2 变更](https://lobehub.com/docs/self-hosting/migration/v2/breaking-changes)、[认证变量](https://lobehub.com/docs/self-hosting/environment-variables/auth)。
