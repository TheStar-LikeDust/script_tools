# 命令设计理念 (CLI Command Design)

本文件说明各服务目录下 cli.sh 的命令规范、文件职责分层与设计原因。`deploy_services/` 与 `deploy_apps/` 下的服务遵循统一的命令集、文件分层与行为约定。（`tools/` 为宿主机级工具，命令集按工具自身需要定义，不受本规范约束，见 core.md 第 2 节。）

## 1. 设计思路

脚本工具的设计基于以下核心理念：

- 目录即服务 (Service as a Directory)：服务的运维脚本、配置、数据目录均内聚在同一文件夹下，停止服务或完成一致性备份后拷贝目录即带走本服务资产；外部依赖单独备份。
- Compose 生命周期：Compose 声明容器、网络、端口、环境变量和相对路径 bind mount；cli.sh 生成配置并调用 Compose。
- 职责分层 (Separation by File)：cli.sh 负责配置初始化、随机密钥生成和服务专属操作；Compose 管理容器生命周期。hooks.sh 仅承载确有需要的应用专属初始化，不级联启停或清理共享基础服务。
- 外部依赖：应用使用配置文件中的服务地址和凭证连接独立部署的基础服务，不拥有这些依赖的生命周期。
- 配置与数据分离：脚本本身无状态，运行期的全部配置落盘到 settings_<服务名>.conf，本地数据持久化到 data 目录，外部数据库、缓存和对象存储数据由其独立服务目录管理。

## 2. 文件分层与职责

Compose 服务的部署定义按职责拆分：

- cli.sh（必选）：解析 `--conf` / `--name`，生成 settings 和 Compose YAML，准备数据目录，并将 `init`、`start`、`update`、`stop`、`rm`、`purge`、`reset` 映射到本服务的 Compose 项目。
- `templates/compose.yaml.tpl`（Compose 服务必选）：声明本服务容器、环境变量和数据挂载；CLI 根据配置追加可选端口或 external 网络声明。模板可被人工复制复用，不引入动态编排框架。
- `templates/settings_<服务名>.conf.tpl`（需要配置初始化时）：提供 Bash 配置模板。生成的 `settings_<服务名>.conf` 保存本实例的设置与凭证。
- hooks.sh（可选）：仅承载有实际用途的应用专属操作，当前用于 Casdoor 的 app.conf 渲染。不使用空钩子或通用生命周期钩子分发。

settings 文件是 Bash 配置，不是 Compose `env_file`。cli.sh source 后导出变量供 Compose 插值；生成 YAML 不写入密码或密钥。

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
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
# Load settings, validate required fields and check container ownership.
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { ... }
load_settings() { ... }
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
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
}

do_start() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose up -d
}

do_update() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
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
do_purge() { do_rm; remove_this_service_data; }
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

以上是带外部依赖和本地数据的应用骨架，省略号按服务实现。`load_settings` 检查配置存在，以 `set -a`、`source <(sed 's/\r$//' "$CONF_FILE")`、`set +a` 读取并导出变量，再设置派生变量及校验实例名。Casdoor 在 `start/update` 渲染 app.conf；RustFS 准备数据属主；LobeHub 不创建本地数据目录。

## 4. 常见命令

日常生命周期命令按以下语义实现。Compose 管理的容器定义有变化时，重复运行 `start` 或 `up` 会应用新配置，无需先 `rm`。

- init：生成缺失的 settings、刷新 Compose YAML 并按需创建本服务数据目录，不启动常驻服务。LobeHub 无宿主机 Node.js 时可用一次性应用容器生成 JWKS。
- start：读取 settings、刷新 YAML 并执行 `docker compose up -d`；返回后查看应用日志或健康状态判断是否就绪。
- up：一键组合，等价于 `init` 加 `start`。
- update：执行 `docker compose pull`，再 `docker compose up -d`，保留配置、凭证和数据。
- stop：执行本 Compose 项目的 `stop`，保留容器、网络与数据。
- rm：执行本 Compose 项目的 `down`，移除本服务容器和私有网络，保留配置和 bind mount 数据；外部共享网络不会删除。
- purge：危险操作，在 `rm` 后仅删除本服务拥有的数据目录，并保留 settings。必要时可用一次性 root 容器处理 bind mount 的属主权限；不得吞掉删除失败。
- reset：先 purge，再删除本服务自己的 settings 和生成 YAML；Casdoor 还删除生成的 app.conf。不得删除其他服务配置或共享依赖。

`init` 不覆盖已有 settings，也不自动补写字段或依赖凭证，缺少的字段按模板人工补齐。应用 `start/update` 检查必需连接信息，`stop/rm` 不要求依赖在线。同名容器的 Compose 项目或服务标记不匹配时拒绝操作，应使用唯一实例名。

生成 YAML 保留环境变量引用，直接调用 Compose 前必须由 CLI 的配置加载逻辑准备环境；常规操作使用 `cli.sh`。持久修改部署定义时编辑 `templates/compose.yaml.tpl`，生成 YAML 会在 `init/start/update` 时刷新。

查看实例状态使用 `docker ps -a --filter 'name=^/<INSTANCE_NAME>$'`，日志使用 `docker logs -f <INSTANCE_NAME>`，执行前替换实例名占位符。没有 `status` 命令；宿主机工具的命令以各自说明为准。

## 5. 特殊命令

部分特定场景使用或具有特殊约定的命令与参数：

- help：打印各命令的简短说明及用法。
- `--conf PATH`：将实例 settings、生成的 Compose YAML 和数据目录定位到指定配置文件所在目录，父目录须已存在。CLI 和模板仍位于脚本目录，复制恢复时需一并携带。应用配置包含自身设置、密钥和依赖连接信息，不代表应用拥有这些依赖。
- `--name NAME`：`init` 时指定完整实例名，用于 Compose 项目名、容器名及数据目录。
- `DOCKER_NETWORK`：基础服务和应用加入管理员预先创建的共享 Docker 网络时使用。多个 Compose 项目可通过该网络互通；未配置时，各自使用私有网络。
- `network ls`：应用提供的只读网络查看命令，不代理创建、连接或删除共享网络。
