#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

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
		--version "10.10.2" \
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
		echo "Error: Private key not found: $key_file" >&2
		return 1
	fi
	if [ ! -f "$cert_file" ]; then
		echo "Error: Certificate not found: $cert_file" >&2
		return 1
	fi

	echo "==> Injecting Sealed Secrets master key and restarting controller..."
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

KNOWN_SECRETS=(
	"apps:bgin-secret"
	"database:garage-s3-credentials"
	"database:postgres-app-credentials"
	"media:imgproxy-secrets"
	"messaging:centrifugo-secrets"
	"messaging:mosquitto-auth"
	"messaging:valkey-secret"
	"observability:beszel-agent-secret"
	"observability:openobserve-secrets"
	"observability:portainer-admin-password"
	"search:meilisearch-master-key"
	"security:authelia-secret"
	"security:crowdsec-secrets"
	"storage:garage-config"
	"storage:garage-secrets"
	"storage:rclone-backup-secret"
	"traefik:cloudflare-api-token"
)

get_sealed_secret_path() {
	local sec="$1"
	case "$sec" in
		"bgin-secret") echo "apps/bgin/sealed-secret.yaml" ;;
		"garage-s3-credentials") echo "platform/database/postgres/s3-credentials.sealed.yaml" ;;
		"postgres-app-credentials") echo "platform/database/postgres/app-credentials.sealed.yaml" ;;
		"imgproxy-secrets") echo "platform/media/imgproxy/sealed-secret.yaml" ;;
		"centrifugo-secrets" | "valkey-secret") echo "platform/messaging/centrifugo/sealed-secret.yaml" ;;
		"mosquitto-auth") echo "platform/messaging/mosquitto/sealed-secret.yaml" ;;
		"beszel-agent-secret") echo "platform/observability/beszel/sealed-secret.yaml" ;;
		"openobserve-secrets") echo "platform/observability/openobserve/sealed-secret.yaml" ;;
		"portainer-admin-password") echo "platform/observability/portainer/sealed-secret.yaml" ;;
		"meilisearch-master-key") echo "platform/search/meilisearch/sealed-secret.yaml" ;;
		"authelia-secret") echo "platform/security/authelia/sealed-secret.yaml" ;;
		"crowdsec-secrets") echo "platform/security/crowdsec/sealed-secret.yaml" ;;
		"garage-config" | "garage-secrets") echo "platform/storage/garage/sealed-secret.yaml" ;;
		"rclone-backup-secret") echo "platform/storage/backup/sealed-secret.yaml" ;;
		"cloudflare-api-token") echo "platform/gateway/traefik/sealed-secret.yaml" ;;
		*)
			local found
			found=$(grep -rl "name: $sec" apps/ platform/ 2> /dev/null | grep -E "\.sealed\.yaml$|sealed-secret\.yaml$" | head -n 1 || true)
			if [ -n "$found" ]; then
				echo "$found"
			fi
			;;
	esac
}

cmd_verify() {
	echo "==> Sealed Secrets Controller Key"
	kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active || true

	echo -e "\n==> SealedSecrets Resource Sync Status"
	kubectl get sealedsecrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,REASON:.status.conditions[0].reason || true

	echo -e "\n==> Secret Readiness Verification"
	local failed=0
	for item in "${KNOWN_SECRETS[@]}"; do
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
		echo -e "\nWarning: $failed secret(s) not ready" >&2
		return 1
	fi
}

