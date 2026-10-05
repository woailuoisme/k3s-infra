# ArgoCD GitOps 配置

本目录包含 ArgoCD GitOps 工作流的所有配置文件。

## 目录结构

```text
argocd/
├── applications/              # ArgoCD Application 资源
│   ├── application-github.yaml    # GitHub 仓库配置
│   ├── application-gitea.yaml     # Gitea 仓库配置
│   ├── application-gitee.yaml     # Gitee 仓库配置
│   ├── application-dev.yaml       # 开发环境
│   ├── application-staging.yaml   # 预发布环境
│   └── application-prod.yaml      # 生产环境
├── repo-secrets/              # Git 仓库凭证
│   ├── repo-secret-github.yaml    # GitHub 凭证
│   ├── repo-secret-gitea.yaml     # Gitea 凭证
│   ├── repo-secret-gitee.yaml     # Gitee 凭证
│   └── README.md                  # 凭证配置说明
├── webhook-examples/          # Webhook 配置示例
│   ├── github-webhook-config.json
│   ├── gitea-webhook-config.json
│   ├── gitee-webhook-config.json
│   └── README.md
├── WEBHOOK.md                 # Webhook 配置指南
└── README.md                  # 本文件
```

## 快速开始

### 1. 安装 ArgoCD

```bash
# 创建 argocd 命名空间
kubectl create namespace argocd

# 安装 ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等待所有 Pod 运行
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

### 2. 访问 ArgoCD UI

#### 方式 A: 使用 Port Forward（本地开发）

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

访问：<https://localhost:8080>

#### 方式 B: 使用 Ingress（生产环境）

创建 Ingress 资源：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  rules:
  - host: argocd.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
  tls:
  - hosts:
    - argocd.example.com
    secretName: argocd-tls
```

### 3. 获取初始密码

```bash
# 获取 admin 密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 4. 登录 ArgoCD CLI

```bash
# 安装 ArgoCD CLI
brew install argocd

# 登录
argocd login localhost:8080 --username admin --password <password>

# 修改密码（推荐）
argocd account update-password
```

### 5. 配置 Git 仓库凭证

根据你使用的 Git 仓库类型，配置对应的凭证：

```bash
# 编辑对应的 Secret 文件
vim repo-secrets/repo-secret-github.yaml  # 或 gitea/gitee

# 应用到集群
kubectl apply -f repo-secrets/repo-secret-github.yaml
```

详细说明请参考 [repo-secrets/README.md](repo-secrets/README.md)

### 6. 部署 Application

#### 选择仓库类型

根据你的 Git 仓库，选择对应的 Application 配置：

```bash
# GitHub
kubectl apply -f applications/application-github.yaml

# Gitea
kubectl apply -f applications/application-gitea.yaml

# Gitee
kubectl apply -f applications/application-gitee.yaml
```

#### 或者部署多环境

```bash
# 开发环境
kubectl apply -f applications/application-dev.yaml

# 预发布环境
kubectl apply -f applications/application-staging.yaml

# 生产环境（需要手动同步）
kubectl apply -f applications/application-prod.yaml
```

### 7. 配置 Webhook（可选但推荐）

配置 Webhook 实现自动同步。详细步骤请参考 [WEBHOOK.md](WEBHOOK.md)

## 使用指南

### 查看应用状态

```bash
# 使用 CLI
argocd app list
argocd app get lunchbox-dev

# 使用 kubectl
kubectl get applications -n argocd
kubectl describe application lunchbox-dev -n argocd
```

### 手动同步

```bash
# 同步应用
argocd app sync lunchbox-dev

# 强制同步（忽略差异）
argocd app sync lunchbox-dev --force

# 同步特定资源
argocd app sync lunchbox-dev --resource Deployment:lunchbox:php-fpm
```

### 查看差异

```bash
# 查看 Git 和集群的差异
argocd app diff lunchbox-dev
```

### 回滚

```bash
# 查看历史
argocd app history lunchbox-dev

# 回滚到指定版本
argocd app rollback lunchbox-dev <revision-id>
```

### 删除应用

```bash
# 删除应用（保留资源）
argocd app delete lunchbox-dev --cascade=false

