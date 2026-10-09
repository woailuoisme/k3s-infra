set shell := ["bash", "-uc"]
set dotenv-load := false

default:
    @just --list

# 运行全量静态检测 (Dockerfile, YAML, Kustomize, Helm, Secrets)
check: _lint-docker _lint-k8s _lint-kustomize _lint-helm _lint-secrets
validate: check
lint: check

# 敏感信息静态检测 (Gitleaks)
scan:
    @gitleaks detect --no-git --config .gitleaks.toml --verbose

# 快速使用 Sealed Secrets 离线公钥加密 Secret 清单
seal src dst:
    @kubeseal --cert platform/security/sealed-secrets/public-cert.pem --format yaml < "{{src}}" > "{{dst}}"
    @echo "Sealed {{src}} -> {{dst}} using offline public cert."

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

# 验证集群端 Sealed Secrets 解密状态与对应 Secret 映射
verify-secrets:
    @echo "=== 1. Sealed Secrets 控制器私钥状态 ==="
    @kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active
    @echo
    @echo "=== 2. Sealed Secrets CRD 同步状态 ==="
    @kubectl get sealedsecrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,REASON:.status.conditions[0].reason
    @echo
    @echo "=== 3. 对应生成的标准 Secret 存在性对照 ==="
    @for ns_secret in \
        "apps:bgin-secret" \
        "media:imgproxy-secret" \
        "search:meilisearch-secret" \
        "messaging:centrifugo-secret" \
        "messaging:centrifugo-env" \
        "gateway:cloudflare-api-token" \
        "security:authelia-secret" \
        "security:crowdsec-secret" \
        "storage:garage-rpc-secret" \
        "storage:garage-admin-token" \
        "database:postgres-s3-credentials" \
        "database:postgres-app-credentials" \
        "observability:openobserve-credentials"; do \
        ns=$${ns_secret%%:*}; secret=$${ns_secret##*:}; \
        if kubectl get secret "$$secret" -n "$$ns" >/dev/null 2>&1; then \
            echo "  ✓ [$$ns] $$secret"; \
        else \
            echo "  ✗ [$$ns] $$secret (未生成或解密失败)"; \
        fi \
    done
    @echo
    @echo "排查提示: 如有解密失败，可查看控制器日志:"
    @echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets --tail=50"


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

_lint-secrets:
    @gitleaks detect --no-git --config .gitleaks.toml

_fmt-sh:
    @find . -name "*.sh" -not -path "*/node_modules/*" -exec shfmt -w {} +

_fmt-md:
    @rumdl fmt

lint-helm: _lint-helm
lint-k8s: _lint-k8s
