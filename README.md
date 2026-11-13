# script_tools

基于“目录即服务”的 Docker Compose 部署工具集。

## 设计哲学与核心特性

- 目录即服务：每个部署目录集中保存本服务的部署定义、配置、密钥和相对路径 bind mount 数据。停止服务或完成一致性备份后，可复制该目录到新机器重新启动；共享基础服务的数据从其自己的目录单独迁移。
- 简化生命周期：`cli.sh` 保留配置初始化、随机密钥生成和服务专属操作，容器创建、网络接入和配置变化后的重建交给 Docker Compose。
- 共享基础服务：PostgreSQL、Redis、RustFS 独立部署。应用通过人工填写的 `settings_<应用名>.conf` 连接同机或远程服务，不级联创建、启停或清理依赖。多个应用共享 PostgreSQL 时，各用独立数据库和账号。

## 项目架构

- `deploy_services/`：ParadeDB、Redis、RustFS，独立管理配置、凭证和数据。
- `deploy_apps/`：Casdoor、LobeHub（目录名 `lobechat`）、New API、Open WebUI、Sub2API，每个 Compose 项目只部署应用自身。Open WebUI 默认保留 SQLite，可选接入外部 PostgreSQL。
- `tools/`：宿主机工具，包括 code-server、nginx、certbot 和 Docker 防火墙配置，各用自己的命令接口。

## 设计文档

修改代码或新增服务前，请阅读：

- [服务设计](docs/design/core.md)：目录与数据归属、Compose 配置注入、共享网络和实例隔离。
- [命令规范](docs/design/command.md)：生命周期命令、`update`、薄 CLI 与清理边界。
- [服务文档规范](docs/design/document.md)：各服务说明的结构与内容要求。

## 部署流程

部署脚本面向 Linux，使用 Bash、Docker Engine、Compose v2 插件及常用命令行工具（如 OpenSSL、sed、shuf），Compose 命令为 `docker compose`。流程为先初始化 settings，再生成引用其变量的 YAML，人工填写配置后启动。生成 YAML 会在 `init/start/update` 时刷新，持久调整容器定义应修改 `templates/compose.yaml.tpl`。

### 先独立启动基础服务

同机互通时，管理员先创建共享网络：

```bash
docker network create shared_services

cd deploy_services/paradedb
bash cli.sh init
# Set DOCKER_NETWORK="shared_services" in settings_paradedb.conf.
# Review instance name, credentials and port publishing.
bash cli.sh start
```

Redis、RustFS 也从各自目录初始化、配置并启动。共享网络在 YAML 中声明为 `external: true`，不会随任何应用的 `rm` 删除。

管理员提前为每个应用创建独立数据库与账号，以及需要的 bucket、对象存储凭证和 Redis 隔离资源。建库建号示例见 [ParadeDB 说明](docs/deploy_services/paradedb.md)。仓库 Redis 模板尚未提供认证，不应直接作为多个应用共享的实例；可按应用独立部署，或由管理员先配置认证和隔离。

### 再配置并启动应用

以 New API 为例：

```bash
cd deploy_apps/newapi
bash cli.sh init
# Fill DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD and REDIS_CONN_STRING.
# Set DOCKER_NETWORK="shared_services" for services on the same host.
bash cli.sh start
```

同机容器通过唯一的实例容器名和内部端口连接，例如 `pg-shared:5432`，不要使用 PostgreSQL 的随机宿主机端口。容器内的 `localhost` 指当前应用容器。远程服务填写从容器可访问的主机名/IP 和监听端口；只连接远程服务时 `DOCKER_NETWORK` 可以留空。

settings 是 Bash 配置，密码建议用单引号；分字段 `DB_*` 填原值，脚本负责连接串转义或字段映射。手工填写完整 Redis URI 时需自行 URL 编码凭证。现有 settings 不会被 `init` 覆盖或自动补字段，缺少的字段按模板人工补充。

### 服务与工具说明

三个基础服务和五个应用均使用 Compose，并提供 `update`。各项目的配置与特殊操作见对应说明：

