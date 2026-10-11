#!/usr/bin/env bash
# scripts/lib/common.sh - Common utility functions for cluster operations
set -euo pipefail

# 查找 Deployment 对应的命名空间 (遍历集群中同名 deployment)
find_deployment_ns() {
	kubectl get deployment -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
		| awk -v app="$1" '$2 == app {print $1; exit}'
}
