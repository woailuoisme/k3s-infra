#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORIG_KUBECONFIG="${KUBECONFIG:-}"

if [ -f ".env" ]; then
	set -a
	# shellcheck disable=SC1091
	source .env
	set +a
fi

if [ -n "$ORIG_KUBECONFIG" ]; then
	export KUBECONFIG="$ORIG_KUBECONFIG"
fi

if [ -z "${KUBECONFIG:-}" ] && [ -f "${HOME}/.kube/k3s-remote.yaml" ]; then
	export KUBECONFIG="${HOME}/.kube/k3s-remote.yaml"
fi

find_deployment_ns() {
	kubectl get deployment -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
		| awk -v app="$1" '$2 == app {print $1; exit}'
}

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

cmd_init_key() {
	local key_file="${1:-$HOME/.config/sealed-secrets/master.key}"
	local cert_file="platform/security/sealed-secrets/public-cert.pem"

	if [ ! -f "$key_file" ]; then
		echo "错误: 未找到私钥: $key_file" >&2
		return 1
	fi
	if [ ! -f "$cert_file" ]; then
		echo "错误: 未找到证书: $cert_file" >&2
		return 1
	fi

	echo "==> 注入 Sealed Secrets 密钥并重启控制器"
	kubectl -n kube-system create secret tls sealed-secrets-key \
		--cert="$cert_file" \
		--key="$key_file" \
		--dry-run=client -o yaml | kubectl apply -f -

	kubectl -n kube-system label secret sealed-secrets-key \
		sealedsecrets.bitnami.com/sealed-secrets-key=active --overwrite > /dev/null

	kubectl -n kube-system rollout restart deployment sealed-secrets-controller
	kubectl -n kube-system rollout status deployment sealed-secrets-controller --timeout=60s

	sleep 2
	cmd_verify
}

cmd_verify() {
	echo "==> Sealed Secrets 控制器密钥"
	kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active || true

	echo -e "\n==> SealedSecrets 资源同步状态"
	kubectl get sealedsecrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,REASON:.status.conditions[0].reason || true

	echo -e "\n==> Secret 就绪核验"
	local secrets=(
		"apps:bgin-secret"
		"database:garage-s3-credentials"
		"database:postgres-app-credentials"
		"media:imgproxy-secrets"
		"messaging:centrifugo-secrets"
		"messaging:valkey-secret"
		"observability:beszel-agent-secret"
		"observability:openobserve-secrets"
		"search:meilisearch-master-key"
		"security:authelia-secret"
		"security:crowdsec-secrets"
		"storage:garage-config"
		"storage:garage-secrets"
		"traefik:cloudflare-api-token"
	)

	local failed=0
	for item in "${secrets[@]}"; do
		local ns="${item%%:*}"
		local sec="${item##*:}"
		if kubectl get secret "$sec" -n "$ns" > /dev/null 2>&1; then
			echo "  [OK]   [$ns] $sec"
		else
			echo "  [FAIL] [$ns] $sec"
			failed=$((failed + 1))
		fi
	done

	if [ "$failed" -gt 0 ]; then
		echo -e "\n警告: $failed 个 Secret 未就绪" >&2
		return 1
	fi
}

cmd_ps() {
	echo "==> ArgoCD Applications"
	kubectl get applications -n argocd || true
	echo -e "\n==> Pods"
	kubectl get pods -A
}

cmd_sync() {
	local target="${1:-}"

	if [ -z "$target" ] || [ "$target" = "all" ]; then
		kubectl annotate app --all -n argocd argocd.argoproj.io/refresh=hard --overwrite > /dev/null
		echo "已刷新全量 ArgoCD 应用"
		return 0
	fi

	local app
	app=$( (kubectl get app -n argocd -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -E "(^|-)${target}$" || true) | head -n 1)
	if [ -z "$app" ]; then
		app=$( (kubectl get app -n argocd -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "${target}" || true) | head -n 1)
	fi

	if [ -z "$app" ]; then
		echo "错误: 未找到匹配应用: $target" >&2
		return 1
	fi

	kubectl annotate app "$app" -n argocd argocd.argoproj.io/refresh=hard --overwrite > /dev/null
	echo "已刷新应用: $app"
}

