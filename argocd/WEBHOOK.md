# ArgoCD Webhook 配置指南

Webhook 允许 Git 仓库在代码推送时自动触发 ArgoCD 同步，实现即时部署。

## 概述

当你推送代码到 Git 仓库时，Webhook 会通知 ArgoCD，ArgoCD 会立即检查变更并同步到 Kubernetes 集群。

**工作流程**：

```text
Git Push → Webhook 触发 → ArgoCD 接收通知 → 检测变更 → 自动同步
```

## 前置条件

1. ArgoCD 已安装并运行
2. ArgoCD API Server 可以从外部访问（通过 Ingress 或 LoadBalancer）
3. Git 仓库有配置 Webhook 的权限

## ArgoCD Webhook URL

ArgoCD Webhook 端点：

```text
https://argocd.example.com/api/webhook
```

替换 `argocd.example.com` 为你的 ArgoCD 实际域名。

## 配置步骤

### 1. 获取 Webhook Secret（可选但推荐）

为了安全，建议配置 Webhook Secret 来验证请求来源。

#### 生成 Webhook Secret

```bash
# 生成随机 secret
openssl rand -base64 32
```

#### 在 ArgoCD 中配置 Secret

编辑 ArgoCD ConfigMap：

```bash
kubectl edit configmap argocd-cm -n argocd
```

添加 webhook secret：

```yaml
data:
  webhook.github.secret: <your-webhook-secret>
  webhook.gitea.secret: <your-webhook-secret>
  webhook.gitee.secret: <your-webhook-secret>
```

或者使用 kubectl patch：

```bash
kubectl patch configmap argocd-cm -n argocd --type merge -p '{"data":{"webhook.github.secret":"your-secret-here"}}'
```

### 2. GitHub Webhook 配置

#### 步骤：

1. 进入 GitHub 仓库
2. Settings → Webhooks → Add webhook

#### 配置项：

- **Payload URL**: `https://argocd.example.com/api/webhook`
- **Content type**: `application/json`
- **Secret**: 输入上面生成的 webhook secret
- **SSL verification**: Enable SSL verification（推荐）
- **Which events would you like to trigger this webhook?**
  - 选择 "Just the push event"
- **Active**: ✓ 勾选

#### 测试：

点击 "Recent Deliveries" 查看 webhook 请求状态。

### 3. Gitea Webhook 配置

#### 步骤：

1. 进入 Gitea 仓库
2. Settings → Webhooks → Add Webhook → Gitea

#### 配置项：

- **Target URL**: `https://argocd.example.com/api/webhook`
- **HTTP Method**: `POST`
- **POST Content Type**: `application/json`
- **Secret**: 输入上面生成的 webhook secret
- **Trigger On**: 选择 "Push events"
- **Active**: ✓ 勾选

#### 测试：

点击 "Test Delivery" 测试 webhook。

### 4. Gitee Webhook 配置

#### 步骤：

1. 进入 Gitee 仓库
2. 管理 → WebHooks → 添加 WebHook

#### 配置项：

- **URL**: `https://argocd.example.com/api/webhook`
- **密码**: 输入上面生成的 webhook secret
- **事件**: 选择 "Push"
- **激活**: ✓ 勾选

#### 测试：

点击 "测试" 按钮测试 webhook。

### 5. GitLab Webhook 配置（额外支持）

#### 步骤：

1. 进入 GitLab 仓库
2. Settings → Webhooks

#### 配置项：

- **URL**: `https://argocd.example.com/api/webhook`
- **Secret token**: 输入上面生成的 webhook secret
- **Trigger**: 选择 "Push events"
- **SSL verification**: Enable SSL verification
- **Active**: ✓ 勾选

## 验证 Webhook 工作

### 方法 1: 推送代码测试

```bash
# 修改配置文件
echo "# test webhook" >> k8s/helm/lunchbox/values.yaml

# 提交并推送
git add .
git commit -m "test: webhook trigger"
git push
```

