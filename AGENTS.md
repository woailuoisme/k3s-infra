# AGENTS.md

欢迎！本文档旨在为 AI 编程助手（Cursor、Aider、Gemini CLI 等）以及自动化工具提供针对 `woailuoisme/k3s-infra` 仓库的完整技术背景、架构模式、工程规范与操作指引。

---

## 1. 项目概览

`k3s-infra` 是专为单台边缘云主机（标准 4C 8G 硬件规格：4 核 vCPU、8GB 内存）量身定制的生产级声明式 GitOps 基础设施仓库。项目借助 **K3s** 与 **ArgoCD v3.0+**，采用行业标准的 **App-of-Apps（应用之应用）** 模式，实现全栈云原生底层基建、数据持久层、可观测性及业务微服务的一键自动化编排与自愈。

### 核心技术栈

- **集群运行时**：K3s（禁用内置旧版 Traefik 与 ServiceLB，释放系统内存）。
- **GitOps 引擎**：ArgoCD（v3.0+，基于官方 Helm Chart 10.x 最小化定制部署），实现以 Git 提交为单一真实源的持续交付。
- **打包与清单管理**：
  - 上游平台中间件：ArgoCD 远端 Helm Chart（拒绝拷贝上游 Chart 导致代码仓库膨胀）。
  - 集群粘合剂与自研应用：原生 Kustomize（位于 `apps/` 目录及各类自定义 CRD 清单）。
  - 混合交付架构：ArgoCD **Multiple Sources（多数据源）** 模式（如 Traefik 官方 Helm Chart + 本地 Git 仓内安全中间件）。
- **核心平台组件**：
  - **边缘入口网关**：Traefik v3（自动化 Let's Encrypt DNS-01 证书申请、安全防护中间件、WAF 限流）。
  - **对象存储**：Garage S3（Rust 编写的高性能 NVMe 轻量对象存储，0 JVM 内存常驻）。
  - **数据库与缓存**：CloudNativePG（PostgreSQL 18 生产集群，集成 Garage S3 Barman 物理全备），Valkey 8（高性能内存键值缓存与分布式锁）。
  - **安全与身份认证**：Authelia（单点登录 SSO / 二阶段验证 2FA / ForwardAuth 网关认证），CrowdSec（协同式 IPS/IDS 入侵防御系统）。
  - **搜索与实时通信**：Meilisearch（毫秒级全文本搜索引擎），Centrifugo（高并发 WebSocket 实时推送引擎），Mosquitto（轻量 MQTT 物联网消息代理）。
  - **异步任务与业务编排**：Asynqmon（Redis 异步队列可视化面板），Temporal（分布式高容错工作流引擎）。
  - **多媒体处理**：Imgproxy（高性能动态图片即时缩放与格式转换）。
  - **全栈可观测性**：Dozzle（轻量容器实时日志流查看器），OpenObserve（日志、指标、链路追踪三合一轻量平台），OpenTelemetry Collector（全集群遥测指标采集与转发代理）。
  - **业务核心服务**：`apps/bgin`（Go/Gin 高性能 REST API + Asynq 异步后台队列消费者）。
- **敏感机密管理**：Sealed Secrets（RSA 4096 离线公钥加密，原生 CRD 声明式存管，解密控制器常驻约 20MB 内存，ArgoCD 原生识别、零插件依赖）。

---

## 2. 仓库目录结构

