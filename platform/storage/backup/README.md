# K3s 本地存储卷异地增量备份 (Rclone Backup)

针对单节点 K3s (`local-path-provisioner`) 的轻量级底层持久化存储异地容灾方案。

## 1. 架构设计

- **执行载体**：轻量级 Kubernetes `CronJob`，每天凌晨 03:00 运行。
- **内存与 CPU 开销**：非备份时段 **0 Pod / 0 内存常驻**，执行期间内存限制 256MiB，对 4C8G 规格完全无感。
- **备份范围**：挂载宿主机 `/var/lib/rancher/k3s/storage`，增量同步非关系型数据（如 Garage S3 元数据与数据分块、Beszel 监控 SQLite、业务静态文件等）。
- **排除规则**：自动排除 `database-postgres-cluster*/**`，因为 PostgreSQL 已由 CloudNativePG 原生 Barman WAL 机制接管秒级热备与 PITR。

## 2. 配置异地对象存储凭据

默认提供的 `sealed-secret.yaml` 为占位模板。要连接真实的异地存储（如 Cloudflare R2 / AWS S3 / Backblaze B2），请按以下步骤重新加密：

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

### 步骤 2：生成并更新 Sealed Secret

在项目根目录下执行：

```bash
kubectl create secret generic rclone-backup-secret \
  --namespace=storage \
  --from-file=rclone.conf=rclone.conf \
  --dry-run=client -o yaml | \
  kubeseal --cert platform/security/sealed-secrets/public-cert.pem --format yaml > platform/storage/backup/sealed-secret.yaml

# 清理明文临时文件
rm -f rclone.conf
```

### 步骤 3：提交 Git 并触发同步

```bash
git add platform/storage/backup/sealed-secret.yaml
git commit -m "feat(backup): update rclone offsite storage credentials"
git push
```