### 方法 2: 查看 ArgoCD 日志

```bash
# 查看 ArgoCD API Server 日志
kubectl logs -n argocd deployment/argocd-server -f | grep webhook

# 查看 Application Controller 日志
kubectl logs -n argocd deployment/argocd-application-controller -f
```

### 方法 3: 使用 ArgoCD CLI

```bash
# 查看应用同步历史
argocd app history lunchbox-dev

# 查看应用事件
argocd app get lunchbox-dev
```

### 方法 4: 使用 ArgoCD UI

1. 登录 ArgoCD UI
2. 选择应用
3. 查看 "Events" 和 "Sync Status"

## 故障排查

### Webhook 未触发

**检查项**：

1. **URL 是否正确**

   ```bash
   curl -X POST https://argocd.example.com/api/webhook
   ```

2. **ArgoCD 是否可访问**

   ```bash
   kubectl get ingress -n argocd
   kubectl get svc -n argocd
   ```

3. **防火墙规则**
   - 确保 Git 服务器可以访问 ArgoCD
   - 检查云服务商的安全组规则

4. **查看 Git 仓库 Webhook 日志**
   - GitHub: Settings → Webhooks → Recent Deliveries
   - Gitea: Settings → Webhooks → Recent Deliveries
   - Gitee: 管理 → WebHooks → 推送记录

### Webhook 触发但未同步

**检查项**：

1. **Application 配置**

   ```bash
   kubectl get application -n argocd lunchbox-dev -o yaml
   ```

   确认 `syncPolicy.automated` 已启用：

   ```yaml
   syncPolicy:
     automated:
       prune: true
       selfHeal: true
   ```

2. **查看 Application 状态**

   ```bash
   argocd app get lunchbox-dev
   ```

3. **手动触发同步测试**

   ```bash
   argocd app sync lunchbox-dev
   ```

### Secret 验证失败

**错误信息**：

```text
Webhook verification failed: invalid signature
```

**解决方法**：

1. 确认 ArgoCD ConfigMap 中的 secret 与 Git 仓库配置一致
2. 重新生成并配置 secret
3. 重启 ArgoCD API Server：

   ```bash
   kubectl rollout restart deployment/argocd-server -n argocd
   ```

### SSL 证书问题

**错误信息**：

```text
SSL certificate problem: unable to get local issuer certificate
```

**解决方法**：

1. 确保 ArgoCD Ingress 配置了有效的 TLS 证书
2. 如果使用自签名证书，在 Git 仓库 Webhook 配置中禁用 SSL 验证（不推荐生产环境）

## 高级配置

### 1. 配置 Webhook 过滤

只在特定分支推送时触发：

在 Git 仓库 Webhook 配置中添加分支过滤（如果支持）。

### 2. 配置多个 Webhook

为不同环境配置不同的 Webhook：

- `main` 分支 → 触发 `lunchbox-dev`
- `staging` 分支 → 触发 `lunchbox-staging`
- `production` 分支 → 触发 `lunchbox-prod`

### 3. 使用 ArgoCD Notifications

配置通知以获取 Webhook 触发和同步结果：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.webhook.webhook-receiver: |
    url: https://your-notification-service.com/webhook
```

## 安全最佳实践

1. **始终使用 HTTPS**：确保 ArgoCD API Server 使用 HTTPS
2. **配置 Webhook Secret**：验证请求来源
3. **限制 IP 访问**：如果可能，限制只允许 Git 服务器 IP 访问
4. **启用 SSL 验证**：在 Git 仓库 Webhook 配置中启用 SSL 验证
5. **定期轮换 Secret**：定期更新 Webhook Secret

## 参考资料

- [ArgoCD Webhook Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/)
- [GitHub Webhooks](https://docs.github.com/en/developers/webhooks-and-events/webhooks)
- [Gitea Webhooks](https://docs.gitea.io/en-us/webhooks/)
- [Gitee Webhooks](https://gitee.com/help/categories/40)