cmd_view_secret() {
	local target="${1:-}"
	local key="${2:-}"

	if [ -z "$target" ]; then
		echo "Usage: just view-secret <component|index|namespace:secret> [KEY]"
		echo -e "\nRegistered Sealed Secrets in cluster:"
		local i=1
		for item in "${KNOWN_SECRETS[@]}"; do
			local ns="${item%%:*}"
			local sec="${item##*:}"
			printf "  [%2d] %-30s (Namespace: %s)\n" "$i" "$sec" "$ns"
			i=$((i + 1))
		done
		echo -e "\nExamples:"
		echo "  just view-secret traefik"
		echo "  just view-secret traefik CF_DNS_API_TOKEN"
		echo "  just view-secret 1"
		echo "  just view-secret database:valkey-secret"
		echo "  just unseal 1                  # Force offline decryption using local key"
		return 0
	fi

	local matched_ns=""
	local matched_sec=""

	if [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "${#KNOWN_SECRETS[@]}" ]; then
		local item="${KNOWN_SECRETS[$((target - 1))]}"
		matched_ns="${item%%:*}"
		matched_sec="${item##*:}"
	elif [[ "$target" == *":"* ]]; then
		matched_ns="${target%%:*}"
		matched_sec="${target##*:}"
	elif [[ "$target" == *"/"* ]]; then
		matched_ns="${target%%/*}"
		matched_sec="${target##*/}"
	else
		for item in "${KNOWN_SECRETS[@]}"; do
			local ns="${item%%:*}"
			local sec="${item##*:}"
			if [ "$target" = "$ns" ] || [ "$target" = "$sec" ] || [[ "$sec" == *"$target"* ]]; then
				matched_ns="$ns"
				matched_sec="$sec"
				break
			fi
		done
	fi

	if [ -z "$matched_ns" ] || [ -z "$matched_sec" ]; then
		echo "Error: No matching Secret found for: '$target'" >&2
		echo "Run 'just view-secret' to list all available secrets" >&2
		return 1
	fi

	local secret_json=""
	local offline_mode="${OFFLINE:-0}"

	if [ "$offline_mode" != "1" ]; then
		echo "==> Reading Secret: [$matched_ns] $matched_sec" >&2
		secret_json=$(kubectl get secret "$matched_sec" -n "$matched_ns" --request-timeout=3s -o json 2> /dev/null || true)
	fi

	if [ -z "$secret_json" ]; then
		local key_file="${SEALED_SECRETS_KEY:-$HOME/.config/sealed-secrets/master.key}"
		if [ -f "$key_file" ]; then
			local sealed_path
			sealed_path=$(get_sealed_secret_path "$matched_sec")
			if [ -n "$sealed_path" ] && [ -f "$sealed_path" ]; then
				echo "==> [Offline Mode] Decrypting using local private key ($sealed_path)..." >&2
				if command -v yq > /dev/null 2>&1; then
					secret_json=$(yq "select(.metadata.name == \"$matched_sec\")" "$sealed_path" | kubeseal --recovery-unseal --recovery-private-key "$key_file" -o json 2> /dev/null || true)
				else
					secret_json=$(kubeseal --recovery-unseal --recovery-private-key "$key_file" -o json < "$sealed_path" 2> /dev/null || true)
				fi
			fi
		fi
	fi

	if [ -z "$secret_json" ]; then
		echo "Error: Unable to read Secret '$matched_sec' (namespace: '$matched_ns') from cluster, and offline decryption failed." >&2
		echo "Hint: Ensure '$HOME/.config/sealed-secrets/master.key' exists and 'kubeseal' is installed for offline decryption." >&2
		return 1
	fi

	if [ -n "$key" ]; then
		local val
		val=$(echo "$secret_json" | jq -r --arg k "$key" '.data[$k] // empty' 2> /dev/null || true)
		if [ -z "$val" ]; then
			echo "Error: Key '$key' not found in Secret '$matched_sec'" >&2
			echo "Available Keys:" >&2
			echo "$secret_json" | jq -r '.data | keys[]' 2> /dev/null || true
			return 1
		fi
		echo "$val" | base64 -d
		echo ""
	else
		if command -v jq > /dev/null 2>&1; then
			echo "$secret_json" | jq '.data | map_values(@base64d)'
		else
			echo "$secret_json" | jq -r '.data' 2> /dev/null || echo "$secret_json"
		fi
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
		echo "Refreshed all ArgoCD applications"
		return 0
	fi

	local app_list
	app_list=$(kubectl get app -n argocd -o jsonpath='{.items[*].metadata.name}' 2> /dev/null || true)

	local app
	app=$(echo "$app_list" | tr ' ' '\n' | grep -E "(^|-)${target}$" | head -n 1 || true)
	if [ -z "$app" ]; then
		app=$(echo "$app_list" | tr ' ' '\n' | grep "${target}" | head -n 1 || true)
	fi

	if [ -z "$app" ]; then
		echo "Error: No matching application found: $target" >&2
		return 1
	fi

	kubectl annotate app "$app" -n argocd argocd.argoproj.io/refresh=hard --overwrite > /dev/null
	echo "Refreshed application: $app"
}

