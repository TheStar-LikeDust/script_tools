# script_tools

基于**“目录即服务 (Service as a Directory)”**理念构建的高度自治 Docker 部署工具集。

## 核心理念

本项目旨在提供一种**开箱即用、高度隔离、资产内聚**的部署体验。我们将一个服务运行所需的所有元素，全部“沙盒化”封装在它专属的文件夹内：

- **资产绝对内聚**：每个服务的配置模板 (`settings.conf`)、控制台脚本 (`cli.sh`)、持久化数据盘 (`./data`)、以及潜在的日志与输入输出目录，全部收敛于当前的独立文件夹中。**要迁移或备份服务，只需打包拷贝这一个文件夹。**
- **命令高度封装**：屏蔽了繁琐的 Docker 命令。所有的生命周期管理（配置生成、启停、数据销毁）都被标准化封装进了该目录下的 `cli.sh` 工具中。
- **环境多开隔离**：即使在同一台机器上拉起 10 个相同服务，其容器名、虚拟网络、宿主机端口和数据映射卷都会通过前缀机制严格隔离，互不交叉。

> **关于特殊目录的说明：**
> 默认情况下，所有服务的持久化数据都保存在其目录下的 `./data` 文件夹中。但某些特殊服务可能会有自己专属的输入/输出目录（如日志、模型挂载路径、特殊外挂配置等）。如果有此类特殊情况，我们会在生成环境时自动创建这些目录，并会在 `docs/` 下该服务的专属文档中进行特别标注。

## 项目架构

本项目将部署逻辑分为三层：
- **`deploy/` (基础部署)**：原子的、可独立运行的服务组件（如 paradedb, rustfs, casdoor, redis）。
- **`deploy_apps/` (复合应用)**：组合多个基础服务，实现一键全栈部署（如 lobechat 全栈）。
- **`tools/` (宿主机工具)**：用于存放宿主机（非 Docker 级别的）环境配置和开发工具（如 code-server, tmux 等）。

## 快速获取安装

我们提供了从 GitHub 获取最新版本一键解包的引导命令，这会免去 `git clone` 的繁琐记录。在终端运行：

```bash
# TODO: 发布前需要把这里的 raw 链接换成你真实的 GitHub 仓库地址
bash <(curl -fsSL https://raw.githubusercontent.com/YourName/YourRepo/main/install.sh)
cd script_tools
```

### 场景一：独立部署单个基础服务

假设你需要一个独立的 ParadeDB 数据库做测试：

```bash
cd deploy/paradedb
```

**方式 1：标准部署（推荐，支持自定义配置）**

首先，仅生成默认配置 `settings.conf` 和 `compose.yml`：

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
1. 在执行 `init` 时，脚本会自动生成 `settings.conf`，里面包含了随机分配的端口和默认的 `INSTANCE_NAME="paradedb"`。
2. 随后根据配置渲染出底层的 `compose.yml`。
3. 执行 `start` 时，自动拉起隔离的 Docker 容器（容器名：`paradedb_paradedb`，数据保存在 `./data/paradedb_paradedb_data`）。

如果后续需要防端口冲突或起第二个库，只需修改 `settings.conf` 里的参数，再执行 `bash cli.sh init && bash cli.sh start` 重载生效。

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
- **默认/内置模式**：部署控制器会去调用 `deploy/paradedb` 给你单独分配一个专属于 LobeChat 的隔离库（名叫 `lobechat_paradedb`），绝对不会和你之前的库混淆。
- **外部模式**：LobeChat 栈不会启动新的数据库容器，而是直接把外部数据库的账号密码传给 Casdoor 和 LobeChat 主程序进行连接。
- **全局网络互通**：所有被拉起的底层组件都会自动连入同一个专属网络（如 `lobechat_network`）。

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