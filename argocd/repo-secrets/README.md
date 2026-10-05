# ArgoCD Git Repository Secrets

本目录包含 ArgoCD 访问 Git 仓库所需的凭证配置。

## 文件说明

- `repo-secret-github.yaml` - GitHub 仓库凭证
- `repo-secret-gitea.yaml` - Gitea 仓库凭证
- `repo-secret-gitee.yaml` - Gitee 仓库凭证

## 使用方法

### 1. 选择你使用的 Git 仓库

根据你的 Git 仓库类型，选择对应的 Secret 文件进行配置。

### 2. 配置凭证

#### 方式 A: 使用 HTTPS + Token（推荐）

编辑对应的 Secret 文件，替换以下内容：

```yaml
stringData:
  url: https://your-git-server.com/your-org/lunchbox.git  # 替换为实际仓库地址
  username: git  # GitHub/Gitea 使用 git，Gitee 使用实际用户名
  password: <your-token>  # 替换为实际的 Personal Access Token
```

#### 方式 B: 使用 SSH Key

如果使用 SSH Key 认证：

1. 生成 SSH Key（如果还没有）：

```bash
ssh-keygen -t ed25519 -C "argocd@example.com"
```

2. 将公钥添加到 Git 仓库的 Deploy Keys 或 SSH Keys

3. 编辑 Secret 文件，使用 SSH URL 和私钥：

```yaml
stringData:
  type: git
  url: git@github.com:your-org/lunchbox.git  # 使用 SSH URL
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ... 粘贴私钥内容 ...
    -----END OPENSSH PRIVATE KEY-----
```

### 3. 应用 Secret 到集群

```bash
# 应用对应的 Secret
kubectl apply -f repo-secret-github.yaml
# 或
kubectl apply -f repo-secret-gitea.yaml
# 或
kubectl apply -f repo-secret-gitee.yaml
```

### 4. 验证 Secret 创建成功

```bash
kubectl get secret -n argocd | grep repo
```

### 5. 在 ArgoCD 中验证仓库连接

#### 使用 ArgoCD CLI：

```bash
argocd repo list
```

#### 使用 ArgoCD UI：

1. 登录 ArgoCD UI
2. 进入 Settings -> Repositories
3. 查看仓库连接状态

## 生成 Personal Access Token

### GitHub

1. 登录 GitHub
2. Settings -> Developer settings -> Personal access tokens -> Tokens (classic)
3. Generate new token (classic)
4. 选择权限：`repo` (Full control of private repositories)
5. 复制生成的 token

### Gitea

1. 登录 Gitea
2. Settings -> Applications -> Generate New Token
3. 选择权限：`repo` (Full control of private repositories)
4. 复制生成的 token

### Gitee

1. 登录 Gitee
2. 设置 -> 私人令牌 -> 生成新令牌
3. 选择权限：`projects` (完全控制私有仓库)
4. 复制生成的令牌

## 安全注意事项

⚠️ **重要**：这些 Secret 文件包含敏感信息，请注意：

1. **不要提交到 Git 仓库**：确保这些文件在 `.gitignore` 中
2. **使用加密存储**：考虑使用 Sealed Secrets 或 External Secrets Operator
3. **定期轮换**：定期更新 Token 和 SSH Key
4. **最小权限原则**：只授予必要的权限

## 使用 Sealed Secrets（推荐）

为了安全地将 Secret 存储在 Git 中，推荐使用 Sealed Secrets：

```bash
# 安装 Sealed Secrets Controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# 安装 kubeseal CLI
brew install kubeseal

# 加密 Secret
kubeseal --format yaml < repo-secret-github.yaml > repo-secret-github-sealed.yaml

# 应用加密的 Secret
kubectl apply -f repo-secret-github-sealed.yaml
```

## 故障排查

### 仓库连接失败

1. 检查 URL 是否正确
2. 验证 Token 是否有效
3. 确认 Token 权限是否足够
4. 检查网络连接

### SSH Key 认证失败

1. 确认公钥已添加到 Git 仓库
2. 验证私钥格式正确
3. 检查 SSH URL 格式

### 查看 ArgoCD 日志

```bash
kubectl logs -n argocd deployment/argocd-repo-server
```
