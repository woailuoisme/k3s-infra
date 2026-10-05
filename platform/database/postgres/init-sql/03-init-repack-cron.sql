-- =============================================================================
-- 注册 pg_cron 定时任务：在线巡检并重组全库膨胀表 (pg_repack)
-- 调度窗口：每月 1 日与 16 日 03:00；触发阈值：死元组 > 100,000 且占比 > 20%
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION public.repack_bloated_tables(
    dead_tup_min   bigint  DEFAULT 100000,
    dead_ratio_min numeric DEFAULT 0.2
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    db   record;
    conn text;
    tbl  record;
BEGIN
    FOR db IN
        SELECT datname FROM pg_database
        WHERE datistemplate = false AND datallowconn
    LOOP
        conn := format('dbname=%I', db.datname);
        FOR tbl IN
            SELECT *
            FROM dblink(
                conn,
                format(
                    'SELECT schemaname, tablename
                     FROM pg_stat_user_tables
                     WHERE n_dead_tup > %s
                       AND (n_dead_tup::numeric / greatest(n_live_tup + n_dead_tup, 1)) > %s
                     ORDER BY pg_total_relation_size(relid) DESC',
                    dead_tup_min, dead_ratio_min
                )
            ) AS t(schemaname text, tablename text)
        LOOP
            BEGIN
                PERFORM dblink_exec(
                    conn,
                    format('SELECT repack.apply(%L)', format('%I.%I', tbl.schemaname, tbl.tablename))
                );
                RAISE NOTICE '[pg_repack] %.%.% repacked', db.datname, tbl.schemaname, tbl.tablename;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[pg_repack] skip %.%.%: %', db.datname, tbl.schemaname, tbl.tablename, SQLERRM;
            END;
        END LOOP;
    END LOOP;
END
$$;

ALTER FUNCTION public.repack_bloated_tables(bigint, numeric) SET statement_timeout = 0;
ALTER FUNCTION public.repack_bloated_tables(bigint, numeric) SET lock_timeout = '60s';

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'repack-bloated-tables';
SELECT cron.schedule_in_database(
    'repack-bloated-tables',
    '0 3 1,16 * *',
    'SELECT public.repack_bloated_tables()',
    'postgres'
);
