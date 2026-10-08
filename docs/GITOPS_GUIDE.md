# 4C8G 单机 K3s + ArgoCD + GitHub 现代 GitOps 运维实战手册

本文档为基于单台 **4C 8G 服务器**（4 vCPU, 8GB RAM）部署与运维 **K3s + ArgoCD + GitHub** 极简生产级 GitOps 的权威操作指南。

---

## 目录

1. [4C8G 宿主机与 K3s 调优初始化](#1-4c8g-宿主机与-k3s-调优初始化)
2. [SOPS + Age 密钥对配置 (0 内存常驻)](#2-sops--age-密钥对配置-0-内存常驻)
3. [ArgoCD 精简安装与 Root-App 引导](#3-argocd-精简安装与-root-app-引导)
4. [GitHub Actions 自动回写与 Webhook 极速触发](#4-github-actions-自动回写与-webhook-极速触发)
5. [常用运维与灾备指令](#5-常用运维与灾备指令)

---

## 1. 4C8G 宿主机与 K3s 调优初始化

### 1.1 系统内核与 Swap 调优

单台 4C8G 服务器建议配置 2GB-4GB 的 ZRAM 或 NVMe Swap 作为防御性缓冲，防止突发流量直接触发内核 Panic：

```bash
# 1. 开启或优化 Swap（使用 swappiness=10 避免频繁换页）
sudo sysctl -w vm.swappiness=10
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=8192

# 写入持久化配置
sudo tee -a /etc/sysctl.d/99-k3s-tuning.conf <<EOF
vm.swappiness=10
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
EOF
```

### 1.2 极简启动 K3s

**必须禁用 K3s 自带的旧版 Traefik 与 ServiceLB**，释放内存并避免与 ArgoCD 纳管的最新官方 Traefik 产生状态冲突：

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --disable-cloud-controller \
  --kubelet-arg='eviction-hard=memory.available<250Mi' \
  --kubelet-arg='eviction-minimum-reclaim=memory.available=100Mi' \
  --write-kubeconfig-mode 644" sh -
```

验证 K3s 运行状态：

```bash
kubectl get nodes -o wide
# 确保 Ready 且无多余组件占用
```

---

## 2. SOPS + Age 密钥对配置 (0 内存常驻)

### 2.1 本地安装与生成 Age 密钥

在您本地工作站（开发机）上执行：

```bash
# macOS
brew install age sops

# 生成 age 密钥对 (注意保管好私钥)
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# 查看生成的公钥 (形如 age1...)
cat ~/.config/sops/age/keys.txt | grep "public key"
```

### 2.2 更新仓库公钥

将生成的公钥填入本仓库根目录的 [`.sops.yaml`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/.sops.yaml) 中：

```yaml
creation_rules:
  - path_regex: .*\.enc\.ya?ml$
    age: "您的_AGE_PUBLIC_KEY"
```

### 2.3 注入私钥至 K3s 集群 (仅需执行一次)

将本地生成的私钥写入 K3s 集群中，供 ArgoCD 容器在内存中按需热解密：

```bash
kubectl create namespace argocd
kubectl create secret generic helm-secrets-private-keys \
  -n argocd \
  --from-file=key.txt=$HOME/.config/sops/age/keys.txt
```

---

## 3. ArgoCD 精简安装与 Root-App 引导

### 3.1 使用官方 Helm Chart 部署精简版 ArgoCD (v3.0+ / Chart 10.x)

采用我们在 [`bootstrap/argocd-values.yaml`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/bootstrap/argocd-values.yaml) 中优化的轻量配置（适配 ArgoCD v3.0+ 细粒度 RBAC、禁用 Dex、裁剪 Redis、注入 SOPS+Age）：

可以直接使用 just 命令一键部署或升级：

```bash
just install-argocd

# 或者手动执行官方 Helm 安装：
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version "^10.0.0" \
  --values bootstrap/argocd-values.yaml
```

获取 ArgoCD 初始登录密码：

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
```

### 3.2 引导 App-of-Apps 根应用

执行此命令后，ArgoCD 将自动接管全量命名空间、平台中间件与业务应用：

```bash
kubectl apply -f bootstrap/root-app.yaml
```

### 3.3 全栈 16 组件波次编排与内存矩阵 (4C8G 规格)

平台原生承载全量云原生基础设施与 IoT 行业业务产品，按照 **Sync Waves 严格波次** 梯度启动，杜绝服务启动时产生瞬时内存洪峰：

| 波次 (Sync Wave) | 领域组件 | 命名空间 | 内部访问端点 | 内存预算 (Req/Limit) | 功能特性 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Wave -1** | `00-namespaces` (`platform/core`) | 全局 | - | - | 10 个命名空间隔离、三级 `PriorityClass` OOM 防御与防爆 `LimitRange` 守护 |
| **Wave 0** | `01-traefik` | `traefik` | `traefik.traefik.svc:80/443` | 64M / 150M | 边缘入口网关 (Let's Encrypt DNS-01 + WAF) |
| **Wave 0** | `02-garage` | `storage` | `garage.storage.svc:3900` | 64M / 256M | 轻量 NVMe 驱动的对象存储 (S3 API / WebUI) |
| **Wave 1** | `03-cnpg-operator` | `cnpg-system` | - | 64M / 128M | CloudNative-PG 官方云原生数据库控制器 |
| **Wave 1** | `04-valkey` | `database` | `valkey-primary.database.svc:6379` | 64M / 256M | 内存键值缓存、分布式锁与会话 (`maxmemory 192M`) |
| **Wave 2** | `03-postgres-cluster`| `database` | `postgres-cluster-rw.database.svc:5432` | 512M / 1024M | 生产多模核心库 (带 Garage S3 Barman 物理全备) |
| **Wave 2** | `05-crowdsec` | `security` | `crowdsec-service.security.svc:8080` | 64M / 256M | 协同入侵防御与恶意 IP 拦截 (SQLite WAL 模式) |
| **Wave 3** | `05-authelia` | `security` | `authelia.security.svc:9091` | 64M / 128M | 统一身份验证、2FA 与前置鉴权中间件 |
| **Wave 3** | `06-meilisearch` | `search` | `meilisearch.search.svc:7700` | 256M / 512M | 轻量级毫秒全文检索 (NVMe 持久化) |
| **Wave 3** | `07-centrifugo` | `messaging` | `centrifugo.messaging.svc:8000` | 64M / 128M | 实时长连接 WebSocket / SSE 广播 (对齐 Valkey) |
| **Wave 3** | `07-mosquitto` | `messaging` | `mosquitto.messaging.svc:1883/9001` | 32M / 128M | 物联网与设备端轻量 MQTT Broker (带持久化卷) |
| **Wave 3** | `08-temporal` | `workflows` | `temporal.workflows.svc:7233/8233` | 128M / 384M | 分布式微服务编排与持久工作流引擎 |
| **Wave 3** | `08-asynqmon` | `workflows` | `asynqmon.workflows.svc:8080` | 32M / 64M | Asynq 分布式异步任务队列监控面板 (接入 Valkey) |
| **Wave 3** | `09-imgproxy` | `media` | `imgproxy.media.svc:8080` | 64M / 256M | 极速动态图片裁剪、缩放与 WebP/AVIF 协商 |
| **Wave 3** | `10-openobserve` | `observability`| `openobserve.observability.svc:5080` | 256M / 512M | 极简云原生日志/指标/链路观测 (持久化至 Garage S3) |
| **Wave 3** | `10-otel-collector` | `observability`| `otel-collector.observability.svc:4317/4318` | 64M / 128M | 统一遥测网关背压清洗管道 |
| **Wave 3** | `10-dozzle` | `observability`| `dozzle.observability.svc:8080` | 32M / 64M | 实时 Pod 流式日志查看器 (原生 K8s RBAC 模式) |
| **Wave 4** | `20-bgin` | `apps` | `bgin.apps.svc:3300` | 128M / 512M | 自研业务微服务 (Go Gin API + Bun Worker 共享存储) |

- **总基准内存占用 (Requests)**: 约 **2.0 GB**
- **全服务极限峰值配额 (Limits)**: 约 **5.1 GB**
- **主机系统与 K3s 控制面保底余量**: 约 **2.9 GB**，完美契合 4C8G 物理硬约束。

可以在 ArgoCD Web UI 或通过 CLI 观测各波次（Sync Waves）的启动：

```bash
# 观测 Pod 内存与状态
kubectl get pods -A
kubectl top pods -A
```

### 3.4 边缘三级 OOM 驱逐防御机制 (PriorityClass)

针对 4C8G 物理硬约束与工控机可能面临的无预警瞬时流量或内存挤压，平台落地严格的三级调度与驱逐优先级：

1. **`edge-critical` (优先级 1,000,000)**：核心基础设施（`Postgres`, `Mosquitto`, `Traefik`）。节点内存承压时由内核保护，绝不主动驱逐，守护离线售货、硬件通信与流量入口；
2. **`platform-standard` (优先级 500,000)**：通用平台与自研业务应用（`Valkey`, `Garage`, `Centrifugo`, `Temporal`, `Bgin` 等）；
3. **`observability-low` (优先级 100,000)**：可观测性与监控探针（`Dozzle`, `OpenObserve`, `Otel Collector`）。当内存逼近安全阈值时，kubelet 优先驱逐此类 Pod 立即释放物理内存，杜绝雪崩。

---

## 4. GitHub Actions 自动回写与 Webhook 极速触发

### 4.1 自动回写 Image Tag

当业务应用构建完成后，在 GitHub Actions 工作流末尾自动修改 `apps/bgin/kustomization.yaml` 中的镜像标签并提交：

```yaml
- name: Update GitOps Tag
  run: |
    cd apps/bgin
    kustomize edit set image ghcr.io/woailuoisme/gin-bun:${{ github.sha }}
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add kustomization.yaml
    git commit -m "chore: release bgin ${{ github.sha }} [skip ci]"
    git push
```

### 4.2 配置 GitHub Webhook 瞬时同步

在 GitHub 仓库设置中添加 Webhook：

- **Payload URL**: `https://<YOUR_DOMAIN>/api/webhook`
- **Content type**: `application/json`
- **Secret**: 与 ArgoCD 凭据中配置的 Webhook Secret 一致
- **Events**: 仅勾选 `Pushes`

ArgoCD 将在推送后 **3 秒内** 完成 Pod 零停机滚动更新。

---

## 5. 常用运维与灾备指令

### 5.1 监控 4C8G 内存水位

```bash
# 查看节点整体内存余量
free -h

# 查看占用内存最高的 Top 10 Pod
kubectl top pods -A --sort-by=memory | head -n 11
```

### 5.2 Postgres (CNPG) 手动全备与状态查询

```bash
# 查看 CNPG 集群健康状态
kubectl cnpg status postgres-cluster -n database

# 手动触发一次快照备份至 Garage S3
kubectl cnpg backup postgres-cluster -n database
```

### 5.3 检查 Garage S3 桶内备份文件

```bash
# 查看 S3 备份存储桶状态
kubectl exec -it -n storage garage-0 -- /garage status
kubectl exec -it -n storage garage-0 -- /garage bucket list
```

### 5.4 全局一键切换根域名

如需更换集群根域名（例如从 `mso.lol` 迁移至自定义生产主域名）：

```bash
# 一键扫描替换全库 YAML、Helm values、Traefik 路由与配置，并自动执行完整语法校验
just set-domain <新域名>

# 查看变更范围
git diff
```
