# Certbot 证书申请 (Deploy)

## 1. 简介

> 使用 Certbot 通过 Let's Encrypt 为域名申请 TLS 证书。

`start` 自动安装缺失的 Certbot，再通过 HTTP-01 验证申请证书并输出证书与私钥路径；域名需解析到当前服务器，且公网 TCP 80 可访问。

## 2. 核心配置项

无需配置文件。`start` 接收一个域名或完整网址，自动提取域名；证书保存在 `/etc/letsencrypt/live/<域名>/`。

## 3. 备注

- 自动安装使用 `apt-get`，适用于 Debian/Ubuntu；已安装 Certbot 时跳过安装。
- 安装依赖、写入证书和监听 TCP 80 需要 root 权限；普通用户自动通过 `sudo` 执行，可能提示输入 sudo 密码。
- 申请使用非交互模式，接受服务条款并以无邮箱方式注册；脚本不配置续期任务。
- 重复执行 `start` 会复用未到续期时间的证书，需要续期时重新签发。
- standalone 验证会临时监听 TCP 80；如果 Nginx 已占用该端口，申请前需先停止 Nginx。
- 证书文件为 `fullchain.pem`，私钥文件为 `privkey.pem`。
- 续期时 HTTP-01 验证仍需公网 TCP 80 可访问且未被其他进程占用。

## 4. 快速执行

```bash
cd tools/certbot
bash cli.sh start https://example.com
```

也可直接传入域名：

```bash
bash cli.sh start example.com
```

## 5. 命令解释

#### start

依次安装缺失的 Certbot、申请或续期域名证书、显示证书与私钥路径。以下为 CLI 内部调用，`domain` 来自输入网址的域名部分，`SUDO` 在普通用户下为 `sudo`，root 下为空。

```bash
if ! command -v certbot >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y certbot
fi

$SUDO certbot certonly \
    --standalone \
    --preferred-challenges http \
    --server https://acme-v02.api.letsencrypt.org/directory \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --keep-until-expiring \
    --cert-name "$domain" \
    -d "$domain"
```

## 6. 其他补充

- 证书路径：`/etc/letsencrypt/live/<域名>/fullchain.pem`
- 私钥路径：`/etc/letsencrypt/live/<域名>/privkey.pem`
- 证书由宿主机管理，不保存在本工具目录；备份应保存 `/etc/letsencrypt` 中的证书、私钥、链接目标和续期配置。
