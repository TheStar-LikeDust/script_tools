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

实例配置文件统一命名为 `settings_<服务名>.conf`（如 `settings_openwebui.conf`、`settings_paradedb.conf`），模板同步命名为 `templates/settings_<服务名>.conf.tpl`。配套应用的 settings 同时保存应用设置及本实例依赖的镜像、连接和凭证，不加载其他基础服务的 settings。

`settings_<服务名>.conf` 含随机密钥/密码，属于本地资产：既不提交，也不会被 `purge` 删除；迁移时与 `data/` 一起打包。

## 2. 三层架构

- `deploy_services/`：原子基础服务（如 ParadeDB、RustFS、Redis），每个目录独立维护 Compose 定义、配置、凭证和数据，通过 `INSTANCE_NAME` 与端口多开隔离。
- `deploy_apps/`：应用及默认配套依赖。Casdoor 配套 PostgreSQL，New API 和 Sub2API 配套 PostgreSQL、Redis，LobeHub 配套 PostgreSQL、Redis、RustFS，同一个 Compose 项目统一管理。Open WebUI 默认使用本地 SQLite；其已有外部数据库配置方式保留。
- `tools/`：宿主机工具，包括 code-server、Nginx、Certbot 和 Docker 防火墙配置。该层按工具自身需要设计命令；支持的命令和本地文件位置见各工具说明。

## 3. 编排方式：Compose 与薄 CLI

容器编排由 Docker Compose 负责，`cli.sh` 只做配置和服务专属操作：

- `init` 生成本地配置、刷新 Compose YAML，并按需创建本地数据目录。四个配套应用补齐缺失或空的默认依赖字段，不访问数据库或对象存储，也不启动容器。
- `start` 刷新 YAML 并执行 `docker compose up -d`；Compose 负责整套实例的容器创建、网络和配置变化后的重建。PostgreSQL 首次启动创建配置指定的账号和数据库，Redis 持久化数据，LobeHub 的一次性初始化服务创建缺失 Bucket。
- `update` 执行 `docker compose pull` 后再次 `up -d`，保留配置、凭证和数据。
- `stop`、`rm`、`purge`、`reset` 的范围限定为本 Compose 项目及其拥有的数据，配套依赖属于应用项目。`rm` 保留持久化数据和配置，`purge` 删除本实例整套数据，`reset` 再删除配置；独立基础服务和外部资源不参与应用清理。bind mount 按明确路径清理，不使用 `down -v`。

服务模板放在 `templates/compose.yaml.tpl`，生成的 `settings_<服务名>.compose.yaml` 是部署目录内可读、可复制的定义。暂不引入动态编排框架；需要复用服务时，复制服务目录或模板并人工调整配置。

默认使用 Compose 为整套实例创建的私有网络。配套容器通过带实例名的容器地址和内部端口连接，PostgreSQL、Redis 不发布宿主机端口。需要共享网络时，管理员预先创建并配置 `DOCKER_NETWORK`，脚本以 `external: true` 接入且不创建、删除该网络。容器内的 `localhost` 只指向当前容器。当前四个应用只自动编排默认配套依赖，修改连接字段不会自动移除配套服务。

## 4. 配置注入：Bash settings 作为权威来源

`cli.sh` 以 Bash 方式读取 `settings_<服务名>.conf`，再导出变量供 Compose 插值；Compose 命令显式使用 `--env-file /dev/null`，避免误读目录中其他 `.env` 文件。settings 文件不是 Compose `env_file`，其中的引号、注释和 Bash 语法必须保持有效。

密码、密钥和包含空格或 `$` 的值需在 settings 中使用单引号并按 Bash 规则转义。例如原值 `a'b$ c` 写为 `DB_PASSWORD='a'\''b$ c'`。只读取可信的 settings，它是可执行的 Bash 配置。密钥不写入版本库；生成的 Compose YAML 只保留变量引用。Casdoor 的 app.conf 按应用需要保存连接凭证并限制文件权限。配置变更后再次执行 `start` 或 `up`，由 Compose 重新创建受影响的容器。

应用的 `DB_*` 保存原始字段，由脚本按镜像所需 DSN 格式转义，或映射到镜像环境变量。配套 PostgreSQL 的 `POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD` 使用相同配置，在空数据目录首次启动时初始化；之后修改 settings 不会改变已有数据库密码。应用镜像负责业务表和迁移。Redis 默认无认证，不生成虚假密码；数据库编号和键前缀只区分数据，不提供权限隔离。

LobeHub 的 `APP_URL`、浏览器使用的 `S3_ENDPOINT` 和真实 `AUTH_ALLOWED_EMAILS` 由使用者填写，`init` 提示缺项，`start/update` 检查必需值。服务端 S3 使用配套 RustFS 的内部地址；Bucket 在启动阶段创建，CORS 暂留待处理。模型和 OAuth 等外部凭证不生成占位值。

