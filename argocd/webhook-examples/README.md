# Webhook 配置示例

本目录包含各种 Git 仓库的 Webhook 配置示例。

## 文件说明

- `github-webhook-config.json` - GitHub Webhook 配置示例
- `gitea-webhook-config.json` - Gitea Webhook 配置示例
- `gitee-webhook-config.json` - Gitee Webhook 配置示例

## 使用方法

这些 JSON 文件仅供参考，展示了各个平台的 Webhook 配置结构。

实际配置时，请通过 Git 仓库的 Web UI 进行配置，而不是直接使用这些 JSON 文件。

## 配置步骤

### GitHub

1. 进入仓库 Settings → Webhooks → Add webhook
2. 填写配置项（参考 `github-webhook-config.json`）
3. 点击 "Add webhook"

### Gitea

1. 进入仓库 Settings → Webhooks → Add Webhook → Gitea
2. 填写配置项（参考 `gitea-webhook-config.json`）
3. 点击 "Add Webhook"

### Gitee

1. 进入仓库 管理 → WebHooks → 添加 WebHook
2. 填写配置项（参考 `gitee-webhook-config.json`）
3. 点击 "添加"

## 配置说明

### 通用配置

所有平台都需要配置：

- **URL**: ArgoCD Webhook 端点 `https://argocd.example.com/api/webhook`
- **Secret/Password**: Webhook 密钥（用于验证请求来源）
- **Events**: 触发事件（通常选择 "Push"）
- **Active**: 启用 Webhook

### 平台特定配置

#### GitHub

- **Content type**: 选择 `application/json`
- **SSL verification**: 启用（推荐）

#### Gitea

- **HTTP Method**: `POST`
- **POST Content Type**: `application/json`

#### Gitee

- **加密类型**: 通常选择 "密码"

## 测试 Webhook

配置完成后，建议立即测试：

1. 在 Git 仓库 Webhook 页面找到 "Test" 或 "测试" 按钮
2. 点击测试
3. 查看响应状态（应该返回 200 OK）
4. 检查 ArgoCD 是否收到通知

## 故障排查

如果 Webhook 不工作，请检查：

1. URL 是否正确
2. ArgoCD 是否可以从外部访问
3. Secret 是否配置正确
4. 防火墙规则是否允许访问
5. SSL 证书是否有效

详细的故障排查步骤请参考 `../WEBHOOK.md`。
