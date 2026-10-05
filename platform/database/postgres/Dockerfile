# ==============================================================================
# CloudNative-PG 多模态扩展镜像 (4C8G 单机云原生生产调优)
# 集成：PostGIS (空间)、pgvector (向量)、TimescaleDB (时序)、pg_cron (调度)、pg_repack (在线维护)
# ==============================================================================
ARG CNPG_POSTGRES_VERSION=18
FROM ghcr.io/cloudnative-pg/postgresql:${CNPG_POSTGRES_VERSION}

LABEL maintainer="seaside <531773730@qq.com>"

USER root

ARG TIMEZONE=Asia/Shanghai
ARG CHINA=true

# 切换国内镜像源加速构建 (Debian)
RUN if [ "$CHINA" = "true" ]; then \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list 2>/dev/null || true; \
    fi

# 添加 PostgreSQL 官方 PGDG 仓库（确保获取最新构建的 PG18 扩展包）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && curl -fSsL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 安装核心多模扩展
# 注：TimescaleDB、PostGIS 3、pgvector、pg_cron、pg_repack
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-18-postgis-3 \
    postgresql-18-pgvector \
    postgresql-18-cron \
    postgresql-18-repack \
    postgresql-18-timescaledb \
    tzdata \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 设置时区
RUN ln -snf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && echo ${TIMEZONE} > /etc/timezone

# 声明 TimescaleDB Apache 许可
ENV TS_LICENSE=apache

# 切换回 postgres 专用安全非特权用户 (UID 26，符合 CNPG 规范)
USER 26
