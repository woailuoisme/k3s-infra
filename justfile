set shell := ["bash", "-uc"]
set dotenv-load := true

default:
    @just --list

# ------------------------------------------------------------------------------
# 1. 质量门禁与代码格式化 (Local Linters & Formatters)
# ------------------------------------------------------------------------------

# 运行全量静态检测门禁 (YAML, Kustomize, Schema, Helm, Gitleaks)
check: _lint-k8s _lint-kustomize _lint-schema _lint-helm _lint-secrets
validate: check
lint: check

# Kubernetes 清单与配置安全合规扫描 (Trivy)
audit:
    @trivy config apps/ platform/ bootstrap/ --severity HIGH,CRITICAL
sec: audit

# 自动格式化 Shell 脚本与 Markdown 文档
fmt: _fmt-sh _fmt-md
fix: fmt

# 敏感信息静态泄露扫描 (Gitleaks)
scan:
    @gitleaks detect --no-git --config .gitleaks.toml

# 渲染应用 Kustomize 清单 (默认: bgin)
render app="bgin":
    @kubectl kustomize apps/{{app}}
template app="bgin": (render app)

# ------------------------------------------------------------------------------
# 2. 声明式 GitOps 编排与集群运维 (GitOps & Cluster Operations)
# ------------------------------------------------------------------------------

# 引导启动或同步 ArgoCD 根应用 (App-of-Apps)
up:
    @kubectl apply -f bootstrap/root-app.yaml
bootstrap: up

# 卸载根应用 (保留命名空间与存储卷)
down:
    @kubectl delete -f bootstrap/root-app.yaml

# 查看 ArgoCD 应用与全集群 Pod 状态
ps:
    @./scripts/cluster.sh ps
status: ps

# 集群全面健康度巡检 (连通性, 节点, 异常 Pod, ArgoCD)
health:
    @./scripts/cluster.sh health
doctor: health

# 集群资源预占与水位巡检 (kube-capacity: 4C8G CPU/Memory Requests & Limits)
capacity:
    @kube-capacity --pods --util
cap: capacity

# 滚动重启指定应用 (例如: just restart bgin-api [namespace])
restart app ns="":
    @./scripts/cluster.sh restart "{{app}}" "{{ns}}"

# 查看应用实时日志 (例如: just logs bgin [lines] [namespace])
logs app lines="50" ns="":
    @./scripts/cluster.sh logs "{{app}}" "{{lines}}" "{{ns}}"
log app lines="50" ns="": (logs app lines ns)

# 远程集群运维入口 (转发至 scripts/cluster.sh, 支持所有子命令)
ops cmd="status" *args="":
    @./scripts/cluster.sh "{{cmd}}" {{args}}

# 强制刷新并触发 ArgoCD 应用同步 (默认: 全量应用, 支持指定如: just sync bgin)
sync app="":
    @./scripts/cluster.sh sync "{{app}}"
refresh app="": (sync app)

# 部署或就地升级 ArgoCD (官方 Helm Chart 10.10.2 / ArgoCD v3.5+)
argocd:
    @./scripts/cluster.sh argocd
install-argocd: argocd
upgrade-argocd: argocd

# 获取 ArgoCD 初始 admin 管理员密码
pass:
    @./scripts/cluster.sh pass

# 端口转发快速访问本地 ArgoCD 控制台 (:8080)
ui:
    @echo "ArgoCD UI forwarding on https://localhost:8080 (Ctrl+C to stop)..."
    @kubectl port-forward svc/argocd-server -n argocd 8080:443

# 初始化 Garage S3 单节点集群布局与业务桶 (首次部署后执行)
init-garage:
    @./scripts/cluster.sh init-garage

# 导入预构建镜像到 K3s containerd
import-image image="jiaoio/postgres:18-trixie":
    @./scripts/cluster.sh import-image "{{image}}"

# ------------------------------------------------------------------------------
# 3. 密钥安全与全局配置管理 (Secrets & Global Configuration)
# ------------------------------------------------------------------------------

# 快速使用 Sealed Secrets 离线公钥加密明文 Secret 清单
seal src dst:
    @kubeseal --cert platform/security/sealed-secrets/public-cert.pem --format yaml < "{{src}}" > "{{dst}}"
    @echo "Sealed {{src}} -> {{dst}} using offline public cert."

# 验证集群端 Sealed Secrets 解密状态与 Secret 映射
verify:
    @./scripts/cluster.sh verify
verify-secrets: verify

# 查看已解密的 Secret 明文 (优先连接集群，集群未就绪/断网时自动降级为本地 master.key 离线解密)
view-secret target="" key="":
    @./scripts/cluster.sh view-secret "{{target}}" "{{key}}"
secret target="" key="": (view-secret target key)

# 强制本地纯离线解密查看 Secret (仅使用本地 master.key，无需连接集群)
unseal target="" key="":
    @OFFLINE=1 ./scripts/cluster.sh view-secret "{{target}}" "{{key}}"
decrypt target="" key="": (unseal target key)

# 注入 Sealed Secrets 离线主私钥并触发全量自愈解密
init-key key="$HOME/.config/sealed-secrets/master.key":
    @./scripts/cluster.sh init-key "{{key}}"
init-secrets key="$HOME/.config/sealed-secrets/master.key": (init-key key)

# 从 VPS 拉取生成远程 kubeconfig (~/.kube/k3s-remote.yaml)
fetch-kube vps_ip="64.118.149.72":
    @./scripts/cluster.sh fetch-kube "{{vps_ip}}"

# 批量替换根域名并校验 (默认旧域名: haoxiaoguai.xyz)
domain new_domain old_domain="haoxiaoguai.xyz":
    @./scripts/cluster.sh domain "{{new_domain}}" "{{old_domain}}"
    @just check
set-domain new_domain old_domain="haoxiaoguai.xyz": (domain new_domain old_domain)

# 批量替换 GitOps 仓库远端地址
repo new_repo old_repo="https://github.com/woailuoisme/k3s-infra.git":
    @./scripts/cluster.sh repo "{{new_repo}}" "{{old_repo}}"
    @just check
set-repo new_repo old_repo="https://github.com/woailuoisme/k3s-infra.git": (repo new_repo old_repo)

# ------------------------------------------------------------------------------
# 4. 内部辅助子任务 (Internal Sub-tasks)
# ------------------------------------------------------------------------------
_lint-k8s:
    @yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" bootstrap/ platform/ apps/bgin/

_lint-kustomize:
    @find . -name "kustomization.yaml" -exec dirname {} \; | sort | while read -r dir; do \
        kubectl kustomize "$dir" > /dev/null || exit 1; \
    done

_lint-schema:
    @find . -name "kustomization.yaml" -exec dirname {} \; | sort | while read -r dir; do \
        kubectl kustomize "$dir" | kubeconform -summary -ignore-missing-schemas -insecure-skip-tls-verify > /dev/null || exit 1; \
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
lint-schema: _lint-schema
