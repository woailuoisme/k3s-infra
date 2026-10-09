#!/usr/bin/env bash
# ==============================================================================
# scripts/cluster.sh - K3s & ArgoCD 集群运维与生命周期管理脚本
# ==============================================================================
set -euo pipefail

# 终端颜色输出
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ------------------------------------------------------------------------------
# 1. ArgoCD 安装与维护
# ------------------------------------------------------------------------------
cmd_argocd() {
	log_info "正在通过官方 Helm Chart (10.x) 安装/就地升级 ArgoCD..."
	helm repo add argo https://argoproj.github.io/argo-helm > /dev/null 2>&1 || true
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd \
		--create-namespace \
		--version "^10.0.0" \
		--values bootstrap/argocd-values.yaml
	log_ok "ArgoCD 部署/升级完成！"
}

cmd_pass() {
	log_info "获取 ArgoCD 初始管理员密码 (admin):"
	if kubectl -n argocd get secret argocd-initial-admin-secret > /dev/null 2>&1; then
		kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
		echo
	else
		log_warn "未找到 argocd-initial-admin-secret，可能已修改密码或该 Secret 已被删除。"
	fi
}

# ------------------------------------------------------------------------------
# 2. 集群与密钥全栈状态核验
# ------------------------------------------------------------------------------
cmd_verify() {
	echo "======================================================================"
	echo " 1. Sealed Secrets 控制器与主私钥状态"
	echo "======================================================================"
	if kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active > /dev/null 2>&1; then
		kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active
		log_ok "已检测到活跃的主解密私钥 Secret！"
	else
		log_err "未在 kube-system 发现 active 标签的主私钥！请参考 README.md 注入私钥。"
	fi
	echo

	echo "======================================================================"
	echo " 2. Sealed Secrets CRD 资源解密同步状态"
	echo "======================================================================"
	if kubectl get sealedsecrets -A > /dev/null 2>&1; then
		kubectl get sealedsecrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,REASON:.status.conditions[0].reason
	else
		log_warn "集群中未检索到任何 SealedSecret 资源。"
	fi
	echo

	echo "======================================================================"
	echo " 3. 对应生成的标准 Kubernetes Secret 存在性对照"
	echo "======================================================================"
	local secrets=(
		"apps:bgin-secret"
		"media:imgproxy-secret"
		"search:meilisearch-secret"
		"messaging:centrifugo-secret"
		"messaging:centrifugo-env"
		"gateway:cloudflare-api-token"
		"security:authelia-secret"
		"security:crowdsec-secret"
		"storage:garage-rpc-secret"
		"storage:garage-admin-token"
		"database:postgres-s3-credentials"
		"database:postgres-app-credentials"
		"observability:openobserve-credentials"
	)

	local all_ok=true
	for item in "${secrets[@]}"; do
		local ns="${item%%:*}"
		local sec="${item##*:}"
		if kubectl get secret "$sec" -n "$ns" > /dev/null 2>&1; then
			echo -e "  ${GREEN}✓${NC} [$ns] $sec"
		else
			echo -e "  ${RED}✗${NC} [$ns] $sec (未生成或解密失败)"
			all_ok=false
		fi
	done
	echo

	if [ "$all_ok" = false ]; then
		log_warn "排查提示: 若解密失败，可查看控制器实时日志定位异常:"
		echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets --tail=50"
	else
		log_ok "全量 13 个业务与平台 Secret 解密就绪！"
	fi
}

cmd_ps() {
	echo "======================================================================"
	echo " ArgoCD Applications 状态"
	echo "======================================================================"
	kubectl get applications -n argocd || true
	echo
	echo "======================================================================"
	echo " 全集群 Pod 运行状态"
	echo "======================================================================"
	kubectl get pods -A
}

# ------------------------------------------------------------------------------
# 3. 镜像导入
# ------------------------------------------------------------------------------
cmd_import_image() {
	local image="${1:-jiaoio/postgres:18-trixie}"
	if command -v k3s > /dev/null 2>&1; then
		log_info "导入 $image 至 K3s containerd..."
		k3s ctr images pull "$image"
		log_ok "镜像导入完成: $image"
	else
		log_warn "未检测到本地 k3s 二进制命令。"
		echo "可在远程 K3s 云主机执行: k3s ctr images pull $image"
	fi
}

# ------------------------------------------------------------------------------
# 4. 全局域名与仓库批量替换
# ------------------------------------------------------------------------------
cmd_set_domain() {
	local new_domain="${1:?请指定新域名，例如: just domain mydomain.com}"
	local old_domain="${2:-haoxiaoguai.xyz}"

	log_info "全局替换域名: \"$old_domain\" -> \"$new_domain\"..."
	find bootstrap platform apps -type f \( -name "*.yaml" -o -name "*.md" \) \
		-exec perl -pi -e "s/\Q$old_domain\E/$new_domain/g" {} +
	if [ -f README.md ]; then
		perl -pi -e "s/\Q$old_domain\E/$new_domain/g" README.md
	fi
	log_ok "域名替换完成！建议运行 'just check' 验证清单语法合规性。"
}

cmd_set_repo() {
	local new_repo="${1:?请指定新仓库 URL，例如: just repo https://github.com/user/k3s-infra.git}"
	local old_repo="${2:-https://github.com/woailuoisme/k3s-infra.git}"

	log_info "全局替换 GitOps 仓库地址: \"$old_repo\" -> \"$new_repo\"..."
	find bootstrap -type f -name "*.yaml" \
		-exec perl -pi -e "s|\Q$old_repo\E|$new_repo|g" {} +
	log_ok "仓库地址替换完成！建议运行 'just check' 验证清单语法合规性。"
}

# ------------------------------------------------------------------------------
# 5. CLI 帮助手册
# ------------------------------------------------------------------------------
cmd_help() {
	cat << EOF
k3s-infra 集群运维工具 (scripts/cluster.sh)

使用说明:
  ./scripts/cluster.sh <command> [arguments...]

常用指令:
  verify                   核验全栈 13 个 Sealed Secrets 解密及生成状态
  ps | status              查看 ArgoCD 应用同步状态与集群 Pod 运行列表
  argocd                   通过官方 Helm Chart 安装或就地升级 ArgoCD (v3.0+)
  pass                     获取 ArgoCD 初始管理员 admin 登录密码
  import-image [IMG]       拉取并导入指定镜像至 K3s containerd
  domain <NEW> [OLD]       全局批量替换清单与文档中的主域名 (默认旧域名: haoxiaoguai.xyz)
  repo <NEW> [OLD]         全局批量替换 bootstrap 中的 Git 仓库地址
  help                     显示本帮助信息

示例:
  ./scripts/cluster.sh verify
  ./scripts/cluster.sh domain example.com
EOF
}

# ------------------------------------------------------------------------------
# 主入口路由
# ------------------------------------------------------------------------------
ACTION="${1:-help}"
shift || true

case "$ACTION" in
	verify | verify-secrets)
		cmd_verify "$@"
		;;
	ps | status)
		cmd_ps "$@"
		;;
	argocd | install-argocd | upgrade-argocd)
		cmd_argocd "$@"
		;;
	pass)
		cmd_pass "$@"
		;;
	import-image)
		cmd_import_image "$@"
		;;
	domain | set-domain)
		cmd_set_domain "$@"
		;;
	repo | set-repo)
		cmd_set_repo "$@"
		;;
	help | -h | --help)
		cmd_help
		;;
	*)
		log_err "未知子命令: $ACTION"
		echo "运行 './scripts/cluster.sh help' 查看可用命令。"
		exit 1
		;;
esac
