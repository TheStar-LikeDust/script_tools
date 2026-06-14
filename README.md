# script_tools

基于**“目录即服务 (Service as a Directory)”**理念构建的高度自治 Docker 部署工具集。

## 设计哲学与核心特性

本项目面向的是“开箱即用、高度隔离、资产内聚”的部署体验。我们将底层的复杂逻辑完全抽离，让新用户只需关注最简单直观的操作。

- **目录即服务 (Service as a Directory)**：一个服务运行所需的全部元素（配置、脚本、持久化数据）全部内聚在专属文件夹中。备份或迁移服务，只需拷贝这一个文件夹，目录在服务器上也可随意移动而不会失效。
- **纯原生 Docker 架构**：全面弃用 `docker-compose`。无论是单体应用还是复合微服务系统，全靠纯粹的 `docker run` 与原生隔离网络来拉起。只需安装最基础的 Docker，即刻可用。
- **傻瓜化与防冲突沙箱**：屏蔽繁琐的 Docker 参数。所有的生命周期管理标准化封装在 `cli.sh` 中（例如 `bash cli.sh up` 一键启动）。内置端口与实例名防碰撞机制，在同机拉起 10 个相同的服务也互不干扰。
- **高自由度组装**：通过“委托式级联”机制实现服务的原子化。既能一键拉起全套业务栈（如 New API + 专属数据库 + Redis），也能通过改一行配置，将业务无缝接入已有的外部中间件。

## 项目架构

本项目将部署逻辑分为三层：
- **`deploy/` (基础部署)**：原子的、可独立运行的服务组件（如 paradedb, rustfs, redis）。
- **`deploy_apps/` (复合应用)**：按用途划分的应用层组件（如 lobechat 全栈【暂时终止开发】、openwebui、casdoor、newapi、sub2api），可组合多个基础服务实现一键部署。
- **`tools/` (宿主机工具)**：用于存放宿主机（非 Docker 级别的）环境配置和开发工具（如 code-server、nginx 反代网关、docker 宿主机配置 ufw-docker 等）。

> **深入了解底层实现？**
> 我们把所有底层架构细节剥离到了设计文档中。如果你想了解我们为何摒弃 `docker-compose`、多环境隔离的动态组网原理以及为何使用特殊机制注入配置，请参阅：
> - [`docs/design/core.md`](docs/design/core.md)：核心编排逻辑、配置透传机制与沙箱网络原理。
> - [`docs/design/command.md`](docs/design/command.md)：生命周期命令的实现规范。

## 设计文档

修改本项目代码或新增服务前，请先阅读 `docs/design/` 下的三份设计文档，了解统一的约定与背后原因（后续维护或 AI 协作时应以这三份为准）：

- `docs/design/command.md`：cli.sh 的命令与代码设计（命令集、`do_` 前缀命名、脚本结构、`hr()` 回显规范、`start` 幂等语义）。
- `docs/design/core.md`：服务/目录的组织与部署设计（目录即服务、单容器优先用 docker run、`source + -e` 配置注入、实例命名、委托式级联与 `--conf`/`--name` 通用参数、app 级网络组装）。
- `docs/design/document.md`：服务说明文档（`docs/*.md`）的章节结构规范，以 `docs/openwebui.md` 为模板。

## 快速获取安装

我们提供了从 GitHub 获取最新版本一键解包的引导命令，这会免去 `git clone` 的繁琐记录。在终端运行：

