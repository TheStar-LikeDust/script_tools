# 服务设计理念 (Service Design)

本文件说明“一个服务 / 一个目录”如何组织与部署。三个基础服务和五个应用均以 Docker Compose 为容器编排边界。

## 1. 目录即服务 (Service as a Directory)

一个服务运行所需的全部元素都内聚在它专属的文件夹里：控制脚本 `cli.sh`、可选的服务特殊操作 `hooks.sh`、配置模板 `templates/*.tpl`、生成的 `settings_<服务名>.conf`、生成的 Compose YAML、持久化数据 `./data`。停止服务或完成一致性备份后，可打包拷贝该目录迁移；共享基础服务仍从自己的服务目录迁移。

职责分层：`cli.sh` 负责配置初始化、随机密钥生成和生命周期编排；Docker Compose 管理容器。`hooks.sh` 承载服务片段、环境变量和连接串生成、应用依赖组合、Casdoor 的 app.conf 渲染、New API 管理员初始化，以及 LobeHub 的 JWKS 和 RustFS 初始化调用。RustFS 的目录属主、Bucket、用户与策略逻辑只在服务 hooks 中实现。详见 [命令规范](command.md)。

路径锚定：`SCRIPT_DIR` 是 CLI 所在目录，用于定位 templates 和可选 hooks；`CONF_DIR` 是 settings 所在目录，用于定位生成 YAML 和本实例数据，默认等于 `SCRIPT_DIR`。Compose 使用 `CONF_DIR` 作为项目目录，数据挂载采用相对路径。`--conf` 可指定其他位置，其父目录须预先存在。

命令边界：八个 Compose 部署均支持 `init/start/up/update/stop/rm/purge/reset`，五个应用另提供只读 `network ls`。三个基础服务提供只读 `render/env`；RustFS 还提供 `prepare-data/resource-init`。宿主机工具按自身职责提供命令。

源文件与生成物的区分：

- 源文件（纳入版本管理）：`cli.sh`、有实际用途的 `hooks.sh`、`templates/*.tpl`、该服务的说明文档。
- 生成物（不提交，由 `.gitignore` 忽略）：`settings_<服务名>.conf`、`<服务名>.compose.yaml`、应用生成的附属配置、各服务的 `data/`。

实例配置统一命名为 `settings_<服务名>.conf`，模板为 `templates/settings_<服务名>.conf.tpl`。应用与依赖配置分开保存：Casdoor 共两份，New API、Sub2API 共三份，LobeHub 共四份。应用记录 `PARADEDB_CONF`、`REDIS_CONF`、`RUSTFS_CONF` 中实际需要的路径，并通过服务接口获取连接信息。

`settings_<服务名>.conf` 含随机密钥/密码，属于本地资产：既不提交，也不会被 `purge` 删除；迁移时与 `data/` 一起打包。

## 2. 三层架构

- `deploy_services/`：ParadeDB、RustFS、Redis 各自维护配置、凭证、Compose 片段和连接信息，同时支持独立部署和应用组合。
- `deploy_apps/`：四个应用复用服务接口默认部署专属依赖，父 Compose 项目统一管理。Casdoor 使用 PostgreSQL，New API、Sub2API 使用 PostgreSQL 与 Redis，LobeHub 另加 RustFS。Open WebUI 保留本地 SQLite 和现有手工外接配置。
- `tools/`：宿主机工具，包括 code-server、Nginx、Certbot 和 Docker 防火墙配置。该层按工具自身需要设计命令；支持的命令和本地文件位置见各工具说明。

## 3. 编排方式：Compose 与薄 CLI

容器编排由 Docker Compose 负责，`cli.sh` 只做配置和服务专属操作：

- `init` 先通过服务 `init --config-only` 准备全部 settings，再组合 YAML 和创建本地数据目录；不访问服务、不启动容器。三个基础服务均支持只生成配置的模式。
- `start` 刷新 YAML 并由 Compose 启动实例。PostgreSQL 在空数据目录中创建账号和数据库，Redis 持久化数据。LobeHub 先启动依赖，调用 RustFS `resource-init` 后启动应用。New API 等待 HTTP 接口后初始化管理员，成功保存标记、重复启动跳过；失败返回错误并保留已启动容器。
- `update` 执行 `docker compose pull` 后再次 `up -d`，保留配置、凭证和数据。
- `stop/rm/purge/reset` 只管理本 Compose 项目。`rm` 保留数据和配置，`purge` 删除本实例整套数据，`reset` 再删除本实例配置及生成物；目录外依赖 settings 保留。独立基础服务不参与应用清理，bind mount 按明确路径删除。

