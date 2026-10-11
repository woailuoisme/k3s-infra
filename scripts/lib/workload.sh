#!/usr/bin/env bash
# scripts/lib/workload.sh - Workload observability and cluster health operations
set -euo pipefail

cmd_health() {
	echo -n "==> Probing API Server... "
	if ! kubectl cluster-info --request-timeout=5s > /dev/null 2>&1; then
		echo "Failed"
		return 1
	fi
	echo "OK"
	printf "\n==> Node Status\n"
	kubectl get nodes -o wide

	printf "\n==> Abnormal Pods\n"
	local abnormal_pods
	abnormal_pods=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2> /dev/null || true)
	if [ -z "$abnormal_pods" ]; then
		echo "  No abnormal pods found"
	else
		echo "$abnormal_pods"
	fi

	printf "\n==> ArgoCD Application Health Summary\n"
	kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2> /dev/null || true
}

cmd_ps() {
	echo "==> ArgoCD Applications"
	kubectl get applications -n argocd || true
	printf "\n==> Pods\n"
	kubectl get pods -A
}

cmd_sync() {
	local target="${1:-}"

	if [ -z "$target" ] || [ "$target" = "all" ]; then
		kubectl annotate app --all -n argocd argocd.argoproj.io/refresh=hard --overwrite > /dev/null
		echo "Refreshed all ArgoCD applications"
		return 0
	fi

	local app_list
	app_list=$(kubectl get app -n argocd -o jsonpath='{.items[*].metadata.name}' 2> /dev/null || true)

	local app=""
	local item=""

	# 优先精确匹配或前缀波次后缀匹配 (如 bgin 匹配 20-bgin)
	for item in $app_list; do
		if [[ "$item" == "$target" || "$item" == *"-${target}" ]]; then
			app="$item"
			break
		fi
	done

	# 降级为包含匹配
	if [ -z "$app" ]; then
		for item in $app_list; do
			if [[ "$item" == *"$target"* ]]; then
				app="$item"
				break
			fi
		done
	fi

	if [ -z "$app" ]; then
		echo "Error: No matching application found: $target" >&2
		return 1
	fi

	kubectl annotate app "$app" -n argocd argocd.argoproj.io/refresh=hard --overwrite > /dev/null
	echo "Refreshed application: $app"
}

cmd_restart() {
	local app="${1:?Missing application name, usage: ./scripts/cluster.sh restart <APP_NAME> [NAMESPACE]}"
	local ns="${2:-$(find_deployment_ns "$app")}"

	if [ -z "$ns" ]; then
		echo "Error: Deployment not found: $app" >&2
		return 1
	fi

	echo "==> Restarting [$ns] deployment/$app"
	kubectl -n "$ns" rollout restart deployment "$app"
	kubectl -n "$ns" rollout status deployment "$app" --timeout=90s
}

cmd_logs() {
	local app="${1:?Missing application name, usage: ./scripts/cluster.sh logs <APP> [LINES] [NS]}"
	local lines="${2:-50}"
	local ns="${3:-$(find_deployment_ns "$app")}"

	if [ -z "$ns" ]; then
		echo "Error: Deployment not found: $app" >&2
		return 1
	fi

	echo "==> [$ns] $app logs (tail $lines lines)"
	kubectl -n "$ns" logs -l "app.kubernetes.io/name=$app" --tail="$lines" -f 2> /dev/null \
		|| kubectl -n "$ns" logs "deployment/$app" --tail="$lines" -f
}
