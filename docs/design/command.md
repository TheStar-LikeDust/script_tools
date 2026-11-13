# 命令设计理念 (CLI Command Design)

本文件说明各服务目录下 cli.sh 的命令规范、文件职责分层与设计原因。`deploy_services/` 与 `deploy_apps/` 下的服务遵循统一的命令集、文件分层与行为约定。（`tools/` 为宿主机级工具，命令集按工具自身需要定义，不受本规范约束，见 core.md 第 2 节。）

## 1. 设计思路

脚本工具的设计基于以下核心理念：

- 目录即服务 (Service as a Directory)：服务的运维脚本、配置、数据目录均内聚在同一文件夹下，停止服务或完成一致性备份后拷贝目录即带走本服务资产；外部依赖单独备份。
- Compose 生命周期：Compose 声明容器、网络、端口、环境变量和相对路径 bind mount；cli.sh 生成配置并调用 Compose。
- 职责分层 (Separation by File)：cli.sh 负责配置初始化、随机密钥生成及专属操作的调用；Compose 管理容器生命周期。服务专属的片段渲染、连接串生成、等待与初始化请求放在 hooks.sh，不级联启停或清理共享基础服务。
- 配套依赖：Casdoor、LobeHub、New API、Sub2API 均通过基础服务的配置、环境导出与片段接口组合自己的 Compose 项目。应用管理整套实例，独立部署的基础服务仍由其自身 CLI 管理。
- 配置与数据分离：脚本本身无状态，独立服务配置落盘到 `settings_<服务名>.conf`，应用主配置落盘到 `settings_<应用名>.conf`，应用配套依赖配置使用 `settings_<应用名>_<服务名>.conf`，应用及配套数据库、缓存、对象存储数据持久化到配置目录下的 `data/`。外部资源另行管理。

## 2. 文件分层与职责

Compose 服务的部署定义按职责拆分：

- cli.sh（必选）：解析参数、生成 settings，并调用 hooks 将生命周期映射到本 Compose 项目。三个基础服务额外分发只读 `render/env`；RustFS 分发 `prepare-data/resource-init`。
- `templates/compose.yaml.tpl`（必选）：三个基础服务只维护自己的服务片段，独立部署与应用组合复用同一模板。四个组合应用的模板只声明应用本身；顶层 `services:`、网络和依赖片段由组合函数生成。
- `templates/settings_<服务名>.conf.tpl`（需要配置初始化时）：提供 Bash 配置模板。生成的 `settings_<服务名>.conf` 保存本实例的设置与凭证。
- hooks.sh：由 CLI 直接加载和调用。基础服务在此实现片段、连接信息及特殊操作，应用在此组合依赖并处理专属初始化：Casdoor 渲染 app.conf，New API 初始化管理员，LobeHub 生成 JWKS、调用 RustFS 目录准备和资源初始化。RustFS 的属主、Bucket、用户和策略逻辑只实现一次，不复制到应用。

settings 文件是 Bash 配置，不是 Compose `env_file`。cli.sh source 后导出变量供 Compose 插值；生成 YAML 不写入密码或密钥。组合调用方通过服务 CLI 的 `env` 获取带前缀的变量，不直接 source 其他服务 settings，避免覆盖同名字段。

## 3. 脚本结构

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

## 4. 常见命令

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

## 5. 特殊命令

部分特定场景使用或具有特殊约定的命令与参数：

- help：打印各命令的简短说明及用法。
- `--conf PATH`：将实例 settings、生成的 Compose YAML、应用及配套依赖数据定位到指定配置文件所在目录，父目录须已存在。CLI、存在的 hooks.sh 和模板仍位于脚本目录，复制恢复时需一并携带。
- `--name NAME`：`init` 时指定完整实例名，用于 Compose 项目名、容器名及数据目录。
- `DOCKER_NETWORK`：基础服务和应用加入管理员预先创建的共享 Docker 网络时使用。多个 Compose 项目可通过该网络互通；未配置时，各自使用私有网络。
- `network ls`：应用提供的只读网络查看命令，不代理创建、连接或删除共享网络。

### 5.1 基础服务复用接口

ParadeDB、Redis 的 `init/up` 支持 `--image`、`--port`、`--publish-port true|false`、`--network`，ParadeDB 另支持数据库参数。RustFS 使用 `--publish-ports` 控制两个端口，增加 `--admin-port`、`--init-image`、`--access-key`、`--secret-key`。已有非空配置优先于参数、默认或随机值。三者的 `init --config-only` 均只生成或补齐 settings。

- `render --conf PATH [--service-name NAME]`：读取配置，向标准输出写入缩进后的单个服务片段，不包含顶层 `services:` 或 `networks:`。默认服务键名为 `paradedb`、`redis`；例如可用 `--service-name postgres` 接入应用的依赖名称。独立部署使用同一渲染入口。
- `env --conf PATH`：输出经 Bash 转义、带服务前缀的 `export`，包含 `PARADEDB_DSN`、`REDIS_URL` 或 `RUSTFS_ENDPOINT`。输出含凭证，不作为普通日志打印。连接信息使用实际容器名和内部端口，不重复保存在应用配置中。
- Redis 的 `env --db N`：指定 URL 中的逻辑库编号，默认 `0`；只影响连接串，不创建数据库或提供权限隔离。

`render/env` 只读配置并输出文本，诊断信息写入标准错误，不启动容器或连接服务。四个应用均通过明确路径复用；默认各份配置在同一目录，显式目录外配置不改变父项目的数据挂载位置。组合方负责顶层网络和错误返回，不调用服务的独立启停或清理命令。

### 5.2 RustFS 启动阶段接口

- `prepare-data --conf PATH [--data-dir PATH]`：按配置镜像准备数据目录属主，应用明确传入父项目的数据路径；不启动 RustFS 服务。
- `resource-init --conf PATH --owner NAME --bucket NAME --access-key KEY --secret-key SECRET [--endpoint URL]`：使用指定 RustFS 容器的网络执行临时 `rc` 客户端，等待就绪后创建 Bucket、专用用户和策略。管理员凭证只从服务 settings 读取。

资源归属标记放在容器实际 `/data` 挂载源的 `.resources/` 中，包含所属实例、Bucket、访问键和密码摘要。在创建前记录归属，以便中途失败后继续；无标记的同名资源明确报错。客户端只有“资源不存在”允许进入创建流程，其余查询错误直接返回。协议依据、命令和镜像注意事项保存在 [RustFS 部署文档](../deploy_services/rustfs.md)。
