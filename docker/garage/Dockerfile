ARG GARAGE_VERSION=v2.4.1
FROM dxflrs/garage:${GARAGE_VERSION}

# 移除 COPY garage.toml 以避免敏感凭证（如 admin_token / rpc_secret）泄露。
# 配置文件在运行时通过 docker-compose 卷挂载到 /etc/garage.toml 即可。

# 容器健康检查：利用内置二进制直接查询本地节点状态
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD ["/garage", "status"]

ENTRYPOINT ["/garage"]
CMD ["server"]
