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

ensure_connection() {
	if [ -z "${KUBECONFIG:-}" ] || [ ! -f "${KUBECONFIG}" ]; then
		echo "错误: 未找到 kubeconfig: ${KUBECONFIG:-未设置}" >&2
		exit 1
	fi

	if ! kubectl cluster-info --request-timeout=5s > /dev/null 2>&1; then
		echo "错误: 无法连接 Kubernetes API" >&2
		exit 1
	fi
}

find_deployment_ns() {
	kubectl get deployment -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
		| awk -v app="$1" '$2 == app {print $1; exit}'
}

cmd_status() {
	ensure_connection

	echo "==> 节点状态"
	kubectl get nodes -o wide

	echo -e "\n==> 异常 Pod"
	local abnormal
	abnormal=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2> /dev/null || true)
	if [ -n "$abnormal" ]; then
		echo "$abnormal"
	else
		echo "  无异常 Pod"
	fi

	echo -e "\n==> ArgoCD 应用"
	kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2> /dev/null || true
}

cmd_restart() {
	local app="${1:?缺少应用名称，用法: ./scripts/remote-ops.sh restart <APP> [NS]}"
	local ns="${2:-$(find_deployment_ns "$app")}"

	ensure_connection

	if [ -z "$ns" ]; then
		echo "错误: 未找到 Deployment: $app" >&2
		return 1
	fi

	echo "==> 重启 [$ns] deployment/$app"
	kubectl -n "$ns" rollout restart deployment "$app"
	kubectl -n "$ns" rollout status deployment "$app" --timeout=90s
}

cmd_logs() {
	local app="${1:?缺少应用名称，用法: ./scripts/remote-ops.sh logs <APP> [LINES] [NS]}"
	local lines="${2:-50}"
	local ns="${3:-$(find_deployment_ns "$app")}"

	ensure_connection

	if [ -z "$ns" ]; then
		echo "错误: 未找到 Deployment: $app" >&2
		return 1
	fi

	echo "==> [$ns] $app 日志 (最近 $lines 行)"
	kubectl -n "$ns" logs -l "app.kubernetes.io/name=$app" --tail="$lines" -f 2> /dev/null \
		|| kubectl -n "$ns" logs "deployment/$app" --tail="$lines" -f
}

cmd_fetch_kubeconfig() {
	local vps_ip="${1:-64.118.149.72}"
	local target_file="${HOME}/.kube/k3s-remote.yaml"

	if ! command -v ssh > /dev/null 2>&1; then
		echo "错误: 未找到 ssh 命令" >&2
		return 1
	fi

	mkdir -p "$(dirname "$target_file")"
	if ssh "root@$vps_ip" "cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/$vps_ip/g" > "$target_file.tmp"; then
		mv "$target_file.tmp" "$target_file"
		chmod 600 "$target_file"
		echo "已生成: $target_file"
	else
		rm -f "$target_file.tmp"
		echo "错误: 抓取失败，请检查 SSH 连通性" >&2
		return 1
	fi
}

cmd_help() {
	cat << EOF
k3s-infra 远程集群运维工具 (scripts/remote-ops.sh)

用法:
  ./scripts/remote-ops.sh <command> [arguments...]

指令:
  status                   查看集群状态 (节点、异常 Pod、ArgoCD)
  restart <APP> [NS]       滚动重启应用 (自动匹配命名空间)
  logs <APP> [LINES] [NS]  查看应用日志 (默认 50 行)
  fetch-kube [VPS_IP]      拉取并生成 ~/.kube/k3s-remote.yaml
  help                     显示帮助信息
EOF
}

ACTION="${1:-status}"
shift || true

case "$ACTION" in
	status | health | doctor) cmd_status "$@" ;;
	restart) cmd_restart "$@" ;;
	logs | log) cmd_logs "$@" ;;
	fetch-kube | fetch-kubeconfig | pull-kube) cmd_fetch_kubeconfig "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		echo "未知命令: $ACTION (运行 './scripts/remote-ops.sh help' 查看帮助)" >&2
		exit 1
		;;
esac
