# script_tools

基于**“目录即服务 (Service as a Directory)”**理念构建的高度自治 Docker 部署工具集。

## 核心理念

本项目旨在提供一种**开箱即用、高度隔离、资产内聚**的部署体验。我们将一个服务运行所需的所有元素，全部“沙盒化”封装在它专属的文件夹内：

- **资产绝对内聚**：每个服务的配置模板 (`settings.conf`)、控制台脚本 (`cli.sh`)、持久化数据盘 (`./data`)、以及潜在的日志与输入输出目录，全部收敛于当前的独立文件夹中。**要迁移或备份服务，只需打包拷贝这一个文件夹。**
- **路径动态锚定**：控制脚本在运行时会动态计算自身所在目录的绝对路径，并以此作为基准锚点。配置文件内严禁写死任何绝对路径。因此，从任意路径（cwd）去调用脚本，或是整体移动/复制服务目录，均能无缝正常工作。
- **命令高度封装**：屏蔽了繁琐的 Docker 命令。所有的生命周期管理（配置生成、启停、数据销毁）都被标准化封装进了该目录下的 `cli.sh` 工具中。
- **环境多开隔离**：即使在同一台机器上拉起 10 个相同服务，其容器名、虚拟网络、宿主机端口和数据映射卷都会通过前缀机制严格隔离，互不交叉。

> **关于特殊目录的说明：**
> 默认情况下，所有服务的持久化数据都保存在其目录下的 `./data` 文件夹中。但某些特殊服务可能会有自己专属的输入/输出目录（如日志、模型挂载路径、特殊外挂配置等）。如果有此类特殊情况，我们会在生成环境时自动创建这些目录，并会在 `docs/` 下该服务的专属文档中进行特别标注。

## 项目架构

本项目将部署逻辑分为三层：
- **`deploy/` (基础部署)**：原子的、可独立运行的服务组件（如 paradedb, rustfs, redis）。
- **`deploy_apps/` (复合应用)**：按用途划分的应用层组件（如 lobechat 全栈、openwebui、casdoor），可组合多个基础服务实现一键部署。
- **`tools/` (宿主机工具)**：用于存放宿主机（非 Docker 级别的）环境配置和开发工具（如 code-server, tmux 等）。

## 编排与配置设计

不同复杂度的服务采用不同的容器编排方式，并以原生 docker run 为首选：

- 单容器服务（如 openwebui）：直接用原生 `docker run` 管理，不依赖 docker compose，只需装了 `docker`。
- 自带依赖的集合服务（如 casdoor、lobechat）：用 docker run + 委托式级联组装——上层把底层服务的 `cli.sh` 当函数调用（通过 `--conf`/`--name` 参数嵌入），并在 app 级 user-defined network 内按容器名互通，全程不依赖 compose。lobechat 进一步级联 paradedb/redis/rustfs 与同级的 casdoor。详见 `docs/design/core.md` 第 6 节。

配置注入统一约定：`cli.sh` 先 `source settings.conf`，再用 `docker run -e VAR` 把变量透传给容器，而不是用 `--env-file` 或 `sed` 渲染。原因是 `--env-file` 不剥引号、`sed` 渲染对特殊字符脆弱，而 `source` 能让含空格/斜杠的值（如 `USER_AGENT`）正确解析，且人工手动 run 时行为与脚本一致。

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

首先，仅生成默认配置 `settings.conf`（单容器服务用原生 `docker run`，不再渲染 `compose.yml`）：

```bash
bash cli.sh init
```

你可以随时打开 `settings.conf` 修改随机生成的端口、密码或 `INSTANCE_NAME`（修改名字可实现同机器多实例）。确认无误后，启动服务：

```bash
bash cli.sh start
```

**方式 2：快速一键启动（全部使用随机默认值）**

```bash
bash cli.sh up
```

**发生了什么？**
1. 在执行 `init` 时，脚本会自动生成 `settings.conf`，里面包含了随机分配的端口和默认的 `INSTANCE_NAME`，并预建数据目录 `./data/<INSTANCE_NAME>_data`。实例名采用 **时间戳后缀** 规则：独立部署时为 `<服务名>_<4位时间戳>`（例如 `paradedb_8421`）。
2. 执行 `start` 时，`cli.sh` 先 `source settings.conf`，再用原生 `docker run` 直接拉起隔离的容器（容器名等于 `INSTANCE_NAME`，如 `paradedb_8421`；数据保存在 `./data/<INSTANCE_NAME>_data`，如 `./data/paradedb_8421_data`）。

