# Lunchbox Kubernetes 故障排查指南

本文档提供常见问题的诊断和解决方案。

## 目录

- [Pod 问题](#pod-问题)
- [网络问题](#网络问题)
- [存储问题](#存储问题)
- [性能问题](#性能问题)
- [应用问题](#应用问题)
- [诊断工具](#诊断工具)

## Pod 问题

### Pod 一直处于 Pending 状态

**症状**: Pod 创建后一直处于 `Pending` 状态

**可能原因**:

1. 资源不足（CPU/内存）
2. PVC 无法绑定
3. 节点选择器不匹配
4. 污点和容忍度问题

**诊断步骤**:

```bash
# 查看 Pod 详情
kubectl describe pod <pod-name> -n lunchbox

# 查看节点资源
kubectl top nodes

# 查看 PVC 状态
kubectl get pvc -n lunchbox

# 查看事件
kubectl get events -n lunchbox --sort-by='.lastTimestamp'
```

**解决方案**:

1. **资源不足**:

   ```yaml
   # 降低资源请求
   resources:
     requests:
       cpu: 50m
       memory: 128Mi
   ```

2. **PVC 问题**:

   ```bash
   # 检查 StorageClass
   kubectl get storageclass
   
   # 手动创建 PV（如果需要）
   kubectl apply -f pv.yaml
   ```

3. **节点问题**:

   ```bash
   # 移除节点污点
   kubectl taint nodes <node-name> key=value:NoSchedule-
   ```

### Pod 处于 CrashLoopBackOff 状态

**症状**: Pod 不断重启

**可能原因**:

1. 应用启动失败
2. 配置错误
3. 依赖服务未就绪
4. 健康检查失败

**诊断步骤**:

```bash
# 查看 Pod 日志
kubectl logs <pod-name> -n lunchbox

# 查看上一次运行的日志
kubectl logs <pod-name> -n lunchbox --previous

# 查看 Pod 详情
kubectl describe pod <pod-name> -n lunchbox

# 进入容器调试
kubectl exec -it <pod-name> -n lunchbox -- /bin/sh
```

**解决方案**:

1. **应用配置错误**:

   ```bash
   # 检查 ConfigMap
   kubectl get configmap -n lunchbox
   kubectl describe configmap <configmap-name> -n lunchbox
   
   # 检查 Secret
   kubectl get secret -n lunchbox
   ```

2. **依赖服务未就绪**:

   ```yaml
   # 添加 initContainer 等待依赖
   initContainers:
   - name: wait-for-db
     image: busybox
     command: ['sh', '-c', 'until nc -z postgres 5432; do sleep 1; done']
   ```

3. **健康检查过于严格**:

   ```yaml
   # 调整健康检查参数
   livenessProbe:
     initialDelaySeconds: 60  # 增加初始延迟
     periodSeconds: 30        # 增加检查间隔
     failureThreshold: 5      # 增加失败阈值
   ```

### Pod 处于 ImagePullBackOff 状态

**症状**: 无法拉取容器镜像

**可能原因**:

1. 镜像不存在
2. 镜像仓库认证失败
3. 网络问题

**诊断步骤**:

```bash
# 查看 Pod 事件
kubectl describe pod <pod-name> -n lunchbox

# 检查镜像拉取密钥
kubectl get secret -n lunchbox
```

**解决方案**:

1. **检查镜像名称**:

   ```yaml
   image:
     repository: your-registry.com/php-fpm
     tag: v1.0.0  # 确保标签存在
   ```

2. **配置镜像拉取密钥**:

   ```bash
   # 创建 Docker Registry Secret
   kubectl create secret docker-registry regcred \
     -n lunchbox \
     --docker-server=your-registry.com \
     --docker-username=your-username \
     --docker-password=your-password \
     --docker-email=your-email@example.com
   ```

   ```yaml
   # 在 values.yaml 中配置
   global:
     imagePullSecrets:
       - regcred
   ```

3. **使用公共镜像仓库**:

   ```yaml
   image:
     repository: docker.io/library/nginx
     tag: alpine
   ```

### Pod 内存溢出 (OOMKilled)

**症状**: Pod 因内存不足被杀死

**诊断步骤**:

```bash
# 查看 Pod 状态
kubectl get pod <pod-name> -n lunchbox

# 查看 Pod 资源使用
kubectl top pod <pod-name> -n lunchbox

# 查看 Pod 事件
kubectl describe pod <pod-name> -n lunchbox | grep -A 5 "OOMKilled"
```

**解决方案**:

```yaml
# 增加内存限制
resources:
  requests:
    memory: 512Mi
  limits:
    memory: 1Gi
```

## 网络问题

### 无法访问应用

**症状**: 通过域名无法访问应用

**可能原因**:

1. DNS 未配置
2. Ingress 配置错误
3. Service 配置错误
4. 防火墙阻止

**诊断步骤**:

```bash
# 检查 DNS 解析
nslookup dev.your-domain.com

# 检查 Traefik Service
kubectl get svc -n traefik

# 检查 IngressRoute
kubectl get ingressroute -n lunchbox
kubectl describe ingressroute <route-name> -n lunchbox

# 检查 Service
kubectl get svc -n lunchbox
kubectl describe svc <service-name> -n lunchbox

# 测试 Service 内部访问
kubectl run -it --rm debug --image=busybox --restart=Never -n lunchbox -- \
  wget -O- http://php-fpm:80
```

**解决方案**:

1. **配置 DNS**:

   ```bash
   # 获取 Traefik LoadBalancer IP
   kubectl get svc -n traefik traefik
   
   # 配置 DNS A 记录
   # dev.your-domain.com -> <TRAEFIK-IP>
   ```

2. **检查 IngressRoute**:

   ```yaml
   apiVersion: traefik.io/v1alpha1
   kind: IngressRoute
   metadata:
     name: app-https
     namespace: lunchbox
   spec:
     entryPoints:
       - websecure
     routes:
     - match: Host(`dev.your-domain.com`)
       kind: Rule
       services:
       - name: php-fpm
         port: 80
     tls:
       certResolver: letsencrypt
   ```

3. **检查 Service 选择器**:

   ```bash
   # 确保 Service 选择器匹配 Pod 标签
   kubectl get pods -n lunchbox --show-labels
   kubectl get svc php-fpm -n lunchbox -o yaml | grep selector
   ```

### Service 无法连接到 Pod

**症状**: Service 创建成功但无法访问 Pod

**诊断步骤**:

```bash
# 检查 Endpoints
kubectl get endpoints -n lunchbox

# 检查 Pod 标签
kubectl get pods -n lunchbox --show-labels

# 检查 Service 选择器
kubectl describe svc <service-name> -n lunchbox
```

**解决方案**:

确保 Service 选择器与 Pod 标签匹配：

```yaml
# Service
selector:
  app: php-fpm

# Pod
labels:
  app: php-fpm
```

### NetworkPolicy 阻止连接

**症状**: 启用 NetworkPolicy 后服务无法通信

**诊断步骤**:

```bash
# 查看 NetworkPolicy
kubectl get networkpolicy -n lunchbox
kubectl describe networkpolicy <policy-name> -n lunchbox

# 临时禁用 NetworkPolicy 测试
kubectl delete networkpolicy --all -n lunchbox
```

**解决方案**:

```yaml
# 调整 NetworkPolicy 规则
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-db
spec:
  podSelector:
    matchLabels:
      app: postgres
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: php-fpm
    ports:
    - protocol: TCP
      port: 5432
```

## 存储问题

### PVC 一直处于 Pending 状态

**症状**: PersistentVolumeClaim 无法绑定

**可能原因**:

1. 没有可用的 PV
2. StorageClass 不存在
3. 存储容量不足

**诊断步骤**:

```bash
# 查看 PVC 状态
kubectl get pvc -n lunchbox
kubectl describe pvc <pvc-name> -n lunchbox

# 查看 PV
kubectl get pv

# 查看 StorageClass
kubectl get storageclass
```

**解决方案**:

1. **使用默认 StorageClass**:

   ```yaml
   persistence:
     storageClass: ""  # 使用默认
   ```

2. **创建 StorageClass**:

   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: fast-ssd
   provisioner: kubernetes.io/aws-ebs
   parameters:
     type: gp3
   ```

3. **手动创建 PV**:

   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: postgres-pv
   spec:
     capacity:
       storage: 20Gi
     accessModes:
       - ReadWriteOnce
     hostPath:
       path: /data/postgres
   ```

### 数据丢失

**症状**: Pod 重启后数据丢失

**可能原因**:

1. 未启用持久化
2. PVC 被删除
3. 使用 emptyDir

**解决方案**:

```yaml
# 启用持久化
persistence:
  enabled: true
  size: 20Gi

# 使用 PVC 而不是 emptyDir
volumes:
- name: data
  persistentVolumeClaim:
    claimName: postgres-data
```

## 性能问题

### 应用响应慢

**症状**: 应用响应时间长

**诊断步骤**:

```bash
# 查看资源使用
kubectl top pods -n lunchbox
kubectl top nodes

# 查看 Pod 日志
kubectl logs <pod-name> -n lunchbox

# 检查数据库连接
kubectl exec -it <php-pod> -n lunchbox -- \
  php artisan tinker
```

**解决方案**:

1. **增加资源**:

   ```yaml
   resources:
     requests:
       cpu: 500m
       memory: 512Mi
     limits:
       cpu: 2000m
       memory: 2Gi
   ```

2. **增加副本数**:

   ```yaml
   replicaCount: 5
   ```

3. **启用 HPA**:

   ```bash
   kubectl autoscale deployment php-fpm \
     -n lunchbox \
     --cpu-percent=70 \
     --min=2 \
     --max=10
   ```

4. **优化数据库**:

   ```sql
   -- 添加索引
   CREATE INDEX idx_users_email ON users(email);
   
   -- 分析查询
   EXPLAIN ANALYZE SELECT * FROM users WHERE email = 'test@example.com';
   ```

### 数据库连接池耗尽

**症状**: 数据库连接错误

**解决方案**:

```yaml
# 增加 PostgreSQL 最大连接数
postgresql:
  config:
    max_connections: 200
```

```php
// Laravel 配置
'connections' => [
    'pgsql' => [
        'pool' => [
            'min' => 2,
            'max' => 20,
        ],
    ],
],
```

## 应用问题

### 数据库连接失败

**症状**: 应用无法连接数据库

**诊断步骤**:

```bash
# 检查 PostgreSQL Pod
kubectl get pods -n lunchbox -l app=postgres

# 测试数据库连接
kubectl exec -it <postgres-pod> -n lunchbox -- \
  psql -U lunchbox -d lunchbox

# 检查 Secret
kubectl get secret postgres-secret -n lunchbox -o yaml

# 从应用 Pod 测试连接
kubectl exec -it <php-pod> -n lunchbox -- \
  nc -zv postgres 5432
```

**解决方案**:

1. **检查环境变量**:

   ```bash
   kubectl exec <php-pod> -n lunchbox -- env | grep DB_
   ```

2. **检查 Service**:

   ```bash
   kubectl get svc postgres -n lunchbox
   kubectl get endpoints postgres -n lunchbox
   ```

3. **检查密码**:

   ```bash
   # 解码 Secret
   kubectl get secret postgres-secret -n lunchbox -o jsonpath='{.data.password}' | base64 -d
   ```

### Redis 连接失败

**症状**: 缓存或队列不工作

**诊断步骤**:

```bash
# 检查 Redis Pod
kubectl get pods -n lunchbox -l app=redis

# 测试 Redis 连接
kubectl exec -it <redis-pod> -n lunchbox -- redis-cli ping

# 从应用 Pod 测试
kubectl exec -it <php-pod> -n lunchbox -- \
  redis-cli -h redis -a <password> ping
```

**解决方案**:

```bash
# 检查 Redis 密码
kubectl get secret redis-secret -n lunchbox -o jsonpath='{.data.password}' | base64 -d

# 重启 Redis
kubectl rollout restart statefulset redis -n lunchbox
```

### 队列任务不执行

**症状**: Laravel Horizon 队列任务堆积

**诊断步骤**:

```bash
# 查看 Horizon Pod 日志
kubectl logs -n lunchbox -l app=php-horizon -f

# 检查 Redis 连接
kubectl exec -it <horizon-pod> -n lunchbox -- \
  php artisan horizon:status
```

**解决方案**:

```bash
# 重启 Horizon
kubectl rollout restart deployment php-horizon -n lunchbox

# 清空失败队列
kubectl exec -it <horizon-pod> -n lunchbox -- \
  php artisan queue:flush
```

## 诊断工具

### 常用命令

```bash
# 查看所有资源
kubectl get all -n lunchbox

# 查看事件
kubectl get events -n lunchbox --sort-by='.lastTimestamp'

# 查看日志
kubectl logs -n lunchbox <pod-name> -f

# 进入容器
kubectl exec -it -n lunchbox <pod-name> -- /bin/sh

# 端口转发
kubectl port-forward -n lunchbox <pod-name> 8080:80

# 查看资源使用
kubectl top nodes
kubectl top pods -n lunchbox
```

### 调试 Pod

创建调试 Pod：

```bash
# 使用 busybox
kubectl run -it --rm debug --image=busybox --restart=Never -n lunchbox -- sh

# 使用 curl
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n lunchbox -- sh

# 使用 PostgreSQL 客户端
kubectl run -it --rm psql --image=postgres:16 --restart=Never -n lunchbox -- \
  psql -h postgres -U lunchbox -d lunchbox
```

### 网络调试

```bash
# DNS 测试
kubectl run -it --rm debug --image=busybox --restart=Never -n lunchbox -- \
  nslookup postgres

# 端口测试
kubectl run -it --rm debug --image=busybox --restart=Never -n lunchbox -- \
  nc -zv postgres 5432

# HTTP 测试
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n lunchbox -- \
  curl -v http://php-fpm:80/health
```

### 日志聚合

使用 Dozzle 查看日志：

```bash
# 访问 Dozzle
https://dozzle.your-domain.com
```

或使用 kubectl：

```bash
# 查看所有 Pod 日志
kubectl logs -n lunchbox --all-containers=true -f

# 查看特定标签的 Pod 日志
kubectl logs -n lunchbox -l app=php-fpm -f

# 查看最近 100 行日志
kubectl logs -n lunchbox <pod-name> --tail=100
```

## 获取帮助

如果问题仍未解决：

1. 收集诊断信息：

   ```bash
   kubectl get all -n lunchbox > debug-info.txt
   kubectl describe pods -n lunchbox >> debug-info.txt
   kubectl get events -n lunchbox >> debug-info.txt
   kubectl logs -n lunchbox <pod-name> >> debug-info.txt
   ```

2. 查看相关文档：
   - [部署指南](DEPLOYMENT.md)
   - [配置指南](CONFIGURATION.md)
   - [安全配置](SECURITY.md)

3. 检查 Kubernetes 官方文档：
   - [Kubernetes 故障排查](https://kubernetes.io/docs/tasks/debug/)
   - [应用调试](https://kubernetes.io/docs/tasks/debug/debug-application/)

4. 社区支持：
   - Kubernetes Slack
   - Stack Overflow
   - GitHub Issues
