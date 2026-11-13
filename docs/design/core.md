# 服务设计理念 (Service Design)

本文件说明“一个服务 / 一个目录”如何组织与部署。三个基础服务和五个应用均以 Docker Compose 为容器编排边界。

## 1. 目录即服务 (Service as a Directory)

一个服务运行所需的全部元素都内聚在它专属的文件夹里：控制脚本 `cli.sh`、可选的服务特殊操作 `hooks.sh`、配置模板 `templates/*.tpl`、生成的 `settings_<服务名>.conf`、生成的 Compose YAML、持久化数据 `./data`。停止服务或完成一致性备份后，可打包拷贝该目录迁移；共享基础服务仍从自己的服务目录迁移。

职责分层：`cli.sh` 负责配置初始化、随机密钥生成、Compose YAML 渲染和服务专属操作；容器创建、网络接入、配置变化后的重建交给 Docker Compose。`hooks.sh` 仅在有应用专属职责时保留，当前只有 Casdoor 用它渲染 app.conf。详见 [命令规范](command.md)。

路径锚定：`SCRIPT_DIR` 是 CLI 所在目录，用于定位 templates 和可选 hooks；`CONF_DIR` 是 settings 所在目录，用于定位生成 YAML 和本实例数据，默认等于 `SCRIPT_DIR`。Compose 使用 `CONF_DIR` 作为项目目录，数据挂载采用相对路径。`--conf` 可指定其他位置，其父目录须预先存在。

命令边界：当前八个 Compose 部署均支持 `init/start/up/update/stop/rm/purge/reset`，五个应用另提供只读 `network ls`。宿主机工具按自身职责提供命令，不能假定也支持 Compose 命令集。

源文件与生成物的区分：

- 源文件（纳入版本管理）：`cli.sh`、有实际用途的 `hooks.sh`、`templates/*.tpl`、该服务的说明文档。
- 生成物（不提交，由 `.gitignore` 忽略）：`settings_<服务名>.conf`、`settings_<服务名>.compose.yaml`、应用生成的附属配置、各服务的 `data/`。

实例配置文件统一命名为 `settings_<服务名>.conf`（如 `settings_openwebui.conf`、`settings_paradedb.conf`），模板同步命名为 `templates/settings_<服务名>.conf.tpl`。应用只生成自己的配置，通过人工填写的连接信息访问基础服务。

`settings_<服务名>.conf` 含随机密钥/密码，属于本地资产：既不提交，也不会被 `purge` 删除；迁移时与 `data/` 一起打包。

## 2. 三层架构

- `deploy_services/`：原子基础服务（如 ParadeDB、RustFS、Redis），每个目录独立维护 Compose 定义、配置、凭证和数据，通过 `INSTANCE_NAME` 与端口多开隔离。
- `deploy_apps/`：应用服务。每个应用只维护自身 Compose 服务，人工在 `settings_<应用名>.conf` 中填写基础服务地址、端口、数据库、账号和密码；应用不管理共享依赖的生命周期。Open WebUI 默认使用本地 SQLite，外部 PostgreSQL 为可选配置。
- `tools/`：宿主机工具，包括 code-server、Nginx、Certbot 和 Docker 防火墙配置。该层按工具自身需要设计命令；支持的命令和本地文件位置见各工具说明。

## 3. 编排方式：Compose 与薄 CLI

容器编排由 Docker Compose 负责，`cli.sh` 只做配置和服务专属操作：

- `init` 生成缺失配置、刷新 Compose YAML，并按需创建本地数据目录，不启动常驻服务。LobeHub 在宿主机没有 Node.js 时，会用一次性应用容器生成 JWKS。
- `start` 刷新 YAML 并执行 `docker compose up -d`；Compose 负责容器创建、网络和配置变化后的重建。
- `update` 执行 `docker compose pull` 后再次 `up -d`，保留配置、凭证和数据。
- `stop`、`rm`、`purge`、`reset` 的范围严格限定为本服务。bind mount 数据由脚本按明确路径清理，不使用 `down -v`；外部共享资源不参与清理。

服务模板放在 `templates/compose.yaml.tpl`，生成的 `settings_<服务名>.compose.yaml` 是部署目录内可读、可复制的定义。暂不引入动态编排框架；需要复用服务时，复制服务目录或模板并人工调整配置。

同机共享服务使用管理员预先创建的 Docker 网络，例如 `docker network create shared_services`。配置 `DOCKER_NETWORK` 后，脚本在 Compose YAML 中以 `external: true` 接入该网络；脚本不创建或删除该网络。未配置时，Compose 使用本项目私有网络。容器之间使用唯一的实例容器名和容器端口连接，避免多个项目都提供 `paradedb` 等服务名造成 DNS 歧义。容器内的 `localhost` 只指向当前容器；远程服务填写容器可访问的主机地址与端口。

## 4. 配置注入：Bash settings 作为权威来源

