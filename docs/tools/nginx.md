# Nginx 网关 (Deploy)

## 1. 简介

> 宿主机级别的反向代理网关，将上游应用仅按白名单路径前缀（默认 `/v1/`）暴露到公网，其余路径一律返回 404。

该服务直接运行在宿主物理机上，非容器化；nginx 作为普通宿主机进程监听，受 UFW 正常管控。配置以渲染的站点文件软链进 `/etc/nginx/conf.d/` 的方式部署，`reload` 生效。`start` 首次运行自动生成 `settings_nginx.conf`，提示按需修改后重跑。管理后台不经公网暴露，经 SSH 端口转发访问上游应用的本机端口。

## 2. 核心配置项

### settings_nginx.conf

- `INSTANCE_NAME`: 实例名，决定 `/etc/nginx/conf.d/` 中的站点文件名（默认时间戳后缀，如 `nginx_8421`）。
- `SERVER_NAME`: 公网主机名，默认 `_` 只是占位名称，不是通配符；是否接收未匹配请求由 Nginx 的默认 server 选择规则决定，域名部署应填写实际域名。
- `LISTEN_PORT`: nginx 公网监听端口，作为宿主机进程受 UFW 管控（默认 `80`）。
- `UPSTREAM_PORT`: 上游应用的宿主机端口（如 newapi 的 `NEWAPI_PORT`），反代到 `127.0.0.1:UPSTREAM_PORT`。
- `ALLOW_PREFIX`: 唯一对公网放行的路径前缀（默认 `/v1/`）。

## 3. 备注

- 渲染落点：站点配置渲染到 `data/${INSTANCE_NAME}_config/site.conf`，再软链至 `/etc/nginx/conf.d/${INSTANCE_NAME}.conf`，源真值随服务目录迁移。
- 路径白名单：仅 `ALLOW_PREFIX` 反代到上游，`location /` 返回 404，Web UI 与管理接口不对外。
- 流式支持：站点配置关闭 `proxy_buffering` 并设较长 `proxy_read_timeout`，适配 SSE 流式响应。
- 配置校验：`start` 部署后执行 `nginx -t`，校验失败自动撤回软链并退出，避免污染 nginx。
- 直连防护：本服务只控制网关入口，上游 Compose `ports` 发布的端口需单独限制访问，可配合 `tools/docker-setup` 管理。
- 权限：写入 `/etc/nginx` 与操作 ufw 需 root，脚本对非 root 调用自动回退 `sudo`。
- `--conf PATH` 指定 settings 及生成 site.conf 的目录，父目录须已存在；`--name NAME` 仅在首次生成配置时生效。UFW 放行或撤销失败不会使当前脚本报错，防火墙状态需由管理员管理。

## 4. 快速执行

```bash
cd tools/nginx

# Generate settings, then edit SERVER_NAME, ports and ALLOW_PREFIX.
bash cli.sh start

# Apply the configured gateway.
bash cli.sh start

# Remove the gateway site.
bash cli.sh stop
```

## 5. 命令解释

以下片段展示 CLI 内部操作，变量来自 settings 和脚本计算，权限处理由 CLI 完成；日常使用 `bash cli.sh start` 或 `bash cli.sh stop`。

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

- 命令集：提供 `start` 与 `stop`，配置生成包含在首次 `start` 中，不提供 Compose 生命周期或镜像 `update`。
- 管理访问：上游端口仅绑本机（或经 ufw-docker 对公网屏蔽），管理 UI 经 SSH 隧道访问，例如 `ssh -L ${UPSTREAM_PORT}:127.0.0.1:${UPSTREAM_PORT} <user>@<server>`。
- TLS：当前模板仅提供 HTTP，没有证书配置字段。需要 HTTPS 时须扩展站点模板与配置，Certbot 的证书不会被本脚本自动接入。
- 复制恢复：保存脚本、templates、settings 和 data，目标机器准备 Nginx 与 UFW 后运行 `start` 重建站点软链；复制目录不会携带 `/etc/nginx` 中的链接和宿主机防火墙规则。
