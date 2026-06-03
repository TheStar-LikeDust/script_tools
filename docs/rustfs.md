# RustFS

## 服务简介

RustFS 是一款高性能、兼容 Amazon S3 的对象存储服务器。在当前的架构中，它主要用于存储各类业务场景产生的文件、用户上传的头像、以及知识库相关的大型非结构化数据。

## 部署与隔离特性

- **多端口分离**：服务同时对外暴露 S3 API 端口（用于应用调用）和 Console 端口（用于管理员 Web 界面操作）。
- **自带控制台**：你可以直接通过浏览器访问控制台端口，可视化管理 Bucket 和 Object。
- **持久化隔离**：数据文件映射于 `./data/<实例名>_rustfs_data`，互不干扰。

## 核心配置项 (`settings.conf`)

执行 `./cli.sh init` 之后会生成配置文件，其中主要变量如下：

- `INSTANCE_NAME`: 实例前缀（默认 `rustfs`）
- `RUSTFS_PORT`: API 服务对宿主机的暴露端口
- `RUSTFS_ADMIN_PORT`: 控制台 UI 服务暴露端口
- `RUSTFS_ACCESS_KEY`: 自动生成的强密码
- `RUSTFS_SECRET_KEY`: 自动生成的强密码

## 管理与访问

服务启动后，打开浏览器访问 `http://<服务器IP>:<RUSTFS_ADMIN_PORT>` 即可登录后台界面，手动创建所需的 Access Key 和 Bucket。

## 常见操作

```bash
cd deploy/rustfs

# 快速一键拉起
bash cli.sh up

# 销毁容器但不删文件
bash cli.sh rm
```
