#!/bin/sh
set -e

if [ -n "$VALKEY_PASSWORD" ] && [ "$1" = 'valkey-server' ]; then
	set -- "$@" --requirepass "$VALKEY_PASSWORD"
fi

# 使用 exec 替换当前进程，确保信号能正确传递 (优雅停机)
exec "$@"
