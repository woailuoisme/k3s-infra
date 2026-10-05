#!/usr/bin/env bash
set -euo pipefail

# 创建业务数据库并授予权限（扩展安装由 01 处理，表结构由 02 处理）

function create_db_if_not_exists() {
	local db=$1
	if [ "$(psql -XtA -c "SELECT 1 FROM pg_database WHERE datname='$db'" --username "$POSTGRES_USER" --dbname "postgres")" != '1' ]; then
		echo "Creating database: ${db}"
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<- EOSQL
			CREATE DATABASE ${db};
			GRANT ALL PRIVILEGES ON DATABASE ${db} TO "$POSTGRES_USER";
		EOSQL
		echo "Database ${db} created successfully."
	else
		echo "Database ${db} already exists, skipping creation."
	fi
}

# 默认数据库由 POSTGRES_DB 自动创建；按需创建额外业务库
if [ "${POSTGRES_DB:-}" != "lunchbox" ]; then
	create_db_if_not_exists "lunchbox"
fi
create_db_if_not_exists "authelia"
create_db_if_not_exists "glitchtip"
create_db_if_not_exists "openobserve"
create_db_if_not_exists "zitadel"
create_db_if_not_exists "chatwoot"
create_db_if_not_exists "casdoor"
create_db_if_not_exists "infisical"
create_db_if_not_exists "signoz"
create_db_if_not_exists "peerdb"

echo "Database administrator tasks completed."