```text
k3s-infra/
├── .github/workflows/       # GitHub Actions 自动化 CI 门禁流水线 (gitops-ci.yml, docker-build-push.yml)
├── apps/                    # 自研业务微服务 (基于 Kustomize 声明式打包)
│   └── bgin/                # Gin API + Asynq Worker 负载清单与 kustomization.yaml
├── bootstrap/               # ArgoCD App-of-Apps 根应用引导入口与子应用声明
│   ├── applications/        # 00-namespaces.yaml ... 20-bgin.yaml (严格按 Sync Wave 波次排序)
│   ├── argocd-values.yaml   # ArgoCD 生产精简版 Helm Values 配置
│   └── root-app.yaml        # ArgoCD 根应用 (App-of-Apps Entrypoint)
├── platform/                # 平台级基础设施组件配置
│   ├── core/                # 全局命名空间、PriorityClass 优先级、LimitRange 防爆规则
│   ├── gateway/traefik/     # Traefik Helm Values、安全中间件与独立 Kustomization
│   ├── storage/garage/      # Garage S3 部署清单与自动化初始化 Job
│   ├── database/postgres/   # CloudNativePG 数据库集群配置与声明式初始化 SQL
│   ├── cache/valkey/        # Valkey 缓存部署与资源限额
│   ├── security/            # Authelia, CrowdSec 安全与权限配置
│   ├── search/meilisearch/  # Meilisearch 搜索引擎清单
│   ├── messaging/           # Centrifugo, Mosquitto 消息中间件
│   ├── workflows/           # Asynqmon, Temporal 工作流与任务编排
│   ├── media/imgproxy/      # Imgproxy 部署清单
│   └── observability/       # Dozzle, OpenObserve, OpenTelemetry Collector 可观测套件
├── docs/                    # 架构手册与运维实战指南 (GITOPS_GUIDE.md)
├── justfile                 # 项目核心工作流与运维任务运行器
├── lefthook.yml             # 本地 Git 提交/推送前自动化检查钩子
├── .mise.toml               # 统一工具链依赖与版本管理声明 (just, kubectl, helm, linters)
├── platform/security/sealed-secrets/ # Sealed Secrets 离线公钥证书 (public-cert.pem)
└── AGENTS.md                # AI 编程助手专属上下文与规范指南 (本文档)
```

---

## 3. 环境与工具链配置

本项目所有 CLI 工具版本与依赖均在 [`.mise.toml`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/.mise.toml) 中统一维护。

```bash
# 1. 通过 mise 安装本仓库所需的全套 CLI 工具链
mise install

# 2. 安装本地 Git 预提交检查钩子
lefthook install
```

### 必备核心命令行工具

- `just`：自动化任务运行器（对应根目录 [`justfile`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/justfile)）。
- `kubectl` 与 `helm`：Kubernetes 集群交互与 Helm 包管理器。
- `yamllint`：YAML 文件静态语法与缩进格式校验。
- `hadolint`：Dockerfile 规范与最佳实践检测。
- `shellcheck` 与 `shfmt`：Shell 脚本语法检查与格式化工具。
- `actionlint`：GitHub Actions Workflow 语法校验器。
- `rumdl`：Markdown 规范校验与代码格式化工具。

---

## 4. 开发与日常运维指令

请始终从仓库根目录执行 `just` 任务。**严禁编写临时 ad-hoc 脚本**，优先复用已有工作流：

| 命令 | 用途说明 |
| :--- | :--- |
| `just check` | 运行全量静态检测门禁（别名：`validate`, `lint`） |
| `just fmt` | 自动格式化所有 Shell 脚本 (`shfmt`) 与 Markdown 文档 (`rumdl fmt`)（别名：`fix`） |
| `just render [app]` | 渲染指定应用的 Kustomize 最终清单至终端（默认应用：`bgin`，别名：`template`） |
| `just import-image [IMG]` | 快速拉取或导入预构建镜像至 K3s containerd（默认：`jiaoio/postgres:18-trixie`） |
| `just set-repo <URL>` | 全局批量替换 `bootstrap/*.yaml` 中的 GitOps 仓库远端地址 |
| `just set-domain <DOMAIN>` | 全局批量替换所有 YAML 清单与文档中的根域名 |
| `just argocd` | 基于官方 Helm Chart 10.x 部署或就地升级 ArgoCD 到 v3.0+ 精简生产版 |
| `just pass` | 快速获取 ArgoCD 初始 admin 登录密码并自动 base64 解密输出 |
| `just ui` | 本地端口转发快速访问 ArgoCD 控制台（8080 端口） |
| `just up` | 触发集群 GitOps 全量声明式接管（`kubectl apply -f bootstrap/root-app.yaml`，别名：`bootstrap`） |
| `just ps` | 查看 ArgoCD 应用全量同步状态及集群内所有 Pod 运行健康度（别名：`status`） |

