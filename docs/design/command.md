# 命令设计理念 (CLI Command Design)

本文件说明各服务目录下 cli.sh 的命令规范、文件职责分层与设计原因。`deploy/` 与 `deploy_apps/` 下的服务遵循统一的命令集、文件分层与行为约定。（`tools/` 为宿主机级工具，命令集按工具自身需要定义，不受本规范约束，见 core.md 第 2 节。）

## 1. 设计思路

脚本工具的设计基于以下核心理念：
- 目录即服务 (Service as a Directory)：服务的运维脚本、配置、数据目录均内聚在同一文件夹下，拷贝目录即带走该服务全部资产。
- 纯 docker run 派发：不再依赖 docker compose，所有服务的生命周期均通过原生 docker run 管理。
- 职责分层 (Separation by File)：cli.sh 只保留最基础的生命周期骨架与本服务的 docker run；服务专属的特殊操作（级联依赖、附属配置渲染、组网）下沉到同目录可选的 hooks.sh；跨服务复用的选配能力（如容器网络）抽到项目级共享库 lib/。三者解耦，使简单服务保持极简，复杂服务的复杂度被隔离在 hooks.sh 中。
- 委托式级联 (Delegated Cascade)：复合服务将底层基础服务的 cli.sh 视作函数进行调用，通过参数隔离不同上层的实例数据。
- 配置与数据分离：脚本本身无状态，运行期的全部配置落盘到 settings.conf，所有数据固化在 data 目录，确保销毁容器不丢数据。

## 2. 文件分层与职责

每个服务的运维逻辑按职责拆成三层：

