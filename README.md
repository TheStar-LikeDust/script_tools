# script_tools

基于“目录即服务”的 Docker Compose 部署工具集。

## 设计哲学与核心特性

- 目录即服务：每个部署目录集中保存本服务的部署定义、配置、密钥和相对路径 bind mount 数据。停止服务或完成一致性备份后，可复制该目录到新机器重新启动；共享基础服务的数据从其自己的目录单独迁移。
- 简化生命周期：`cli.sh` 保留配置初始化、随机密钥生成和服务专属操作，容器创建、网络接入和配置变化后的重建交给 Docker Compose。
- 配套部署：Casdoor 默认组合 PostgreSQL；New API、Sub2API 组合 PostgreSQL、Redis；LobeHub 组合 PostgreSQL、Redis、RustFS。基础服务配置和服务片段由 `deploy_services/` 生成，应用生命周期管理本实例整套服务。

## 项目架构

- `deploy_services/`：ParadeDB、Redis、RustFS，统一维护服务配置、凭证、Compose 片段与连接信息，同时支持独立部署。
- `deploy_apps/`：Casdoor、New API、Sub2API、LobeHub（目录名 `lobechat`）调用服务接口组合默认依赖。Open WebUI 默认使用 SQLite 和本地存储。
- `tools/`：宿主机工具，包括 code-server、nginx、certbot 和 Docker 防火墙配置，各用自己的命令接口。

## 设计文档

修改代码或新增服务前，请阅读：

- [服务设计](docs/design/core.md)：目录与数据归属、Compose 配置注入、共享网络和实例隔离。
- [命令规范](docs/design/command.md)：生命周期命令、`update`、薄 CLI 与清理边界。
- [服务文档规范](docs/design/document.md)：各服务说明的结构与内容要求。

## 部署流程

部署脚本面向 Linux，使用 Bash、Docker Engine、Compose v2 插件及常用命令行工具（如 OpenSSL、sed、shuf），Compose 命令为 `docker compose`。`init` 只生成本地配置、YAML 和数据目录；`start` 启动整套实例。生成 YAML 会在 `init/start/update` 时刷新，持久调整容器定义应修改 `templates/compose.yaml.tpl`。

### 默认配套部署

以 New API 为例：

```bash
cd deploy_apps/newapi
bash cli.sh init
bash cli.sh start
```

New API 的 `init` 会通过 `deploy_services/paradedb` 和 `deploy_services/redis` 准备三份 settings，并由服务接口生成数据库 DSN 和 Redis URL。PostgreSQL 首次启动时创建配置指定的数据库及账号；Redis 默认无密码，数据持久化。数据库和 Redis 使用容器端口 `5432`、`6379`，不发布宿主机端口。Compose 自动创建本实例私有网络，无需先启动 `deploy_services/` 中的服务。

LobeHub 的 `APP_URL` 默认使用 `http://localhost:<LOBECHAT_PORT>`，`S3_ENDPOINT` 默认使用 `http://localhost:<RUSTFS_PORT>`；远程访问时应改为浏览器可访问的地址。初始 `AUTH_ALLOWED_EMAILS` 默认生成随机的 `admin-<随机值>@example.invalid`；可通过 `init --app-url --s3-endpoint --auth-allowed-emails` 覆盖，也可在应用 settings 中修改。启动阶段调用 RustFS `resource-init` 创建或补建专用用户、Bucket 和访问策略；管理员凭证由 RustFS settings 保存。CORS 暂不自动配置，模型 API Key、OAuth 等外部凭证由使用者提供。

四个应用先生成或读取应用与依赖的全部 settings，再组合 YAML。应用只保存自身字段、依赖配置路径及需要的专用 S3 凭证，数据库账号和密码保存在 ParadeDB settings，连接串由服务生成。settings 是 Bash 配置；外接依赖切换不属于当前自动化流程。旧版单配置及旧数据不做自动迁移。

### 独立基础服务

`deploy_services/` 中的 ParadeDB、Redis、RustFS 仍可单独 `init/start`。这些独立项目由各自 CLI 管理，不参与应用默认部署的启停或清理。需要多个项目互通时，可由管理员预建共享网络并设置 `DOCKER_NETWORK`；该网络不会随 `rm` 删除。

### 复用基础服务定义

三个基础服务的 `init` 支持注入实例名、镜像、宿主机端口、发布开关和网络；ParadeDB 另支持数据库名、账号和密码，RustFS 支持控制台端口及管理员凭证。已有非空配置优先，参数只用于新配置或补齐空字段。`init --config-only` 只准备 settings，便于应用准备全部配置后再构建总 YAML。

`render` 输出服务 YAML 片段，`env` 输出带 `PARADEDB_*`、`REDIS_*`、`RUSTFS_*` 前缀的 Bash 导出语句及连接信息；独立部署使用同一模板。四个应用均已接入，生成 YAML 仅保留变量引用。RustFS 还提供 `prepare-data` 和 `resource-init`，由应用 hooks 调用。接口和已核对的部署依据见 [ParadeDB](docs/deploy_services/paradedb.md)、[Redis](docs/deploy_services/redis.md)、[RustFS](docs/deploy_services/rustfs.md)。

