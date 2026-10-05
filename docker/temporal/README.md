# Temporal 开发环境服务

基于官方单机镜像 `temporalio/temporal:1.9.1` 搭建的 Temporal 工作流编排与分布式事务引擎（集成内嵌 Web UI）。

## 架构与组件说明

Temporal 单机开发镜像将 Temporal 核心微服务（Frontend、History、Matching、Worker）与 Web UI 全部打包在单一容器进程中运行：

- **上游源码**：[temporalio/temporal](https://github.com/temporalio/temporal)
- **Docker Hub 镜像**：[temporalio/temporal](https://hub.docker.com/r/temporalio/temporal/tags)
- **镜像标签**：`temporalio/temporal:1.9.1`（上游未发布 minor 别名标签，遵循固定版本号规范）

## 端口与网络分配

| 服务/端口 | 协议 | 容器内端口 | 宿主机端口 | 所属网络 | 说明 |
|---|---|---|---|---|---|
| Temporal gRPC | gRPC | 7233 | `7233` | `backend` | 供 Temporal SDK 客户端及外部 Worker 连接调度 |
| Temporal Web UI | HTTP | 8233 | `8233` | `frontend` | 工作流可视化执行追踪、命名空间管理与执行历史看板 |
| Prometheus 指标 | HTTP | 9090 | - | `backend` | 内置 Prometheus Metrics 端点 (`/metrics`) |

## 数据持久化

- **持久化路径**：`${DATA_PATH}temporal` 挂载至容器内部 `/etc/temporal`
- **数据库文件**：`${DATA_PATH}temporal/temporal.db`（SQLite 存储模式，避免了传统集群对外部 Cassandra/PostgreSQL 的重度依赖，重启后工作流历史与任务状态不丢失）

## 接入与使用指南

### 1. 启动服务

```bash
# 启动 Temporal 容器
docker compose up -d temporal

# 查看运行状态与日志
docker compose logs -f temporal
```

### 2. Web UI 访问

- **本地直接访问**：`http://localhost:8233`
- **Caddy 反代访问**：
  若需通过域名反代访问，在 `gateways/caddy/Caddyfile` 中启用：

  ```caddyfile
  import proxy-app temporal.{$SITE_ADDRESS} temporal:8233
  ```

  访问地址即为：`https://temporal.{$SITE_ADDRESS}`

### 3. SDK 客户端连接

在应用代码（如 Go、PHP/RoadRunner、Node.js、Python 等）中，连接地址配置为：

- **容器内部通信**：`temporal:7233`
- **宿主机直连**：`localhost:7233` 或 `127.0.0.1:7233`
- **默认命名空间**：`default`（启动命令中已通过 `--namespace=default` 预先初始化）

### 4. 常用 CLI 操作

可在容器内直接调用内置的 `temporal` CLI 工具：

```bash
# 集群健康检查
docker compose exec temporal temporal operator cluster health

# 查看命名空间列表
docker compose exec temporal temporal operator namespace list

# 列出当前工作流执行列表
docker compose exec temporal temporal workflow list
```
