# 锁定 Centrifugo 版本
ARG CENTRIFUGO_VERSION=v6.9
FROM centrifugo/centrifugo:${CENTRIFUGO_VERSION}

# 临时切换到 root 账户配置系统环境 (UID 0)
USER 0

# 设置系统时区并安装 tzdata
ENV TZ=Asia/Shanghai
RUN apk add --no-cache tzdata && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone

# 创建数据与配置目录，并设置非 root 用户权限
RUN mkdir -p /centrifugo && \
    chown -R centrifugo:centrifugo /centrifugo

# 仅复制单配置文件 config.yaml 到容器中
COPY --chown=centrifugo:centrifugo config.yaml /centrifugo/config.yaml

# 恢复使用官方非 root 用户 centrifugo (UID 1001)
USER 1001

WORKDIR /centrifugo

EXPOSE 8000

# 生产级健康检查
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD ["wget", "-qO-", "http://localhost:8000/health"]
