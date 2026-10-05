# 安全配置指南

本文档说明 Lunchbox Kubernetes 部署的安全配置。

## Pod Security Standards

本项目遵循 Kubernetes Pod Security Standards (PSS) 的 **Restricted** 级别。

### 命名空间标签

为命名空间添加 Pod Security 标签：

```bash
kubectl label namespace lunchbox \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

## SecurityContext 配置

### Pod 级别 SecurityContext

所有 Pod 都配置了以下安全上下文：

```yaml
securityContext:
  runAsNonRoot: true      # 禁止以 root 用户运行
  runAsUser: 1000         # 使用非特权用户 UID
  fsGroup: 1000           # 文件系统组 ID
  seccompProfile:
    type: RuntimeDefault  # 使用默认 seccomp 配置
```

### 容器级别 SecurityContext

所有容器都配置了以下安全上下文：

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false  # 禁止权限提升
  readOnlyRootFilesystem: false    # 根文件系统（某些应用需要写入）
  capabilities:
    drop:
    - ALL                           # 移除所有 Linux capabilities
```

## Network Policy

### 启用 NetworkPolicy

在 `values.yaml` 中启用网络策略：

```yaml
networkPolicy:
  enabled: true
```

### 网络隔离策略

#### 数据层隔离

- **PostgreSQL**: 仅允许来自 PHP 应用的连接
- **Redis**: 仅允许来自 PHP 应用和 Reverb 的连接
- **Meilisearch**: 允许来自 PHP 应用和 Traefik Ingress 的连接
- **MinIO**: 允许来自 PHP 应用和 Traefik Ingress 的连接

#### 应用层隔离

- **PHP-FPM**: 允许来自 Traefik Ingress 的连接，可访问所有数据层服务
- **PHP-RoadRunner**: 允许来自 Traefik Ingress 的连接，可访问所有数据层服务
- **PHP-Reverb**: 允许来自 Traefik Ingress 的 WebSocket 连接，可访问 Redis
- **PHP-Horizon**: 仅出站流量，可访问数据层服务
- **PHP-Schedule**: 仅出站流量，可访问数据层服务

#### DNS 和外部访问

所有 Pod 都允许：

- DNS 查询（UDP 53）
- HTTPS 外部 API 访问（TCP 443）

### 禁用 NetworkPolicy

如果集群不支持 NetworkPolicy（如某些托管 Kubernetes），可以禁用：

```yaml
networkPolicy:
  enabled: false
```

## 资源限制

### CPU 和内存限制

所有容器都配置了资源请求（requests）和限制（limits）：

```yaml
resources:
  requests:
    cpu: 100m      # 最小 CPU 保证
    memory: 256Mi  # 最小内存保证
  limits:
    cpu: 500m      # 最大 CPU 使用
    memory: 512Mi  # 最大内存使用
```

### 资源配额建议

#### 开发环境

- PHP-FPM: 100m CPU / 256Mi 内存
- PostgreSQL: 100m CPU / 256Mi 内存
- Redis: 50m CPU / 128Mi 内存

#### 生产环境

- PHP-FPM: 500m-1000m CPU / 512Mi-1Gi 内存
- PostgreSQL: 500m-2000m CPU / 1Gi-4Gi 内存
- Redis: 200m-500m CPU / 512Mi-2Gi 内存

## Secret 管理

### 敏感信息加密

所有敏感信息都存储在 Kubernetes Secret 中：

- 数据库密码
- Redis 密码
- MinIO 凭证
- Meilisearch Master Key
- Authelia SMTP 凭证
- 应用密钥（APP_KEY, JWT_SECRET）

### 生产环境建议

1. **使用外部 Secret 管理器**
   - HashiCorp Vault
   - AWS Secrets Manager
   - Azure Key Vault
   - Google Secret Manager

2. **启用 Secret 加密**

   ```bash
   # 在 Kubernetes API Server 启用静态加密
   --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
   ```

3. **使用 Sealed Secrets**

   ```bash
   # 安装 Sealed Secrets Controller
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml
   ```

## RBAC 配置

### ServiceAccount

以下服务需要 ServiceAccount 和 RBAC 权限：

- **Homepage**: 读取集群资源（Pods, Services, Deployments）
- **Dozzle**: 读取 Pod 日志

### 最小权限原则

所有 ServiceAccount 都遵循最小权限原则，仅授予必要的权限。

## TLS/SSL 配置

### Traefik TLS

Traefik 自动管理 TLS 证书：

```yaml
tls:
  enabled: true
  certResolver: letsencrypt
```

### Let's Encrypt

生产环境使用 Let's Encrypt 自动签发证书：

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      tlsChallenge: {}
```

## 审计和监控

### 启用审计日志

建议在生产环境启用 Kubernetes 审计日志：

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
```

### 安全扫描

定期扫描容器镜像：

```bash
# 使用 Trivy 扫描镜像
trivy image your-registry/php-fpm:latest

# 使用 Snyk 扫描
snyk container test your-registry/php-fpm:latest
```

## 合规性检查

### 使用 kube-bench

检查集群是否符合 CIS Kubernetes Benchmark：

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs -f job/kube-bench
```

### 使用 Polaris

检查 Kubernetes 资源的最佳实践：

```bash
kubectl apply -f https://github.com/FairwindsOps/polaris/releases/latest/download/dashboard.yaml
kubectl port-forward -n polaris svc/polaris-dashboard 8080:80
```

## 安全更新

### 定期更新

1. **容器镜像**: 每月更新基础镜像
2. **Kubernetes**: 跟随官方支持版本
3. **Helm Charts**: 定期更新依赖

### 漏洞响应

1. 订阅安全公告
2. 建立漏洞响应流程
3. 定期进行安全演练

## 参考资源

- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
