#!/usr/bin/env bash
# scripts/lib/secrets.sh - OpenBao credentials vault and ESO secrets governance
set -euo pipefail

# ------------------------------------------------------------------------------
# OpenBao Token, CLI & Target Resolution Helpers
# ------------------------------------------------------------------------------

_CACHED_KNOWN_SECRETS=()

# 动态发现集群内纳管的全部 ExternalSecret (优先在线集群，离线降级扫描本地 YAML)
get_known_secrets() {
	if [ "${#_CACHED_KNOWN_SECRETS[@]}" -gt 0 ]; then
		printf '%s\n' "${_CACHED_KNOWN_SECRETS[@]}"
		return 0
	fi

	local secrets=()
	local live_secrets
	live_secrets=$(kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{":"}{.metadata.name}{"\n"}{end}' 2> /dev/null || true)
	if [ -n "$live_secrets" ]; then
		while IFS= read -r item; do
			[ -n "$item" ] && secrets+=("$item")
		done <<< "$live_secrets"
	fi

	if [ "${#secrets[@]}" -eq 0 ]; then
		local manifest_files
		manifest_files=$(find apps platform -name "*external-secret*.yaml" 2> /dev/null || true)
		if [ -n "$manifest_files" ]; then
			local manifest_secrets
			# shellcheck disable=SC2086
			manifest_secrets=$(awk '
				/^kind: ExternalSecret/ { is_es=1; name=""; ns="" }
				is_es && /^[[:space:]]*name:[[:space:]]*/ { name=$2 }
				is_es && /^[[:space:]]*namespace:[[:space:]]*/ { ns=$2 }
				is_es && name && ns { print ns ":" name; is_es=0; name=""; ns="" }
			' $manifest_files | sort -u)
			while IFS= read -r item; do
				[ -n "$item" ] && secrets+=("$item")
			done <<< "$manifest_secrets"
		fi
	fi

	_CACHED_KNOWN_SECRETS=("${secrets[@]}")
	printf '%s\n' "${secrets[@]}"
}

get_bao_root_token() {
	local token="${OPENBAO_TOKEN:-${VAULT_TOKEN:-}}"
	if [ -z "$token" ] && [ -f "${HOME}/.config/openbao/cluster-keys.json" ]; then
		token=$(jq -r '.root_token // empty' "${HOME}/.config/openbao/cluster-keys.json" 2> /dev/null || true)
	fi
	echo "$token"
}

require_bao_token() {
	local token
	token=$(get_bao_root_token)
	if [ -z "$token" ]; then
		echo "Error: Root token not found. Please set OPENBAO_TOKEN or run 'just init-bao' first." >&2
		return 1
	fi
	echo "$token"
}

bao_exec() {
	local token="$1"
	shift
	kubectl exec -n openbao openbao-0 -c openbao -- env BAO_TOKEN="$token" VAULT_TOKEN="$token" bao "$@"
}

resolve_secret_target() {
	local target="$1"

	# 快速路径: 明确包含命名空间与名称的格式 (ns/name 或 ns:name)
	if [[ "$target" == *":"* ]]; then
		echo "${target%%:*}:${target##*:}"
		return 0
	elif [[ "$target" == *"/"* ]]; then
		echo "${target%%/*}:${target##*/}"
		return 0
	fi

	local secrets=()
	while IFS= read -r item; do
		[ -n "$item" ] && secrets+=("$item")
	done < <(get_known_secrets)

	# 数字序号匹配
	if [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "${#secrets[@]}" ]; then
		echo "${secrets[$((target - 1))]}"
		return 0
	fi

	# 模糊或纯名称匹配
	for item in "${secrets[@]}"; do
		local ns="${item%%:*}"
		local sec="${item##*:}"
		if [ "$target" = "$ns" ] || [ "$target" = "$sec" ] || [[ "$sec" == *"$target"* ]]; then
			echo "$ns:$sec"
			return 0
		fi
	done

	return 1
}

# ------------------------------------------------------------------------------
# 1. OpenBao Initialization & Setup (init-bao)
# ------------------------------------------------------------------------------

cmd_init_bao() {
	echo "==> Checking OpenBao pod status..."
	if ! kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n openbao --timeout=60s; then
		echo "Error: openbao/openbao-0 Pod is not ready" >&2
		return 1
	fi

	local status_json
	status_json=$(kubectl exec -n openbao openbao-0 -c openbao -- bao status -format=json 2> /dev/null || true)

	local is_init
	is_init=$(echo "$status_json" | jq -r '.initialized // false' 2> /dev/null || true)

	local key_file="${HOME}/.config/openbao/cluster-keys.json"
	local root_token="${OPENBAO_TOKEN:-${VAULT_TOKEN:-}}"

	if [ "$is_init" != "true" ]; then
		echo "--> Initializing OpenBao (1 key share, threshold 1)..."
		local init_out
		init_out=$(kubectl exec -n openbao openbao-0 -c openbao -- bao operator init -key-shares=1 -key-threshold=1 -format=json)

		mkdir -p "$(dirname "$key_file")"
		echo "$init_out" > "$key_file"
		chmod 600 "$key_file"
		echo "--> Saved OpenBao master credentials to $key_file"

		local unseal_key
		unseal_key=$(echo "$init_out" | jq -r '.unseal_keys_b64[0]')
		root_token=$(echo "$init_out" | jq -r '.root_token')

		echo "--> Creating in-cluster auto-unseal Secret (openbao/openbao-unseal-key)..."
		kubectl -n openbao create secret generic openbao-unseal-key \
			--from-literal=unseal-key="$unseal_key" \
			--dry-run=client -o yaml | kubectl apply -f -

		echo "--> Unsealing openbao-0..."
		kubectl exec -n openbao openbao-0 -c openbao -- bao operator unseal "$unseal_key"
		sleep 2
	else
		echo "--> OpenBao is already initialized."
		local is_sealed
		is_sealed=$(echo "$status_json" | jq -r '.sealed // false' 2> /dev/null || true)
		if [ "$is_sealed" = "true" ]; then
			echo "--> OpenBao is currently sealed. Attempting unseal..."
			local unseal_key=""
			if kubectl -n openbao get secret openbao-unseal-key > /dev/null 2>&1; then
				unseal_key=$(kubectl -n openbao get secret openbao-unseal-key -o jsonpath='{.data.unseal-key}' | base64 -d)
			elif [ -f "$key_file" ]; then
				unseal_key=$(jq -r '.unseal_keys_b64[0] // empty' "$key_file" 2> /dev/null || true)
			fi

			if [ -n "$unseal_key" ]; then
				kubectl exec -n openbao openbao-0 -c openbao -- bao operator unseal "$unseal_key"
				sleep 2
			else
				echo "Error: OpenBao is sealed but no unseal key found in cluster secret or $key_file" >&2
				return 1
			fi
		fi

		if [ -z "$root_token" ] && [ -f "$key_file" ]; then
			root_token=$(jq -r '.root_token // empty' "$key_file" 2> /dev/null || true)
		fi
	fi

	if [ -z "$root_token" ]; then
		echo "Warning: No root token found. Set OPENBAO_TOKEN or provide ~/.config/openbao/cluster-keys.json to configure auth/policy." >&2
		return 0
	fi

	echo "--> Ensuring KV v2 secrets engine at path 'secret'..."
	bao_exec "$root_token" secrets enable -path=secret -version=2 kv 2> /dev/null || true

	echo "--> Ensuring Kubernetes auth engine is enabled..."
	bao_exec "$root_token" auth enable kubernetes 2> /dev/null || true

	echo "--> Configuring Kubernetes auth engine endpoint..."
	bao_exec "$root_token" write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"

	echo "--> Writing eso-policy for External Secrets Operator..."
	kubectl exec -i -n openbao openbao-0 -c openbao -- env BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" \
		bao policy write eso-policy - << 'POLICY_EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY_EOF

	echo "--> Writing eso-role for External Secrets Operator..."
	bao_exec "$root_token" write auth/kubernetes/role/eso-role \
		bound_service_account_names="external-secrets" \
		bound_service_account_namespaces="external-secrets" \
		policies="eso-policy" \
		ttl="1h"

	echo "==> OpenBao initialization and ESO RBAC setup completed successfully!"
}

# ------------------------------------------------------------------------------
# 2. OpenBao Web UI Forwarding (bao-ui)
# ------------------------------------------------------------------------------

cmd_bao_ui() {
	echo "==> Forwarding OpenBao Web UI on http://localhost:8200 (Ctrl+C to stop)..."
	kubectl port-forward svc/openbao -n openbao 8200:8200
}

# ------------------------------------------------------------------------------
# 3. Synchronize .secrets.env to OpenBao & Trigger ESO (bao-sync)
# ------------------------------------------------------------------------------

cmd_bao_sync() {
	local target="${1:-}"
	local file="${2:-.secrets.env}"

	if [ -n "$target" ] && [ -f "$target" ] && [ "$file" = ".secrets.env" ]; then
		file="$target"
		target=""
	fi

	if [ ! -f "$file" ]; then
		echo "Error: Secrets file '$file' not found." >&2
		echo "Hint: Copy the template to create your local secrets configuration:" >&2
		echo "  cp .secrets.env.example .secrets.env" >&2
		return 1
	fi

	local root_token
	root_token=$(require_bao_token) || return 1

	local target_resolved=""
	if [ -n "$target" ]; then
		if ! target_resolved=$(resolve_secret_target "$target"); then
			echo "Error: Target '$target' does not match any registered secret." >&2
			return 1
		fi
		target_resolved="${target_resolved//:/\/}"
	fi

	echo "==> Parsing '$file' and syncing into OpenBao..."
	if [ -n "$target_resolved" ]; then
		echo "    Filtering for target: $target_resolved"
	fi

	local current_sec=""
	local kv_pairs=()
	local total_seeded=0
	local synced_secrets=()

	_flush_section() {
		local sec="$1"
		shift
		local pairs=("$@")

		[ -z "$sec" ] && return 0
		[ ${#pairs[@]} -eq 0 ] && return 0

		if [ -n "$target_resolved" ] && [ "$sec" != "$target_resolved" ]; then
			return 0
		fi

		echo "--> Syncing secret to OpenBao: secret/$sec (${#pairs[@]} keys)..."

		if bao_exec "$root_token" kv get -format=json "secret/$sec" > /dev/null 2>&1; then
			bao_exec "$root_token" kv patch "secret/$sec" "${pairs[@]}"
		else
			bao_exec "$root_token" kv put "secret/$sec" "${pairs[@]}"
		fi
		total_seeded=$((total_seeded + 1))
		synced_secrets+=("$sec")
	}

	local line=""
	local new_sec=""
	local k=""
	local v=""

	while IFS= read -r line || [ -n "$line" ]; do
		# 原生修剪首尾空白，零子进程
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"

		case "$line" in
			"" | \#* | \;*) continue ;;
		esac

		if [[ "$line" =~ ^\[(.*)\]$ ]]; then
			new_sec="${BASH_REMATCH[1]}"
			new_sec="${new_sec#"${new_sec%%[![:space:]]*}"}"
			new_sec="${new_sec%"${new_sec##*[![:space:]]}"}"
			new_sec="${new_sec#secret/data/}"
			new_sec="${new_sec#secret/}"
			new_sec="${new_sec//:/\/}"

			if [ -n "$current_sec" ] && [ ${#kv_pairs[@]} -gt 0 ]; then
				_flush_section "$current_sec" "${kv_pairs[@]}"
				kv_pairs=()
			fi
			current_sec="$new_sec"
			continue
		fi

		if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
			k="${BASH_REMATCH[1]}"
			v="${BASH_REMATCH[2]}"
			k="${k#"${k%%[![:space:]]*}"}"
			k="${k%"${k##*[![:space:]]}"}"
			v="${v#"${v%%[![:space:]]*}"}"
			v="${v%"${v##*[![:space:]]}"}"

			if [[ "$v" =~ ^\"(.*)\"$ ]]; then
				v="${BASH_REMATCH[1]}"
				v="$(printf '%b' "$v")"
				v="${v//\\\"/\"}"
			elif [[ "$v" =~ ^\'(.*)\'$ ]]; then
				v="${BASH_REMATCH[1]}"
			else
				# 裸值安全性检测
				if [[ "$v" == *" "* ]]; then
					echo "    [Warning] Key '$k' has unquoted spaces in value. Wrap in single quotes '' if unintended." >&2
				fi
				if [[ "$v" == *"#"* ]]; then
					echo "    [Warning] Key '$k' contains '#' without quotes. Wrap in single quotes '' to prevent ambiguity." >&2
				fi
			fi

			kv_pairs+=("$k=$v")
		fi
	done < "$file"

	if [ -n "$current_sec" ] && [ ${#kv_pairs[@]} -gt 0 ]; then
		_flush_section "$current_sec" "${kv_pairs[@]}"
	fi

	if [ "$total_seeded" -eq 0 ]; then
		if [ -n "$target_resolved" ]; then
			echo "Warning: No matching section [$target_resolved] found in '$file'." >&2
		else
			echo "Warning: No valid sections found in '$file'." >&2
		fi
		return 1
	fi

	echo "==> Successfully synced $total_seeded secret(s) to OpenBao!"

	# 立即触发 ESO 强制刷新，实现秒级端到端同步到集群 Secret
	echo "==> Triggering immediate ESO sync for modified secrets..."
	local now
	now=$(date +%s)
	for sec in "${synced_secrets[@]}"; do
		local ns="${sec%%/*}"
		local name="${sec##*/}"
		kubectl annotate externalsecret "$name" -n "$ns" force-sync="$now" --overwrite > /dev/null 2>&1 || true
	done
	echo "==> All secrets in OpenBao and cluster are now in sync!"
}
