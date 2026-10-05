ARG MEILI_VERSION=v1.54
FROM getmeili/meilisearch:${MEILI_VERSION}

ARG TZ=Asia/Shanghai

RUN apk add --no-cache tzdata && \
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo ${TZ} > /etc/timezone

# 复制配置文件
COPY config.toml /meili_config/config.toml

HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=5 \
    CMD ["wget", "--spider", "-q", "http://127.0.0.1:7700/health"]
