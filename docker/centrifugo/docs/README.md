# Centrifugo v6 生产环境部署与使用指南

本项目对 Centrifugo 进行了生产级容器化与架构优化。本指南专注于**生产环境**的各个维度进行详细说明，包含集群部署、安全隔离、网关反代、长连接协议及监控日志体系。

---

## 1. 生产环境架构设计

在生产环境下，Centrifugo 采用**自定义 Dockerfile + Valkey 分布式引擎**的运行模式，以确保高可用性、非 root 容器安全性以及完善的网关拦截机制。

* **安全加固镜像 (Dockerfile)**：基于官方 `centrifugo/centrifugo:v6.8.1` 镜像定制。
  * 时区锁定为 `Asia/Shanghai`，保证内部日志和业务数据的时序一致性。
  * 强制使用非 root 用户 `centrifugo`（UID 1001）运行进程，遵循最小特权原则。
  * 挂载健康检查：通过在容器内定期调用 `http://localhost:8000/health` 接口，结合 Docker daemon 实现自动化故障复位。
* **统一生产配置 (config.yaml)**：管理核心的协议启用状态以及高度细分且带有严密安全策略的通道命名空间（Namespaces）。
* **分布式存储引擎 (Valkey)**：生产环境下强依赖 Valkey 引擎（高度兼容 Redis 协议的云原生键值存储），支持多节点水平扩展（Cluster/Sentinel）及消息的断线重连补发（Recovery）。

---

## 2. 生产环境部署与运行

### A. 环境变量配置 (生产环境)

在生产环境的宿主机 `.env` 文件中，必须配置以下环境变量来覆盖容器的默认行为：

```env
# 核心引擎类型：指定使用 redis 引擎（在此项目中兼容对接 Valkey）
CENTRIFUGO_ENGINE_TYPE=redis

# 严格的客户端接入策略：生产环境强制开启 JWT 认证，绝对禁止匿名连接
CENTRIFUGO_CLIENT_ALLOW_ANONYMOUS_CONNECT_WITHOUT_TOKEN=false

# 严格的 CORS 跨域源限制：必须显式配置为允许的可信业务域名，严禁使用通配符 "*"
# 格式为 JSON 字符串数组，例如：["https://yourdomain.com", "https://app.yourdomain.com"]
CENTRIFUGO_ALLOWED_ORIGINS=["https://yourdomain.com"]

# 生产日志级别控制：锁死为 info 级别，既保证关键事件可追溯，又防止过量 Debug 日志撑爆磁盘
CENTRIFUGO_LOG_LEVEL=info

# 生产环境核心安全密钥（必须使用强随机算法生成，避免泄露）
# 1. 客户端 Token (JWT) 校验密钥
CENTRIFUGO_TOKEN_HMAC_SECRET_KEY=prod-super-secure-jwt-hmac-secret-key-change-me
# 2. 服务端调用 HTTP API 的鉴权 API KEY
CENTRIFUGO_API_KEY=prod-super-secure-http-api-key-change-me
# 3. 管理控制台 (Admin UI) 登录密码及加密 Secret
CENTRIFUGO_ADMIN_PASSWORD=prod-strong-admin-password-change-me
CENTRIFUGO_ADMIN_SECRET=prod-strong-admin-token-secret-change-me
```

### B. 服务启动

在定义好上述生产环境变量后，使用 Docker Compose 在后台拉起服务：

```bash
# 启动包含 Valkey 在内的生产环境服务
docker compose up -d valkey centrifugo
```

---

## 3. Caddy 反向代理与安全隔离 (Caddyfile)

生产环境中，Centrifugo 不能直接将 `8000` 端口暴露到公网。必须通过网关（如 Caddy）进行统一反向代理，并实施**路径级安全隔离防御**。

### A. 安全反代配置示例 (Caddyfile)

在生产环境中，`/metrics` 和 `/api` 端点通常是内部组件或服务器内部通信专用的，对外必须进行拦截阻断，以防系统数据外泄和接口滥用。

```caddyfile
# 生产环境 Caddy 网关反代配置
push.{$SITE_ADDRESS} {
	import ../snippets/request-log.conf
	import ../snippets/security.conf
	import ../snippets/waf/waf.conf
	encode zstd gzip

	# 1. 安全策略：强行拦截公网对监控指标 /metrics 的直接请求
	@blocked_endpoints {
		path /metrics
	}
	handle @blocked_endpoints {
		abort
	}

	# 2. 安全策略：限制敏感的后端 API 推送入口 /api 仅允许特定内网 IP 或本地访问
	@internal_only {
		path /api
		not remote_ip 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
	}
	handle @internal_only {
		respond "Forbidden: Internal Network Only" 403
	}

	# 3. 核心代理：反代所有剩余合法流量（包含连接端点 /connection/*，管理后台 /admin 等）
	handle {
		reverse_proxy centrifugo:8000 {
			header_up X-Accel-Buffering "no"
			# 禁用响应缓冲以保证 WebSocket / SSE / HTTP Stream 实时推送的低延迟
			flush_interval -1
		}
	}
}
```

