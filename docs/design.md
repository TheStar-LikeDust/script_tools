# 设计文档

## 服务设计理念 (Service Design)

本文件说明“一个服务 / 一个目录”如何组织与部署。三个基础服务和五个应用均以 Docker Compose 为容器编排边界。

### 1. 目录即服务 (Service as a Directory)

一个服务运行所需的全部元素都内聚在它专属的文件夹里：控制脚本 `cli.sh`、可选的服务特殊操作 `hooks.sh`、配置模板 `templates/*.tpl`、生成的 `settings_<服务名>.conf`、生成的 Compose YAML、持久化数据 `./data`。停止服务或完成一致性备份后，可打包拷贝该目录迁移；共享基础服务仍从自己的服务目录迁移。

职责分层：`cli.sh` 负责配置初始化、随机密钥生成和生命周期编排；Docker Compose 管理容器。`hooks.sh` 承载服务片段、环境变量和连接串生成、应用依赖组合、Casdoor 的 app.conf 渲染、New API 管理员初始化，以及 LobeHub 的 JWKS 和 RustFS 初始化调用。RustFS 的目录属主、Bucket、用户与策略逻辑只在服务 hooks 中实现。详见 [命令设计理念](#命令设计理念-cli-command-design)。

路径锚定：`SCRIPT_DIR` 是 CLI 所在目录，用于定位 templates 和可选 hooks；`CONF_DIR` 是 settings 所在目录，用于定位生成 YAML 和本实例数据，默认等于 `SCRIPT_DIR`。Compose 使用 `CONF_DIR` 作为项目目录，数据挂载采用相对路径。`--conf` 可指定其他位置，其父目录须预先存在。

命令边界：八个 Compose 部署均支持 `init/start/up/update/stop/rm/purge/reset`，五个应用另提供只读 `network ls`。三个基础服务提供只读 `render/env`；RustFS 还提供 `prepare-data/resource-init`。宿主机工具使用 `install/start/stop/rm` 管理软件、运行态和本工具生成的配置；`rm` 不卸载软件且保留用户数据。Certbot 是一次性命令，仅提供 `install/start`。

源文件与生成物的区分：

- 源文件（纳入版本管理）：`cli.sh`、有实际用途的 `hooks.sh`、`templates/*.tpl`、该服务的说明文档。
- 生成物（不提交，由 `.gitignore` 忽略）：`settings_<服务名>.conf`、`<服务名>.compose.yaml`、应用生成的附属配置、各服务的 `data/`。

独立服务配置命名为 `settings_<服务名>.conf`，应用主配置命名为 `settings_<应用名>.conf`，模板为 `templates/settings_<应用名>.conf.tpl`。应用配套依赖配置命名为 `settings_<应用名>_<服务名>.conf`，例如 New API 的 `settings_newapi_paradedb.conf`；独立部署 ParadeDB 时仍使用 `settings_paradedb.conf`。应用与依赖配置分开保存：Casdoor 共两份，New API、Sub2API 共三份，LobeHub 共四份。应用记录 `PARADEDB_CONF`、`REDIS_CONF`、`RUSTFS_CONF` 中实际需要的路径，并通过服务接口获取连接信息。

`settings_<服务名>.conf` 含随机密钥/密码，属于本地资产：既不提交，也不会被 `purge` 删除；迁移时与 `data/` 一起打包。

### 2. 三层架构

- `deploy_services/`：ParadeDB、RustFS、Redis 各自维护配置、凭证、Compose 片段和连接信息，同时支持独立部署和应用组合。
- `deploy_apps/`：四个应用复用服务接口默认部署专属依赖，父 Compose 项目统一管理。Casdoor 使用 PostgreSQL，New API、Sub2API 使用 PostgreSQL 与 Redis，LobeHub 另加 RustFS。Open WebUI 保留本地 SQLite 和现有手工外接配置。
- `tools/`：宿主机工具，包括 code-server、Nginx、Certbot 和 Docker 防火墙配置。常驻工具使用 `install/start/stop/rm`；Certbot 只使用 `install/start`。`rm` 删除本工具实例配置，不卸载系统软件或删除用户数据。Docker 防火墙规则由本地 CLI 写入 UFW 配置，不下载外部脚本。具体命令和清理范围见各工具说明。

### 3. 编排方式：Compose 与薄 CLI

容器编排由 Docker Compose 负责，`cli.sh` 只做配置和服务专属操作：

- `init` 先通过服务 `init --config-only` 准备全部 settings，再组合 YAML 和创建本地数据目录；不访问服务、不启动容器。三个基础服务均支持只生成配置的模式。
- `start` 刷新 YAML 并由 Compose 启动实例。PostgreSQL 在空数据目录中创建账号和数据库，Redis 持久化数据。LobeHub 先启动依赖，调用 RustFS `resource-init` 后启动应用。New API 等待 HTTP 接口后初始化管理员，成功保存标记、重复启动跳过；失败返回错误并保留已启动容器。
- `update` 执行 `docker compose pull` 后再次 `up -d`，保留配置、凭证和数据。
- `stop/rm/purge/reset` 只管理本 Compose 项目。`rm` 保留数据和配置，`purge` 删除本实例整套数据，`reset` 再删除本实例配置及生成物；目录外依赖 settings 保留。独立基础服务不参与应用清理，bind mount 按明确路径删除。

三个基础服务的 `templates/compose.yaml.tpl` 只维护各自服务片段；独立部署和 `render` 使用同一入口。应用组合 `services:`、依赖片段、自身片段及顶层网络，不复制基础服务的启动参数、挂载和健康检查。生成的 `<应用名>.compose.yaml` 不作为手工维护入口。

四个应用先通过 `init --config-only --conf PATH` 准备或读取全部 settings，再调用 `env/render`。默认各份配置放在同一目录，总 Compose 的相对挂载始终以应用 `CONF_DIR` 为准。显式指定目录外的依赖配置不改变这个数据位置，也不表示外接已运行服务。不得再对这些组合配置调用服务 CLI 的独立启停或清理命令。

默认使用 Compose 私有网络，PostgreSQL、Redis 使用容器名和内部端口，不发布宿主机端口。需要共享网络时由管理员预建 `DOCKER_NETWORK`，父项目以 `external: true` 接入。容器内 `localhost` 指向自身；本轮不实现外接服务切换。

### 4. 配置注入：Bash settings 作为权威来源

`cli.sh` 以 Bash 方式读取 `settings_<服务名>.conf`，再导出变量供 Compose 插值；Compose 命令显式使用 `--env-file /dev/null`，避免误读目录中其他 `.env` 文件。settings 文件不是 Compose `env_file`，其中的引号、注释和 Bash 语法必须保持有效。

服务 settings 仍使用 `INSTANCE_NAME`、`IMAGE` 等名称，由服务 CLI 在独立进程读取；`env` 输出经过 Bash 转义的 `PARADEDB_*`、`REDIS_*`、`RUSTFS_*` 变量。应用确认成功后才加载输出，不能整体 source 服务 settings。`PARADEDB_DSN` 使用实际容器名、5432 和 `sslmode=disable`，服务负责 URL 编码；`REDIS_URL` 使用容器名、6379 和 `env --db N` 指定的逻辑库；`RUSTFS_ENDPOINT` 使用容器名和 9000。派生连接串不重复保存。

初始化参数的优先级为已有非空配置、调用方注入值、默认或随机生成值。新配置可注入名称、镜像、宿主机端口、端口发布开关和网络，ParadeDB 还可注入数据库名、账号和密码；重复初始化不覆盖已有凭证。服务配置中的 `DB_PORT`、`REDIS_PORT` 是宿主机映射端口，不用于默认容器间连接串。

密码、密钥和包含空格或 `$` 的值需在 settings 中使用单引号并按 Bash 规则转义。例如原值 `a'b$ c` 写为 `DB_PASSWORD='a'\''b$ c'`。只读取可信的 settings，它是可执行的 Bash 配置。密钥不写入版本库；生成的 Compose YAML 只保留变量引用。Casdoor 的 app.conf 按应用需要保存连接凭证并限制文件权限。配置变更后再次执行 `start` 或 `up`，由 Compose 重新创建受影响的容器。

数据库字段统一由 ParadeDB settings 维护；应用消费 DSN 或将服务导出字段映射到自身环境变量。`POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD` 只初始化空数据目录，修改配置不会重置已有数据库密码。应用镜像负责业务表和迁移。Redis 默认无认证，不生成密码，逻辑库和键前缀不提供权限隔离。

LobeHub 的 `APP_URL` 默认由 `LOBECHAT_PORT` 生成 localhost 地址，初始 `AUTH_ALLOWED_EMAILS` 默认生成随机的 `.invalid` 邮箱；两者可由初始化参数或 settings 覆盖。浏览器和容器均可访问的 `S3_ENDPOINT` 仍须提供，启动时检查缺项。内部 S3 地址由 RustFS 服务导出，应用 settings 保存专用 S3 凭证，管理员凭证只保存在服务配置中。Bucket、用户和策略在启动阶段创建，CORS 暂留待处理。模型和 OAuth 等外部凭证不生成占位值。

### 5. 实例命名与多开隔离 (INSTANCE_NAME)

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

### 6. 配置与数据沙箱化 (--conf)

基础服务和应用的 `cli.sh` 提供两个通用参数，使同一脚本可以管理多个独立 Compose 项目：

- `--conf PATH`：指定该实例的 `settings_<服务名>.conf` 位置（默认 `<脚本目录>/settings_<服务名>.conf`）。Compose YAML、应用及配套依赖数据均由配置文件所在目录推导，具体后缀见第 5 节。
- `--name NAME`：`init` 时写入完整实例名（默认自动 `<服务名>_<4位时间戳>`），用于 Compose 项目名、容器名和数据目录。

应用通过明确的配置路径调用服务接口，不扫描或任选已有容器。备份恢复需携带应用与所用服务的 CLI、hooks、templates，保留相对目录结构，并保存全部 settings、密钥、YAML 和数据。RustFS 归属标记随其数据目录保存，重启或 `docker rm` 后仍可继续初始化。旧版单配置和旧数据不做自动迁移；不能直接复制运行中的数据库作为一致性备份。

### 7. 随机化默认凭证与账户名

由脚本提供的初始密码、应用密钥和 Access Key 在 `init` 阶段随机生成并保存到 settings。Sub2API、Open WebUI、New API 的初始管理员账号也采用随机值。New API、ParadeDB、Redis 以及其他应用仅补齐缺失或空的默认字段，保留非空配置、密码和应用密钥；外部凭证仍由使用者提供。

约定：

- Sub2API、Open WebUI 的账户名使用 `random_letters()` 生成 4 位随机小写字母（如 `kxqp`）。
- New API 的 `NEWAPI_ADMIN_USERNAME` 使用 8 位随机十六进制字符串，`NEWAPI_ADMIN_PASSWORD` 使用 16 位随机 Base64 字符串；首次 `start/up` 通过 `hooks.sh` 向 `/api/setup` 提交，配置不用于重置已有管理员。
- 同一随机串可同时作账户名与邮箱本地名：邮箱由“随机串 + 固定后缀”拼接（如 `kxqp@sub2api.local`、`kxqp@example.com`），用户名直接取该随机串。范例：`deploy_apps/sub2api`（`ADMIN_EMAIL`）、`deploy_apps/openwebui`（`WEBUI_ADMIN_NAME` 与 `WEBUI_ADMIN_EMAIL` 共用同一随机串）。
- 随机值在 `init` 时一次性写入 `settings_<服务名>.conf`，后续生命周期统一从该文件读取，重复初始化不会重新生成密钥，初始账户信息从本地 settings 查阅。

有意例外：

- 由应用本体创建或交互设置的管理员（如 Casdoor）按应用自身流程管理。
- LobeHub 通过注册流程创建用户，`AUTH_ALLOWED_EMAILS` 默认生成随机 `.invalid` 地址用于初始注册；缺失 JWKS 在 `start/update` 生成一次并保存。
- 独立 ParadeDB 默认管理员名为 `postgres`；配套 PostgreSQL 的账号与密码由服务 settings 维护。RustFS 服务 settings 保存管理凭证，LobeHub 使用仅访问自身 Bucket 的专用用户；不扩展共享 Redis ACL 或外接依赖管理。

## 命令设计理念 (CLI Command Design)

本文件说明各服务目录下 cli.sh 的命令规范、文件职责分层与设计原因。`deploy_services/` 与 `deploy_apps/` 下的服务遵循统一的命令集、文件分层与行为约定。常驻宿主机工具使用 `install/start/stop/rm`；`rm` 只删除自身生成配置，不清理用户数据或卸载软件。Certbot 是一次性命令，只提供 `install/start`。

### 1. 设计思路

脚本工具的设计基于以下核心理念：

- 目录即服务 (Service as a Directory)：服务的运维脚本、配置、数据目录均内聚在同一文件夹下，停止服务或完成一致性备份后拷贝目录即带走本服务资产；外部依赖单独备份。
- Compose 生命周期：Compose 声明容器、网络、端口、环境变量和相对路径 bind mount；cli.sh 生成配置并调用 Compose。
- 职责分层 (Separation by File)：cli.sh 负责配置初始化、随机密钥生成及专属操作的调用；Compose 管理容器生命周期。服务专属的片段渲染、连接串生成、等待与初始化请求放在 hooks.sh，不级联启停或清理共享基础服务。
- 配套依赖：Casdoor、LobeHub、New API、Sub2API 均通过基础服务的配置、环境导出与片段接口组合自己的 Compose 项目。应用管理整套实例，独立部署的基础服务仍由其自身 CLI 管理。
- 配置与数据分离：脚本本身无状态，独立服务配置落盘到 `settings_<服务名>.conf`，应用主配置落盘到 `settings_<应用名>.conf`，应用配套依赖配置使用 `settings_<应用名>_<服务名>.conf`，应用及配套数据库、缓存、对象存储数据持久化到配置目录下的 `data/`。外部资源另行管理。

### 2. 文件分层与职责

Compose 服务的部署定义按职责拆分：

- cli.sh（必选）：解析参数、生成 settings，并调用 hooks 将生命周期映射到本 Compose 项目。三个基础服务额外分发只读 `render/env`；RustFS 分发 `prepare-data/resource-init`。
- `templates/compose.yaml.tpl`（必选）：三个基础服务只维护自己的服务片段，独立部署与应用组合复用同一模板。四个组合应用的模板只声明应用本身；顶层 `services:`、网络和依赖片段由组合函数生成。
- `templates/settings_<服务名>.conf.tpl`（需要配置初始化时）：提供 Bash 配置模板。生成的 `settings_<服务名>.conf` 保存本实例的设置与凭证。
- hooks.sh：由 CLI 直接加载和调用。基础服务在此实现片段、连接信息及特殊操作，应用在此组合依赖并处理专属初始化：Casdoor 渲染 app.conf，New API 初始化管理员，LobeHub 生成 JWKS、调用 RustFS 目录准备和资源初始化。RustFS 的属主、Bucket、用户和策略逻辑只实现一次，不复制到应用。

settings 文件是 Bash 配置，不是 Compose `env_file`。cli.sh source 后导出变量供 Compose 插值；生成 YAML 不写入密码或密钥。组合调用方通过服务 CLI 的 `env` 获取带前缀的变量，不直接 source 其他服务 settings，避免覆盖同名字段。

### 3. 脚本结构

为避免遮蔽系统命令（如 rm），并保持各服务行为一致，cli.sh 自上而下采用五段式结构，且段落分隔统一使用英文注释与轻量虚线。具体可见以下伪代码：

```bash
#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Parse instance options.
CONF_FILE=""
NAME_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Locate source templates and instance files separately.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_<服务名>.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
IMAGE="..."
CONF_BASENAME="$(basename "$CONF_FILE")"
COMPOSE_BASENAME="${CONF_BASENAME#settings_}"
COMPOSE_FILE="$CONF_DIR/${COMPOSE_BASENAME%.conf}.compose.yaml"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
# Load settings, validate required fields and check container ownership.
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { ... }
load_settings() { ... }
save_setting() { ... }
complete_settings() { ... }
require_connections() { ... }
require_managed_container() { ... }
compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
# Generate this service's settings and Compose definition.
generate_settings() { ... }
generate_compose() { ... }

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
# Each lifecycle command owns only this Compose project.
do_init() {
    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    complete_settings
    load_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data"
}

do_start() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data"
    compose up -d
}

do_update() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data"
    compose pull
    compose up -d
}

do_stop() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    compose stop
}

do_rm() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    compose down
}
do_purge() { do_rm; remove_this_project_data; }
do_reset() { do_purge; rm -f -- "$CONF_FILE" "$COMPOSE_FILE"; }
do_help()  { ... }

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init; do_start ;;
    update)  do_update ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    reset)   do_reset ;;
    *)       do_help ;;
esac
```

以上只展示生命周期骨架。四个组合应用实际先执行 `prepare_dependency_settings`、`load_dependency_environment`，再调用 hooks 中的 `render_compose`，使用各依赖 settings 的实例名准备数据目录。`load_settings` 读取本应用的可信 Bash 配置；`complete_settings` 只补齐空字段，三个基础服务遵循相同规则。调用服务 `env` 须先确认成功再加载带前缀的输出。Open WebUI 保留现有流程。

Casdoor 在 `start/update` 渲染 app.conf；LobeHub 在这两个阶段补齐 JWKS、调用 RustFS `prepare-data`。没有宿主机 Node.js 时，JWKS 使用一次性应用容器生成，不在 `init` 执行。LobeHub 先启动 PostgreSQL、Redis、RustFS，再调用 `resource-init`，成功后启动应用；失败返回错误并保留已启动依赖。

New API 的 `init` 生成并保存缺失的管理员凭证；`start` 在 `compose up -d` 后调用 `hooks.sh` 的 `initialize_admin`，`up` 通过 `start` 复用该流程。hook 等待本机 HTTP 接口后发送初始化 POST，成功才写入 `data/<INSTANCE_NAME>_data/.admin_initialized`，重复启动检测标记后跳过。失败时命令返回非零状态，保留容器且不写标记；已手工初始化但无标记的旧实例也按接口错误处理。`rm` 保留标记，`purge/reset` 随应用数据清理；`update` 不调用管理员初始化 hook。

### 4. 常见命令

日常生命周期命令按以下语义实现。Compose 管理的容器定义有变化时，重复运行 `start` 或 `up` 会应用新配置，无需先 `rm`。

- init：只生成本地配置、YAML 和目录。三个基础服务均支持参数注入及 `--config-only`；应用准备完全部 settings 后才组合总 YAML。LobeHub 默认生成 localhost 应用地址和随机 `.invalid` 初始注册邮箱；S3 地址可经初始化参数提供，缺项时提示填写。
- start：读取 settings、刷新 YAML 并执行 `docker compose up -d`，启动整套实例；New API 首次启动还执行管理员初始化 hook，已有标记时跳过。其他启动场景返回后查看应用日志或健康状态判断是否就绪。
- up：一键组合，等价于 `init` 加 `start`。
- update：拉取本项目应用及配套服务的镜像，再执行 `docker compose up -d`，保留配置、凭证和数据。
- stop：执行本 Compose 项目的 `stop`，保留容器、网络与数据。
- rm：执行本 Compose 项目的 `down`，移除应用及配套容器和私有网络，保留配置和 bind mount 数据；外部共享网络不会删除。单独 `docker rm` 删除容器也不会删除这些宿主机数据。
- purge：危险操作，在 `rm` 后按明确路径删除本实例应用及配套服务的数据目录，并保留 settings。必要时可用一次性 root 容器处理 bind mount 的属主权限；不得吞掉删除失败。
- reset：先 purge，再删除应用 settings、生成 YAML 和默认依赖 settings。Casdoor、LobeHub、Sub2API 同时删除实例目录内明确引用的自定义依赖 settings 及对应 YAML；目录外配置保留。Casdoor 还删除 app.conf 所在生成目录。保留源码、其他实例和独立基础服务。

重复 `init` 保留已有非空设置和密钥，补齐缺失默认字段；不迁移旧版单配置或数据。PostgreSQL 环境变量只初始化空数据目录，不能借修改 settings 更改已有密码。`stop/rm` 不要求依赖在线；容器项目或服务标记不匹配时拒绝操作。

生成 YAML 保留环境变量引用，直接调用 Compose 前必须由 CLI 的配置加载逻辑准备环境；常规操作使用 `cli.sh`。持久修改部署定义时编辑 `templates/compose.yaml.tpl`，生成 YAML 会在 `init/start/update` 时刷新。

查看实例状态使用 `docker ps -a --filter 'name=^/<INSTANCE_NAME>$'`，日志使用 `docker logs -f <INSTANCE_NAME>`，执行前替换实例名占位符。没有 `status` 命令；宿主机工具的命令以各自说明为准。

### 5. 特殊命令

部分特定场景使用或具有特殊约定的命令与参数：

- help：打印各命令的简短说明及用法。
- `--conf PATH`：将实例 settings、生成的 Compose YAML、应用及配套依赖数据定位到指定配置文件所在目录，父目录须已存在。CLI、存在的 hooks.sh 和模板仍位于脚本目录，复制恢复时需一并携带。
- `--name NAME`：`init` 时指定完整实例名，用于 Compose 项目名、容器名及数据目录。
- `DOCKER_NETWORK`：基础服务和应用加入管理员预先创建的共享 Docker 网络时使用。多个 Compose 项目可通过该网络互通；未配置时，各自使用私有网络。
- `network ls`：应用提供的只读网络查看命令，不代理创建、连接或删除共享网络。

#### 5.1 基础服务复用接口

ParadeDB、Redis 的 `init/up` 支持 `--image`、`--port`、`--publish-port true|false`、`--network`，ParadeDB 另支持数据库参数。RustFS 使用 `--publish-ports` 控制两个端口，增加 `--admin-port`、`--init-image`、`--access-key`、`--secret-key`。已有非空配置优先于参数、默认或随机值。三者的 `init --config-only` 均只生成或补齐 settings。

- `render --conf PATH [--service-name NAME]`：读取配置，向标准输出写入缩进后的单个服务片段，不包含顶层 `services:` 或 `networks:`。默认服务键名为 `paradedb`、`redis`；例如可用 `--service-name postgres` 接入应用的依赖名称。独立部署使用同一渲染入口。
- `env --conf PATH`：输出经 Bash 转义、带服务前缀的 `export`，包含 `PARADEDB_DSN`、`REDIS_URL` 或 `RUSTFS_ENDPOINT`。输出含凭证，不作为普通日志打印。连接信息使用实际容器名和内部端口，不重复保存在应用配置中。
- Redis 的 `env --db N`：指定 URL 中的逻辑库编号，默认 `0`；只影响连接串，不创建数据库或提供权限隔离。

`render/env` 只读配置并输出文本，诊断信息写入标准错误，不启动容器或连接服务。四个应用均通过明确路径复用；默认各份配置在同一目录，显式目录外配置不改变父项目的数据挂载位置。组合方负责顶层网络和错误返回，不调用服务的独立启停或清理命令。

#### 5.2 RustFS 启动阶段接口

- `prepare-data --conf PATH [--data-dir PATH]`：按配置镜像准备数据目录属主，应用明确传入父项目的数据路径；不启动 RustFS 服务。
- `resource-init --conf PATH --owner NAME --bucket NAME --access-key KEY --secret-key SECRET [--endpoint URL]`：使用指定 RustFS 容器的网络执行临时 `rc` 客户端，等待就绪后创建 Bucket、专用用户和策略。管理员凭证只从服务 settings 读取。

资源归属标记放在容器实际 `/data` 挂载源的 `.resources/` 中，包含所属实例、Bucket、访问键和密码摘要。在创建前记录归属，以便中途失败后继续；无标记的同名资源明确报错。客户端只有“资源不存在”允许进入创建流程，其余查询错误直接返回。协议依据、命令和镜像注意事项保存在 [RustFS 部署文档](deploy_services/rustfs.md)。

## 服务文档结构设计 (Service Doc Structure)

本文件规定 `docs/` 下每个服务说明文档的章节结构，以 `docs/deploy_services/paradedb.md` 为 Compose 服务基准模板。文档分别放入 `docs/deploy_services/`、`docs/deploy_apps/`、`docs/tools/`，与脚本目录对应。宿主机工具只描述其实际命令，不套用 Compose 生命周期。

文档约定：

- 标题必带序号：二级标题必须带数字序号（例如 `## 1. 简介`）。
- 精简通用信息：Compose 生命周期、目录即服务、配套依赖与独立服务的边界应在设计文档中统一说明，服务文档只保留该服务特有的配置与行为。
- 排版规范：正文避免使用加粗（`**`）与 emoji；列表用 `- 标题：说明` 的形式；代码/变量/路径用反引号包裹。
- 行文语气：面向最终用户说明，但避免使用“你”、“您的”等第二人称代词，采用客观专业的通用文档陈述语气（例如将“你需要修改”改为“需修改”）。

### 章节骨架

按以下顺序组织章节：

1. `# <服务名> 部署 (Deploy)`
2. `## 1. 简介`
3. `## 2. 核心配置项`
4. `## 3. 备注`
5. `## 4. 快速执行`
6. `## 5. 命令解释`
7. `## 6. 其他可选补充章节`

### 各章节要点

#### 1. 简介

这个服务是什么、提供什么功能、在架构中起什么作用，必须精简为一两句话并放在 `>` 引用块中。随后精简地总结该服务特有的部署逻辑和硬性要求（如自动生成密码、健康探测等），合并为一段紧凑的陈述。
不单列“功能”章节，不使用“需求/痛点 -> 方案”结构；通用行为引用设计文档。

#### 2. 核心配置项

每个配置文件使用三级标题单列，直接列出参数用途、默认值和必填条件。区分自动生成字段和使用者必须填写的字段、宿主机端口与容器端口、原始凭证与派生 URI；说明配套服务使用的镜像、数据目录和凭证，以及哪些变量已透传。支持初始化参数注入时，列明参数与配置字段的对应关系，以及已有非空配置、注入参数、默认值之间的优先级。

#### 3. 备注

放该服务特有的注意点（如配置文件渲染覆写机制、特殊的目录挂载、首登行为等），通用行为不要重复写。

#### 4. 快速执行

Compose 服务先给出 `init/start/update` 流程。四个配套应用均调用基础服务接口，文档列明生成的全部 settings、路径解析方式和启动顺序。LobeHub 需说明 localhost 地址与随机 `.invalid` 初始注册邮箱的默认行为，以及 S3 地址的初始化参数。`up` 用于必填配置已就绪的实例；清理命令标明数据、目录内配置和目录外配置的边界，代码示例注释使用英文。

提供复用接口的服务补充 `init --config-only`、`render`、`env` 示例，明确先准备全部配置再组合 YAML 的顺序。说明配置目录与相对挂载路径的关系，片段和环境变量输出由调用方消费；调用方须处理命令失败，不能把尚未接入接口的应用写成已自动复用。

#### 5. 命令解释

每条实际支持的命令使用独立四级小节，说明行为、保留资产与删除范围；须覆盖 `init/start/up/update/stop/rm/purge/reset`。内部 `compose` 示例需说明配置来源。应用 `init` 先准备全部配置再组合 YAML，不启动容器。LobeHub 的 JWKS、RustFS 属主及资源初始化属于启动阶段；New API 的管理员凭证在 `init` 生成，请求在 `start` hook 提交，文档说明标记、跳过及错误返回。`status` 不是标准命令。

三个基础服务须说明 `render/env` 契约：片段不含顶层 YAML、变量使用服务前缀、诊断写入标准错误、连接地址采用内部端口。`env` 含凭证，不引导直接 source 服务 settings。RustFS 另说明 `prepare-data/resource-init`、专用凭证、归属标记和失败重试；Redis 逻辑库仅区分数据。

#### 6. 其他补充

说明镜像版本、服务专属备份恢复、复制目录的范围和反代要求。复制范围须包括 CLI 实际依赖的 hooks.sh 和模板。应用密钥与数据库备份的对应关系必须明确，逐项说明默认配套数据位于配置目录下，独立外部数据另行备份；复制运行中的数据库目录不能作为一致性备份。

已查明的关键部署依据写入对应应用或服务文档，包含核对日期、官方来源链接、实际命令和版本限制。明确区分文档核对与真实运行结果，避免后续重复查询或把未运行的功能写成验收通过。

#### 服务特有 vs 通用

通用规则集中在本文件的“服务设计理念”和“命令设计理念”部分，服务文档按需引用。应用文档须说明默认配套依赖、连接生成方式、生命周期范围和持久化位置；仍支持的外部配置按实际行为说明。功能尚未接入时写明当前边界，不将手工修改连接字段描述为自动停用配套服务。保留明确约定的待处理限制，例如 LobeHub CORS；不保留废弃接口或已取消的工作清单。
