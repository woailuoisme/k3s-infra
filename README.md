# k3s-infra

> 生产级单机 4C8G 边缘云主机声明式 GitOps 基础设施（K3s + ArgoCD + OpenBao + ESO）

---

## 架构概览

本项目采用 **App-of-Apps** 模式，实现从底层系统、网关存储、数据库、安全鉴权到业务微服务的一键自动化编排与自愈。

- **运行时**：K3s（禁用内置旧版 Traefik 与 ServiceLB，释放系统开销）
- **GitOps 引擎**：ArgoCD v3.5+（官方 Helm Chart 10.10.2 最小化定制）
- **密钥安全**：OpenBao + External Secrets Operator（开源集中式机密仓库，单副本 Raft 持久化与 Auto-Unseal，声明式 ExternalSecret 自动同步）
- **边缘网关**：Traefik v3（自动化 Let's Encrypt 证书、WAF 限流中间件）
- **数据持久层**：CloudNativePG (PostgreSQL 18 HA) + Garage S3 (NVMe 对象存储 / Barman 物理全备) + Valkey 8 (缓存)
- **业务微服务**：`apps/bgin` (Go/Gin REST API + Asynq 队列消费者)

---

## 快速开始（生产部署执行流程）

如果是全新的一台新服务器/新集群（以 `64.118.150.69` 为例），按顺序执行以下 6 个阶段即可完成全栈一键编排与自愈：

### 阶段 1：更新本地配置与集群凭据拉取

将脚本与 `justfile` 中的默认 IP 调整为 `64.118.150.69`，并通过 SSH 拉取远程 K3s 的集群凭据：

```bash
# 从 VPS 拉取 kubeconfig 并生成本地 ~/.kube/k3s-remote.yaml
just fetch-kube 64.118.150.69

# 验证 kubectl 远程集群连通性
kubectl get nodes
```

### 阶段 2：代码质量卡点与 Git 提交推送

提交当前代码库的 OpenBao/ESO 重构及配置更新，并推送至远端 `origin main`，作为 ArgoCD 单一真实源：

```bash
# 提交配置并推送至 GitHub main
git commit -m "feat(deploy): migrate to openbao eso and update target server to 64.118.150.69"
git push origin main
```

### 阶段 3：引导 ArgoCD 生产实例

在远程集群安装精简生产版 ArgoCD v3.5+ (官方 Helm Chart 10.10.2)：

```bash
# 安装/升级 ArgoCD 控制面
just argocd

# 等待 ArgoCD 控制平面各 Pod 达到就绪状态
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

### 阶段 4：初始化敏感机密层 (OpenBao & ESO)

触发根应用接管（开始 Wave -1 启动），初始化 OpenBao 密钥库并同步全量凭据：

```bash
# 1. 触发根应用接管全栈组件 (App-of-Apps)
just up

# 2. 待 OpenBao Pod 启动后，初始化主密钥与 auto-unseal Secret，配置 ESO 权限
just init-bao

# 3. 将本地 .secrets.env 批量注入 OpenBao，秒级触发 ESO 生成 Kubernetes Secret
just bao-sync
```

### 阶段 5：初始化存储与数据依赖

待 Garage S3 (Wave 0) 启动后，执行单节点布局与存储桶初始化：

```bash
# 初始化 Garage S3 单节点 dc1 布局与业务存储桶 (bgin, postgres-backups 等)
just init-garage
```

### 阶段 6：波次收敛与全集群健康巡检

监控 Wave 1~6 逐步收敛（PostgreSQL 集群、Authelia、Traefik 证书、业务应用等），巡检健康状态与资源水位：

```bash
# 查看全集群 Pod 运行健康度与 ArgoCD 应用同步状态
just ps

# 集群全面健康度巡检 (API, 节点, 异常 Pod, ArgoCD)
just health