### B. 生产环境访问入口汇总

基于上述反代策略，外部客户端与内部服务端与 Centrifugo 交互时的统一接入点如下：

1. **客户端 WebSocket 接入**
    * **公网 URL**：`wss://push.yourdomain.com/connection/websocket`
    * **说明**：用于双向长连接，客户端库 SDK 首选。
2. **客户端 SSE (Server-Sent Events) 双向接入**
    * **公网 URL**：`https://push.yourdomain.com/connection/sse`
    * **说明**：适用于严格防火墙环境下拦截了 WebSocket 时的降级双向长连接。
3. **单向推送长连接 (Unidirectional SSE / EventSource)**
    * **公网 URL**：`https://push.yourdomain.com/connection/uni_sse`
    * **说明**：用于前端利用浏览器原生 `EventSource` 直连，只需接收后端推送、无需向推送服务发送上行报文的极简开发场景。
4. **管理后台 Web 控制台 (Admin Dashboard)**
    * **公网 URL**：`https://push.yourdomain.com/admin/`
    * **安全**：已通过 `admin.handler_prefix: "/admin"` 挂载在该路径。访问需要输入 `.env` 中定义的 `CENTRIFUGO_ADMIN_PASSWORD` 强密码。
5. **服务端推送接口 (HTTP API)**
    * **Docker 内部 URL**：`http://centrifugo:8000/api` (微服务/后端容器间通信)
    * **公网限流 URL**：`https://push.yourdomain.com/api` (已加固，非内网 IP 访问会被拒绝)
    * **调用权限**：必须带上 HTTP Header `Authorization: apikey <CENTRIFUGO_API_KEY>`。
6. **服务状态监控 (Prometheus & Health)**
    * **容器监控指标**：`http://centrifugo:8000/metrics` (仅供内网 Prometheus 服务拉取指标)
    * **网关健康端点**：`https://push.yourdomain.com/health` (对外公开返回 `{}`, 供自动化拨测)

---

## 4. 生产环境命名空间最佳实践

在生产环境的 `config.yaml` 中，各命名空间采用不同的安全策略与资源限制，以提升服务器承载力：

1. **`public` (公开频道)**
    * **场景**：大厅广播、全局消息流。
    * **设计原则**：启用消息缓存与历史恢复 (`force_recovery: true`，历史长度 100)，防止客户端因网络波动重连时出现消息断档；虽然是公开频道，但生产环境下依然需要客户端拥有 Token 认证后才允许建立连接。
2. **`private` (私密频道)**
    * **场景**：单对单业务交互、隐私系统消息推送。
    * **设计原则**：**绝对禁止**客户端直接往此频道发布消息 (`allow_publish_for_subscriber: false`)，所有上行消息必须先由客户端发给后端接口进行权限校验，再由后端 API 推送给 Centrifugo；同时**严格校验订阅 Token**，客户端订阅此频道前必须先从后端服务器获取专用 JWT 订阅凭证。
3. **`user` (用户个人专属频道)**
    * **场景**：个人提醒、红点消息。
    * **设计原则**：为极致降低高并发下的内存消耗和 Valkey 开销，**完全禁用** `presence`（在线人数统计）与 `join_leave`（上下线通知），因为个人频道仅有一个在线实体，无须了解其他人的上下线状态。开启 `force_recovery` 保证消息必达。
4. **`notification` (非核心广播通道)**
    * **场景**：运维公告、滚屏跑马灯。
    * **设计原则**：此频道吞吐量高、非关键。因此缩短历史 TTL 为 `60s`，且**关闭强制恢复机制**，大幅减少 Valkey/Redis 内存驻留压力和网络同步负载。

---

## 5. 生产环境客户端安全认证与连接方式

生产环境中禁用了一切匿名通道，客户端连接时必须使用 JWT Token 进行安全认证。

### A. Unidirectional SSE (浏览器原生 EventSource) 连接

由于原生 `EventSource` 不支持在初始化时自定义 Request Header，所有的认证参数（JWT Token）和订阅频道信息必须经过 URL 编码后通过 `cf_connect` 参数传递：