### 服务与工具说明

三个基础服务和五个应用均使用 Compose，并提供 `update`。各项目的配置与特殊操作见对应说明：

- 基础服务：[ParadeDB](docs/deploy_services/paradedb.md)、[Redis](docs/deploy_services/redis.md)、[RustFS](docs/deploy_services/rustfs.md)。
- 应用：[Casdoor](docs/deploy_apps/casdoor.md)、[LobeHub](docs/deploy_apps/lobechat.md)、[New API](docs/deploy_apps/newapi.md)、[Open WebUI](docs/deploy_apps/openwebui.md)、[Sub2API](docs/deploy_apps/sub2api.md)。
- 宿主机工具：[code-server](docs/tools/codeserver.md)、[Nginx](docs/tools/nginx.md)、[Certbot](docs/tools/certbot.md)、[Docker 防火墙](docs/tools/docker-setup.md)。

## 常用管理命令

以下命令适用于 `deploy_services/` 和 `deploy_apps/`。在对应目录执行，也可用 `--conf PATH` 指定配置位置（父目录须已存在）、用 `init --name NAME` 为新配置指定唯一实例名。不同实例必须使用不同名称；同名容器属于其他部署时，CLI 拒绝操作。

```bash
bash cli.sh init      # Generate local settings, YAML and data directories.
bash cli.sh start     # Refresh YAML and apply the current configuration.
bash cli.sh up        # init + start; fill any prompted application settings first.
bash cli.sh update    # Pull this project's images, then apply them with Compose.
bash cli.sh stop      # Stop only this project.
bash cli.sh rm        # Remove its containers/private network; keep settings and data.
```

LobeHub 在 `start/update` 时补齐缺失的 JWKS 并保存，优先使用宿主机 Node.js，没有 Node.js 时运行一次性应用容器。重复启动保留原值，`init` 不运行密钥生成容器。

`update` 拉取并应用本 Compose 项目的应用及依赖镜像，由各自 settings 中的 `IMAGE` 决定，保留配置、密钥和 bind mount 数据。镜像可能升级数据库结构；该命令不负责 PostgreSQL 跨主版本数据迁移。RustFS 根据拉取后的镜像修正数据目录属主，LobeHub 继续调用资源初始化接口。

危险的清理命令：

```bash
bash cli.sh purge    # Remove this project and its own local runtime data.
bash cli.sh reset    # purge, then remove this settings file and generated YAML.
```

四个配套应用的 `rm` 删除整套实例容器和私有网络，保留配置与持久化数据；随后 `start` 可重建容器。`purge` 删除本实例应用及依赖的数据目录，保留 settings；`reset` 再删除应用 settings、生成 YAML、默认依赖 settings 和附属配置。Casdoor、LobeHub、Sub2API 也删除本实例目录内明确引用的自定义依赖 settings 及对应 YAML，目录外配置保留。Casdoor 的 `purge` 保留 app.conf，`reset` 删除其生成配置目录。清理不涉及源码模板、其他实例或独立基础服务。

查看状态使用 `docker ps -a --filter 'name=^/<INSTANCE_NAME>$'`，日志使用 `docker logs -f <INSTANCE_NAME>`，执行前替换实例名占位符。应用的 `bash cli.sh network ls` 只读显示配置网络；没有 `status` 命令。`start/update` 返回成功表示 Compose 已启动容器，应用就绪情况查看日志或健康状态。

## 复制目录迁移

停止整套实例或完成一致性备份后，复制完整部署目录，包括 CLI、存在的 hooks.sh、模板、settings、生成 YAML、密钥和本地 data。四个配套应用的数据包含 `data/<INSTANCE_NAME>_postgres_data`，需要 Redis 或 RustFS 时还包含对应的 `_redis_data`、`_rustfs_data`。目标机器准备 Docker Engine 和 Compose v2，保留实例名、配置及目录对应关系后运行 `start`；使用 external 网络时另行准备该网络。物理复制 PostgreSQL 数据目录必须先停止数据库并使用兼容主版本，不能直接复制正在写入的数据库目录。

默认配套依赖的数据随应用配置目录一起保存；独立部署的基础服务仍从各自目录备份和迁移。Open WebUI 默认 SQLite 与上传文件保存在本地数据目录。复制恢复必须保留应用加密密钥，切换 Open WebUI 的数据库类型不会自动搬迁数据。

使用 `--conf` 时还需携带应用及所用 `deploy_services/` 的 CLI、hooks 和 templates，并保留脚本之间的相对目录结构。复制配置目录本身不能替代部署脚本。多实例分别使用独立配置目录及唯一实例名，避免默认依赖配置文件重名。自定义配置位置应放在版本库外，或自行补充忽略规则。