cmd_import_image() {
	local image="${1:-jiaoio/postgres:18-trixie}"
	if command -v k3s > /dev/null 2>&1; then
		k3s ctr images pull "$image"
	else
		echo "Local k3s not detected. Run on node: k3s ctr images pull $image" >&2
	fi
}

cmd_set_domain() {
	local new_domain="${1:?Missing new domain argument, usage: just domain <NEW_DOMAIN> [OLD_DOMAIN]}"
	local old_domain="${2:-haoxiaoguai.xyz}"

	find bootstrap platform apps README.md -type f \( -name "*.yaml" -o -name "*.md" \) \
		-exec perl -pi -e "s/\Q$old_domain\E/$new_domain/g" {} +
	echo "Domain replaced: $old_domain -> $new_domain"
}

cmd_set_repo() {
	local new_repo="${1:?Missing new repo URL argument, usage: just repo <NEW_REPO> [OLD_REPO]}"
	local old_repo="${2:-https://github.com/woailuoisme/k3s-infra.git}"

	find bootstrap -type f -name "*.yaml" \
		-exec perl -pi -e "s|\Q$old_repo\E|$new_repo|g" {} +
	echo "Repository URL replaced: $old_repo -> $new_repo"
}

cmd_health() {
	echo -n "==> Probing API Server... "
	if ! kubectl cluster-info --request-timeout=5s > /dev/null 2>&1; then
		echo "Failed"
		return 1
	fi
	echo "OK"

	echo -e "\n==> Node Status"
	kubectl get nodes -o wide

	echo -e "\n==> Abnormal Pods"
	local abnormal_pods
	abnormal_pods=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2> /dev/null || true)
	if [ -z "$abnormal_pods" ]; then
		echo "  No abnormal pods found"
	else
		echo "$abnormal_pods"
	fi

	echo -e "\n==> ArgoCD Application Health Summary"
	kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2> /dev/null || true
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

cmd_fetch_kubeconfig() {
	local vps_ip="${1:-64.118.149.72}"
	local target_file="${HOME}/.kube/k3s-remote.yaml"

	if ! command -v ssh > /dev/null 2>&1; then
		echo "Error: ssh command not found" >&2
		return 1
	fi

	mkdir -p "$(dirname "$target_file")"
	if ssh "root@$vps_ip" "cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/$vps_ip/g" > "$target_file.tmp"; then
		mv "$target_file.tmp" "$target_file"
		chmod 600 "$target_file"
		echo "Generated: $target_file"
	else
		rm -f "$target_file.tmp"
		echo "Error: Failed to fetch kubeconfig, check SSH connectivity" >&2
		return 1
	fi
}