# 删除应用（同时删除资源）
argocd app delete lunchbox-dev
```

## 环境配置

### 开发环境 (dev)

- **命名空间**: `lunchbox-dev`
- **分支**: `main`
- **Values**: `values.yaml` + `values-dev.yaml`
- **自动同步**: ✓ 启用
- **自动修复**: ✓ 启用
- **自动清理**: ✓ 启用

### 预发布环境 (staging)

- **命名空间**: `lunchbox-staging`
- **分支**: `staging`
- **Values**: `values.yaml` + `values-staging.yaml`
- **自动同步**: ✓ 启用
- **自动修复**: ✓ 启用
- **自动清理**: ✓ 启用

### 生产环境 (prod)

- **命名空间**: `lunchbox-prod`
- **分支**: `production`
- **Values**: `values.yaml` + `values-prod.yaml`
- **自动同步**: ✗ 禁用（需要手动批准）
- **自动修复**: ✗ 禁用
- **自动清理**: ✗ 禁用

## GitOps 工作流

### 标准工作流

```text
1. 开发人员修改代码/配置
   ↓
2. 提交并推送到 Git 仓库
   ↓
3. Webhook 触发 ArgoCD（或定期轮询）
   ↓
4. ArgoCD 检测到变更
   ↓
5. ArgoCD 应用变更到 Kubernetes
   ↓
6. 健康检查和状态同步
   ↓
7. 通知（可选）
```

### 多环境发布流程

```text
开发 (main 分支)
   ↓ 自动部署到 dev
   ↓ 测试通过
   ↓ 合并到 staging 分支
   ↓ 自动部署到 staging
   ↓ 验收测试通过
   ↓ 合并到 production 分支
   ↓ 手动触发部署到 prod
   ↓ 生产环境验证
```

## 故障排查

### Application 状态异常

```bash
# 查看应用详情
argocd app get lunchbox-dev

# 查看事件
kubectl describe application lunchbox-dev -n argocd

# 查看 ArgoCD 日志
kubectl logs -n argocd deployment/argocd-application-controller -f
kubectl logs -n argocd deployment/argocd-server -f
kubectl logs -n argocd deployment/argocd-repo-server -f
```

### 同步失败

常见原因：

1. **Helm 模板错误**: 检查 Helm Chart 语法
2. **资源冲突**: 检查是否有重复的资源
3. **权限不足**: 检查 ArgoCD ServiceAccount 权限
4. **网络问题**: 检查 Git 仓库连接

### 仓库连接失败

```bash
# 测试仓库连接
argocd repo list

# 重新添加仓库
argocd repo add https://github.com/your-org/lunchbox.git \
  --username git \
  --password <token>
```

### Webhook 不工作

请参考 [WEBHOOK.md](WEBHOOK.md) 的故障排查部分。

## 最佳实践

### 1. 使用声明式配置

所有 Application 配置都应该存储在 Git 中，使用 kubectl apply 而不是 argocd CLI 创建。

### 2. 环境隔离

- 使用不同的命名空间隔离环境
- 使用不同的分支管理环境配置
- 生产环境禁用自动同步

### 3. 安全性

- 使用 Sealed Secrets 或 External Secrets 管理敏感信息
- 配置 RBAC 限制访问权限
- 启用 Webhook Secret 验证
- 定期轮换凭证

### 4. 监控和通知

- 配置 ArgoCD Notifications
- 集成 Slack/Email 通知
- 监控同步状态和健康状态

### 5. 版本管理

- 使用语义化版本号
- 为生产环境使用 Git Tag
- 保留足够的历史版本用于回滚

## 高级功能

### 1. App of Apps 模式

创建一个 "root" Application 来管理其他 Applications：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/your-org/lunchbox.git
    path: k8s/argocd/applications
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 2. ApplicationSet

使用 ApplicationSet 自动生成多个 Applications：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: lunchbox-envs
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - env: dev
        branch: main
      - env: staging
        branch: staging
      - env: prod
        branch: production
  template:
    metadata:
      name: 'lunchbox-{{env}}'
    spec:
      source:
        repoURL: https://github.com/your-org/lunchbox.git
        targetRevision: '{{branch}}'
        path: k8s/helm/lunchbox
        helm:
          valueFiles:
          - values.yaml
          - 'values-{{env}}.yaml'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'lunchbox-{{env}}'
```

### 3. Sync Waves

使用 sync waves 控制资源部署顺序：

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # 数据库先部署
---
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"  # 应用后部署
```

## 参考资料

- [ArgoCD 官方文档](https://argo-cd.readthedocs.io/)
- [GitOps 最佳实践](https://www.gitops.tech/)
- [Helm Charts 文档](https://helm.sh/docs/)
- [Kubernetes 文档](https://kubernetes.io/docs/)

## 支持

如有问题，请：

1. 查看本目录的文档
2. 查看 ArgoCD 日志
3. 参考官方文档
4. 提交 Issue
