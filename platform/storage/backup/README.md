# K3s 本地存储卷异地增量备份 (Rclone Backup)

针对单节点 K3s (`local-path-provisioner`) 的轻量级底层持久化存储异地容灾方案。

## 1. 架构设计

- **执行载体**：轻量级 Kubernetes `CronJob`，每天凌晨 03:00 运行。
- **内存与 CPU 开销**：非备份时段 **0 Pod / 0 内存常驻**，执行期间内存限制 256MiB，对 4C8G 规格完全无感。
- **备份范围**：挂载宿主机 `/var/lib/rancher/k3s/storage`，增量同步非关系型数据（如 Garage S3 元数据与数据分块、Beszel 监控 SQLite、业务静态文件等）。
- **排除规则**：自动排除 `database-postgres-cluster*/**`，因为 PostgreSQL 已由 CloudNativePG 原生 Barman WAL 机制接管秒级热备与 PITR。
- **凭据同步**：通过 `external-secret.yaml` 声明式定义，由 External Secrets Operator (ESO) 自动从 OpenBao 的 `secret/storage/rclone-backup-secret` 提取并同步为集群原生 Secret。

## 2. 配置异地对象存储凭据

要连接真实的异地存储（如 Cloudflare R2 / AWS S3 / Backblaze B2），请按以下步骤注入 OpenBao：

### 步骤 1：准备本地 `rclone.conf`

创建临时文件 `rclone.conf`（以 Cloudflare R2 为例）：

```ini
[remote]
type = s3
provider = Cloudflare
access_key_id = <YOUR_R2_ACCESS_KEY_ID>
secret_access_key = <YOUR_R2_SECRET_ACCESS_KEY>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
acl = private
```

### 步骤 2：注入 OpenBao 密钥库

在项目根目录下执行（将 `rclone.conf` 内容写入 OpenBao）：

```bash
just bao-put storage/rclone-backup-secret rclone.conf="$(cat rclone.conf)"

# 清理明文临时文件
rm -f rclone.conf
```

### 步骤 3：验证同步状态

```bash
# 验证 ExternalSecret 与 Secret 映射状态
just verify
```

ESO 会在数秒内自动将该配置同步生成 `storage` 命名空间下的 `rclone-backup-secret`，CronJob 挂载后即可完成异地传输。
