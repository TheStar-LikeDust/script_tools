# RustFS 部署 (Deploy)

## 服务简介

RustFS 是一款高性能、兼容 Amazon S3 的对象存储服务器，使用 `rustfs/rustfs:latest` 镜像。常用于存储业务文件、用户上传的头像、知识库等大型非结构化数据。单容器即可独立运行，自带 Web 控制台。

## 部署特性

- 轻量独立：单容器，无需任何外部组件。
- 资产内聚：对象数据全部落在 `./data/<实例名>_data`，拷贝目录即带走全部数据。
- 多开隔离：通过 `INSTANCE_NAME` 与端口隔离，同机可起多个对象存储实例。
- 不依赖 docker compose：单容器直接用原生 `docker run` 管理，只需装了 `docker` 即可。`settings.conf` 是唯一配置源，由 `cli.sh` `source` 后通过 `-e VAR` 透传给容器。
- 多端口分离：同时暴露 S3 API 端口（应用调用）与 Console 端口（Web 管理界面）。
- 自带控制台：浏览器访问 Console 端口即可可视化管理 Bucket 与 Object。
- 健康检查：容器内置 `/health` 探测，便于判断服务是否就绪。

## 核心配置项 (`settings.conf`)

执行 `bash cli.sh init` 后生成，主要变量：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `rustfs_8421`），决定容器名与数据目录。
- `RUSTFS_PORT`: S3 API 对宿主机暴露的端口（容器内为 `9000`）。
- `RUSTFS_ADMIN_PORT`: 控制台 UI 暴露的端口（容器内为 `9001`）。
- `RUSTFS_ACCESS_KEY`: 自动生成的访问密钥（S3 Access Key）。
- `RUSTFS_SECRET_KEY`: 自动生成的访问私钥（S3 Secret Key）。

## 备注

- 不自动建桶：本服务只提供纯净的对象存储，启动后默认没有任何 Bucket。需要 Bucket 时，可通过控制台 UI 手动创建，或由上层应用按需创建。
- 数据本地化：对象数据仅保存在本地 `./data/<实例名>_data`，迁移时与 `settings.conf` 一起打包。

## 快速执行

```bash
cd deploy/rustfs

# 一键拉起（init + start）
bash cli.sh up

# 或分步：先生成配置、按需改 settings.conf，再启动
bash cli.sh init
bash cli.sh start
```

## 命令解释

每条命令对应的实际执行内容如下（`INSTANCE_NAME`、`RUSTFS_PORT` 等取自 `settings.conf`，启动前已 `set -a; source settings.conf; set +a` 导出为环境变量）。

路径锚定：脚本启动时计算自身所在目录 `SCRIPT_DIR`，模板恒取自 `$SCRIPT_DIR/templates`；配置文件默认 `$SCRIPT_DIR/settings.conf`（可用 `--conf` 覆盖），**数据目录在运行时派生为「配置文件所在目录」下的 `data/<实例名>_data`**。配置里不写死任何绝对路径，因此从任意 cwd 运行、或整体移动目录后再运行都不会失效。

### `init`

若配置文件不存在则用模板渲染生成，再创建数据目录，不启动容器。`--name` 指定完整实例名（不传则自动生成 `rustfs_<时间戳>`）。