- 基础服务：[ParadeDB](docs/deploy_services/paradedb.md)、[Redis](docs/deploy_services/redis.md)、[RustFS](docs/deploy_services/rustfs.md)。
- 应用：[Casdoor](docs/deploy_apps/casdoor.md)、[LobeHub](docs/deploy_apps/lobechat.md)、[New API](docs/deploy_apps/newapi.md)、[Open WebUI](docs/deploy_apps/openwebui.md)、[Sub2API](docs/deploy_apps/sub2api.md)。
- 宿主机工具：[code-server](docs/tools/codeserver.md)、[Nginx](docs/tools/nginx.md)、[Certbot](docs/tools/certbot.md)、[Docker 防火墙](docs/tools/docker-setup.md)。

## 常用管理命令

以下命令适用于 `deploy_services/` 和 `deploy_apps/`。在对应目录执行，也可用 `--conf PATH` 指定配置位置（父目录须已存在）、用 `init --name NAME` 为新配置指定唯一实例名。不同实例必须使用不同名称；同名容器属于其他部署时，CLI 拒绝操作。

```bash
bash cli.sh init      # Generate missing settings, then YAML; no long-running service.
bash cli.sh start     # Refresh YAML and apply the current configuration.
bash cli.sh up        # init + start; fill external connection settings first.
bash cli.sh update    # Pull IMAGE, then apply it with Compose.
bash cli.sh stop      # Stop only this project.
bash cli.sh rm        # Remove its containers/private network; keep settings and data.
```

LobeHub 首次生成 JWKS 时优先使用宿主机 Node.js；没有 Node.js 时会运行一次性应用容器生成密钥。

`update` 执行 `docker compose pull` 后执行 `docker compose up -d`，镜像由 settings 中的 `IMAGE` 决定，保留配置、密钥和 bind mount 数据。镜像可能自动升级数据库结构，升级前应备份并核对版本要求；该命令不负责 PostgreSQL 跨主版本数据迁移。RustFS 还会根据拉取后的镜像修正数据目录属主。

危险的清理命令：

```bash
bash cli.sh purge    # Remove this project and its own local runtime data.
bash cli.sh reset    # purge, then remove this settings file and generated YAML.
```

应用的 `purge/reset` 不清空外部数据库、Redis 或 S3；LobeHub 无本地运行数据，`purge` 等同 `rm`。Casdoor 的 `purge` 保留 app.conf，`reset` 再将其删除。部分本地文件由容器用户写入，脚本用一次性 root 容器删除本实例数据。不要以 `purge/reset` 代替升级或迁移，`reset` 删除应用密钥后可能无法解密保留在外部库中的数据。

查看状态使用 `docker ps -a --filter 'name=^/<INSTANCE_NAME>$'`，日志使用 `docker logs -f <INSTANCE_NAME>`，执行前替换实例名占位符。应用的 `bash cli.sh network ls` 只读显示配置网络；没有 `status` 命令。`start/update` 返回成功表示 Compose 已启动容器，应用就绪情况查看日志或健康状态。

## 复制目录迁移

停止服务或完成一致性备份后，复制完整部署目录，包括 CLI、模板、settings、生成 YAML、密钥和本地 data。目标机器准备 Docker Engine、Compose v2 和所需共享网络，保留实例名与数据目录名的对应关系，核对端口、连接地址和镜像版本后运行 `start`。物理复制 PostgreSQL 数据目录必须先停止数据库并使用兼容主版本；不能直接复制正在写入的数据库目录。

应用目录只携带应用本地资产。共享 PostgreSQL、Redis 和 RustFS 的配置及数据由各自服务目录独立备份和迁移。LobeHub 的业务数据全部位于外部依赖中；Open WebUI 默认 SQLite 与上传文件保存在本地数据目录。复制恢复必须保留应用加密密钥，切换 Open WebUI 的数据库类型不会自动搬迁数据。

使用 `--conf` 将配置放在其他目录时，还需携带对应 CLI 和 templates；复制配置目录本身不能替代部署脚本。自定义配置位置应放在版本库外，或自行补充忽略规则。