---

## 5. 测试与质量卡点门禁

在提交任何代码或配置变更前，必须确保 100% 通过各项自动化检测：

### 本地验证工作流

```bash
# 1. 运行所有 Kubernetes 静态语法及 linter 检测
just validate

# 2. 检查 GitHub Actions 流水线语法（若修改过 .github/workflows/ 目录文件）
actionlint .github/workflows/*.yml

# 3. 自动对齐代码与文档格式
just fmt

# 4. 模拟运行 Git 预提交钩子
lefthook run pre-commit
```

### 远端 CI 自动化质量卡点

GitHub Actions 流水线 [`.github/workflows/gitops-ci.yml`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/.github/workflows/gitops-ci.yml) 会在每次 PR 与推送到 `main` 分支时自动触发：

- 对全仓 YAML 执行 `yamllint` 检查。
- 对所有 Dockerfile 执行 `hadolint` 规范扫描。
- 对所有 Shell 脚本执行 `shellcheck` 校验。
- 对所有 Workflow 执行 `actionlint` 检查。
- 执行 `just validate`，确保每个 Kustomize 目录均能正常渲染且无语法漂移。

---

## 6. 代码风格与 GitOps 架构准则

### 6.1 混合 GitOps 交付法则 (Helm + Kustomize)

- **三方平台组件与官方 Operator**：
  - 在 `bootstrap/applications/<序号>-<名称>.yaml` 中声明为 ArgoCD 远端官方 Helm Source。
  - 自定义参数统一存放于 `platform/<领域>/<组件>/values.yaml`（或特定 `*-values.yaml`）。
  - **严禁**将上游体量庞大的官方 Helm Chart 源码直接复制到本仓库中。
- **自研应用与集群粘合层**：
  - 存放在 `apps/` 或 `platform/` 目录下，采用纯净的 Kustomize 清单进行声明。
  - 清单应当保持模块化、结构清晰，避免引入过度复杂的模板拼接。
- **Multiple Sources 架构解耦原则 (Decoupling & DRY)**：
  - 当三方组件依赖自定义资源（例如 Traefik 的安全中间件 CRD、IngressRoute）时，**禁止**在 `values.yaml` 的 `extraObjects` 中内联上百行 YAML。
  - 应将自定义资源抽离到独立的 `kustomization.yaml` 中，并在 ArgoCD 声明中使用 `sources:` 双源机制：源 1（上游官方 Helm Chart）+ 源 2（本地 Git Kustomize 路径）。

### 6.2 零 `:latest` 镜像标签发布规范

- 生产环境中**绝对禁止**使用 `:latest` 容器镜像标签。
- 针对三方工具与辅助 Job（如初始化 Pod、kubectl 容器），必须显式锁死具体 SemVer 版本（例如：`bitnami/kubectl:1.32.2`）。
- 针对自研业务（如 `apps/bgin`），必须在对应 `kustomization.yaml` 中使用 `images:` 块进行声明式映射：

  ```yaml
  images:
    - name: ghcr.io/woailuoisme/bgin
      newTag: v1.0.0
  ```

  Deployment 等工作负载清单中只写基础镜像名称，不得硬编码版本标签。

### 6.3 Sync Wave 梯度波次编排

`bootstrap/applications/` 目录下的所有 ArgoCD Application 均须配置 `argocd.argoproj.io/sync-wave` 注解，按依赖层级梯度启动，彻底规避 4C8G 规格下的启动内存瞬时洪峰：

