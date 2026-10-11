#!/usr/bin/env bash
# scripts/cluster.sh - k3s-infra Unified Operations CLI Facade
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

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

# Load common utilities
# shellcheck source=scripts/lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

cmd_help() {
	cat << 'EOF'
k3s-infra Cluster Operations CLI (scripts/cluster.sh)

Usage:
  ./scripts/cluster.sh <command> [arguments...]

Commands:
  health | doctor | status Check cluster health (API, nodes, abnormal pods, ArgoCD)
  ps                       View ArgoCD applications and all pods
  restart <APP> [NS]       Rolling restart deployment (auto-detects namespace)
  logs <APP> [LINES] [NS]  Follow application logs (default 50 lines)
  fetch-kube [VPS_IP]      Fetch and generate ~/.kube/k3s-remote.yaml via SSH
  init-bao                 Initialize OpenBao, create unseal secret & configure ESO RBAC
  bao-ui                   Port-forward OpenBao Web UI to http://localhost:8200
  bao-sync [TARGET] [FILE] Sync secrets from .secrets.env to OpenBao & trigger ESO
  sync [APP]               Refresh ArgoCD applications (default: all)
  argocd                   Install or upgrade ArgoCD
  pass                     Retrieve ArgoCD initial admin password
  init-garage              Initialize Garage S3 layout and application buckets
  import-image [IMG]       Pull and import container image to K3s containerd
  domain <NEW> [OLD]       Replace root domain across configs
  repo <NEW> [OLD]         Replace GitOps repository URL across configs
  help                     Show this help message
EOF
}

ACTION="${1:-help}"
shift || true

case "$ACTION" in
	# --------------------------------------------------------------------------
	# Workload & Observability Operations (scripts/lib/workload.sh)
	# --------------------------------------------------------------------------
	health | doctor | status | ps | sync | restart | logs | log)
		# shellcheck source=scripts/lib/workload.sh disable=SC1091
		source "${SCRIPT_DIR}/lib/workload.sh"
		case "$ACTION" in
			health | doctor | status) cmd_health "$@" ;;
			ps) cmd_ps "$@" ;;
			sync) cmd_sync "$@" ;;
			restart) cmd_restart "$@" ;;
			logs | log) cmd_logs "$@" ;;
		esac
		;;

	# --------------------------------------------------------------------------
	# Secrets Governance & OpenBao / ESO (scripts/lib/secrets.sh)
	# --------------------------------------------------------------------------
	init-bao | bao-ui | bao-sync | bao-seed)
		# shellcheck source=scripts/lib/secrets.sh disable=SC1091
		source "${SCRIPT_DIR}/lib/secrets.sh"
		case "$ACTION" in
			init-bao) cmd_init_bao "$@" ;;
			bao-ui) cmd_bao_ui "$@" ;;
			bao-sync | bao-seed) cmd_bao_sync "$@" ;;
		esac
		;;

	# --------------------------------------------------------------------------
	# Platform Bootstrap & Infrastructure Services (scripts/lib/bootstrap.sh)
	# --------------------------------------------------------------------------
	argocd | install-argocd | upgrade-argocd | pass | init-garage | import-image | \
		fetch-kube | fetch-kubeconfig | pull-kube | domain | set-domain | repo | set-repo)
		# shellcheck source=scripts/lib/bootstrap.sh disable=SC1091
		source "${SCRIPT_DIR}/lib/bootstrap.sh"
		case "$ACTION" in
			argocd | install-argocd | upgrade-argocd) cmd_argocd "$@" ;;
			pass) cmd_pass "$@" ;;
			init-garage) cmd_init_garage "$@" ;;
			import-image) cmd_import_image "$@" ;;
			fetch-kube | fetch-kubeconfig | pull-kube) cmd_fetch_kubeconfig "$@" ;;
			domain | set-domain) cmd_set_domain "$@" ;;
			repo | set-repo) cmd_set_repo "$@" ;;
		esac
		;;

	help | -h | --help)
		cmd_help
		;;

	*)
		echo "Unknown command: $ACTION (run './scripts/cluster.sh help' for usage)" >&2
		exit 1
		;;
esac
