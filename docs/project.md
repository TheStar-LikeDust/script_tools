# 项目架构与开发规范 (Project Architecture & Development Standards)

本文档定义了 `script_tools` 项目的核心架构理念、目录组织原则以及所有生命周期脚本 (`cli.sh`) 的开发与行为规范。在新增任何服务或工具时，必须严格遵循本规范，以确保项目整体表现的高度统一。

## 1. 核心理念与架构哲学

- **Service as a Directory (目录即服务)**: 所有服务的运维脚本、配置文件（`settings.conf`）、容器描述模板（`compose.yml.tpl`）、以及持久化数据目录（`./data`）必须严格内聚在同一个文件夹内。实现“拷贝目录即带走全部资产”的沙盒化部署。
- **分层解耦**:
  - `deploy/`: 存放原子的基础服务（如 Postgres/ParadeDB, RustFS, Redis）。每个组件完全独立部署、启动、销毁，并通过 `INSTANCE_NAME` 和端口进行多开隔离。
  - `deploy_apps/`: 存放复合应用（如 LobeChat, Open WebUI）。通过向下级联调用的方式组装底层的原子服务。在配置中需要提供“内置隔离组装”与“连接外部已有服务”两种分支。
  - `tools/`: 宿主机（非 Docker 级别）的开发环境与工具集（如 code-server, tmux）。

## 2. CLI 脚本 (`cli.sh`) 开发规范

所有的组件管理必须通过其目录下的 `cli.sh` 控制。脚本必须提供统一的命令和一致的行为，并且**必须在缺省执行时提供明确的命令用法提示 (Usage/Help)。**

### 2.1 必须实现的生命周期指令

| 命令 | 行为描述与约定 |
| :--- | :--- |
| `init` | **仅渲染配置，不拉起服务**。基于模板生成 `settings.conf`（和 `compose.yml`）。生成后必须通过终端输出明确的“下一步操作指引”（如提醒用户修改凭证或密码）。 |
| `start` | **读取已有配置启动服务**（对于 Docker 则是 `docker compose up -d`）。成功启动后，必须在终端高亮回显**访问端口、访问地址及关键的默认账号/密码**。 |
| `up` | **一键启动组合**。逻辑上等同于 `init` + `start`。用于纯默认参数下的快速体验。 |
| `stop` | **停止服务**。仅停止容器进程，不销毁容器，不删除数据。 |
| `rm` | **移除容器资源**。销毁容器及挂载的网络等 Docker 级隔离资源，但**绝对保留持久化数据盘 (`./data`)** 及本地配置文件。 |
| `purge` | **【危险操作】深度清理**。除了执行 `rm` 销毁容器外，还要**彻底删除关联的持久化 `./data` 数据卷目录**。**注：无论如何都必须保留最初生成的 `settings.conf` 避免随机密钥永久丢失导致无法回溯。** |
| `status` | **查看状态**。输出当前服务的运行状态（如 `docker compose ps`）。 |

### 2.2 缺省参数与提示规范 (Help/Usage)

**所有 `cli.sh` 脚本如果不带任何参数运行，或输入了未知参数，必须打印出带有各命令简短说明的 Help 列表。**

*规范示例：*
```bash
# 错误做法：仅抛出简单的字符串
# Usage: bash cli.sh [init|start|up|stop|rm|purge|status]

# 正确做法：必须带说明
Usage: bash cli.sh {init|start|up|stop|rm|purge|status}
  init    : Generate configurations (settings.conf & compose.yml) without starting
  start   : Start the service containers
  up      : Initialize configs and start containers instantly
  stop    : Stop running containers
  rm      : Remove containers (Preserves ./data and configs)
  purge   : DANGER - Remove containers AND permanently delete ./data (Preserves configs)
  status  : Show container running status
```

## 3. UI/UX 终端回显规范

为了保证运维过程中的日志可读性，所有的 `echo` 回显信息必须遵循以下排版和语言约定：

1. **语言统一**: 本地的 Shell 脚本提示回显原则上使用**原生风格的英文**。
2. **视觉分栏边界**: 在重要的控制流（如准备初始化、启动成功、销毁提示等阶段），必须使用以下等号边界符进行包裹，以区分长串日志：
   ```bash
   echo "======================================================================"
   echo "[INFO] Starting code-server..."
   echo "======================================================================"
   ```
3. **关键信息暴露**: 当服务成功 `start` 后，必须在边界符内部，清晰打印出当前实例暴露的 IP/端口，以及随机生成的密码或默认的初始账号。
4. **人工介入指引分离**: 诸如“第一次启动 Casdoor 需要人工进入后台创建应用”这类“鸡生蛋”的强介入环节，绝不能拆分成 `start_bases` 等多段碎片脚本，而应维持原子的 `init` -> `start`。并在 `init` 步骤结束后的回显中，显眼地提供“Manual Action Required”的操作说明手册。

## 4. 实例命名规范 (INSTANCE_NAME)

实例名由 `cli.sh init` 在首次生成 `settings.conf` 时自动分配，采用 **时间戳后缀** 规则，保证同机多开互不冲突：

- **独立部署**：`<服务名>_<4位时间戳>`，例如 `paradedb_8421`。
- **被 app 级联部署**：上层 app 通过 `export APP_PREFIX="${INSTANCE_NAME}"` 注入前缀，底层服务命名为 `<服务名>_<APP_PREFIX>_<4位时间戳>`，例如 `paradedb_lobechat_8421_9032`。

派生命名约定（所有组件必须一致）：

- 容器名：直接等于 `INSTANCE_NAME`。
- compose 项目名：`${INSTANCE_NAME}_proj`。
- 持久化目录：`./data/${INSTANCE_NAME}_data`。

## 5. 网络传播约束 (NETWORK_NAME)

复合应用依靠 **环境变量继承** 把底层服务织入同一张 Docker 网络，机制如下：

1. 复合应用在 `init` 中 `source settings.conf` 后 `export NETWORK_NAME`（默认 `<app>_network`）。
2. 随后以子 shell 方式 `(cd ../../deploy/xxx && bash cli.sh init)` 调用底层服务，子 shell 继承到该 `NETWORK_NAME`。
3. 底层服务渲染时使用 `${NETWORK_NAME:-${INSTANCE_NAME}_network}` 兜底，从而落到上层指定的同一网络。

**强约束**：基础服务（`deploy/*`）的 `settings.conf` **禁止固化 `NETWORK_NAME`**，必须保持上述 `:-` 兜底写法。一旦在基础服务配置中写死 `NETWORK_NAME`，子 shell 继承将被覆盖，级联组网立即失效，底层容器无法被应用按容器名解析。

## 6. 生成物与源文件 (Generated vs. Source)

每个服务目录中需要区分「纳入版本管理的源文件」与「`init` 渲染产生、不应提交」的生成物：

- **源文件（提交）**：`cli.sh`、`templates/*.tpl`、该服务的说明文档。
- **生成物（不提交，由 `.gitignore` 忽略）**：`settings.conf`、`compose.yml`、Casdoor 的 `config/app.conf`、各服务的 `data/` 持久化目录。

注意：`settings.conf` 含随机生成的密钥/密码，属于本地资产，既不提交也不会被 `purge` 删除（见 §2.1）；迁移服务时应连同 `settings.conf` 与 `data/` 一起打包。
