#!/usr/bin/env bash
# scripts/lint-staged-k8s.sh - 增量校验暂存的 Kubernetes YAML 及所属 Kustomize 目录
set -euo pipefail

if [ "$#" -eq 0 ]; then
	exit 0
fi

staged_files=("$@")

# 1. 快速语法检查 (yamllint)
yamllint -d "{extends: relaxed, rules: {line-length: {max: 300}}}" "${staged_files[@]}"

# 2. 收集受影响的 Kustomize 根目录
kustomize_dirs=()
for file in "${staged_files[@]}"; do
	dir="$(dirname "$file")"
	while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
		if [ -f "$dir/kustomization.yaml" ] || [ -f "$dir/kustomization.yml" ]; then
			kustomize_dirs+=("$dir")
			break
		fi
		dir="$(dirname "$dir")"
	done
done

# 去重目录
if [ ${#kustomize_dirs[@]} -gt 0 ]; then
	unique_dirs=($(printf '%s\n' "${kustomize_dirs[@]}" | sort -u))
	for kdir in "${unique_dirs[@]}"; do
		echo "--> Validating Kustomize rendering for: $kdir"
		kubectl kustomize "$kdir" > /dev/null
	done
fi