cmd_init_garage() {
	echo "==> Initializing Garage S3 single-node layout and buckets..."
	if ! kubectl wait --for=jsonpath='{.status.phase}'=Running pod/garage-0 -n storage --timeout=60s; then
		echo "Error: storage/garage-0 Pod is not ready" >&2
		return 1
	fi

	garage_exec() {
		kubectl exec -n storage garage-0 -c garage -- /garage "$@"
	}

	echo "--> Checking Garage cluster status and node ID..."
	local node_full_id
	node_full_id=$(garage_exec node id 2> /dev/null | head -n1 | cut -d'@' -f1 || true)
	if [ -z "$node_full_id" ]; then
		echo "Error: Unable to retrieve Garage node ID" >&2
		return 1
	fi
	local node_id="${node_full_id:0:16}"
	echo "Garage node ID: $node_id"

	local layout_info
	layout_info=$(garage_exec layout show 2> /dev/null || true)
	if echo "${layout_info}" | grep -q "Current cluster layout version: 0" || ! echo "${layout_info}" | grep -q "==== CURRENT CLUSTER LAYOUT ===="; then
		echo "--> Assigning single-node layout (zone: dc1, capacity: 100G)..."
		garage_exec layout assign -z dc1 -c 100G "${node_id}"
		garage_exec layout apply --version 1 || true
	else
		echo "--> Cluster layout is already configured, skipping assignment."
	fi

	echo "--> Checking default AccessKey..."
	local existing_keys
	existing_keys=$(garage_exec key list 2> /dev/null || true)
	if echo "${existing_keys}" | grep -qw "default"; then
		echo "Key 'default' already exists."
	else
		local default_ak default_sk
		default_ak=$(kubectl -n storage get secret garage-secrets -o jsonpath='{.data.default-access-key}' 2> /dev/null | base64 -d || true)
		default_sk=$(kubectl -n storage get secret garage-secrets -o jsonpath='{.data.default-secret-key}' 2> /dev/null | base64 -d || true)
		if [ -n "$default_ak" ] && [ -n "$default_sk" ] && [ "$default_ak" != "GK_replace_with_garage_access_key" ]; then
			echo "--> Importing preset Key 'default'..."
			garage_exec key import -n default "${default_ak}" "${default_sk}" --yes || true
		else
			echo "--> Creating new Key 'default'..."
			garage_exec key create default || true
		fi
	fi

	echo "--> Checking and initializing S3 buckets (default, bgin, postgres-backups)..."
	local existing_buckets
	existing_buckets=$(garage_exec bucket list 2> /dev/null || true)
	for bucket in default bgin postgres-backups; do
		if echo "${existing_buckets}" | grep -qw "${bucket}"; then
			echo "Bucket '${bucket}' already exists."
		else
			echo "--> Creating bucket '${bucket}'..."
			garage_exec bucket create "${bucket}" || true
		fi

		echo "--> Granting Key 'default' read/write permissions to bucket '${bucket}'..."
		local perm_flags=(--read --write)
		if [ "${bucket}" = "bgin" ] || [ "${bucket}" = "postgres-backups" ]; then
			perm_flags+=(--owner)
		fi
		garage_exec bucket allow "${bucket}" --key default "${perm_flags[@]}" || true
	done

	echo "==> Garage initialization completed! Current status:"
	garage_exec bucket list
	garage_exec key list
}

cmd_help() {
	cat << EOF
k3s-infra Cluster Operations CLI (scripts/cluster.sh)

Usage:
  ./scripts/cluster.sh <command> [arguments...]

Commands:
  health | doctor | status Check cluster health (API, nodes, abnormal pods, ArgoCD)
  ps                       View ArgoCD applications and all pods
  restart <APP> [NS]       Rolling restart deployment (auto-detects namespace)
  logs <APP> [LINES] [NS]  Follow application logs (default 50 lines)
  fetch-kube [VPS_IP]      Fetch and generate ~/.kube/k3s-remote.yaml via SSH
  init-key [KEY_FILE]      Inject Sealed Secrets master key and trigger self-healing
  verify                   Verify Sealed Secrets decryption and Kubernetes Secrets status
  view-secret [TARGET] [KEY] View decrypted Secret plaintext (alias: secret)
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
	health | doctor | status) cmd_health "$@" ;;
	restart) cmd_restart "$@" ;;
	logs | log) cmd_logs "$@" ;;
	fetch-kube | fetch-kubeconfig | pull-kube) cmd_fetch_kubeconfig "$@" ;;
	init-key | init-secrets) cmd_init_key "$@" ;;
	verify | verify-secrets) cmd_verify "$@" ;;
	view-secret | secret) cmd_view_secret "$@" ;;
	sync) cmd_sync "$@" ;;
	ps) cmd_ps "$@" ;;
	argocd | install-argocd | upgrade-argocd) cmd_argocd "$@" ;;
	pass) cmd_pass "$@" ;;
	init-garage) cmd_init_garage "$@" ;;
	import-image) cmd_import_image "$@" ;;
	domain | set-domain) cmd_set_domain "$@" ;;
	repo | set-repo) cmd_set_repo "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		echo "Unknown command: $ACTION (run './scripts/cluster.sh help' for usage)" >&2
		exit 1
		;;
esac