# 审计 4C8G 节点 CPU 与内存 Requests/Limits 预占水位
just capacity
```

---

## Sync Wave 梯度编排与内存预算 (4C8G)

全栈组件严格按波次梯度启动，杜绝服务冷启动瞬时内存风暴：

| 波次 | 应用组件 | 命名空间 | 内存配额 (Req/Limit) | 核心功能 |
| :--- | :--- | :--- | :--- | :--- |
| **Wave -1** | `00-namespaces`, `00-openbao`, `00-external-secrets` | `openbao`, `external-secrets` 等 | 110M / 384M | 全局资源隔离、OpenBao 凭据库、ESO 同步 Operator |
| **Wave 0** | `01-traefik`, `02-garage` | `traefik`, `storage` | 128M / 406M | 边缘入口网关、NVMe 轻量 S3 存储 |
| **Wave 1** | `03-cnpg-operator`, `04-valkey` | `cnpg-system`, `database` | 128M / 384M | PostgreSQL 控制器、内存缓存与会话 |
| **Wave 2** | `03-postgres-cluster`, `05-crowdsec` | `database`, `security` | 576M / 1280M | PostgreSQL 生产集群 (S3 备份)、入侵防御 |
| **Wave 3** | `05-authelia` | `security` | 64M / 128M | 统一身份验证与 2FA ForwardAuth |
| **Wave 4** | `06-meilisearch`, `07-centrifugo`, `07-mosquitto` | `search`, `messaging` | 352M / 768M | 全文搜索、实时 WebSocket 广播、MQTT Broker |
| **Wave 5** | `08-asynqmon`, `09-imgproxy`, `10-beszel/gatus/homepage/dozzle/openobserve` | `workflows`, `media`, `observability` | 472M / 1216M | 异步队列监控、图片处理、主机监控、健康探测、应用导航、日志追踪 |
| **Wave 6** | `20-bgin` | `apps` | 128M / 512M | 自研业务微服务 (Gin API + Worker) |

- **总基础基线 (Requests)**：约 **2.2 GB**
- **极限上限 (Limits)**：约 **5.5 GB**
- **系统与 K3s 预留**：约 **2.5 GB**

---

## 常用开发与运维指令 (`just`)

本项目的所有日常操作已封装为声明式任务，请在根目录执行：

| 指令 | 说明 |
| :--- | :--- |
| `just check` | 运行全量静态检测门禁（YAML, Kustomize, Schema, Helm, Gitleaks）（别名：`lint`） |
| `just audit` | 运行 Trivy 对全仓 Kubernetes 清单进行安全合规与风险检测 |
| `just capacity` | 查看全集群 CPU 与内存 Requests/Limits 预占水位 |
| `just fmt` | 自动格式化 Shell 脚本与 Markdown 文档 |
| `just up` | 引导启动或同步 ArgoCD 根应用 (App-of-Apps) |
| `just ps` | 查看全集群 Pod 运行健康度与 ArgoCD 应用同步状态 |
| `just sync [app]` | 强制刷新并触发 ArgoCD 应用同步（默认全量，支持 `just sync bgin`） |
| `just init-bao` | 初始化 OpenBao，生成 auto-unseal Secret，启用 KV v2 与 K8s 鉴权并配置 ESO RBAC 策略 |
| `just bao-sync [target] [file]` | 批量或指定组件从本地 `.secrets.env` 同步机密至 OpenBao 并立即触发 ESO 生效 |
| `just bao-ui` | 本地端口转发快速访问 OpenBao 控制台 (`localhost:8200`) |
| `just argo-ui` | 端口转发访问本地 ArgoCD 控制台 (`localhost:8080`)（别名：`ui`） |
| `just domain <DOMAIN>` | 全局批量替换所有清单与文档中的主域名 |
| `just repo <URL>` | 全局批量替换 ArgoCD GitOps 仓库远端地址 |

---

## 密钥治理法则

### 1. 核心架构 (OpenBao + External Secrets Operator)

平台采用开源安全凭据库 **OpenBao** 配合 **External Secrets Operator (ESO)** 实现云原生声明式密钥管理：

- **集中凭据保管 (OpenBao)**：
  - 运行在 `openbao` 命名空间，单副本 Raft 嵌入式存储，挂载 `local-path` PVC (2Gi) 持久化。
  - 挂载 KV v2 引擎于 `secret/`，路径约定为 `<namespace>/<secret-name>`（例如 `secret/data/apps/bgin-secret`）。
  - 内存占用极简（约 80-120MB），完全满足 4C8G 规格下的高可靠持久化。
- **声明式同步 (External Secrets Operator)**：
  - 部署全局 `ClusterSecretStore` (`openbao-backend`)，基于 Kubernetes 原生 ServiceAccount TokenRequest 鉴权访问 OpenBao。
  - 各应用与组件通过 `external-secret.yaml` 清单声明所需的敏感配置，ESO 自动从 OpenBao 拉取并渲染为标准 Kubernetes Secret。
  - 支持定时刷新（`refreshInterval: 1h`）与自动生命周期同步。
- **零人工运维自愈 (Auto-Unseal)**：
  - OpenBao 实例内置 `auto-unseal-helper` sidecar 容器。
  - 自动读取 Secret `openbao-unseal-key` 执行解封，VPS 重启或 Pod 漂移时无需人工登录执行 `vault operator unseal`。

### 2. 极简密钥运维流程 (声明式工作流)

```bash
# 1. 统一单文件配置初始化 (复制模版并填入真实参数)
cp .secrets.env.example .secrets.env

# 2. 一键批量同步全集群机密至 OpenBao (并立即触发 ESO 秒级刷新至集群)
just bao-sync

# 亦支持仅同步指定单组件机密 (例如: just bao-sync bgin)
just bao-sync bgin

# 3. 端口转发访问 OpenBao Web 控制台查看与核验 (localhost:8200)
just bao-ui
```

### 3. 查看与审计 Secret 明文

- **OpenBao Web 控制台 (`just bao-ui`)**：
  访问 `http://localhost:8200`，输入初始化生成的 root_token（或 `cat ~/.config/openbao/cluster-keys.json | jq -r .root_token`），即可在可视化界面浏览、搜索与管理全量机密。

- **原生 `kubectl` 查看**：

  ```bash
  # 1. 一键解码整个 Secret 的所有明文字段 (配合 jq)
  kubectl get secret cloudflare-api-token -n traefik -o json | jq '.data | map_values(@base64d)'

  # 2. 提取单个字段明文
  kubectl get secret cloudflare-api-token -n traefik -o jsonpath='{.data.CF_DNS_API_TOKEN}' | base64 -d; echo
  ```

- **终端可视化查看 (`k9s`)**：
  运行 `k9s` → 输入 `:secret` 进入 Secret 列表 → 光标移动到目标 Secret 按键盘快捷键 **`x`**，即可直接高亮查看所有字段解码后的明文。

---

## 常用排错与运维

```bash
# 1. 检查节点内存余量与 Top Pod
free -h
kubectl top pods -A --sort-by=memory | head -n 10

# 2. 手动触发 Postgres 备份至 Garage S3
kubectl cnpg backup postgres-cluster -n database

# 3. 检查 External Secrets Operator 日志
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50
```
