ARG POSTGRES_VERSION=18.6-trixie
FROM postgres:${POSTGRES_VERSION}
LABEL maintainer="seaside <531773730@qq.com>"

ARG TIMEZONE=Asia/Shanghai
ARG CHINA=true

# 切换镜像源 (Debian Trixie)
RUN if [ "$CHINA" = "true" ]; then \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources; \
    fi

# 添加 PostgreSQL 官方 PGDG 仓库
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && curl -fSsL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 定义扩展版本参数（Debian 13 / trixie 对应 PGDG 构建后缀 pgdg13+1）
ARG TIMESCALEDB_VERSION=2.29.2+dfsg-1.pgdg13+1
ARG PGCRON_VERSION=1.6.7-3.pgdg13+1
ARG POSTGIS_VERSION=3.6.4+dfsg-2.pgdg13+1
ARG PGVECTOR_VERSION=0.8.6-1.pgdg13+1
ARG PGREPACK_VERSION=1.5.3-1.pgdg13+1

# 安装核心扩展：时序 (TimescaleDB)、地理空间 (PostGIS)、向量 (pgvector)、定时调度 (pg_cron)、在线维护 (pg_repack)
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-18-timescaledb="${TIMESCALEDB_VERSION}" \
    postgresql-18-postgis-3="${POSTGIS_VERSION}" \
    postgresql-18-pgvector="${PGVECTOR_VERSION}" \
    postgresql-18-cron="${PGCRON_VERSION}" \
    postgresql-18-repack="${PGREPACK_VERSION}" \
    tzdata \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 设置系统时区
RUN ln -snf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && echo ${TIMEZONE} > /etc/timezone

# 复制优化后的配置文件
COPY postgresql.conf /etc/postgresql/postgresql.conf

# 复制扩展初始化脚本
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

# 设置环境变量（TS_LICENSE 声明使用 TimescaleDB Apache 开源许可版）
ENV POSTGRES_CONFIG_FILE=/etc/postgresql/postgresql.conf \
    TS_LICENSE=apache

# 使用原始入口点，通过 CMD 传递配置参数
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]

HEALTHCHECK --interval=60s --timeout=10s --retries=5 --start-period=60s \
    CMD ["sh", "-c", "pg_isready -d ${POSTGRES_DB:-postgres} -U ${POSTGRES_USER:-postgres}"]

EXPOSE 5432