```bash
sed -e "s/{{INSTANCE_NAME}}/<--name 或 rustfs_时间戳>/g" \
    -e "s/{{RUSTFS_PORT}}/<随机端口>/g" \
    -e "s/{{RUSTFS_ADMIN_PORT}}/<随机端口>/g" \
    -e "s/{{RUSTFS_ACCESS_KEY}}/<随机密钥>/g" \
    -e "s/{{RUSTFS_SECRET_KEY}}/<随机密钥>/g" \
    "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"

mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

### `start`

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
# 已存在
docker start "${INSTANCE_NAME}"

# 不存在（新建）
docker run -d \
    --name "${INSTANCE_NAME}" \
    -p "${RUSTFS_PORT}:9000" \
    -p "${RUSTFS_ADMIN_PORT}:9001" \
    -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/data" \
    -e RUSTFS_CONSOLE_ENABLE="true" \
    -e RUSTFS_ACCESS_KEY \
    -e RUSTFS_SECRET_KEY \
    --health-cmd "wget -qO- http://localhost:9000/health >/dev/null 2>&1 || exit 1" \
    --health-interval 5s \
    --health-timeout 3s \
    --health-retries 30 \
    --restart unless-stopped \
    rustfs/rustfs:latest \
    --access-key "${RUSTFS_ACCESS_KEY}" --secret-key "${RUSTFS_SECRET_KEY}" /data
```

### `up`

先 `init` 再 `start`。

### `stop`

```bash
docker stop "${INSTANCE_NAME}"
```

### `rm`

删除容器，保留 `./data/` 与 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

### `purge`

删除容器并删除本地数据目录，保留 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

### `status`

```bash
docker ps -a --filter "name=^${INSTANCE_NAME}$"
```

### 无参 / 未知参数

打印 Usage 帮助。

## 作为子服务嵌入 (`--conf` / `--name`)

除了独立部署，本服务可被上层 app（如 lobechat）作为「附带对象存储」调用，把配置与数据安置到上层目录里，docker run 逻辑零重复。两个可选参数：

- `--conf PATH`：指定配置文件位置（默认 `$SCRIPT_DIR/settings.conf`）。数据目录运行时派生为该文件所在目录下的 `data/<实例名>_data`。支持相对路径（相对当前 cwd 解析）。
- `--name NAME`：在 `init` 时写入的完整实例名，由调用方决定（不传则自动 `rustfs_<时间戳>`）。

约定：实例命名完全交给调用方，本服务不再使用 `APP_PREFIX` 之类的前缀拼接，也不固化网络名（网络由上层组装）。上层负责生成形如 `rustfs_lobechat_8421` 的完整名再用 `--name` 传入。

样例（调用方在自身目录下托管一个 rustfs）：

```bash
# init：配置落到上层目录的 settings_rustfs.conf，数据落到该目录的 data/
bash ../../deploy/rustfs/cli.sh init \
    --conf "$PWD/settings_rustfs.conf" \
    --name "rustfs_lobechat_8421"

# start / stop / rm / purge / status：同样带上 --conf 指向同一文件
bash ../../deploy/rustfs/cli.sh start --conf "$PWD/settings_rustfs.conf"
```

## 其他补充

- 镜像版本：当前固定 `rustfs/rustfs:latest`。若需可复现部署，可锁定到更具体的版本标签。
- 控制台访问：启动后打开 `http://<服务器IP>:<RUSTFS_ADMIN_PORT>`，用 Access Key / Secret Key 登录，可视化创建 Bucket 与对象。

## 待办：可选的建桶特色命令 (未实现)

当前 RustFS 启动后不自动建桶。后续可加一个特色命令 `bash cli.sh bucket [name]`，一键创建并公开一个桶，便于上层应用（如 lobechat）直接使用。方案要点（备忘，暂未落地）：

- 建桶逻辑沉淀为快捷脚本 `templates/bucket.sh.tpl`（内含 `mc alias set` / `mc mb` / `mc anonymous set public`），改逻辑只动模板。
- `cli.sh` 增加 `do_bucket` 派发，用一次性 `docker run --rm minio/mc` 执行，跑完即删。
- 借用 rustfs 容器网络命名空间（`--network "container:${INSTANCE_NAME}"`），mc 内 `localhost:9000` 即可连上，不依赖发布端口、不破坏单服务无 `--network` 的约定。
- 桶名默认读 `settings.conf` 的 `RUSTFS_DEFAULT_BUCKET`，也允许命令行参数临时指定。

这属于将来处理 lobechat 级联依赖时再决定是否落地的能力，不影响 RustFS 独立运行。
