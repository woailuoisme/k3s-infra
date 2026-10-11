#!/usr/bin/env bash
# scripts/lib/bootstrap.sh - Platform bootstrap, infrastructure services, and configuration
set -euo pipefail

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

cmd_fetch_kubeconfig() {
	local vps_ip="${1:-64.118.150.69}"
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
	if [[ "$layout_info" == *"Current cluster layout version: 0"* || "$layout_info" != *"==== CURRENT CLUSTER LAYOUT ===="* ]]; then
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
	local old_domain="${2:-mso.lol}"

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
