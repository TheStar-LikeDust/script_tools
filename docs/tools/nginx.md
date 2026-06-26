# Nginx 网关 (Deploy)

## 1. 简介

> 宿主机级别的反向代理网关，将上游应用仅按白名单路径前缀（默认 `/v1/`）暴露到公网，其余路径一律返回 404。

该服务直接运行在宿主物理机上，非容器化；nginx 作为普通宿主机进程监听，受 UFW 正常管控。配置以渲染的站点文件软链进 `/etc/nginx/conf.d/` 的方式部署，`reload` 生效。`start` 首次运行自动生成 `settings_nginx.conf`，提示按需修改后重跑。管理后台不经公网暴露，经 SSH 端口转发访问上游应用的本机端口。

## 2. 核心配置项

### settings_nginx.conf

- `INSTANCE_NAME`: 实例名，决定 `/etc/nginx/conf.d/` 中的站点文件名（默认时间戳后缀，如 `nginx_8421`）。
- `SERVER_NAME`: 公网主机名，`_` 匹配任意主机。
- `LISTEN_PORT`: nginx 公网监听端口，作为宿主机进程受 UFW 管控（默认 `80`）。
- `UPSTREAM_PORT`: 上游应用的宿主机端口（如 newapi 的 `NEWAPI_PORT`），反代到 `127.0.0.1:UPSTREAM_PORT`。
- `ALLOW_PREFIX`: 唯一对公网放行的路径前缀（默认 `/v1/`）。

## 3. 备注

- 渲染落点：站点配置渲染到 `data/${INSTANCE_NAME}_config/site.conf`，再软链至 `/etc/nginx/conf.d/${INSTANCE_NAME}.conf`，源真值随服务目录迁移。
- 路径白名单：仅 `ALLOW_PREFIX` 反代到上游，`location /` 返回 404，Web UI 与管理接口不对外。
- 流式支持：站点配置关闭 `proxy_buffering` 并设较长 `proxy_read_timeout`，适配 SSE 流式响应。
- 配置校验：`start` 部署后执行 `nginx -t`，校验失败自动撤回软链并退出，避免污染 nginx。
- 直连防护：本服务只开放白名单入口，上游 `-p` 直连端口需配合 `tools/docker-setup`（ufw-docker）关闭，否则公网仍可绕过网关直连。
- 权限：写入 `/etc/nginx` 与操作 ufw 需 root，脚本对非 root 调用自动回退 `sudo`。

## 4. 快速执行

```bash
cd tools/nginx

# 首次运行生成 settings_nginx.conf（随后按需修改 SERVER_NAME / LISTEN_PORT / UPSTREAM_PORT / ALLOW_PREFIX）
bash cli.sh start

# 修改 settings_nginx.conf 后再次运行以部署网关
bash cli.sh start

# 下线网关
bash cli.sh stop
```

## 5. 命令解释

#### start

首次运行生成 `settings_nginx.conf` 并提示修改后退出；配置就绪后渲染站点、软链进 conf.d、校验并 `reload` nginx，最后 `ufw allow` 监听端口。缺失 nginx 时经 `apt-get` 安装。

```bash
ln -sf "$site_file" "/etc/nginx/conf.d/${INSTANCE_NAME}.conf"
nginx -t && systemctl reload nginx
ufw allow "${LISTEN_PORT}/tcp"
```

#### stop

移除 conf.d 中的站点软链并 `reload` nginx，再 `ufw delete allow` 监听端口；保留 `settings_nginx.conf`。

```bash
rm -f "/etc/nginx/conf.d/${INSTANCE_NAME}.conf"
systemctl reload nginx
ufw delete allow "${LISTEN_PORT}/tcp"
```

## 6. 其他补充

- 命令集裁剪：仅保留 `start` 与 `stop`，配置生成折叠进 `start`，不实现 `init`/`up`/`rm`/`purge`/`reset`。
- 管理访问：上游端口仅绑本机（或经 ufw-docker 对公网屏蔽），管理 UI 经 SSH 隧道访问，例如 `ssh -L ${UPSTREAM_PORT}:127.0.0.1:${UPSTREAM_PORT} <user>@<server>`。
- TLS 扩展：HTTPS 作为本服务的后续可选维度（`settings_nginx.conf` 增加证书相关项、`site.conf.tpl` 条件渲染 `listen 443 ssl`），不另起服务。
