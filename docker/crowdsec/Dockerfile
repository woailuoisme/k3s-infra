FROM crowdsecurity/crowdsec:v1.8.1-slim
LABEL maintainer="seaside <531773730@qq.com>"

# 预置环境并预装 Traefik 和 Caddy 解析器与防御规则集合 (构建期固化，消除容器冷启动联网下载)
RUN mkdir -p /etc/crowdsec /var/lib/crowdsec/data && \
    cp -r /staging/etc/crowdsec/* /etc/crowdsec/ && \
    cscli hub update && \
    cscli collections install \
        crowdsecurity/traefik \
        crowdsecurity/caddy \
        crowdsecurity/http-cve \
        crowdsecurity/whitelist-good-actors \
        crowdsecurity/base-http-scenarios \
        crowdsecurity/appsec-virtual-patching \
        crowdsecurity/appsec-generic-rules && \
    cp -r /etc/crowdsec/* /staging/etc/crowdsec/ && \
    mkdir -p /staging/var/lib/crowdsec/data && \
    cp -r /var/lib/crowdsec/data/* /staging/var/lib/crowdsec/data/

# 静态内置配置与自定义规则 (包含 acquis.d 采集定义与 s02-enrich 白名单，同步至 /staging 供持久化卷初始装载)
COPY config/ /etc/crowdsec/
COPY config/ /staging/etc/crowdsec/

# 生产级精准探活：检测 Local API (LAPI) 监听就绪状态
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
    CMD ["sh", "-c", "cscli lapi status > /dev/null 2>&1 || exit 1"]
