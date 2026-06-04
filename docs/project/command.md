# 命令设计理念 (CLI Command Design)

本文件说明各服务目录下 `cli.sh` 的命令规范与设计原因。所有服务的 `cli.sh` 必须遵循统一的命令集与行为，以 `deploy_apps/openwebui` 的实现为基准范例。

## 1. cli.sh 是唯一入口

每个服务的全部生命周期（生成配置、启动、停止、销毁、查看状态）都收敛到该目录下的 `cli.sh`，屏蔽底层 docker 命令细节。用户只需记住一套命令，无需关心服务底层用的是 docker run 还是 docker compose。

## 2. 生命周期命令

| 命令 | 行为约定 |
| :--- | :--- |
| `init` | 仅生成配置（渲染 `settings.conf`，多服务模式下还有 `compose.yml`），不启动容器。结束时必须回显“下一步操作指引”（如提醒修改凭证或密码）。 |
| `start` | 读取已有配置启动容器（单容器用 `docker run` / `docker start`，多服务用 `docker compose up -d`）。成功后必须高亮回显访问地址、端口及关键默认账号/密码。 |
| `up` | 一键组合，等价于 `init` + `start`，用于纯默认值快速体验。 |
| `stop` | 仅停止容器进程，不删除容器与数据。 |
| `rm` | 删除容器（及网络等隔离资源），保留 `./data` 与 `settings.conf`。 |
| `purge` | 危险操作：在 `rm` 基础上彻底删除 `./data` 数据目录；但必须保留 `settings.conf`，避免随机密钥永久丢失。 |
| `status` | 查看当前实例容器运行状态。 |

缺省或未知参数时，必须打印带各命令简短说明的 Usage 帮助，而不是一行裸字符串。

## 3. 命令与函数的命名约定（do_ 前缀）

派发函数统一用 `do_` 前缀：`do_init` / `do_start` / `do_stop` / `do_rm` / `do_purge` / `do_status` / `do_help`。

reason why：不能把函数直接命名成命令本身（如 `rm()`）。`rm` 是真实系统命令，一旦定义同名函数就会遮蔽它；而 `do_purge` 内部要调用 `rm -rf` 删数据目录，若函数叫 `rm` 就会递归调用自己而非删文件，逻辑直接崩坏。`stop` / `start` / `status` 等同理是隐患。加 `do_` 前缀既能和命令一一对应，又不遮蔽任何系统命令。

## 4. 脚本结构（工具函数在前，流程函数在后）

`cli.sh` 自上而下分三段：

1. 顶部常量与工具函数：如 `hr`（打印分隔线）、`random_port`、`random_secret`、`require_conf`、`container_exists`。这些函数无副作用、可复用。
2. 流程函数：`do_*` 系列，编排具体生命周期，带副作用。
3. 末尾 `case "$COMMAND"` 派发到对应的 `do_*`。

## 5. start 幂等语义

约定 `start` 幂等，重复执行不报错：

- 容器已存在：仅 `docker start`（或 compose 复用）。
- 容器不存在：`docker run` 新建。

注意：原生 docker run 模式下，已存在的容器不会重新读取 `settings.conf`。修改配置（端口、环境变量等）后，需先 `bash cli.sh rm` 再 `bash cli.sh start` 才能生效；数据在 `./data` 卷中，重建容器不会丢失。

## 6. 终端回显规范

为保证运维日志可读：

- 分隔线统一用工具函数 `hr()` 打印（那条 `===` 长线只在一处定义），重要控制流（初始化、启动成功、销毁提示）用 `hr` 包裹。
- 回显文案统一用原生风格英文。
- 服务 `start` 成功后，必须在分隔线内清晰打印 IP/端口与随机生成的密码或默认账号。
- 强介入环节（如首次启动 Casdoor 需人工进后台建应用）不拆成多段碎片脚本，而是维持原子的 `init` -> `start`，并在 `init` 回显里显眼给出 “Manual Action Required” 操作说明。