三个基础服务的 `templates/compose.yaml.tpl` 只维护各自服务片段；独立部署和 `render` 使用同一入口。应用组合 `services:`、依赖片段、自身片段及顶层网络，不复制基础服务的启动参数、挂载和健康检查。生成的 `<应用名>.compose.yaml` 不作为手工维护入口。

四个应用先通过 `init --config-only --conf PATH` 准备或读取全部 settings，再调用 `env/render`。默认各份配置放在同一目录，总 Compose 的相对挂载始终以应用 `CONF_DIR` 为准。显式指定目录外的依赖配置不改变这个数据位置，也不表示外接已运行服务。不得再对这些组合配置调用服务 CLI 的独立启停或清理命令。

默认使用 Compose 私有网络，PostgreSQL、Redis 使用容器名和内部端口，不发布宿主机端口。需要共享网络时由管理员预建 `DOCKER_NETWORK`，父项目以 `external: true` 接入。容器内 `localhost` 指向自身；本轮不实现外接服务切换。

## 4. 配置注入：Bash settings 作为权威来源

`cli.sh` 以 Bash 方式读取 `settings_<服务名>.conf`，再导出变量供 Compose 插值；Compose 命令显式使用 `--env-file /dev/null`，避免误读目录中其他 `.env` 文件。settings 文件不是 Compose `env_file`，其中的引号、注释和 Bash 语法必须保持有效。

服务 settings 仍使用 `INSTANCE_NAME`、`IMAGE` 等名称，由服务 CLI 在独立进程读取；`env` 输出经过 Bash 转义的 `PARADEDB_*`、`REDIS_*`、`RUSTFS_*` 变量。应用确认成功后才加载输出，不能整体 source 服务 settings。`PARADEDB_DSN` 使用实际容器名、5432 和 `sslmode=disable`，服务负责 URL 编码；`REDIS_URL` 使用容器名、6379 和 `env --db N` 指定的逻辑库；`RUSTFS_ENDPOINT` 使用容器名和 9000。派生连接串不重复保存。

初始化参数的优先级为已有非空配置、调用方注入值、默认或随机生成值。新配置可注入名称、镜像、宿主机端口、端口发布开关和网络，ParadeDB 还可注入数据库名、账号和密码；重复初始化不覆盖已有凭证。服务配置中的 `DB_PORT`、`REDIS_PORT` 是宿主机映射端口，不用于默认容器间连接串。

密码、密钥和包含空格或 `$` 的值需在 settings 中使用单引号并按 Bash 规则转义。例如原值 `a'b$ c` 写为 `DB_PASSWORD='a'\''b$ c'`。只读取可信的 settings，它是可执行的 Bash 配置。密钥不写入版本库；生成的 Compose YAML 只保留变量引用。Casdoor 的 app.conf 按应用需要保存连接凭证并限制文件权限。配置变更后再次执行 `start` 或 `up`，由 Compose 重新创建受影响的容器。

数据库字段统一由 ParadeDB settings 维护；应用消费 DSN 或将服务导出字段映射到自身环境变量。`POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD` 只初始化空数据目录，修改配置不会重置已有数据库密码。应用镜像负责业务表和迁移。Redis 默认无认证，不生成密码，逻辑库和键前缀不提供权限隔离。

LobeHub 的 `APP_URL`、浏览器和容器均可访问的 `S3_ENDPOINT`、真实 `AUTH_ALLOWED_EMAILS` 可由初始化参数或 settings 提供；启动时检查缺项。内部 S3 地址由 RustFS 服务导出，应用 settings 保存专用 S3 凭证，管理员凭证只保存在服务配置中。Bucket、用户和策略在启动阶段创建，CORS 暂留待处理。模型和 OAuth 等外部凭证不生成占位值。

## 5. 实例命名与多开隔离 (INSTANCE_NAME)

实例名由 `cli.sh init` 首次生成 `settings_<服务名>.conf` 时分配，默认采用时间戳后缀；同机多开应显式用 `--name` 指定唯一名称。Compose 项目名需匹配 `[a-z0-9][a-z0-9_-]*`：

- 独立部署：`<服务名>_<4位时间戳>`，如 `paradedb_8421`。
- 由管理员命名的实例：`--name` 指定可读的完整实例名，同时决定配套容器和数据目录前缀。