cmd_import_image() {
	local image="${1:-jiaoio/postgres:18-trixie}"
	if command -v k3s > /dev/null 2>&1; then
		k3s ctr images pull "$image"
	else
		echo "未检测到本地 k3s，请在节点执行: k3s ctr images pull $image" >&2
	fi
}

cmd_set_domain() {
	local new_domain="${1:?缺少新域名参数，用法: just domain <NEW_DOMAIN> [OLD_DOMAIN]}"
	local old_domain="${2:-haoxiaoguai.xyz}"

	find bootstrap platform apps README.md -type f \( -name "*.yaml" -o -name "*.md" \) \
		-exec perl -pi -e "s/\Q$old_domain\E/$new_domain/g" {} +
	echo "域名已替换: $old_domain -> $new_domain"
}

cmd_set_repo() {
	local new_repo="${1:?缺少新仓库地址参数，用法: just repo <NEW_REPO> [OLD_REPO]}"
	local old_repo="${2:-https://github.com/woailuoisme/k3s-infra.git}"

	find bootstrap -type f -name "*.yaml" \
		-exec perl -pi -e "s|\Q$old_repo\E|$new_repo|g" {} +
	echo "仓库地址已替换: $old_repo -> $new_repo"
}

cmd_health() {
	echo -n "==> 探测 API Server... "
	if ! kubectl cluster-info --request-timeout=5s > /dev/null 2>&1; then
		echo "失败"
		return 1
	fi
	echo "正常"

	echo -e "\n==> 节点状态"
	kubectl get nodes -o wide

	echo -e "\n==> 异常 Pod"
	local abnormal_pods
	abnormal_pods=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2> /dev/null || true)
	if [ -z "$abnormal_pods" ]; then
		echo "  无异常 Pod"
	else
		echo "$abnormal_pods"
	fi

	echo -e "\n==> ArgoCD 应用健康概览"
	kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2> /dev/null || true
}

cmd_restart() {
	local app="${1:?缺少应用名称，用法: ./scripts/cluster.sh restart <APP_NAME> [NAMESPACE]}"
	local ns="${2:-$(find_deployment_ns "$app")}"

	if [ -z "$ns" ]; then
		echo "错误: 未找到 Deployment: $app" >&2
		return 1
	fi

	echo "==> 重启 [$ns] deployment/$app"
	kubectl -n "$ns" rollout restart deployment "$app"
	kubectl -n "$ns" rollout status deployment "$app" --timeout=90s
}

cmd_help() {
	cat << EOF
k3s-infra 集群运维工具 (scripts/cluster.sh)

用法:
  ./scripts/cluster.sh <command> [arguments...]

指令:
  health | doctor          集群健康检查 (连通性、节点、异常 Pod、ArgoCD)
  restart <APP> [NS]       滚动重启应用 (自动匹配命名空间)
  init-key [KEY_FILE]      注入 Sealed Secrets 私钥并触发自愈
  verify                   核验 Sealed Secrets 解密及生成状态
  sync [APP]               刷新 ArgoCD 应用 (默认全量)
  ps | status              查看 ArgoCD 应用状态与 Pod 列表
  argocd                   安装或升级 ArgoCD
  pass                     获取 ArgoCD 初始 admin 密码
  import-image [IMG]       拉取并导入镜像至 K3s containerd
  domain <NEW> [OLD]       替换主域名 (默认旧域名: haoxiaoguai.xyz)
  repo <NEW> [OLD]         替换 GitOps 仓库地址
  help                     显示帮助信息
EOF
}

ACTION="${1:-help}"
shift || true

case "$ACTION" in
	health | doctor) cmd_health "$@" ;;
	restart) cmd_restart "$@" ;;
	init-key | init-secrets) cmd_init_key "$@" ;;
	verify | verify-secrets) cmd_verify "$@" ;;
	sync) cmd_sync "$@" ;;
	ps | status) cmd_ps "$@" ;;
	argocd | install-argocd | upgrade-argocd) cmd_argocd "$@" ;;
	pass) cmd_pass "$@" ;;
	import-image) cmd_import_image "$@" ;;
	domain | set-domain) cmd_set_domain "$@" ;;
	repo | set-repo) cmd_set_repo "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		echo "未知命令: $ACTION (运行 './scripts/cluster.sh help' 查看帮助)" >&2
		exit 1
		;;
esac
