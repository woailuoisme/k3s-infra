#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cmd_argocd() {
	helm repo add argo https://argoproj.github.io/argo-helm > /dev/null 2>&1 || true
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd \
		--create-namespace \
		--version "^10.0.0" \
		--values bootstrap/argocd-values.yaml
}

cmd_pass() {
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
	echo
}

cmd_verify() {
	echo "==> 1. Sealed Secrets 主密钥状态"
	kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active || true

	echo -e "\n==> 2. SealedSecrets 同步状态"
	kubectl get sealedsecrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,REASON:.status.conditions[0].reason || true

	echo -e "\n==> 3. 标准 Secret 存在性对照"
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

	local failed=0
	for item in "${secrets[@]}"; do
		local ns="${item%%:*}"
		local sec="${item##*:}"
		if kubectl get secret "$sec" -n "$ns" > /dev/null 2>&1; then
			echo -e "  \033[32m✓\033[0m [$ns] $sec"
		else
			echo -e "  \033[31m✗\033[0m [$ns] $sec"
			failed=$((failed + 1))
		fi
	done

	if [ "$failed" -gt 0 ]; then
		echo -e "\n\033[33m提示:\033[0m 有 $failed 个 Secret 未就绪，排查日志: kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets --tail=50"
		return 1
	fi
}

cmd_ps() {
	echo "==> ArgoCD Applications"
	kubectl get applications -n argocd || true
	echo -e "\n==> Pods"
	kubectl get pods -A
}

cmd_import_image() {
	local image="${1:-jiaoio/postgres:18-trixie}"
	if command -v k3s > /dev/null 2>&1; then
		k3s ctr images pull "$image"
	else
		echo "未检测到本地 k3s，请在目标节点执行: k3s ctr images pull $image"
	fi
}

cmd_set_domain() {
	local new_domain="${1:?缺少新域名参数，用法: just domain <NEW_DOMAIN> [OLD_DOMAIN]}"
	local old_domain="${2:-haoxiaoguai.xyz}"

	find bootstrap platform apps -type f \( -name "*.yaml" -o -name "*.md" \) \
		-exec perl -pi -e "s/\Q$old_domain\E/$new_domain/g" {} +
	if [ -f README.md ]; then
		perl -pi -e "s/\Q$old_domain\E/$new_domain/g" README.md
	fi
	echo "域名已替换: $old_domain -> $new_domain"
}

cmd_set_repo() {
	local new_repo="${1:?缺少新仓库地址参数，用法: just repo <NEW_REPO> [OLD_REPO]}"
	local old_repo="${2:-https://github.com/woailuoisme/k3s-infra.git}"

	find bootstrap -type f -name "*.yaml" \
		-exec perl -pi -e "s|\Q$old_repo\E|$new_repo|g" {} +
	echo "仓库地址已替换: $old_repo -> $new_repo"
}

cmd_help() {
	cat << EOF
k3s-infra 集群运维工具 (scripts/cluster.sh)

用法:
  ./scripts/cluster.sh <command> [arguments...]

指令:
  verify                   核验 13 个 Sealed Secrets 解密及生成状态
  ps | status              查看 ArgoCD 应用状态与 Pod 列表
  argocd                   安装或就地升级 ArgoCD (v3.0+)
  pass                     获取 ArgoCD 初始 admin 登录密码
  import-image [IMG]       拉取并导入镜像至 K3s containerd
  domain <NEW> [OLD]       批量替换主域名 (默认旧域名: haoxiaoguai.xyz)
  repo <NEW> [OLD]         批量替换 GitOps 仓库地址
  help                     显示此帮助信息
EOF
}

ACTION="${1:-help}"
shift || true

case "$ACTION" in
	verify | verify-secrets) cmd_verify "$@" ;;
	ps | status) cmd_ps "$@" ;;
	argocd | install-argocd | upgrade-argocd) cmd_argocd "$@" ;;
	pass) cmd_pass "$@" ;;
	import-image) cmd_import_image "$@" ;;
	domain | set-domain) cmd_set_domain "$@" ;;
	repo | set-repo) cmd_set_repo "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		echo "未知命令: $ACTION (运行 './scripts/cluster.sh help' 查看帮助)"
		exit 1
		;;
esac
