ARG MOSQUITTO_VERSION=2.1-alpine
FROM eclipse-mosquitto:${MOSQUITTO_VERSION}
LABEL maintainer="seaside <531773730@qq.com>"

ARG CHINA=true
ARG TIMEZONE=Asia/Shanghai
ARG TZ=${TIMEZONE}
RUN if [ "${CHINA}" = "true" ]; then \
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories; \
    fi && \
    apk add --no-cache tzdata && \
    ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime && \
    echo "${TIMEZONE}" > /etc/timezone


ENV DEV=true

# 将配置复制到默认运行目录
COPY config/*.conf /mosquitto/config/
COPY config/acl.default /mosquitto/config/acl.default

# 同时创建一份只读的备份模板，以防止宿主机空挂载遮蔽配置
RUN mkdir -p /etc/mosquitto.templates && \
    cp /mosquitto/config/mosquitto.conf /etc/mosquitto.templates/mosquitto.conf && \
    cp /mosquitto/config/acl.default /etc/mosquitto.templates/acl

COPY startup.sh /usr/local/bin/startup.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/startup.sh && \
    chmod +x /usr/local/bin/healthcheck.sh

# 健康检查（支持认证）
HEALTHCHECK --interval=60s --timeout=10s --start-period=5s --retries=3 \
    CMD ["sh", "-c", "/usr/local/bin/healthcheck.sh"]

# 设置启动命令
ENTRYPOINT ["/usr/local/bin/startup.sh"]

CMD ["mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
