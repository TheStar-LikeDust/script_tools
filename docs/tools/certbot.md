# Certbot 证书申请 (Deploy)

## 1. 简介

> 使用 Certbot 通过 Let's Encrypt 为域名申请 TLS 证书。

证书通过 HTTP-01 验证；域名需解析到当前服务器，且公网 TCP 80 可访问。

## 2. 核心配置项

无需配置文件。Certbot 默认将证书保存在 `/etc/letsencrypt/live/<域名>/`。

## 3. 备注

- 需预先安装 `certbot`。
- 脚本直接调用 Certbot，不自动提权；写入 `/etc/letsencrypt` 和监听 TCP 80 时需有相应权限。
- 申请使用非交互模式，接受服务条款并以无邮箱方式注册；脚本不配置续期任务。
- standalone 验证会临时监听 TCP 80；如果 Nginx 已占用该端口，申请前需先停止 Nginx。
- 证书文件为 `fullchain.pem`，私钥文件为 `privkey.pem`。
- 续期时 HTTP-01 验证仍需公网 TCP 80 可访问且未被其他进程占用。

## 4. 快速执行

```bash
cd tools/certbot
bash cli.sh issue https://example.com
```

也可直接传入域名：

```bash
bash cli.sh issue example.com
```

## 5. 命令解释

#### issue

为输入网址中的域名申请 Let's Encrypt 证书，并显示证书与私钥路径。以下为 CLI 内部调用，`domain` 来自输入网址的域名部分。

```bash
certbot certonly --standalone --preferred-challenges http \
  --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
```

## 6. 其他补充

- 证书路径：`/etc/letsencrypt/live/<域名>/fullchain.pem`
- 私钥路径：`/etc/letsencrypt/live/<域名>/privkey.pem`
- 证书由宿主机管理，不保存在本工具目录；备份应保存 `/etc/letsencrypt` 中的证书、私钥、链接目标和续期配置。
