set shell := ["bash", "-uc"]
set dotenv-load := false

# 列出所有可用任务
default:
    @just --list

# 运行全量静态语法与规范检查 (GitOps / K8s / Kustomize / Dockerfile)
lint: lint-dockerfile lint-k8s lint-kustomize lint-helm

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

# 校验 Helm 自研应用 Chart (若存在)
lint-helm:
    @if find apps platform -name "Chart.yaml" -maxdepth 3 2>/dev/null | grep -q .; then \
        find apps platform -name "Chart.yaml" -exec dirname {} \; | while read -r chart; do \
            helm lint "$chart" --strict || exit 1; \
        done; \
    else \
        echo "No Helm charts in apps/, skipping."; \
    fi

# 校验所有 Kustomization 目录渲染正确性
lint-kustomize:
    @find . -name "kustomization.yaml" -exec dirname {} \; | sort | while read -r dir; do \
        kubectl kustomize "$dir" > /dev/null || exit 1; \
    done

# 校验静态 Kubernetes / GitOps 配置文件语法
lint-k8s:
    @yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" bootstrap/ platform/ apps/bgin/

# 执行全量校验 (lint 别名)
validate: lint

# 渲染应用清单输出 (默认 bgin)
template app="bgin":
    @kubectl kustomize apps/{{app}}


# 部署或升级 ArgoCD 到 v3.0+ 生产精简版 (官方 Helm Chart 10.x)
install-argocd:
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update argo
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --version "^10.0.0" \
        --values bootstrap/argocd-values.yaml

# 升级现有 ArgoCD 到 v3.0+ (别名)
upgrade-argocd: install-argocd

# 全局一键切换根域名并执行语法与规范校验 (例: just set-domain mydomain.com)
set-domain new_domain old_domain="haoxiaoguai.xyz":
    @OLD="{{old_domain}}" NEW="{{new_domain}}"; \
    echo "Replacing \"$OLD\" with \"$NEW\"..."; \
    find bootstrap platform apps docs -type f \( -name "*.yaml" -o -name "*.md" \) \
        -exec perl -pi -e "s/\Q$OLD\E/$NEW/g" {} +; \
    echo "Done! Replaced \"$OLD\" -> \"$NEW\" across repository."
    @just validate

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
