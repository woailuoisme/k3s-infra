#!/usr/bin/env bash
set -euo pipefail

# 遍历所有非模板数据库，统一加载核心扩展并配置环境
# 说明：pg_cron 仅在 cron.database_name (postgres) 生效；未启用 ON_ERROR_STOP 允许其他库跳过 pg_cron 继续安装
# TimescaleDB 仅装入 TIMESCALE_DATABASES 声明的库，避免常驻 scheduler 进程耗尽 max_worker_processes

TIMESCALE_DATABASES="${TIMESCALE_DATABASES:-lunchbox}"
DATABASES=$(psql -XtA -c "SELECT datname FROM pg_database WHERE datistemplate = false;" --username "$POSTGRES_USER" --dbname "postgres")

for db in $DATABASES; do
	echo "Initializing extensions for database: ${db}"

	# 时序扩展 (按需加载以节省 worker 资源)
	if [[ " $TIMESCALE_DATABASES " == *" $db "* ]]; then
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<- 'EOSQL'
			CREATE EXTENSION IF NOT EXISTS timescaledb;
		EOSQL
		echo "TimescaleDB extension installed for database: ${db}"
	fi

	psql --username "$POSTGRES_USER" --dbname "$db" <<- 'EOSQL'
		-- 核心特化：空间地理、向量检索 (HNSW/IVFFlat)、内置任务调度
		CREATE EXTENSION IF NOT EXISTS postgis;
		CREATE EXTENSION IF NOT EXISTS vector;
		CREATE EXTENSION IF NOT EXISTS pg_cron;

		-- 性能监控与缓存预热
		CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
		CREATE EXTENSION IF NOT EXISTS pg_prewarm;

		-- 文本检索与复合/排他索引加速
		CREATE EXTENSION IF NOT EXISTS citext;
		CREATE EXTENSION IF NOT EXISTS pg_trgm;
		CREATE EXTENSION IF NOT EXISTS btree_gin;
		CREATE EXTENSION IF NOT EXISTS btree_gist;
		CREATE EXTENSION IF NOT EXISTS ltree;

		-- 在线维护：在线表/索引重组治理膨胀
		CREATE EXTENSION IF NOT EXISTS pg_repack;
	EOSQL

	echo "Extensions initialized successfully for database: ${db}"
done

echo "All databases extension initialization completed."