如果后续需要防端口冲突或起第二个库，只需修改 `settings.conf` 里的 `INSTANCE_NAME`/端口等参数，再执行 `bash cli.sh rm && bash cli.sh start` 重建生效（数据在 `./data` 卷里，不会丢）。

### 场景二：一键部署全栈业务 (以 LobeChat 为例)

当你需要拉起一套包含 ParadeDB + RustFS + Redis + Casdoor + LobeChat 的完整架构时：

```bash
cd deploy_apps/lobechat
```

**方式 1：标准部署（推荐，支持连接外部数据库）**

首先，仅生成配置文件：

```bash
bash cli.sh init
```

此时会生成 `settings.conf`。你可以根据需求选择：
- **方案 A（内置隔离库）**：保持 `USE_INTERNAL_DB="true"` 不变，会自动新建一个 LobeChat 专属库。
- **方案 B（连接已有数据库）**：如果你想把 LobeChat 连到“场景一”建好的测试库或者云厂商 RDS，请修改以下配置：

```bash
USE_INTERNAL_DB="false"
EXTERNAL_DB_HOST="<已有库的IP或容器名>"
EXTERNAL_DB_PASSWORD="<已有库的密码>"
```

配置修改保存后，执行全栈启动：

```bash
bash cli.sh start
```

**方式 2：快速一键启动（使用全套内置默认组件）**

如果你不需要复用之前的数据库，只想要一个完全独立的新环境，可直接一键拉起：

```bash
bash cli.sh up
```

**发生了什么？**
- **委托式级联**：控制器调用各基础服务自己的 `cli.sh --conf settings_X.conf --name X_<实例名>`，把依赖的配置与数据都安置在 lobechat 目录下；实例名如 `paradedb_lobechat_8421`。casdoor 作为同级 app 被直接调用，并自带一个独立 paradedb（全量捆绑时共两个 paradedb 容器）。
- **外部模式**：任一依赖置 `USE_INTERNAL_*=false` 时，LobeChat 不启动该容器，而是直接读 `EXTERNAL_*` 连接信息。
- **app 级组网**：`start` 时建一个 user-defined network `<实例名>_net`，把所有依赖与 LobeChat 容器接入，按名互通；lobechat 自身也是纯 `docker run`，不再依赖 docker compose。

### 场景三：部署单容器应用 (以 Open WebUI 为例)

Open WebUI 是单容器服务，不依赖 docker compose，可直接一键拉起：

```bash
cd deploy_apps/openwebui
bash cli.sh up
```

**发生了什么？**
1. `init` 生成 `settings.conf`（随机端口、随机密钥、时间戳实例名），并预建数据目录 `./data/<INSTANCE_NAME>_data`，不渲染 `compose.yml`。
2. `start` 时 `cli.sh` 先 `source settings.conf`，再用 `docker run` 直接拉起容器，把配置通过 `-e VAR` 透传进去。
3. 修改 `settings.conf` 后，需先 `bash cli.sh rm` 再 `bash cli.sh start` 重建生效（数据在 `./data` 卷里，不会丢）。

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

**【危险】**销毁容器并彻底清除对应的 `./data` 数据卷（但保留 settings.conf 配置）：
```bash
bash cli.sh purge
```

查看容器运行状态：
```bash
bash cli.sh status
```

## 已知 TODO / 待优化

### 各 `cli.sh` 重复样板代码（与"目录即服务"冲突，待定方案）

当前每个服务目录的 `cli.sh` 都重复实现了几乎一致的样板：`random_port` / `stop` / `rm` / `purge` / `status` / `case` 派发 / `print_usage`，连 `random_secret` 长度都各写各的。这违反 DRY，但抽公共库又会破坏"拷贝单个目录即带走全部资产"的核心理念。

候选方案（尚未决策）：
- **方案 A（现状）**：保留重复，换取目录自包含。维护成本高。
- **方案 B（根级共享库）**：新增 `lib/common.sh`，各 `cli.sh` 通过相对路径 `source`。代价：单目录拷贝会丢失 lib，破坏自包含。**注意**：`.gitignore` 第 17 行的 `lib/`（Python 打包规则）会误伤根级 `lib/` 目录，启用前需加例外。
- **方案 C（init 时注入）**：`install.sh` 或各 `cli.sh` 的 `init` 把 `lib/common.sh` 拷贝进当前目录，兼顾 DRY 与自包含，但引入"生成物"的同步复杂度。

倾向方案 C，待确认后实施。