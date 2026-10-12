set shell := ["bash", "-uc"]
set dotenv-load := true

default:
    @just --list

# ------------------------------------------------------------------------------
# 1. 质量门禁与代码格式化 (Local Linters & Formatters)
# ------------------------------------------------------------------------------

# 运行全量静态检测门禁 (YAML, Kustomize, Schema, Helm, Gitleaks)
check: _lint-k8s _lint-kustomize-schema _lint-helm _lint-secrets
lint: check
validate: check

# Kubernetes 清单与配置安全合规扫描 (Trivy)
audit:
    @trivy config apps/ platform/ bootstrap/ --severity HIGH,CRITICAL

# 自动格式化 Shell 脚本与 Markdown 文档
fmt: _fmt-sh _fmt-md

# 渲染应用 Kustomize 清单 (默认: bgin)
render app="bgin":
    @kubectl kustomize apps/{{app}}

# ------------------------------------------------------------------------------
# 2. 声明式 GitOps 编排与集群运维 (GitOps & Cluster Operations)
# ------------------------------------------------------------------------------

# 引导启动或同步 ArgoCD 根应用 (App-of-Apps)
up:
    @kubectl apply -f bootstrap/root-app.yaml

# 卸载根应用 (保留命名空间与存储卷)
down:
    @kubectl delete -f bootstrap/root-app.yaml

# 查看 ArgoCD 应用与全集群 Pod 状态
ps:
    @./scripts/cluster.sh ps

# 集群全面健康度巡检 (连通性, 节点, 异常 Pod, ArgoCD)
health:
    @./scripts/cluster.sh health

# 集群资源预占与水位巡检 (kube-capacity: 4C8G CPU/Memory Requests & Limits)
capacity:
    @kube-capacity --pods --util

# 滚动重启指定应用 (例如: just restart bgin-api [namespace])
restart app ns="":
    @./scripts/cluster.sh restart "{{app}}" "{{ns}}"

# 查看应用实时日志 (例如: just logs bgin [lines] [namespace])
logs app lines="50" ns="":
    @./scripts/cluster.sh logs "{{app}}" "{{lines}}" "{{ns}}"

# 远程集群运维入口 (转发至 scripts/cluster.sh, 支持所有子命令)
ops cmd="status" *args="":
    @./scripts/cluster.sh "{{cmd}}" {{args}}

# 强制刷新并触发 ArgoCD 应用同步 (默认: 全量应用, 支持指定如: just sync bgin)
sync app="":
    @./scripts/cluster.sh sync "{{app}}"

# 部署或就地升级 ArgoCD (官方 Helm Chart 10.10.2 / ArgoCD v3.5+)
argocd:
    @./scripts/cluster.sh argocd

# 获取 ArgoCD 初始 admin 管理员密码
pass:
    @./scripts/cluster.sh pass

# 端口转发快速访问本地 ArgoCD 控制台 (:8080)
argo-ui:
    @echo "ArgoCD UI forwarding on https://localhost:8080 (Ctrl+C to stop)..."
    @kubectl port-forward svc/argocd-server -n argocd 8080:443
ui: argo-ui

# 初始化 Garage S3 单节点集群布局与业务桶 (首次部署后执行)
init-garage:
    @./scripts/cluster.sh init-garage

# 导入预构建镜像到 K3s containerd
import-image image="jiaoio/postgres:18-trixie":
    @./scripts/cluster.sh import-image "{{image}}"

# ------------------------------------------------------------------------------
# 3. 密钥安全与全局配置管理 (Secrets & Global Configuration)
# ------------------------------------------------------------------------------

# 初始化 OpenBao 集群、配置自动解封 Secret 并绑定 ESO Kubernetes RBAC
init-bao:
    @./scripts/cluster.sh init-bao

# 端口转发快速访问 OpenBao Web UI (:8200)
bao-ui:
    @./scripts/cluster.sh bao-ui

# 批量或指定组件从本地 .secrets.env 同步机密至 OpenBao 并立即触发 ESO 生效
bao-sync target="" file=".secrets.env":
    @./scripts/cluster.sh bao-sync "{{target}}" "{{file}}"

# 从 VPS 拉取生成远程 kubeconfig (~/.kube/k3s-remote.yaml)
fetch-kube vps_ip="64.118.150.69":
    @./scripts/cluster.sh fetch-kube "{{vps_ip}}"

# 批量替换根域名并校验 (默认旧域名: mso.lol)
domain new_domain old_domain="mso.lol":
    @./scripts/cluster.sh domain "{{new_domain}}" "{{old_domain}}"
    @just check

# 批量替换 GitOps 仓库远端地址
repo new_repo old_repo="https://github.com/woailuoisme/k3s-infra.git":
    @./scripts/cluster.sh repo "{{new_repo}}" "{{old_repo}}"
    @just check

# ------------------------------------------------------------------------------
# 4. 内部辅助子任务 (Internal Sub-tasks)
# ------------------------------------------------------------------------------
_lint-k8s:
    @yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" bootstrap/ platform/ apps/

_lint-kustomize-schema:
    @find apps platform bootstrap -name "kustomization.yaml" -exec dirname {} \; | sort -u | xargs -n 1 -P 4 -I {} bash -c 'set -o pipefail; kubectl kustomize "{}" | kubeconform -summary -ignore-missing-schemas -insecure-skip-tls-verify > /dev/null'

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
    @find . -name "*.sh" -not -path "*/node_modules/*" -not -path "*/.git/*" -exec shfmt -w {} +

_fmt-md:
    @rumdl fmt