```javascript
// 1. 准备连接载荷 (JWT 应该从您的业务后端获取)
const connectParams = {
  token: "YOUR_JWT_TOKEN_FROM_BACKEND",
  channels: ["public:announcements"]
};

// 2. 拼接连接地址，cf_connect 必须进行 URL 编码
const connectUrl = new URL("https://push.yourdomain.com/connection/uni_sse");
connectUrl.searchParams.append("cf_connect", JSON.stringify(connectParams));

// 3. 发起原生 EventSource 连接
const eventSource = new EventSource(connectUrl);

eventSource.onmessage = function(event) {
  const payload = JSON.parse(event.data);
  console.log("接收到来自命名空间的实时消息：", payload);
};

eventSource.onerror = function(err) {
  console.error("生产环境 SSE 链路异常：", err);
};
```

### B. 使用 SDK 的连接形式

当使用 `centrifuge-js` 或其他语言官方 SDK 时，必须配置 Token 获取的回调函数，以防 Token 过期导致连接断开：

```javascript
import { Centrifuge } from 'centrifuge';

const centrifuge = new Centrifuge('https://push.yourdomain.com/connection/websocket', {
  // 设置动态 Token 获取机制，防止由于生产环境 Token 默认 1 小时过期引发的断连
  getToken: async function(ctx) {
    const res = await fetch("/api/get-centrifugo-token");
    const data = await res.json();
    return data.token; 
  }
});

const sub = centrifuge.newSubscription('private:user_123');
sub.on('publication', function(ctx) {
  console.log('接收到私有通道消息:', ctx.data);
});

sub.subscribe();
centrifuge.connect();
```

---

## 6. 监控、日志与问题排查

### A. 容器生存监控

Dockerfile 内置了健康检测，每 10 秒发起一次对 `8000/health` 的诊断。

```bash
# 宿主机查看健康诊断细节
docker inspect --format='{{json .State.Health}}' centrifugo
```

### B. 结构化日志收集

Centrifugo v6 默认将日志以结构化 JSON 格式输出至 stdout。容器日志将自动流向系统的日志聚合中心（如 Vector / Loki），在检索日志时：

* **连接断开排查**：重点检索关键字 `"level":"info"` 且 `"message":"client connection closed"`，通过 `reason`（如 `token expired` 或 `ping timeout`）了解断连根源。
* **Redis 引擎报警**：如果日志中出现 `"level":"warn"` 且包含 `redis` / `valkey`，应立即检查网络延时或 Valkey 连接数上限。

### C. 经典生产故障排查

1. **CORS 跨域连接被拒**
    * **现象**：浏览器控制台报 `origin not allowed`，连接断开。
    * **排查**：检查环境变量 `CENTRIFUGO_CLIENT_ALLOWED_ORIGINS`，确认当前的请求 Origin 是否精准包含在 JSON 数组中。
2. **`token expired` 报错**
    * **现象**：客户端频繁出现断线重连，服务器日志输出 `token expired`。
    * **排查**：在生产环境，由后端签发的 JWT 必须包含合理合规的 `exp` 声明。客户端必须实现 `getToken` 钩子，以便在 Token 即将过期时自动向后端请求续期，实现无感刷新连接。
3. **时区错乱问题**
    * **现象**：导出的历史消息和日志记录出现 8 小时时差。
    * **排查**：确保部署时使用的是由自定义 Dockerfile 编译的 `centrifugo` 本地镜像，而非直接拉取的官方裸镜像。重新构建命令：`docker compose build --no-cache centrifugo`。

---

## 7. 多语言业务后端集成最佳实践 (SDK & Guides)

针对本项目主流开发栈，提供了详细的企业级实战集成指南：

* 🏭 **工业级生产指南**：[工业产品级架构与实践指南](file:///Users/seaside/Projects/docker/development/centrifugo/docs/industrial_production_guide.md)（含 IIoT 场景、高可用拓扑、内核调优、弱网恢复与可观测性）
* 🐘 **Laravel 13 (PHP 8.2+)**：[Laravel 13 最佳实践集成指南](file:///Users/seaside/Projects/docker/development/centrifugo/docs/laravel13_integration.md)（含自定义 Broadcaster、JWT 鉴权、事件广播）
* 🦁 **NestJS (TypeScript)**：[NestJS 最佳实践集成指南](file:///Users/seaside/Projects/docker/development/centrifugo/docs/nestjs_integration.md)（含动态 Module、TokenService、EventEmitter 监听与 Webhook Guard）
* 🚀 **Go Fiber (v2/v3)**：[Go Fiber SDK 实战与长连接指南](file:///Users/seaside/Projects/docker/development/centrifugo/docs/fiber_go_sdk.md)（含 gocent 封装、SSE / WebSocket 接入与并发广播）