> **TODO（发布前必改）**：`install.sh` 与下方命令中的 `YourName/YourRepo` 都是占位符，发布前必须替换成真实的 GitHub 仓库地址（同时确认 `install.sh` 顶部的 `GITHUB_REPO` 与 `VERSION`）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YourName/YourRepo/main/install.sh)
cd script_tools
```

### 场景一：独立部署单个基础服务

假设你需要一个独立的 ParadeDB 数据库做测试：

```bash
cd deploy/paradedb
```

**方式 1：标准部署（推荐，支持自定义配置）**

首先，仅生成默认配置 `settings_paradedb.conf`（单容器服务用原生 `docker run`，不再渲染 `compose.yml`）：

```bash
bash cli.sh init
```

你可以随时打开 `settings_paradedb.conf` 修改随机生成的端口、密码或 `INSTANCE_NAME`（修改名字可实现同机器多实例）。确认无误后，启动服务：

```bash
bash cli.sh start
```

**方式 2：快速一键启动（全部使用随机默认值）**

```bash
bash cli.sh up
```

**发生了什么？**
1. 在执行 `init` 时，脚本会自动生成 `settings_paradedb.conf`，里面包含了随机分配的端口和默认的 `INSTANCE_NAME`，并预建数据目录 `./data/<INSTANCE_NAME>_data`。实例名采用 **时间戳后缀** 规则：独立部署时为 `<服务名>_<4位时间戳>`（例如 `paradedb_8421`）。
2. 执行 `start` 时，`cli.sh` 先 `source settings_paradedb.conf`，再用原生 `docker run` 直接拉起隔离的容器（容器名等于 `INSTANCE_NAME`，如 `paradedb_8421`；数据保存在 `./data/<INSTANCE_NAME>_data`，如 `./data/paradedb_8421_data`）。

如果后续需要防端口冲突或起第二个库，只需修改 `settings_paradedb.conf` 里的 `INSTANCE_NAME`/端口等参数，再执行 `bash cli.sh rm && bash cli.sh start` 重建生效（数据在 `./data` 卷里，不会丢）。

### 场景二：一键部署全栈业务 (以 New API 为例)

当你需要拉起一套包含 ParadeDB + Redis + New API 的完整架构时：

```bash
cd deploy_apps/newapi
```

**方式 1：标准部署（推荐，支持自定义配置）**

首先，仅生成配置文件：

```bash
bash cli.sh init
```

此时会在 newapi 目录下生成三份配置：`settings_newapi.conf`（New API 自身的端口与实例名）、`settings_paradedb.conf` 和 `settings_redis.conf`（两个附带依赖的凭证与端口）。按需检查修改后，执行全栈启动：

```bash
bash cli.sh start
```

**方式 2：快速一键启动（全部使用随机默认值）**

如果你只想要一个完全独立的新环境，可直接一键拉起：

```bash
bash cli.sh up
```

**发生了什么？**
- **委托式级联**：控制器调用各基础服务自己的 `cli.sh --conf settings_X.conf --name <实例名>_X`，把依赖的配置与数据都安置在 newapi 目录下；实例名如 `newapi_8421_paradedb`、`newapi_8421_redis`。
- **连接串实时拼装**：`SQL_DSN` 与 `REDIS_CONN_STRING` 不落盘，每次 `start` 时从两份附带配置实时读取拼装（host 为依赖容器名），经 `-e` 注入 New API 容器。
- **app 级组网**：`start` 时建一个 user-defined network `<实例名>_net`，把 ParadeDB、Redis 与 New API 容器接入，按名互通；全程纯 `docker run`，不依赖 docker compose。

### 场景三：部署单容器应用 (以 Open WebUI 为例)

Open WebUI 是单容器服务，不依赖 docker compose，可直接一键拉起：

```bash
cd deploy_apps/openwebui
bash cli.sh up
```

**发生了什么？**
1. `init` 生成 `settings_openwebui.conf`（随机端口、随机密钥、时间戳实例名），并预建数据目录 `./data/<INSTANCE_NAME>_data`，不渲染 `compose.yml`。
2. `start` 时 `cli.sh` 先 `source settings_openwebui.conf`，再用 `docker run` 直接拉起容器，把配置通过 `-e VAR` 透传进去。
3. 修改 `settings_openwebui.conf` 后，需先 `bash cli.sh rm` 再 `bash cli.sh start` 重建生效（数据在 `./data` 卷里，不会丢）。

## 常用管理命令

所有目录下的 `cli.sh` 都遵循相同的命令规范。

初始化或重载配置与模板：
```bash
bash cli.sh init
```

仅启动服务（依赖配置已生成）：
```bash
bash cli.sh start
```

快速启动（等同于 init + start）：
```bash
bash cli.sh up
```

停止服务：
```bash
bash cli.sh stop
```

销毁容器（保留本地 `./data/` 数据卷）：
```bash
bash cli.sh rm
```

**【危险】**销毁容器并彻底清除对应的 `./data` 数据卷（但保留 settings_<服务名>.conf 配置）：
```bash
bash cli.sh purge
```

> 容器数据多由内部 root 进程写入，宿主机普通用户直接删会因属主权限失败。为此 docker 服务的 `purge` 会借一个一次性 root 容器来删除数据目录，无需 `sudo` 也能彻底清干净；删除失败会显式报错，不会假装成功。

**【危险·最强】**彻底重置：在 `purge` 基础上再删除该服务目录下所有 settings（`settings_<服务名>.conf` 及 `settings_*.conf` 等），把目录还原成 `git clone` 时的纯源文件态：
```bash
bash cli.sh reset
```

> 破坏力阶梯为 `rm` → `purge` → `reset`。`reset` 会一并删掉含随机密钥的 `settings_<服务名>.conf`，且为复合服务清空附带依赖的全部生成配置；执行后需重新 `init` 才能再次启动。

查看容器运行状态（`status` 命令已移除，直接用原生 docker）：
```bash
docker ps -a --filter name=<INSTANCE_NAME>
```

## 已知 TODO / 个人待优化的清单

### 项目目录整体比较乱

### 容器/网络/数据目录命名不统一