`cli.sh` 以 Bash 方式读取 `settings_<服务名>.conf`，再导出变量供 Compose 插值；Compose 命令显式使用 `--env-file /dev/null`，避免误读目录中其他 `.env` 文件。settings 文件不是 Compose `env_file`，其中的引号、注释和 Bash 语法必须保持有效。

密码、密钥和包含空格或 `$` 的值需在 settings 中使用单引号并按 Bash 规则转义。例如原值 `a'b$ c` 写为 `DB_PASSWORD='a'\''b$ c'`。只读取可信的 settings，它是可执行的 Bash 配置。密钥不写入版本库；生成的 Compose YAML 只保留变量引用。Casdoor 的 app.conf 按应用需要保存连接凭证并限制文件权限。配置变更后再次执行 `start` 或 `up`，由 Compose 重新创建受影响的容器。

应用的 `DB_*` 填写原始字段，由脚本按镜像所需 DSN 格式转义，或映射到镜像的数据库环境变量；手工填写完整 Redis URI 时需自行对用户名、密码进行 URL 编码。`init` 允许连接字段留空，`start/update` 才检查必需值；应用脚本不建库、建账号或创建 bucket。应用镜像可在专用数据库内初始化业务表和执行结构迁移。应用自身保存到数据库的设置仍遵循应用的覆盖优先级。

## 5. 实例命名与多开隔离 (INSTANCE_NAME)

实例名由 `cli.sh init` 首次生成 `settings_<服务名>.conf` 时分配，默认采用时间戳后缀；同机多开应显式用 `--name` 指定唯一名称。Compose 项目名需匹配 `[a-z0-9][a-z0-9_-]*`：

- 独立部署：`<服务名>_<4位时间戳>`，如 `paradedb_8421`。
- 由管理员配置的独立实例：`--name` 可指定可读的完整实例名，应用通过网络地址连接基础服务，不以 `--name` 委托管理基础服务。

派生命名约定：

- 容器名：直接等于 `INSTANCE_NAME`。
- 持久化目录：`<配置文件所在目录>/data/${INSTANCE_NAME}_data`（默认即服务自身目录下的 `./data`）。
- 渲染配置目录（如 Casdoor 的 app.conf）：`data/${INSTANCE_NAME}_config`，与数据目录平级，避免配置混入运行数据。

具有本地数据的服务会在 `do_init` / `do_start` 预建挂载目录；LobeHub 没有本地数据挂载。RustFS 另按镜像用户修正数据属主，Casdoor 在 `start/update` 时生成单独的配置文件。

## 6. 配置与数据沙箱化 (--conf)

基础服务和应用的 `cli.sh` 提供两个通用参数，使同一脚本可以管理多个独立 Compose 项目：

- `--conf PATH`：指定该实例的 `settings_<服务名>.conf` 位置（默认 `<脚本目录>/settings_<服务名>.conf`）。Compose YAML 和数据目录都由配置文件所在目录推导，数据落在 `<dir-of-conf>/data/<INSTANCE_NAME>_data`。
- `--name NAME`：`init` 时写入完整实例名（默认自动 `<服务名>_<4位时间戳>`），用于 Compose 项目名、容器名和数据目录。

应用只通过网络地址连接这些独立项目，不调用基础服务的生命周期脚本。复制完整部署目录时需携带 CLI、templates、settings、YAML、密钥和本地数据；使用外置 `--conf` 目录时还需携带相应脚本与模板。共享基础服务单独备份和迁移，复制运行中的数据库目录不能作为一致性备份。自定义配置位置需放在版本库外或自行补充忽略规则。

## 7. 随机化默认凭证与账户名

由脚本提供的初始密码、应用密钥和 Access Key 在 `init` 阶段随机生成并保存到 settings。Sub2API、Open WebUI 的初始管理员账号也采用随机值；外部依赖凭证由管理员提供，不能在应用中另行生成替代值。

约定：

- Sub2API、Open WebUI 的账户名使用 `random_letters()` 生成 4 位随机小写字母（如 `kxqp`）。
- 同一随机串可同时作账户名与邮箱本地名：邮箱由“随机串 + 固定后缀”拼接（如 `kxqp@sub2api.local`、`kxqp@example.com`），用户名直接取该随机串。范例：`deploy_apps/sub2api`（`ADMIN_EMAIL`）、`deploy_apps/openwebui`（`WEBUI_ADMIN_NAME` 与 `WEBUI_ADMIN_EMAIL` 共用同一随机串）。
- 随机值在 `init` 时一次性写入 `settings_<服务名>.conf`，后续生命周期统一从该文件读取，重复初始化不会重新生成密钥，初始账户信息从本地 settings 查阅。

有意例外：

- 由应用本体创建或交互设置的管理员（如 Casdoor、New API）按应用自身流程管理。
- LobeHub 通过注册流程创建用户；settings 的随机 `example.invalid` 邮箱仅是注册允许列表占位值，须改为实际邮箱或域名。
- 数据库管理员名保留 `postgres`（如 `deploy_services/paradedb` 的 `DB_USER`），用于服务管理；应用使用管理员提前创建的独立数据库与账号，不复用管理员凭证。
