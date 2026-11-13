# Casdoor 部署 (Deploy)

## 1. 简介

> Casdoor 是支持 OAuth 2.0、OIDC、SAML 等协议的身份与访问管理平台。

本目录通过一个 Docker Compose 项目部署 Casdoor 和配套 ParadeDB。`init` 通过 ParadeDB 服务接口准备数据库配置并组合服务定义；数据库凭据与连接串由 ParadeDB 维护，Casdoor 的 `app.conf` 在启动阶段生成。

## 2. 核心配置项

### settings_casdoor.conf

- `INSTANCE_NAME`：Compose 项目名、应用容器名及应用数据目录前缀；使用小写字母、数字、下划线和连字符，以字母或数字开头。
- `IMAGE`：Casdoor 镜像，默认 `casbin/casdoor:latest`。
- `CASDOOR_PORT`：宿主机 Web 端口；容器端口为 `8000`。
- `DOCKER_NETWORK`：可选的、预先创建的共享网络；留空使用本项目私有网络。
- `PARADEDB_CONF`：ParadeDB settings 路径；相对路径按应用 settings 所在目录解析，默认 `settings_casdoor_paradedb.conf`。

### settings_casdoor_paradedb.conf

由 ParadeDB CLI 维护，保存数据库镜像、容器名、数据库名、账号、密码和宿主机端口。Casdoor 通过 `env` 接口读取带 `PARADEDB_` 前缀的服务字段及 `PARADEDB_DSN`，不在应用 settings 中重复保存数据库凭据。

### data/<INSTANCE_NAME>_config/app.conf

Casdoor 使用的 INI 配置，包含数据库连接串，以 `600` 权限保存并只读挂载到 `/conf/app.conf`。`start` 和 `update` 根据 ParadeDB DSN 与 `templates/app.conf.tpl` 重新生成；持久化调整应修改模板。

## 3. 备注

- `init` 先补齐应用 settings，再调用 ParadeDB `init --config-only`、`env` 和 `render`，最后生成总 YAML 和本地数据目录；不启动容器。
- ParadeDB 默认数据库名和账号由 Casdoor 初始化参数设为 `casdoor`；每个 Casdoor 实例使用独立的数据库容器名、密码与持久化目录。已有非空依赖设置优先保留。
- `start` 和 `update` 通过 ParadeDB 服务生成的 `PARADEDB_DSN` 渲染 app.conf。Compose 使用数据库服务的健康检查控制 Casdoor 启动顺序；容器间连接使用 ParadeDB 容器名和内部端口 `5432`。
- Casdoor settings 仍使用 Bash 语法。ParadeDB DSN 由服务 CLI 负责编码，应用配置仅检查 Casdoor 直接使用的数据库名格式。
- `app.conf` 内容摘要作为 Compose label；配置变化后再次运行 `start` 会触发应用容器更新。生成 YAML 仅保存环境变量引用。
- 应用数据位于 `data/<INSTANCE_NAME>_data`，ParadeDB 数据目录由 `settings_casdoor_paradedb.conf` 中的实例名决定，默认是 `data/<INSTANCE_NAME>_postgres_data`。`rm` 和单独删除容器不删除这些目录，随后运行 `start` 可恢复。
- 既有应用配置中的 `PARADEDB_CONF` 非空时保留原值，不自动重命名依赖配置；手动迁移旧文件名时需同步修改该字段。
- PostgreSQL 的初始账号、密码和数据库名只在空数据目录首次启动时生效。保留数据库数据时不能仅修改 settings 来重置凭据。
- CLI 检查 Casdoor 和 ParadeDB 容器归属；同名容器属于其他 Compose 项目或服务时拒绝操作。外接数据库切换不属于当前默认编排流程。

## 4. 快速执行

默认配套部署无需先启动独立基础服务，也无需手工填写数据库连接：

```bash
cd deploy_apps/casdoor
bash cli.sh init
bash cli.sh start
```

如需接入预先创建的共享网络，在应用 settings 中填写 `DOCKER_NETWORK` 后重新运行 `init`。需要更新镜像或清理本实例时：

```bash
# Pull and apply the configured app and database images.
bash cli.sh update
bash cli.sh stop
bash cli.sh rm
# DANGER: delete this instance's app and ParadeDB data.
bash cli.sh purge
# DANGER: also remove this instance's settings and generated files.
bash cli.sh reset
```

## 5. 命令解释

#### init

生成或补齐应用 settings，调用 ParadeDB `init --config-only` 准备默认数据库 settings，再用 ParadeDB `render` 组合服务片段与 Casdoor 应用片段，预建应用和数据库数据目录。保留已有非空值和密码，不启动容器。

#### start

读取应用与 ParadeDB settings，通过 ParadeDB `env` 获取专属变量和 DSN，生成 app.conf 与总 YAML，再执行本项目 `docker compose up -d`。首次启动时 PostgreSQL 创建数据库与账号，Casdoor 初始化业务表。

#### up

依次执行 `init` 和 `start`。

#### update

重新读取配置、生成 app.conf 与总 YAML，拉取并应用 Casdoor 和 ParadeDB 镜像；保留配置、凭据和数据。

#### stop

停止本 Compose 项目中的 Casdoor 和 ParadeDB，保留容器及持久化数据。

#### rm

删除本 Compose 项目的应用、数据库容器和私有网络，保留 settings 与 bind mount 数据；external 共享网络不删除。

#### purge

危险操作：先执行 `rm`，再删除本实例的应用和 ParadeDB 数据目录，保留 settings、生成 YAML 和 app.conf。

#### reset

危险操作：先执行 `purge`，再删除当前 `--conf` 对应的应用 settings、总 YAML、生成的 Casdoor 配置目录，以及解析后位于应用配置目录内、且使用 `settings_paradedb.conf` 或 `settings_casdoor_paradedb.conf` 默认名称的 ParadeDB settings 和对应 `.compose.yaml`。自定义依赖配置及 `PARADEDB_CONF` 指向配置目录外部时均保留。

#### network ls

只读显示配置的共享网络或 Compose 私有网络，不创建、接入或删除网络。

`--conf PATH` 指定应用配置和数据落点，父目录须预先存在；`--name NAME` 仅在首次生成应用 settings 时生效。CLI、hooks 和模板从脚本目录读取。ParadeDB settings 路径由 `PARADEDB_CONF` 指定，默认与应用 settings 同目录。

## 6. 升级、备份与复制恢复

`update` 按应用 settings 和 ParadeDB settings 中的镜像字段拉取并应用镜像；默认标签可能滚动更新，可使用固定版本或 digest。升级前备份 Casdoor 配置及业务数据库；Casdoor 负责业务表结构迁移，脚本不执行 PostgreSQL 跨主版本数据迁移。

停止整套服务后，复制应用 CLI、hooks、templates、应用及 ParadeDB settings（新实例默认为 `settings_casdoor_paradedb.conf`）、生成 YAML、`data/<INSTANCE_NAME>_config`、`data/<INSTANCE_NAME>_data` 和 ParadeDB 数据目录。还需携带 `deploy_services/paradedb` 的 CLI、hooks 和模板并保留其相对路径。配置和数据库数据须一并保留；运行中的 PostgreSQL 数据目录不能直接作为一致性备份。

恢复时使用兼容的 PostgreSQL 主版本，保留原实例名、数据库凭据和数据目录后运行 `start`。默认私有网络由 Compose 创建；配置了 `DOCKER_NETWORK` 时需提前准备该共享网络。使用外置 `--conf` 时同时携带对应应用脚本和模板。
