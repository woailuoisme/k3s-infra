#!/usr/bin/env bash
set -euo pipefail

# 为 PgBouncer auth_query 创建低权限认证主体与专用查询函数
# 仅在 postgres 库创建 pgbouncer_auth 角色与 SECURITY DEFINER 函数 pgbouncer_auth_lookup(text)
# 依赖：PGBOUNCER_AUTH_PASSWORD 须与 pgbouncer 服务保持一致

if [ -z "${PGBOUNCER_AUTH_PASSWORD:-}" ]; then
	echo "PGBOUNCER_AUTH_PASSWORD is not set. Skipping PgBouncer auth initialization."
	exit 0
fi

echo "Initializing PgBouncer auth role and lookup function..."

# 密码通过 psql 变量传入，由 :'auth_password' 生成安全的 SQL 字符串字面量，
# 避免密码中的引号破坏语句（此处使用引号定界符，不做 shell 展开）
psql -v ON_ERROR_STOP=1 \
	-v auth_password="$PGBOUNCER_AUTH_PASSWORD" \
	--username "$POSTGRES_USER" \
	--dbname "postgres" <<- 'EOSQL'
		-- 1. 低权限认证角色
		DO $$
		BEGIN
			IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_auth') THEN
				CREATE ROLE pgbouncer_auth LOGIN;
			END IF;
		END
		$$;

		-- 幂等设置密码：轮换 PGBOUNCER_AUTH_PASSWORD 后重跑本脚本即可生效
		ALTER ROLE pgbouncer_auth WITH LOGIN PASSWORD :'auth_password';

		-- 2. SECURITY DEFINER 查询函数
		--    SET search_path 固定为 pg_catalog, pg_temp 是 SECURITY DEFINER 的加固要求：
		--    否则调用者可借 search_path 劫持函数内部的对象解析
		CREATE OR REPLACE FUNCTION public.pgbouncer_auth_lookup(user_name text)
		RETURNS TABLE(usename text, passwd text)
		LANGUAGE sql
		STABLE
		SECURITY DEFINER
		SET search_path = pg_catalog, pg_temp
		AS $$
			-- pg_shadow 视图本身只包含可登录角色（其定义为 pg_authid WHERE rolcanlogin），
			-- 因此无需再判断登录权限；其过期字段名为 valuntil（对应 pg_authid.rolvaliduntil）
			SELECT u.usename, u.passwd
			FROM pg_shadow u
			WHERE u.usename = user_name
			  AND (u.valuntil IS NULL OR u.valuntil > now());
		$$;

		-- 3. 默认 PUBLIC 拥有新函数的 EXECUTE，必须收回后只授予认证角色
		REVOKE ALL ON FUNCTION public.pgbouncer_auth_lookup(text) FROM PUBLIC;
		GRANT EXECUTE ON FUNCTION public.pgbouncer_auth_lookup(text) TO pgbouncer_auth;
	EOSQL

echo "PgBouncer auth initialization completed."