```text
Wave -1 : 00-namespaces (命名空间、PriorityClass、LimitRange), 00-sealed-secrets (解密控制器)
Wave  0 : 01-traefik (边缘网关), 02-garage (S3 对象存储底层)
Wave  1 : 03-cnpg-operator (数据库控制器), 04-valkey (内存缓存层)
Wave  2 : 03-postgres-cluster (HA 核心数据库), 05-crowdsec (协同安全防御)
Wave  3 : 05-authelia (SSO / 身份认证)
Wave  4 : 06-meilisearch (搜索), 07-centrifugo (WebSocket 推送), 07-mosquitto (MQTT 代理)
Wave  5 : 08-asynqmon, 08-temporal, 09-imgproxy, 10-dozzle, 10-openobserve, 10-otel-collector
Wave  6 : 20-bgin (自研业务后端负载)
```

新增任何应用或服务时，必须根据其上下游依赖严格选定对应的 Sync Wave。

### 6.4 资源预算管理 (4C 8G 防御体系)

每个 Pod / Deployment 工作负载清单**必须**明确定义资源配额：

- `resources.requests`：服务正常运行所需的最低内存与 CPU 资源。
- `resources.limits`：防止内存泄漏击穿节点的上限硬限制。
- `priorityClassName`：
  - `system-critical`：存储（Garage S3）、核心数据库（PostgreSQL、Valkey）。
  - `platform-core`：入口网关（Traefik）、安全组件（Authelia、CrowdSec）。
  - `workload-standard`：业务应用（`bgin`）及各类可观测性套件。

### 6.5 密钥安全与敏感数据治理

- **严禁**将明文密码、API Token 或敏感证书提交至 Git 仓库。
- 敏感 Secret 清单必须通过 Sealed Secrets 转换为标准的 `SealedSecret` CRD（`*.sealed.yaml` 或 `sealed-secret.yaml`）。
- 使用 `platform/security/sealed-secrets/public-cert.pem` 离线公钥证书进行加密，解密主私钥离库离线安全存管。
- 集群运行时由 `sealed-secrets-controller` 自动解密生成标准 Kubernetes Secret，ArgoCD 零插件负担、原生识别与同步。

---

## 7. PR 提交与 Commit 规范

- **Commit 信息格式**：严格遵循 [Conventional Commits](https://www.conventionalcommits.org/) 约定规范：
  - `feat(gateway): add traefik ratelimit middleware`
  - `fix(postgres): adjust memory limit to 1024Mi`
  - `chore(ci): update hadolint action version`
  - `docs(gitops): update sync wave table`
- **提交前置校验**：所有分支合并与提交前，本地必须通过 `just validate` 与 `actionlint .github/workflows/*.yml`。

---

## 8. AI Agent 运维避坑指南

1. **受限沙箱环境中的 Git 执行**：
   在无权限读取宿主机 `~/.gitconfig` 的沙箱环境中运行 `git` 时，务必添加 `GIT_CONFIG_GLOBAL=/dev/null` 前缀（例如：`GIT_CONFIG_GLOBAL=/dev/null git status`）。
2. **仓库地址与域名批量更新**：
   **切勿**跨数十个 YAML 文件逐一手动查找替换仓库 URL 或根域名。请直接运行 `just set-repo <URL>` 或 `just set-domain <DOMAIN>`。
3. **Markdown 格式化规范**：
   新建或编辑的任何 Markdown 文件均须符合 [`.rumdl.toml`](file:///Users/seaside/Projects/devops/k3s/k3s-infra/.rumdl.toml) 规则。编辑后请统一执行 `just fmt`。
4. **保持 GitOps 声明式纯粹性**：
   **切勿**针对已被 ArgoCD 接管纳管的集群资源建议执行命令式的 `kubectl apply -f ...`。所有变更应通过修改 Git 代码库触发 ArgoCD 自动比对与同步。
