#!/usr/bin/env bash
set -euo pipefail

# 遍历所有非模板数据库，统一加载核心扩展并配置环境
# 注意：pg_cron 是全局调度器，只能在 postgresql.conf 指定的 cron.database_name (即 postgres) 中安装

DATABASES=$(psql -XtA -c "SELECT datname FROM pg_database WHERE datistemplate = false;" --username "$POSTGRES_USER" --dbname "postgres")

for db in $DATABASES; do
	echo "Initializing extensions for database: ${db}"

	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<- 'EOSQL'
		-- 核心特化：空间地理、向量检索 (HNSW/IVFFlat)
		CREATE EXTENSION IF NOT EXISTS postgis;
		CREATE EXTENSION IF NOT EXISTS vector;

		-- 性能监控与缓存预热
		CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
		CREATE EXTENSION IF NOT EXISTS pg_prewarm;

		-- 文本检索与复合/排他索引加速
		CREATE EXTENSION IF NOT EXISTS citext;
		CREATE EXTENSION IF NOT EXISTS pg_trgm;
		CREATE EXTENSION IF NOT EXISTS btree_gin;
		CREATE EXTENSION IF NOT EXISTS btree_gist;
		CREATE EXTENSION IF NOT EXISTS ltree;
	EOSQL

	# pg_cron 仅在 cron.database_name (即 postgres) 中安装
	if [ "$db" = "postgres" ]; then
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
		echo "Extension pg_cron installed in postgres database."
	fi

	echo "Extensions initialized successfully for database: ${db}"
done

echo "All databases extension initialization completed."
