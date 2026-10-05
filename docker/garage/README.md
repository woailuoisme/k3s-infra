# Garage S3 对象存储与备份同步服务

本目录包含基于 Garage (S3 兼容的高可用分布式存储) 的单节点最佳实践配置，以及配套的容器化 Rclone 客户端同步工具链。

## 文件组织结构

```text
garage/
├── docker-compose.yml      # Garage 核心服务及 WebUI 服务的容器编排定义
├── Dockerfile              # 定制化的 Garage 运行镜像（去除了明文凭证硬编码，带健康检查）
├── garage.toml             # 生产推荐配置：LMDB 数据库引擎、单副本、独立数据及元数据卷
├── README.md               # 项目说明文档
```

> 配套的通用容器化 Rclone 同步与异地灾备工具链位于同级目录 [../rclone/](file:///Users/seaside/Projects/docker/development/storage/rclone)。

---

## 1. 启动 Garage 服务

在项目根目录下直接使用 Docker Compose 启动 Garage 及其 Web 管理页面：

```bash
docker compose up -d
```

> **最佳实践优化说明**：
>
> - 移除了 `Dockerfile` 内的 `COPY garage.toml`，避免敏感 token 烧录进镜像中。
> - 元数据及对象存储卷统一映射在宿主机上，内部更改为 `/var/lib/garage` 标准持久化路径。
> - `garage-webui` 的启动依赖于 `garage` 服务的 `service_healthy` 健康检查状态，确保启动顺序。

---

## 2. 客户端同步工具 (Rclone) 使用说明

所有的 Rclone 操作均已在 [storage/rclone](file:///Users/seaside/Projects/docker/development/storage/rclone) 中统一封装，无需在宿主机安装 Rclone，通过容器自动调用。

### 统一调用入口 `rclone.sh`

```bash
bash ../rclone/rclone.sh ls garage:default
bash ../rclone/rclone.sh copy ./local-file garage:default/
bash ../rclone/rclone.sh sync ./local-dir garage:default/backup/
bash ../rclone/rclone.sh delete garage:default/old-file.txt
```

> **优化亮点**：
>
> - 仅在进行 `copy` 和 `sync` 这类涉及本地文件传输的操作时，才会挂载当前工作目录，有效优化了 `ls` 和 `delete` 的执行效率和权限敏感性。

---

## 3. 云上冷备份与异地容灾

使用 `to-remote.sh` 脚本可快速将本地 Garage 的 Bucket 中的数据备份至阿里云 OSS 或 Cloudflare R2。

### 使用命令

```bash
# 复制模式（追加备份）
bash ../rclone/to-remote.sh copy ali-oss garage:default default
bash ../rclone/to-remote.sh cp r2 garage:default default

# 同步模式（完全镜像同步，会删除云端多余文件）
bash ../rclone/to-remote.sh sync ali-oss garage:default default
bash ../rclone/to-remote.sh sy r2 garage:default default
```

### 参数映射说明

- **操作别名**：`copy` / `cp` （复制）、`sync` / `sy` （同步）。
- **目标服务别名**：`ali-oss` / `ali` （阿里云 OSS）、`cloudflare-r2` / `r2` （Cloudflare R2）。
- 所有别名转换及环境适配已在脚本内部自动映射完成，免除多重 Case 选择嵌套。

---

## 4. `copy` 与 `sync` 的策略选择

- **`copy`**：增量追加操作，安全且保守，云端已有文件不会受本地删除影响。
- **`sync`**：镜像式同步，使目标 Bucket 与源路径完全保持一致，会删除目标端存在而源端已删除的文件。请谨慎使用。
