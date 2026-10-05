set shell := ["bash", "-uc"]
set dotenv-load := false

# 列出所有可用任务
default:
    @just --list

# 运行全量静态语法与规范检查 (GitOps / K8s / Helm / Dockerfile)
lint: lint-dockerfile lint-helm lint-k8s

# 检查 Dockerfile 规范 (hadolint)
lint-dockerfile:
    @find platform -name "Dockerfile*" -exec hadolint {} +

# 本地构建 CNPG 多模态镜像并导入 K3s (免推私有仓库)
build-postgres-cnpg:
    docker build -t ghcr.io/seaside/postgres-multimodal:18 platform/database/postgres/
    @if command -v k3s >/dev/null 2>&1; then \
        echo "Importing image into K3s containerd..."; \
        docker save ghcr.io/seaside/postgres-multimodal:18 | sudo k3s ctr images import - ; \
    fi

# 校验 Helm 自研应用 Chart (apps/lunchbox)
lint-helm:
    @helm lint apps/lunchbox --strict
    @helm template test apps/lunchbox | yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" -

# 校验静态 Kubernetes / GitOps 配置文件语法
lint-k8s:
    @yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" bootstrap/ platform/ apps/lunchbox/values.yaml

# 执行全量校验 (lint 别名)
validate: lint

# 渲染 Helm 模板输出 (默认 lunchbox)
template app="lunchbox":
    @helm template {{app}} apps/{{app}}

# 引导启动 ArgoCD 根应用 (Root-App)
bootstrap:
    @kubectl apply -f bootstrap/root-app.yaml

# 查看 ArgoCD 全量应用同步状态与 Pod 运行状态
status:
    @kubectl get applications -n argocd
    @kubectl get pods -A

# 自动格式化所有代码与文档
fmt: fmt-shell fmt-md

# 格式化 Shell 脚本 (shfmt)
fmt-shell:
    @find . -name "*.sh" -not -path "*/node_modules/*" -exec shfmt -w {} +

# 格式化 Markdown 文档 (rumdl)
fmt-md:
    @rumdl fmt

# 自动修复全量格式 (fmt 别名)
fix: fmt