派生命名约定：

- 应用或独立基础服务容器名：直接等于 `INSTANCE_NAME`。
- 配套容器默认名：`${INSTANCE_NAME}_postgres`、`${INSTANCE_NAME}_redis`、`${INSTANCE_NAME}_rustfs`，实际读取服务 settings。RustFS 资源初始化使用自动删除的临时客户端容器。
- 应用或独立基础服务持久化目录：`<配置文件所在目录>/data/${INSTANCE_NAME}_data`。
- 配套持久化目录：同一配置目录下的 `data/${INSTANCE_NAME}_postgres_data`、`data/${INSTANCE_NAME}_redis_data`、`data/${INSTANCE_NAME}_rustfs_data`。
- 渲染配置目录（如 Casdoor 的 app.conf）：`data/${INSTANCE_NAME}_config`，与数据目录平级，避免配置混入运行数据。

普通 `init/start` 预建挂载目录，三个基础服务的 `init --config-only` 只处理 settings。LobeHub 在 `start/update` 调用 RustFS `prepare-data` 并补齐 JWKS；Casdoor 在这两个阶段渲染 app.conf。每个实例使用独立配置目录和唯一名称，避免默认依赖配置文件重名。

## 6. 配置与数据沙箱化 (--conf)

基础服务和应用的 `cli.sh` 提供两个通用参数，使同一脚本可以管理多个独立 Compose 项目：

- `--conf PATH`：指定该实例的 `settings_<服务名>.conf` 位置（默认 `<脚本目录>/settings_<服务名>.conf`）。Compose YAML、应用及配套依赖数据均由配置文件所在目录推导，具体后缀见第 5 节。
- `--name NAME`：`init` 时写入完整实例名（默认自动 `<服务名>_<4位时间戳>`），用于 Compose 项目名、容器名和数据目录。

应用通过明确的配置路径调用服务接口，不扫描或任选已有容器。备份恢复需携带应用与所用服务的 CLI、hooks、templates，保留相对目录结构，并保存全部 settings、密钥、YAML 和数据。RustFS 归属标记随其数据目录保存，重启或 `docker rm` 后仍可继续初始化。旧版单配置和旧数据不做自动迁移；不能直接复制运行中的数据库作为一致性备份。

## 7. 随机化默认凭证与账户名

由脚本提供的初始密码、应用密钥和 Access Key 在 `init` 阶段随机生成并保存到 settings。Sub2API、Open WebUI、New API 的初始管理员账号也采用随机值。New API、ParadeDB、Redis 以及其他应用仅补齐缺失或空的默认字段，保留非空配置、密码和应用密钥；外部凭证仍由使用者提供。

约定：

- Sub2API、Open WebUI 的账户名使用 `random_letters()` 生成 4 位随机小写字母（如 `kxqp`）。
- New API 的 `NEWAPI_ADMIN_USERNAME` 使用 8 位随机十六进制字符串，`NEWAPI_ADMIN_PASSWORD` 使用 16 位随机 Base64 字符串；首次 `start/up` 通过 `hooks.sh` 向 `/api/setup` 提交，配置不用于重置已有管理员。
- 同一随机串可同时作账户名与邮箱本地名：邮箱由“随机串 + 固定后缀”拼接（如 `kxqp@sub2api.local`、`kxqp@example.com`），用户名直接取该随机串。范例：`deploy_apps/sub2api`（`ADMIN_EMAIL`）、`deploy_apps/openwebui`（`WEBUI_ADMIN_NAME` 与 `WEBUI_ADMIN_EMAIL` 共用同一随机串）。
- 随机值在 `init` 时一次性写入 `settings_<服务名>.conf`，后续生命周期统一从该文件读取，重复初始化不会重新生成密钥，初始账户信息从本地 settings 查阅。

有意例外：

- 由应用本体创建或交互设置的管理员（如 Casdoor）按应用自身流程管理。
- LobeHub 通过注册流程创建用户，`AUTH_ALLOWED_EMAILS` 留空提示填写真实邮箱或域名；缺失 JWKS 在 `start/update` 生成一次并保存。
- 独立 ParadeDB 默认管理员名为 `postgres`；配套 PostgreSQL 的账号与密码由服务 settings 维护。RustFS 服务 settings 保存管理凭证，LobeHub 使用仅访问自身 Bucket 的专用用户；不扩展共享 Redis ACL 或外接依赖管理。
