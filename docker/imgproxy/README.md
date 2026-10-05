# imgproxy 高性能实时图片处理与缩放服务

[imgproxy](https://github.com/imgproxy/imgproxy) 是一款基于 Go 语言和 [libvips](https://github.com/libvips/libvips) 底层图像处理库构建的高性能、安全的开源图片处理服务器。它专为海量图片实时按需缩放、裁剪、格式转换（WebP / AVIF）以及水印处理设计，具备内存占用低、并发处理速度极快和安全性高的特点。

---

## 🎯 为什么选择 imgproxy？

在传统的 Web 应用架构中，由业务服务（如 PHP GD/Imagick 或 Node.js sharp）直接处理图片往往会带来 CPU 飙升、内存激增甚至进程崩溃等问题。imgproxy 提供了独立隔离的专业图片处理能力：

| 维度 | **imgproxy 独立服务** | **业务应用内处理 (PHP GD/Imagick / Node)** |
| :--- | :--- | :--- |
| **底层引擎** | **libvips (流式处理)**，极度节省内存，速度比 ImageMagick 快 4~8 倍 | GD / ImageMagick 需将完整位图加载至内存，极易触发 OOM |
| **并发与隔离** | **独立容器运行**，图片处理压力与业务主逻辑物理隔离，互不干扰 | 大图处理会阻塞业务线程/进程池，导致 API 请求超时 |
| **格式优化** | **自动嗅探协商** (根据客户端 `Accept` 头自适应输出 WebP / AVIF) | 需在业务层编写复杂的客户端 UA/Header 判断逻辑 |
| **安全性** | **HMAC-SHA256 强签名保护**，防止攻击者任意构造大尺寸进行 DoS 攻击 | 若参数校验不严，容易遭受像素放大炸弹 (Decompression Bomb) 攻击 |
| **存储适配** | 原生支持读取本地目录挂载 (`local:///`)、远程 HTTP/HTTPS 与 S3 对象存储 | 需在业务侧下载远程图片后再写入临时文件处理 |

---

## 🏛️ 系统集成架构

```text
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             1. 客户端访问层 (Client Layer)                       │
├──────────────────────────────────────────────────────────────────────────────────┤
│  • 浏览器 / H5 (自动携带 Accept: image/avif,image/webp,*/* 请求头)              │
│  • 移动端 App (iOS / Android 原生或跨平台框架)                                   │
└────────────────────────────────────────┬─────────────────────────────────────────┘
                                         │
                                         │ 1. 请求处理图片 (支持带 HMAC 签名或免签开发 URL)
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                     2. 网关反向代理层 (Caddy Ingress / Proxy)                    │
├──────────────────────────────────────────────────────────────────────────────────┤
│  • HTTPS 证书终结与 SSL 卸载                                                     │
│  • 路由反代: img.{$SITE_ADDRESS} -> imgproxy:8080                                │
│  • HTTP 缓存加速 (静态图片响应缓存，降低重复处理开销)                            │
└────────────────────────────────────────┬─────────────────────────────────────────┘
                                         │
                                         │ 2. 转发内部端口 (8080)
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                        3. imgproxy 核心图像处理引擎                              │
│                         (darthsim/imgproxy:v4)                                   │
├──────────────────────────────────────────────────────────────────────────────────┤
│  • HMAC-SHA256 签名校验 (防盗刷 / 防 DoS)                                        │
│  • libvips 流式图像处理 (缩放、重采样、智能裁剪、模糊、水印)                     │
│  • 客户端格式协商 (自动输出 WebP / AVIF 高压缩格式)                             │
└───────────────────┬──────────────────────────────────────────────┬───────────────┘
                    │                                              │
                    │ 3a. 读取本地持久化挂载 (`local:///`)         │ 3b. 抓取远程源图
                    ▼                                              ▼
┌────────────────────────────────────────┐     ┌───────────────────────────────────┐
│         4. 本地持久化存储挂载          │     │        5. 外部 / 远程媒体源       │
│  • /mnt/data: 业务数据存储主目录       │     │  • 远程 HTTP / HTTPS 图片         │
│  • /mnt/www:  应用代码静态资源目录     │     │  • AWS S3 / Garage 对象存储 Bucket │
└────────────────────────────────────────┘     └───────────────────────────────────┘
```

---

## 🔌 端口与服务映射

| 宿主机端口 | 容器内部端口 | 传输层 | 协议与用途 |
| :--- | :--- | :--- | :--- |
| `8088` (可配置) | `8080` | TCP | **imgproxy HTTP 核心图像处理与健康检查端口** |

---

## ⚙️ 环境变量配置说明

| 环境变量 | 默认值 | 作用与说明 |
| :--- | :--- | :--- |
| `IMGPROXY_KEY` | *(64位十六进制)* | **HMAC 签名密钥**。用于校验 URL 签名，必须为 Hex 字符串。 |
| `IMGPROXY_SALT` | *(64位十六进制)* | **HMAC 签名加盐**。用于混淆签名计算，必须为 Hex 字符串。 |
| `IMGPROXY_INSECURE_URLS` | `true` | **是否允许未签名 URL**。设为 `true` 时允许访问 `/insecure/...`，适合本地开发调试；生产环境建议设为 `false`。 |
| `IMGPROXY_DEVELOPMENT_ERRORS_MODE` | `true` | **开发错误提示模式**。发生异常时在响应 HTTP Header（`X-Error-Code` 等）和日志中输出详细错误信息。 |
| `IMGPROXY_LOCAL_FILESYSTEM_ROOT` | `/mnt` | **本地文件系统白名单根目录**。允许使用 `local:///` 协议读取的容器内根目录。 |
| `IMGPROXY_ENABLE_WEBP_DETECTION` | `true` | **自动 WebP 嗅探**。若客户端 `Accept` 头支持 WebP，自动输出为 WebP 格式。 |
| `IMGPROXY_ENABLE_AVIF_DETECTION` | `true` | **自动 AVIF 嗅探**。若客户端 `Accept` 头支持 AVIF，自动输出为压缩率更高的 AVIF 格式。 |
| `IMGPROXY_PORT` | `8088` | 宿主机暴露的 HTTP 访问端口。 |

---

## 📁 本地目录挂载映射

容器中通过只读方式挂载了两个核心路径：

* `${DATA_PATH:-./data/}:/mnt/data:ro` $\rightarrow$ 对应路径前缀：`local:///data/...`
* `${APP_CODE_PATH:-./}:/mnt/www:ro` $\rightarrow$ 对应路径前缀：`local:///www/...`

---

## 🚀 URL 规范与调用示例

imgproxy URL 的标准语法结构如下：

```text
/%signature/%processing_options/%source_url@%extension
```

### 1. 开发免签模式 (`/insecure/...`)

在 `IMGPROXY_INSECURE_URLS=true` 时，无需计算签名即可直接请求：

#### 本地挂载图片按比例缩放并转为 WebP

```text
http://localhost:8088/insecure/resize:fill:300:300/plain/local:///data/avatars/user.jpg@webp
```

#### 限制最大宽高自适应保持比例 (fit)

```text
http://localhost:8088/insecure/resize:fit:800:600/plain/local:///www/public/banner.png
```

#### 智能人脸/主体居中裁剪 (Smart Gravity)

```text
http://localhost:8088/insecure/resize:fill:400:400:1/gravity:sm/plain/https://images.unsplash.com/photo-1534528741775-53994a69daeb@webp
```

---

### 2. 生产安全签名生成 (HMAC-SHA256)

当 `IMGPROXY_INSECURE_URLS=false` 时，所有处理请求必须携带有效签名。

#### PHP / Laravel 签名生成示例

```php
<?php

function generateImgproxyUrl(
    string $baseUrl,
    string $keyHex,
    string $saltHex,
    string $path
): string {
    $keyBin = pack('H*', $keyHex);
    $saltBin = pack('H*', $saltHex);

    // 计算 HMAC-SHA256
    $hmac = hash_hmac('sha256', $saltBin . $path, $keyBin, true);

    // 转换为标准 Base64URL 编码
    $signature = rtrim(strtr(base64_encode($hmac), '+/', '-_'), '=');

    return rtrim($baseUrl, '/') . '/' . $signature . $path;
}

// 调用示例
$baseUrl = 'http://localhost:8088';
$key = env('IMGPROXY_KEY');
$salt = env('IMGPROXY_SALT');
$path = '/resize:fill:300:300/plain/local:///data/sample.jpg@webp';

$signedUrl = generateImgproxyUrl($baseUrl, $key, $salt, $path);
echo $signedUrl;
```

#### Node.js / TypeScript 签名生成示例

```typescript
import crypto from 'crypto';

export function signImgproxyUrl(
  baseUrl: string,
  keyHex: string,
  saltHex: string,
  path: string
): string {
  const key = Buffer.from(keyHex, 'hex');
  const salt = Buffer.from(saltHex, 'hex');

  const hmac = crypto.createHmac('sha256', key);
  hmac.update(salt);
  hmac.update(Buffer.from(path));

  const signature = hmac.digest('base64url');
  return `${baseUrl.replace(/\/$/, '')}/${signature}${path}`;
}

// 调用示例
const signedUrl = signImgproxyUrl(
  'http://localhost:8088',
  process.env.IMGPROXY_KEY!,
  process.env.IMGPROXY_SALT!,
  '/resize:fill:300:300/plain/local:///data/sample.jpg@webp'
);
console.log(signedUrl);
```

---

## 🛠️ 常用运维管理命令

### 启动服务

```bash
docker compose up -d imgproxy
```

### 查看运行状态与日志

```bash
docker compose logs -f imgproxy
```

### 容器健康检查

imgproxy 提供了内置健康检查，可直接在宿主机或容器内探测：

```bash
curl -I http://localhost:8088/healthz
```

响应返回 `200 OK` 即表示服务正常运行。

---

## 🌐 接入 Caddy 反向代理网关

如需通过子域名（例如 `img.test.local`）对外提供图片处理服务，在 `gateways/caddy/Caddyfile` 中解除注释或添加以下规则：

```caddyfile
import proxy-app img.{$SITE_ADDRESS} imgproxy:8080
```

重载 Caddy 即可生效：

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```
