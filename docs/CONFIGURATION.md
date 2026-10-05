# Lunchbox Kubernetes 配置指南

本文档详细说明 Lunchbox Helm Chart 的所有配置选项。

## 目录

- [全局配置](#全局配置)
- [应用层配置](#应用层配置)
- [数据层配置](#数据层配置)
- [支持服务配置](#支持服务配置)
- [Ingress 配置](#ingress-配置)
- [安全配置](#安全配置)
- [环境变量](#环境变量)

## 全局配置

### global

全局配置影响所有服务。

```yaml
global:
  # 主域名
  domain: example.com
  
  # 时区
  timezone: Asia/Shanghai
  
  # 镜像仓库
  imageRegistry: docker.io
  
  # 镜像拉取密钥
  imagePullSecrets: []
  
  # 存储类
  storageClass: ""  # 空字符串使用集群默认
```

### namespace

应用部署的命名空间。

```yaml
namespace: lunchbox
```

## 应用层配置

### PHP-FPM

主 PHP 应用，使用 Nginx Sidecar 模式。

```yaml
phpFpm:
  enabled: true
  replicaCount: 2
  
  image:
    repository: your-registry/php-fpm
    tag: latest
    pullPolicy: IfNotPresent
  
  # Nginx Sidecar
  nginx:
    image:
      repository: nginx
      tag: alpine
      pullPolicy: IfNotPresent
    port: 80
  
  service:
    type: ClusterIP
    port: 80
  
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  
  # 健康检查
  livenessProbe:
    httpGet:
      path: /health
      port: 80
    initialDelaySeconds: 30
    periodSeconds: 10
  
  readinessProbe:
    httpGet:
      path: /health
      port: 80
    initialDelaySeconds: 10
    periodSeconds: 5
  
  # 应用代码卷
  appCode:
    enabled: true
    size: 5Gi
    mountPath: /var/www/lunchbox
```

### PHP-RoadRunner

高性能 PHP 应用服务器。

```yaml
phpRoadrunner:
  enabled: true
  replicaCount: 2
  
  image:
    repository: your-registry/php-roadrunner
    tag: latest
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 8001
  
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

### PHP-Horizon

Laravel Horizon 队列处理器。

```yaml
phpHorizon:
  enabled: true
  replicaCount: 1
  
  image:
    repository: your-registry/php-horizon
    tag: latest
    pullPolicy: IfNotPresent
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

### PHP-Schedule

Laravel 定时任务调度器。

```yaml
phpSchedule:
  enabled: true
  replicaCount: 1
  
  image:
    repository: your-registry/php-schedule
    tag: latest
    pullPolicy: IfNotPresent
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 100m
      memory: 256Mi
```

### PHP-Reverb

Laravel Reverb WebSocket 服务器。

```yaml
phpReverb:
  enabled: true
  replicaCount: 1
  
  image:
    repository: your-registry/php-reverb
    tag: latest
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 8080
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

## 数据层配置

### PostgreSQL

主数据库。

```yaml
postgresql:
  enabled: true
  
  image:
    repository: postgres
    tag: "16"
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 5432
  
  persistence:
    enabled: true
    size: 20Gi
    storageClass: ""
  
  auth:
    database: lunchbox
    username: lunchbox
    # password 通过 Secret 管理
  
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
```

### Redis

缓存和会话存储。

```yaml
redis:
  enabled: true
  
  image:
    repository: redis
    tag: "7-alpine"
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 6379
  
  persistence:
    enabled: true
    size: 5Gi
    storageClass: ""
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 512Mi
```

### Meilisearch

搜索引擎。

```yaml
meilisearch:
  enabled: true
  
  image:
    repository: getmeili/meilisearch
    tag: v1.30
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 7700
  
  persistence:
    enabled: true
    size: 10Gi
    storageClass: ""
  
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
```

### MinIO

对象存储。

```yaml
minio:
  enabled: true
  
  image:
    repository: minio/minio
    tag: latest
    pullPolicy: IfNotPresent
  
  service:
    api:
      type: ClusterIP
      port: 9000
    console:
      type: ClusterIP
      port: 9001
  
  persistence:
    enabled: true
    size: 50Gi
    storageClass: ""
  
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
```

## 支持服务配置

### Authelia

认证服务。

```yaml
authelia:
  enabled: true
  replicaCount: 1
  
  image:
    repository: authelia/authelia
    tag: latest
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 9091
  
  # SMTP 配置（Resend）
  smtp:
    username: "resend"
    apiKey: "change-this-resend-api-key"
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

**默认用户**:

- 管理员: `admin` / `Admin123!`
- 普通用户: `user` / `User123!`

### Centrifugo

实时消息服务。

```yaml
centrifugo:
  enabled: true
  replicaCount: 1
  
  image:
    repository: centrifugo/centrifugo
    tag: v6
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 8000
  
  # 密钥配置（生产环境请修改）
  tokenSecret: "change-this-token-secret"
  apiKey: "change-this-api-key"
  adminPassword: "change-this-admin-password"
  adminSecret: "change-this-admin-secret"
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

### Mosquitto

MQTT 消息代理。

```yaml
mosquitto:
  enabled: true
  
  image:
    repository: eclipse-mosquitto
    tag: latest
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 1883
  
  persistence:
    enabled: true
    size: 1Gi
    storageClass: ""
  
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

### Gotify

通知推送服务。

```yaml
gotify:
  enabled: true
  
  image:
    repository: gotify/server
    tag: "2.7"
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 80
  
  # 管理员密码（生产环境请修改）
  adminPassword: "change-this-password"
  
  persistence:
    enabled: true
    size: 1Gi
    storageClass: ""
  
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

### Homepage

Kubernetes 仪表板。

```yaml
homepage:
  enabled: true
  
  image:
    repository: ghcr.io/gethomepage/homepage
    tag: v1.8
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 3000
  
  # 需要 RBAC 权限访问 K8s API
  rbac:
    create: true
  
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 100m
      memory: 256Mi
```

### Dozzle

日志查看器。

```yaml
dozzle:
  enabled: true
  
  image:
    repository: amir20/dozzle
    tag: v8.14
    pullPolicy: IfNotPresent
  
  service:
    type: ClusterIP
    port: 8080
  
  # 需要 RBAC 权限访问 K8s API
  rbac:
    create: true
  
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

## Ingress 配置

### 全局 Ingress 设置

```yaml
ingress:
  enabled: true
  className: traefik
  
  # TLS 配置
  tls:
    enabled: true
    certResolver: letsencrypt
```

### 路由配置

每个服务都有独立的路由配置：

```yaml
ingress:
  routes:
    # PHP 应用
    app:
      enabled: true
      host: dev.example.com
      service: php-fpm
      port: 80
      middlewares:
        - authelia-forward-auth
    
    # RoadRunner API
    api:
      enabled: true
      host: rest.example.com
      service: php-roadrunner
      port: 8001
      middlewares:
        - authelia-forward-auth
    
    # WebSocket
    websocket:
      enabled: true
      host: ws.example.com
      service: php-reverb
      port: 8080
    
    # MinIO Console
    minioConsole:
      enabled: true
      host: mo.example.com
      service: minio-console
      port: 9001
      middlewares:
        - authelia-forward-auth
    
    # 其他服务...
```

## 安全配置

### SecurityContext

Pod 级别安全上下文：

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  readOnlyRootFilesystem: false
  seccompProfile:
    type: RuntimeDefault
```

### NetworkPolicy

网络策略配置：

```yaml
networkPolicy:
  enabled: true
  policyTypes:
    - Ingress
    - Egress
```

## 环境变量

### 数据库连接

通过环境变量配置数据库连接：

```yaml
env:
- name: DB_CONNECTION
  value: "pgsql"
- name: DB_HOST
  value: "postgres"
- name: DB_PORT
  value: "5432"
- name: DB_DATABASE
  value: "lunchbox"
- name: DB_USERNAME
  value: "lunchbox"
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgres-secret
      key: password
```

### Redis 连接

```yaml
env:
- name: REDIS_HOST
  value: "redis"
- name: REDIS_PORT
  value: "6379"
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: redis-secret
      key: password
```

### MinIO 连接

```yaml
env:
- name: AWS_ENDPOINT
  value: "http://minio-api:9000"
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: minio-secret
      key: root-user
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: minio-secret
      key: root-password
```

## 多环境配置

### 开发环境 (values-dev.yaml)

```yaml
global:
  domain: dev.example.com

phpFpm:
  replicaCount: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

postgresql:
  persistence:
    size: 10Gi

redis:
  persistence:
    size: 2Gi
```

### 生产环境 (values-prod.yaml)

```yaml
global:
  domain: example.com

phpFpm:
  replicaCount: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

postgresql:
  persistence:
    size: 100Gi
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi

redis:
  persistence:
    size: 20Gi
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
```

## 配置最佳实践

### 1. 使用 Secret 管理敏感信息

不要在 values.yaml 中硬编码密码，使用 Kubernetes Secret：

```bash
kubectl create secret generic my-secret \
  -n lunchbox \
  --from-literal=password='secure-password'
```

### 2. 根据环境调整资源

开发环境使用最小资源，生产环境根据负载调整。

### 3. 启用持久化

生产环境必须启用持久化存储：

```yaml
persistence:
  enabled: true
  size: 100Gi
  storageClass: "fast-ssd"  # 使用高性能存储类
```

### 4. 配置健康检查

确保所有服务都配置了正确的健康检查：

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 80
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /health
    port: 80
  initialDelaySeconds: 10
  periodSeconds: 5
```

### 5. 使用镜像标签

生产环境使用具体的镜像标签，不要使用 `latest`：

```yaml
image:
  repository: your-registry/php-fpm
  tag: "v1.2.3"  # 使用具体版本
  pullPolicy: IfNotPresent
```

## 参考资源

- [部署指南](DEPLOYMENT.md)
- [故障排查指南](TROUBLESHOOTING.md)
- [安全配置指南](SECURITY.md)
- [Helm Values 文件](../helm/lunchbox/values.yaml)
