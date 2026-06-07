# RustFS 部署 (Deploy)

## 1. 简介

> RustFS 是一款高性能、兼容 Amazon S3 的对象存储服务器，常用于存储业务文件、用户上传的头像、知识库等大型非结构化数据。

使用 `rustfs/rustfs:latest` 镜像，单容器即可独立运行，自带 Web 控制台，无需任何外部组件。

## 2. 功能

- 多端口 API 控制隔离
  - 问题：通常 S3 API 和 Web 管理后台混用端口会导致对外映射权限划分不清晰。
  - 方案：通过不同端口将应用层读写调用的 S3 端口和人工登入查看的 Console 管理端口分离暴露，更加安全清晰。
- 极简控制台赋能
  - 痛点：很多极轻量 S3 竞品没有界面，全靠命令敲击十分不便。
  - 方案：RustFS 容器内建了可视化管理层，直接浏览器访问对应管理口即可查阅 Bucket 和对象文件。
- 全局通用功能支持
  - 子组件嵌入：支持通过 `--conf` 和 `--name` 参数被上层应用（如大模型客户端等）当做子组件嵌入部署，实现沙箱化的数据挂靠隔离（详情参见 `docs/design/core.md`）。

## 3. 核心配置项

### settings.conf

S3 服务主配置：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `rustfs_8421`），决定容器名与数据目录。
- `RUSTFS_PORT`: S3 API 对宿主机暴露的端口（容器内为 `9000`）。
- `RUSTFS_ADMIN_PORT`: 控制台 UI 暴露的端口（容器内为 `9001`）。
- `RUSTFS_ACCESS_KEY`: 自动生成的访问密钥（S3 Access Key）。
- `RUSTFS_SECRET_KEY`: 自动生成的访问私钥（S3 Secret Key）。

## 4. 备注

- 不提供初始存储桶：本服务仅提供底层的 S3 对象存储实例，启动后默认没有任何 Bucket。对接应用时需人工登录 Admin 控制台或通过业务代码创建所需 Bucket 后方可读写。

## 5. 快速执行

```bash
cd deploy/rustfs

# 常规分步拉起（推荐）：先生成配置、按需修改 settings.conf 后再启动
bash cli.sh init
bash cli.sh start

# 一键拉起（跳过配置直接启动）
bash cli.sh up

# 停止运行
bash cli.sh stop

# 销毁容器（保留配置与 data/ 数据目录）
bash cli.sh rm

# 危险操作：彻底销毁容器，并删除挂载的 data/ 数据目录
bash cli.sh purge
```

## 6. 命令解释

#### init

若配置文件不存在则用模板渲染生成，再创建数据目录，不启动容器。`--name` 指定完整实例名。

```bash
sed -e "s/{{INSTANCE_NAME}}/<--name 或 rustfs_时间戳>/g" \
    -e "s/{{RUSTFS_PORT}}/<随机端口>/g" \
    -e "s/{{RUSTFS_ADMIN_PORT}}/<随机端口>/g" \
    -e "s/{{RUSTFS_ACCESS_KEY}}/<随机密钥>/g" \
    -e "s/{{RUSTFS_SECRET_KEY}}/<随机密钥>/g" \
    "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"

mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### start

启动容器。若同名容器已存在，仅 `docker start`；否则 `docker run` 新建。

```bash
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

#### up

先 `init` 再 `start`。

#### stop

停止容器。

```bash
docker stop "${INSTANCE_NAME}"
```

#### rm

删除容器，保留 `./data/` 与 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
```

#### purge

删除容器并删除本地数据目录，保留 `settings.conf`。

```bash
docker stop "${INSTANCE_NAME}"
docker rm "${INSTANCE_NAME}"
rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_data"
```

#### status

显示容器状态。

```bash
docker ps -a --filter "name=^${INSTANCE_NAME}$"
```

## 7. 其他补充

- 镜像版本：当前固定 `rustfs/rustfs:latest`。若需可复现部署，可锁定到更具体的版本标签。
- 控制台访问：启动后打开 `http://<服务器IP>:<RUSTFS_ADMIN_PORT>`，用 Access Key / Secret Key 登录，可视化创建 Bucket 与对象。
- 可选的建桶命令：目前不提供自动建桶，将来可能会增加一次性的临时容器跑 `mc` 命令建桶支持。
