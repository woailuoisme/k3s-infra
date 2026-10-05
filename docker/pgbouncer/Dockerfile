FROM debian:trixie-slim
LABEL maintainer="seaside <531773730@qq.com>"

# 构建参数
ARG TIMEZONE=Asia/Shanghai
# pgbouncer 版本号 (来自 PostgreSQL apt 仓库)
ARG PGBOUNCER_VERSION=1.25.2-1.pgdg13+1

# ============================================================================
# PgBouncer 环境变量默认值
# ============================================================================

ENV DATABASE_URL="" \
    PGBOUNCER_AUTH_PASSWORD="" \
    TZ=${TIMEZONE}


# 2. 安装 pgbouncer 与 psql (postgresql-client 提供 psql 与 pg_isready，用于端到端健康探针)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && curl -fSsL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    pgbouncer=${PGBOUNCER_VERSION} \
    postgresql-client-18 \
    tzdata \
    && ln -snf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime \
    && echo "${TIMEZONE}" > /etc/timezone \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 3. 创建非 root 用户和必要目录
RUN groupadd -r pgbouncer 2>/dev/null || true && \
    useradd -r -g pgbouncer pgbouncer 2>/dev/null || true \
    && mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer \
    && chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

# 4. 复制配置文件
COPY --chown=pgbouncer:pgbouncer pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY --chown=pgbouncer:pgbouncer entrypoint.sh /usr/local/bin/

# 设置执行权限
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 15432

# 健康检查 - psql 端到端探测：一次验证 TCP + 认证 + 池分配 + 后端查询
#
# 必须走连接池而非直连后端：DATABASE_URL 指向后端 postgres:5432，因此用 URL 的
# query 参数把 host/port 覆盖为池自身的监听地址。已实测（libpq 18）：query 参数
# 优先级高于 authority；而 -h/-p 命令行关键字**不生效**（会被 URL 覆盖）。
# 探针同时使用业务凭据，因此也覆盖了 auth_query 这条链路。
# 丢弃标准输出但保留 stderr，便于在 docker inspect 中看到认证/连接错误
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
    CMD ["sh", "-c", "psql \"$DATABASE_URL?host=127.0.0.1&port=15432\" -c 'SELECT 1' > /dev/null"]

# 切换到非 root 用户
USER pgbouncer

# 使用 entrypoint 脚本启动
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
