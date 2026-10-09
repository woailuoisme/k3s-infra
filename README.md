# k3s-infra

> 生产级单机 4C8G 边缘云主机声明式 GitOps 基础设施（K3s + ArgoCD + Sealed Secrets）

---

## 架构概览

本项目采用 **App-of-Apps** 模式，实现从底层系统、网关存储、数据库、安全鉴权到业务微服务的一键自动化编排与自愈。

- **运行时**：K3s（禁用内置旧版 Traefik 与 ServiceLB，释放系统开销）
- **GitOps 引擎**：ArgoCD v3.0+（官方 Helm Chart 10.x 最小化定制）
- **密钥安全**：Bitnami Sealed Secrets（RSA 4096 离线公钥加密，0 插件依赖）
- **边缘网关**：Traefik v3（自动化 Let's Encrypt 证书、WAF 限流中间件）
- **数据持久层**：CloudNativePG (PostgreSQL 18 HA) + Garage S3 (NVMe 对象存储 / Barman 物理全备) + Valkey 8 (缓存)
- **业务微服务**：`apps/bgin` (Go/Gin REST API + Asynq 队列消费者)

---

## 快速开始

### 1. 宿主机准备与 K3s 初始化

```bash
# 1. 内核调优与 Swap 缓冲 (防止 4C8G 突发 OOM)
sudo sysctl -w vm.swappiness=10
sudo sysctl -w fs.inotify.max_user_watches=524288

# 2. 极简启动 K3s (禁用旧版内置组件)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --disable-cloud-controller \
  --kubelet-arg='eviction-hard=memory.available<250Mi' \
  --kubelet-arg='eviction-minimum-reclaim=memory.available=100Mi' \
  --write-kubeconfig-mode 644" sh -
```

### 2. 注入 Sealed Secrets 离线主私钥 (仅新集群/灾备执行一次)

新集群在启动控制器前需预先导入离线生成的 RSA 私钥（默认读取 `~/.config/sealed-secrets/master.key`）：

```bash
just init-key
```

### 3. 一键部署 ArgoCD 并引导根应用

```bash
# 1. 部署精简版 ArgoCD (Helm 10.x)
just argocd

# 2. 引导 App-of-Apps 根应用 (自动按 Sync Wave 梯度纳管全栈)
just up

# 3. 获取 ArgoCD 初始登录密码
just pass
```

---

## Sync Wave 梯度编排与内存预算 (4C8G)

全栈组件严格按波次梯度启动，杜绝服务冷启动瞬时内存风暴：

| 波次 | 应用组件 | 命名空间 | 内存配额 (Req/Limit) | 核心功能 |
| :--- | :--- | :--- | :--- | :--- |
| **Wave -1** | `00-namespaces`, `00-sealed-secrets` | `kube-system` 等 | 32M / 64M | 全局资源隔离与解密控制器 |
| **Wave 0** | `01-traefik`, `02-garage` | `traefik`, `storage` | 128M / 406M | 边缘入口网关、NVMe 轻量 S3 存储 |
| **Wave 1** | `03-cnpg-operator`, `04-valkey` | `cnpg-system`, `database` | 128M / 384M | PostgreSQL 控制器、内存缓存与会话 |
| **Wave 2** | `03-postgres-cluster`, `05-crowdsec` | `database`, `security` | 576M / 1280M | PostgreSQL 生产集群 (S3 备份)、入侵防御 |
| **Wave 3** | `05-authelia` | `security` | 64M / 128M | 统一身份验证与 2FA ForwardAuth |
| **Wave 4** | `06-meilisearch`, `07-centrifugo`, `07-mosquitto` | `search`, `messaging` | 352M / 768M | 全文搜索、实时 WebSocket 广播、MQTT Broker |
| **Wave 5** | `08-asynqmon`, `08-temporal`, `09-imgproxy`, `10-可观测套件` | `workflows`, `media`, `observability` | 448M / 1152M | 异步监控、工作流、图片处理、OpenObserve |
| **Wave 6** | `20-bgin` | `apps` | 128M / 512M | 自研业务微服务 (Gin API + Worker) |

- **总基础基线 (Requests)**：约 **2.0 GB**
- **极限上限 (Limits)**：约 **5.1 GB**
- **系统与 K3s 预留**：约 **2.9 GB**

---

## 常用开发与运维指令 (`just`)

本项目的所有日常操作已封装为声明式任务，请在根目录执行：

| 指令 | 说明 |
| :--- | :--- |
| `just check` | 运行全量静态检测门禁（YAML, Helm, Kustomize, Gitleaks）（别名：`validate`, `lint`） |
| `just audit` | 运行 Trivy 对全仓 Kubernetes 清单进行安全合规与风险检测（别名：`sec`） |
| `just fmt` | 自动格式化 Shell 脚本与 Markdown 文档（别名：`fix`） |
| `just up` | 引导启动或同步 ArgoCD 根应用 (App-of-Apps)（别名：`bootstrap`） |
| `just ps` | 查看全集群 Pod 运行健康度与 ArgoCD 应用同步状态（别名：`status`） |
| `just sync [app]` | 强制刷新并触发 ArgoCD 应用同步（默认全量，支持 `just sync bgin`）（别名：`refresh`） |
| `just init-key [KEY]` | 注入 Sealed Secrets 离线主私钥并触发自愈解密（别名：`init-secrets`） |
| `just verify` | 检查集群内 13 个 Sealed Secrets 的解密与 Secret 映射状态（别名：`verify-secrets`） |
| `just seal <src> <dst>` | 使用离线公钥加密明文 Secret 并生成入库清单 |
| `just ui` | 端口转发访问本地 ArgoCD 控制台 (`localhost:8080`) |
| `just domain <DOMAIN>` | 全局批量替换所有清单与文档中的主域名（别名：`set-domain`） |
| `just repo <URL>` | 全局批量替换 ArgoCD GitOps 仓库远端地址（别名：`set-repo`） |

---

## 密钥治理法则

- **零明文入库**：敏感数据必须加密为 `*.sealed.yaml` 或 `sealed-secret.yaml` 后方可提交。
- **公私钥分离**：
  - 公钥证书 [`platform/security/sealed-secrets/public-cert.pem`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/platform/security/sealed-secrets/public-cert.pem) 存放在 Git 中供离线加密。
  - 解密私钥必须离线冷存管（如 `$HOME/.config/sealed-secrets/master.key`），严禁入库。
- **极速加密**：

  ```bash
  just seal secret.tmp.yaml platform/gateway/traefik/sealed-secret.yaml
  ```

---

## 常用排错与运维

```bash
# 1. 检查节点内存余量与 Top Pod
free -h
kubectl top pods -A --sort-by=memory | head -n 10

# 2. 手动触发 Postgres 备份至 Garage S3
kubectl cnpg backup postgres-cluster -n database

# 3. 检查 Sealed Secrets 控制器日志
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets --tail=50
```