- cli.sh（必选，统一骨架）：服务的唯一操作入口与控制接口。承担参数解析、路径锚定、本服务 settings.conf 的渲染（generate_settings）、五个标准生命周期命令（init/start/stop/rm/purge）与 up 组合糖，以及本服务自身的 docker run。docker run 留在 cli.sh，允许各服务存在细微差异（镜像名、端口、挂载、`-e` 列表不同）。cli.sh 在各生命周期点被动回调 hooks.sh 中定义的同名钩子。
- hooks.sh（可选，服务特殊操作）：仅当服务有专属的特殊操作时才存在（典型为复合服务）。集中存放级联依赖的拉起与转发、附属配置（如 Casdoor 的 app.conf）的渲染、专属组网与依赖健康等待等，通过 on_init / on_start / on_stop / on_rm / on_purge / on_network 等钩子暴露，由 cli.sh 被动调用；未定义的钩子自动跳过。无特殊操作的基础服务（如 paradedb）不需要此文件。
- lib/*.sh（选配，项目级共享库）：跨服务复用的通用能力，目前为 lib/network.sh（容器网络的创建、连接、删除、查看）。由用到该能力的 hooks.sh 通过相对路径 source。其路径与项目仓库路径绑定，作为约定不注入到各服务目录内；仅依赖单目录自包含的简单服务本就不引用共享库。

钩子契约：
- cli.sh 顶部 `[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"`，并定义 `hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }`。
- hooks.sh 被 source 进 cli.sh 的同一 shell，与其共享变量（SCRIPT_DIR / CONF_DIR / INSTANCE_NAME / 已 source 的配置项）与工具函数。
- cli.sh 顶部声明 `HOOK_RUN_ARGS=()`；hooks.sh 的 on_start 可向其追加参数（如 `--network <net>`），cli.sh 的 docker run 以 `"${HOOK_RUN_ARGS[@]}"` 注入。这是 docker run 留在 cli.sh、又能被 hooks 影响的桥梁。

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

# 级联参数解析 (--conf, --name)，其余参数（如 --external）收集到 EXTRA_ARGS
CONF_FILE=""
NAME_OVERRIDE=""
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# 路径锚定与数据落点（CONF_DIR 为配置文件所在目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="..."
HOOK_RUN_ARGS=()   # hooks.sh 的 on_start 可填充，注入到 docker run

# 可选的服务特殊操作（级联依赖、附属配置、组网）；简单服务无此文件
[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
# 无副作用、可复用的逻辑
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { ... }
require_conf() { ... }

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
# 本服务 settings.conf 的渲染（填充的字段因服务而异）
generate_settings() { ... }

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
# 统一使用 do_ 前缀；在生命周期点被动调用 hooks.sh 的同名钩子
do_init() {
    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"
    hook on_init          # 级联依赖 init、附属配置渲染等
    # 渲染配置，但不启动
}

do_start() {
    require_conf
    set -a; source "$CONF_FILE"; set +a
    hook on_start         # 拉起级联依赖、组网，并填充 HOOK_RUN_ARGS
    # docker run ... "${HOOK_RUN_ARGS[@]}" ... （已存在则 docker start）
}

do_stop()  { ...; hook on_stop; }
do_rm()    { ...; hook on_rm; }
do_purge() { ...; hook on_purge; }
do_reset() { do_purge; rm -f "$CONF_DIR"/settings*.conf; }   # purge + 删除本服务所有 settings
do_help()  { ... }

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init && do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    reset)   do_reset ;;
    network) if declare -F on_network >/dev/null; then require_conf; source "$CONF_FILE"; on_network "${EXTRA_ARGS[@]}"; else do_help; fi ;;
    *)       do_help ;;
esac
```

## 4. 常见命令

日常生命周期高频使用的标准命令，各服务只要提供该功能，就必须符合下列语义。约定 start 是幂等的（已存在则 docker start，否则 docker run）。修改配置后需执行 rm 再 start。

- init：仅生成配置（渲染 settings.conf；集合服务经 on_init 还会初始化各附带依赖、渲染附属配置），不启动容器。结束时回显下一步操作指引。
- start：读取已有配置启动容器（集合服务经 on_start 按依赖顺序逐个拉起并组网）。成功后高亮回显访问地址、端口及关键默认账号密码。
- up：一键组合，等价于 init 加上 start，用于纯默认值快速体验。
- stop：仅停止容器进程，不删除容器与数据（集合服务经 on_stop 一并停止附带依赖）。
- rm：删除容器（集合服务经 on_rm 一并删除附带依赖与网络等隔离资源），但必须保留 data 与 settings.conf。
- purge：危险操作，在 rm 基础上彻底删除 data 数据目录；但必须保留 settings.conf，避免随机密钥永久丢失。bind-mount 数据常由容器内 root 进程写入，宿主机非 root 用户直接 `rm -rf` 会因属主权限失败；故 docker 服务统一用一次性 root 容器删除（`docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"`），且不得用 `2>/dev/null || true` 吞掉错误，以免删除失败却回显成功。宿主机级工具（如 codeserver）数据归当前用户，普通 `rm -rf` 即可，但同样不静默吞错。
- reset：破坏力最强的命令，破坏阶梯为 rm → purge → reset。先执行 purge（删容器+data，复合服务经 on_purge 级联清依赖 data），再 `rm -f "$CONF_DIR"/settings*.conf` 删除本服务目录下所有生成配置（`settings.conf` 及 `settings_paradedb.conf`/`settings_redis.conf` 等附属配置），把目录还原成 git clone 时的纯源文件态。顺序上 purge 必须在前（purge 依赖 settings.conf 读取 INSTANCE_NAME），删 settings 放最后。与 init 对称：init 生成全部生成物，reset 清空全部生成物。

注：status 不属于标准命令集（已移除）。查看实例运行状态直接用 `docker ps -a --filter name=<INSTANCE_NAME>`。

## 5. 特殊命令

部分特定场景使用或具有特殊约定的命令与参数：

- network：代理命令，仅当服务在 hooks.sh 中定义了 on_network 时才生效（即含底层依赖级联、需要专属网络的复合服务）。cli.sh 检测到 on_network 后将其暴露，常用 `bash cli.sh network ls` 经 lib/network.sh 展示该实例的专属网络及已连接的容器；单体独立应用未定义则回落到 help。
- help：缺省或未知参数时触发，打印各命令的简短说明及用法。
- 钩子 (on_init / on_start / on_stop / on_rm / on_purge / on_network)：并非用户直接调用的命令，而是 cli.sh 在对应生命周期点被动回调 hooks.sh 中的同名函数，用于挂载服务专属的特殊操作（见第 2 节）。
- 级联嵌入参数 (--conf, --name)：附加在基础服务的任意生命周期命令后，可指定被嵌入实例的配置位置与实例名。这改变了命令作用的目标实例而不改变命令语义，如 bash deploy/paradedb/cli.sh start --conf ../settings_paradedb.conf。
- Init-only 模式分歧开关 (如 --external)：对于改变拓扑架构的部署选项（例如是否使用外部云数据库），通过给 init 增加专属 flag 解决。cli.sh 只在 init 阶段解析它（收集在 EXTRA_ARGS 中）并将意图写入 settings.conf，后续生命周期一律统一从 settings.conf 读取状态，实现一次设定、永久生效。
