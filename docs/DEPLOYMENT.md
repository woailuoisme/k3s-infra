# Lunchbox Kubernetes 部署指南

本文档提供 Lunchbox 应用在 Kubernetes 集群上的完整部署指南。

## 目录

- [前置条件](#前置条件)
- [快速开始](#快速开始)
- [详细部署步骤](#详细部署步骤)
- [环境配置](#环境配置)
- [验证部署](#验证部署)
- [常见问题](#常见问题)

## 前置条件

### 必需工具

- **Kubernetes 集群**: v1.33.5 或更高版本
- **kubectl**: v1.33.5 或更高版本
- **Helm**: v4.0.4 或更高版本
- **Git**: 用于克隆仓库

### 集群要求

- **节点数量**: 最少 1 个节点（开发环境），生产环境建议 3+ 个节点
- **CPU**: 最少 4 核心
- **内存**: 最少 8GB
- **存储**: 支持 PersistentVolume（推荐使用 StorageClass）

### 网络要求

- **Ingress Controller**: Traefik v3.6.4（自动安装）
- **DNS**: 配置域名解析到集群 Ingress IP
- **端口**: 80 (HTTP), 443 (HTTPS)

## 快速开始

### 1. 克隆仓库

```bash
git clone <repository-url>
cd lunchbox/k8s
```

### 2. 安装 Traefik Ingress Controller

```bash
cd scripts
./install-traefik.sh
```

### 3. 部署应用

```bash
# 部署到开发环境
./deploy.sh -e dev

# 部署到生产环境
./deploy.sh -e prod
```

### 4. 验证部署

```bash
./verify.sh
```

## 详细部署步骤

### 步骤 1: 准备配置文件

根据目标环境修改配置文件：

```bash
cd helm/lunchbox

# 开发环境
vim values-dev.yaml

# 生产环境
vim values-prod.yaml
```

**必须修改的配置项**：

1. **域名配置**

   ```yaml
   global:
     domain: your-domain.com  # 修改为你的域名
   ```

2. **镜像仓库**

   ```yaml
   global:
     imageRegistry: your-registry.com  # 修改为你的镜像仓库
   ```

3. **数据库密码**

   ```yaml
   # 在 templates/secrets/ 目录下修改各个 Secret 文件
   ```

### 步骤 2: 创建命名空间

```bash
kubectl create namespace lunchbox
```

### 步骤 3: 配置 Secret

**方式一：使用 Helm 默认值（仅开发环境）**

默认配置已包含测试密码，可直接部署。

**方式二：手动创建 Secret（推荐生产环境）**

```bash
# PostgreSQL
kubectl create secret generic postgres-secret \
  -n lunchbox \
  --from-literal=password='your-secure-password'

# Redis
kubectl create secret generic redis-secret \
  -n lunchbox \
  --from-literal=password='your-secure-password'

# MinIO
kubectl create secret generic minio-secret \
  -n lunchbox \
  --from-literal=root-user='admin' \
  --from-literal=root-password='your-secure-password'

# Meilisearch
kubectl create secret generic meilisearch-secret \
  -n lunchbox \
  --from-literal=master-key='your-secure-master-key'

# 应用密钥
kubectl create secret generic app-secret \
  -n lunchbox \
  --from-literal=app-key='base64:your-app-key' \
  --from-literal=jwt-secret='your-jwt-secret'

# Authelia
kubectl create secret generic authelia-secret \
  -n lunchbox \
  --from-literal=resend-username='resend' \
  --from-literal=resend-api-key='your-resend-api-key'
```

### 步骤 4: 部署 Traefik

```bash
cd scripts
./install-traefik.sh
```

验证 Traefik 安装：

```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
```

### 步骤 5: 部署应用

**使用部署脚本（推荐）**：

```bash
# 开发环境
./deploy.sh -e dev

# 预发布环境
./deploy.sh -e staging

# 生产环境
./deploy.sh -e prod
```

**手动部署**：

```bash
cd helm/lunchbox

# 安装
helm install lunchbox . \
  -n lunchbox \
  --create-namespace \
  -f values.yaml \
  -f values-dev.yaml

# 升级
helm upgrade lunchbox . \
  -n lunchbox \
  -f values.yaml \
  -f values-dev.yaml
```

### 步骤 6: 配置 DNS

获取 Traefik LoadBalancer IP：

```bash
kubectl get svc -n traefik traefik
```

配置 DNS A 记录：

```text
dev.your-domain.com      -> <TRAEFIK-IP>
rest.your-domain.com     -> <TRAEFIK-IP>
ws.your-domain.com       -> <TRAEFIK-IP>
mo.your-domain.com       -> <TRAEFIK-IP>
search.your-domain.com   -> <TRAEFIK-IP>
home.your-domain.com     -> <TRAEFIK-IP>
dozzle.your-domain.com   -> <TRAEFIK-IP>
msg.your-domain.com      -> <TRAEFIK-IP>
auth.your-domain.com     -> <TRAEFIK-IP>
```

或使用通配符：

```text
*.your-domain.com -> <TRAEFIK-IP>
```

## 环境配置

### 开发环境 (dev)

- **副本数**: 1
- **资源限制**: 最小
- **持久化**: 启用
- **TLS**: Let's Encrypt Staging
- **日志级别**: debug

配置文件：`values-dev.yaml`

### 预发布环境 (staging)

- **副本数**: 2
- **资源限制**: 中等
- **持久化**: 启用
- **TLS**: Let's Encrypt Production
- **日志级别**: info

配置文件：`values-staging.yaml`

### 生产环境 (prod)

- **副本数**: 3+
- **资源限制**: 根据负载调整
- **持久化**: 启用 + 备份
- **TLS**: Let's Encrypt Production
- **日志级别**: warn
- **高可用**: 启用

配置文件：`values-prod.yaml`

## 验证部署

### 使用验证脚本

```bash
cd scripts
./verify.sh -n lunchbox
```

### 手动验证

**1. 检查 Pod 状态**

```bash
kubectl get pods -n lunchbox
```

所有 Pod 应该处于 `Running` 状态。

**2. 检查 Service**

```bash
kubectl get svc -n lunchbox
```

**3. 检查 IngressRoute**

```bash
kubectl get ingressroute -n lunchbox
```

**4. 检查 PVC**

```bash
kubectl get pvc -n lunchbox
```

所有 PVC 应该处于 `Bound` 状态。

**5. 测试应用访问**

```bash
# 测试 PHP 应用
curl -k https://dev.your-domain.com

# 测试 API
curl -k https://rest.your-domain.com/health

# 测试 Meilisearch
curl -k https://search.your-domain.com/health
```

**6. 查看日志**

```bash
# PHP-FPM 日志
kubectl logs -n lunchbox -l app=php-fpm -f

# PostgreSQL 日志
kubectl logs -n lunchbox -l app=postgres -f

# Authelia 日志
kubectl logs -n lunchbox -l app=authelia -f
```

## 升级部署

### 使用脚本升级

```bash
cd scripts
./deploy.sh -e prod
```

脚本会自动检测现有部署并执行升级。

### 手动升级

```bash
helm upgrade lunchbox ./helm/lunchbox \
  -n lunchbox \
  -f helm/lunchbox/values.yaml \
  -f helm/lunchbox/values-prod.yaml
```

### 回滚

```bash
# 查看历史版本
helm history lunchbox -n lunchbox

# 回滚到上一个版本
helm rollback lunchbox -n lunchbox

# 回滚到指定版本
helm rollback lunchbox 2 -n lunchbox
```

## 卸载

### 使用清理脚本

```bash
cd scripts

# 仅卸载应用
./cleanup.sh

# 删除命名空间
./cleanup.sh --delete-namespace

# 删除所有数据（包括 PVC）
./cleanup.sh --delete-namespace --delete-pvc
```

### 手动卸载

```bash
# 卸载 Helm Release
helm uninstall lunchbox -n lunchbox

# 删除命名空间
kubectl delete namespace lunchbox
```

## 常见问题

### Pod 一直处于 Pending 状态

**原因**: 资源不足或 PVC 无法绑定

**解决方案**:

```bash
# 检查节点资源
kubectl top nodes

# 检查 PVC 状态
kubectl get pvc -n lunchbox

# 检查事件
kubectl get events -n lunchbox --sort-by='.lastTimestamp'
```

### ImagePullBackOff 错误

**原因**: 无法拉取镜像

**解决方案**:

1. 检查镜像仓库地址是否正确
2. 检查镜像是否存在
3. 配置 imagePullSecrets（私有仓库）

```bash
# 创建 Docker Registry Secret
kubectl create secret docker-registry regcred \
  -n lunchbox \
  --docker-server=your-registry.com \
  --docker-username=your-username \
  --docker-password=your-password
```

### CrashLoopBackOff 错误

**原因**: 容器启动失败

**解决方案**:

```bash
# 查看 Pod 日志
kubectl logs -n lunchbox <pod-name>

# 查看 Pod 详情
kubectl describe pod -n lunchbox <pod-name>
```

### 无法访问应用

**原因**: DNS 未配置或 Ingress 配置错误

**解决方案**:

1. 检查 DNS 解析

   ```bash
   nslookup dev.your-domain.com
   ```

2. 检查 Traefik Service

   ```bash
   kubectl get svc -n traefik
   ```

3. 检查 IngressRoute

   ```bash
   kubectl get ingressroute -n lunchbox
   kubectl describe ingressroute -n lunchbox
   ```

### 数据库连接失败

**原因**: 数据库未就绪或密码错误

**解决方案**:

```bash
# 检查 PostgreSQL Pod
kubectl get pods -n lunchbox -l app=postgres

# 测试数据库连接
kubectl exec -it -n lunchbox <postgres-pod> -- psql -U lunchbox -d lunchbox
```

## 监控和日志

### 查看实时日志

```bash
# 所有 Pod 日志
kubectl logs -n lunchbox --all-containers=true -f

# 特定应用日志
kubectl logs -n lunchbox -l app=php-fpm -f
```

### 使用 Dozzle 查看日志

访问: `https://dozzle.your-domain.com`

### 资源监控

```bash
# 节点资源使用
kubectl top nodes

# Pod 资源使用
kubectl top pods -n lunchbox
```

## 备份和恢复

### 备份数据库

```bash
# PostgreSQL 备份
kubectl exec -n lunchbox <postgres-pod> -- \
  pg_dump -U lunchbox lunchbox > backup.sql

# 恢复
kubectl exec -i -n lunchbox <postgres-pod> -- \
  psql -U lunchbox lunchbox < backup.sql
```

### 备份 PVC

使用 Velero 或其他备份工具备份 PersistentVolume。

## 性能优化

### 调整副本数

```yaml
# values-prod.yaml
phpFpm:
  replicaCount: 5  # 增加副本数

postgresql:
  replicaCount: 3  # 高可用配置
```

### 调整资源限制

```yaml
phpFpm:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
```

### 启用 HPA（水平自动扩缩容）

```bash
kubectl autoscale deployment php-fpm \
  -n lunchbox \
  --cpu-percent=70 \
  --min=2 \
  --max=10
```

## 参考资源

- [Kubernetes 官方文档](https://kubernetes.io/docs/)
- [Helm 官方文档](https://helm.sh/docs/)
- [Traefik 文档](https://doc.traefik.io/traefik/)
- [配置指南](CONFIGURATION.md)
- [故障排查指南](TROUBLESHOOTING.md)
- [安全配置指南](SECURITY.md)