## 5. 实例命名与多开隔离 (INSTANCE_NAME)

实例名由 `cli.sh init` 首次生成 `settings_<服务名>.conf` 时分配，默认采用时间戳后缀；同机多开应显式用 `--name` 指定唯一名称。Compose 项目名需匹配 `[a-z0-9][a-z0-9_-]*`：

- 独立部署：`<服务名>_<4位时间戳>`，如 `paradedb_8421`。
- 由管理员命名的实例：`--name` 指定可读的完整实例名，同时决定配套容器和数据目录前缀。

派生命名约定：

- 应用或独立基础服务容器名：直接等于 `INSTANCE_NAME`。
- 配套容器名：`${INSTANCE_NAME}_postgres`、`${INSTANCE_NAME}_redis`、`${INSTANCE_NAME}_rustfs`；LobeHub 的 Bucket 初始化容器为 `${INSTANCE_NAME}_rustfs_init`，仅生成实际需要的服务。
- 应用或独立基础服务持久化目录：`<配置文件所在目录>/data/${INSTANCE_NAME}_data`。
- 配套持久化目录：同一配置目录下的 `data/${INSTANCE_NAME}_postgres_data`、`data/${INSTANCE_NAME}_redis_data`、`data/${INSTANCE_NAME}_rustfs_data`。
- 渲染配置目录（如 Casdoor 的 app.conf）：`data/${INSTANCE_NAME}_config`，与数据目录平级，避免配置混入运行数据。

具有本地数据的服务会在 `do_init` / `do_start` 预建挂载目录。LobeHub 的数据保存在配套依赖的本地挂载目录中；`start/update` 处理 RustFS 数据属主及缺失 JWKS。Casdoor 在 `start/update` 时生成 app.conf。

## 6. 配置与数据沙箱化 (--conf)

基础服务和应用的 `cli.sh` 提供两个通用参数，使同一脚本可以管理多个独立 Compose 项目：

- `--conf PATH`：指定该实例的 `settings_<服务名>.conf` 位置（默认 `<脚本目录>/settings_<服务名>.conf`）。Compose YAML、应用及配套依赖数据均由配置文件所在目录推导，具体后缀见第 5 节。
- `--name NAME`：`init` 时写入完整实例名（默认自动 `<服务名>_<4位时间戳>`），用于 Compose 项目名、容器名和数据目录。

配套依赖直接声明在应用 Compose 模板中，不调用 `deploy_services/` 的生命周期脚本。复制完整部署目录时携带 CLI、templates、settings、YAML、密钥和本实例全部数据；外置 `--conf` 目录还需携带相应脚本与模板。独立基础服务单独备份和迁移，复制运行中的数据库目录不能作为一致性备份。自定义配置位置需放在版本库外或自行补充忽略规则。

## 7. 随机化默认凭证与账户名

由脚本提供的初始密码、应用密钥和 Access Key 在 `init` 阶段随机生成并保存到 settings。Sub2API、Open WebUI 的初始管理员账号也采用随机值。四个配套应用仅补齐缺失或空的默认依赖字段，保留非空配置、密码和应用密钥；外部凭证仍由使用者提供。

约定：

- Sub2API、Open WebUI 的账户名使用 `random_letters()` 生成 4 位随机小写字母（如 `kxqp`）。
- 同一随机串可同时作账户名与邮箱本地名：邮箱由“随机串 + 固定后缀”拼接（如 `kxqp@sub2api.local`、`kxqp@example.com`），用户名直接取该随机串。范例：`deploy_apps/sub2api`（`ADMIN_EMAIL`）、`deploy_apps/openwebui`（`WEBUI_ADMIN_NAME` 与 `WEBUI_ADMIN_EMAIL` 共用同一随机串）。
- 随机值在 `init` 时一次性写入 `settings_<服务名>.conf`，后续生命周期统一从该文件读取，重复初始化不会重新生成密钥，初始账户信息从本地 settings 查阅。

有意例外：

- 由应用本体创建或交互设置的管理员（如 Casdoor、New API）按应用自身流程管理。
- LobeHub 通过注册流程创建用户，`AUTH_ALLOWED_EMAILS` 留空提示填写真实邮箱或域名；缺失 JWKS 在 `start/update` 生成一次并保存。
- 独立 ParadeDB 默认管理员名为 `postgres`；配套 PostgreSQL 使用应用 settings 中的默认账号初始化自己的实例。配套 RustFS 同样使用本实例生成的凭证，不引入共享服务的账号和权限管理。
