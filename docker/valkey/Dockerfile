ARG VALKEY_VERSION=9.1-alpine
FROM valkey/valkey:${VALKEY_VERSION}

# 设置时区并准备目录
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    mkdir -p /usr/local/etc/valkey && \
    chown -R valkey:valkey /usr/local/etc/valkey /data

COPY valkey.conf /usr/local/etc/valkey/valkey.conf
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 健康检查
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD ["sh", "-c", "valkey-cli ${VALKEY_PASSWORD:+-a \"$VALKEY_PASSWORD\"} ping | grep -q PONG || exit 1"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["valkey-server", "/usr/local/etc/valkey/valkey.conf"]
