set shell := ["bash", "-uc"]
set dotenv-load := false

default:
    @just --list

# 运行全量静态检测 (Dockerfile, YAML, Kustomize, Helm)
check: _lint-docker _lint-k8s _lint-kustomize _lint-helm
validate: check
lint: check

# 自动格式化 Shell 脚本与 Markdown 文档
fmt: _fmt-sh _fmt-md
fix: fmt

# 渲染应用 Kustomize 清单 (默认: bgin)
render app="bgin":
    @kubectl kustomize apps/{{app}}
template app="bgin": (render app)

# 导入预构建镜像到 K3s containerd (默认: jiaoio/postgres:18-trixie)
import-image image="jiaoio/postgres:18-trixie":
    @if command -v k3s >/dev/null 2>&1; then \
        echo "Importing {{image}} into K3s containerd..."; \
        k3s ctr images pull {{image}} ; \
    else \
        echo "k3s not found locally. Use docker or pull directly on remote node: k3s ctr images pull {{image}}"; \
    fi

# 引导启动 ArgoCD 根应用 (App-of-Apps)
bootstrap:
    @kubectl apply -f bootstrap/root-app.yaml
up: bootstrap

# 部署或升级 ArgoCD (Helm 10.x)
argocd:
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update argo
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --version "^10.0.0" \
        --values bootstrap/argocd-values.yaml
install-argocd: argocd
upgrade-argocd: argocd

# 获取 ArgoCD 初始 admin 密码
pass:
    @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    @echo

# 端口转发访问 ArgoCD 控制台 (:8080)
ui:
    @echo "ArgoCD UI forwarding on https://localhost:8080 (Ctrl+C to stop)..."
    @kubectl port-forward svc/argocd-server -n argocd 8080:443

# 查看 ArgoCD 应用与集群 Pod 状态
status:
    @kubectl get applications -n argocd
    @kubectl get pods -A
ps: status

# 批量替换 GitOps 仓库远端地址
set-repo new_repo old_repo="https://github.com/woailuoisme/k3s-infra.git":
    @OLD="{{old_repo}}" NEW="{{new_repo}}"; \
    echo "Replacing \"$OLD\" with \"$NEW\"..."; \
    find bootstrap -type f -name "*.yaml" \
        -exec perl -pi -e "s|\Q$OLD\E|$NEW|g" {} +; \
    echo "Done! Replaced \"$OLD\" -> \"$NEW\" across bootstrap/."
    @just check

# 批量替换根域名并校验
set-domain new_domain old_domain="haoxiaoguai.xyz":
    @OLD="{{old_domain}}" NEW="{{new_domain}}"; \
    echo "Replacing \"$OLD\" with \"$NEW\"..."; \
    find bootstrap platform apps docs -type f \( -name "*.yaml" -o -name "*.md" \) \
        -exec perl -pi -e "s/\Q$OLD\E/$NEW/g" {} +; \
    echo "Done! Replaced \"$OLD\" -> \"$NEW\" across repository."
    @just check

# 内部子任务
_lint-docker:
    @find platform -name "Dockerfile*" -exec hadolint {} +

_lint-k8s:
    @yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" bootstrap/ platform/ apps/bgin/

_lint-kustomize:
    @find . -name "kustomization.yaml" -exec dirname {} \; | sort | while read -r dir; do \
        kubectl kustomize "$dir" > /dev/null || exit 1; \
    done

_lint-helm:
    @if find apps platform -name "Chart.yaml" -maxdepth 3 2>/dev/null | grep -q .; then \
        find apps platform -name "Chart.yaml" -exec dirname {} \; | while read -r chart; do \
            helm lint "$chart" --strict || exit 1; \
        done; \
    else \
        echo "No Helm charts in apps/, skipping."; \
    fi

_fmt-sh:
    @find . -name "*.sh" -not -path "*/node_modules/*" -exec shfmt -w {} +

_fmt-md:
    @rumdl fmt

lint-helm: _lint-helm
lint-k8s: _lint-k8s
