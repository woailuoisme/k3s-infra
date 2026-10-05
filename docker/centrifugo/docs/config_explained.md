# Centrifugo v6 `config.yaml` 生产环境详细配置解析指南

本指南对 [config.yaml](file:///Users/seaside/Projects/docker/development/centrifugo/config.yaml) 配置文件中的每一个配置参数进行逐项、深入的工业级解析。内容涵盖参数定义、默认行为、生产环境建议以及背后的架构考量。

---

## 1. 传输协议配置 (Transport Protocols)

Centrifugo v6 支持丰富的长连接底层协议。启用多协议有助于在复杂的公网网络下保证连接的连通率。

### 1.1 `websocket`

* **配置参数**：

    ```yaml
    websocket:
      use_write_buffer_pool: true
    ```

* **详细解析**：控制标准双向 WebSocket 协议行为。`use_write_buffer_pool` 选项开启了写入缓冲区对象池复用。
* **生产建议**：必须保持 `true`。在高并发连接下，该选项能够极大减少 Go 垃圾回收（GC）的内存分配压力，提升系统吞吐。

### 1.2 `uni_websocket`

* **配置参数**：`uni_websocket.enabled: true`
* **详细解析**：启用单向 WebSocket 协议。客户端只需接收服务端数据，不进行上行通信。
* **生产建议**：建议保持启用。可用于纯数据看板或只读终端，减少网络往返消耗。

### 1.3 `http_stream`

* **配置参数**：`http_stream.enabled: true`
* **详细解析**：启用基于长轮询/Chunked 传输编码的单向 HTTP 流传输。
* **生产建议**：保持启用。作为 WebSocket 被代理服务器恶意拦截时的经典降级手段。

### 1.4 `sse`

* **配置参数**：`sse.enabled: true`
* **详细解析**：启用标准双向 Server-Sent Events 连接（通过 SDK 机制模拟双向控制帧）。
* **生产建议**：保持启用，提供标准的 Web 协议降级通道。

### 1.5 `uni_sse`

* **配置参数**：`uni_sse.enabled: true`
* **详细解析**：启用**单向 Server-Sent Events**。允许浏览器使用原生的 `new EventSource()` API 直接连接订阅，免去加载专用 JS SDK。
* **生产建议**：生产环境推荐启用。此举能够使轻量化 Web 前端、第三方系统或者物联网设备的对接代码量减少 90%。

---

## 2. 存储与分布式引擎配置 (Engine Configuration)

引擎控制 Centrifugo 如何在多节点集群中同步状态（PUB/SUB）以及如何缓存频道消息历史。

### 2.1 `engine.type`

* **配置参数**：`engine.type: redis`
* **详细解析**：指定底层存储引擎。可选 `memory`（单机内存，无历史恢复）或 `redis`（支持 Valkey/Redis/KeyDB，支持分布式扩展）。
* **生产建议**：生产环境必须为 `redis`。这是支持水平扩展、高可用节点冗余及断线消息恢复机制的前提。

### 2.2 `engine.redis`

* **配置参数**：

    ```yaml
    engine:
      redis:
        connect_timeout: "1s"
        io_timeout: "4s"
    ```

* **详细解析**：
  * `connect_timeout`：与 Valkey/Redis 建立连接的超时时间。
  * `io_timeout`：对 Valkey/Redis 进行读写操作的超时阈值。
* **生产建议**：在 Centrifugo v6 中，底层默认使用高性能的 `rueidis` 客户端，采用了自动流水线连接复用技术，因此不需要以前的 `pool_size` 线程池参数。保持这两个超时限制能有效防止 Valkey 节点故障时引发的网络挂起阻塞。

---

## 3. 全局客户端连接控制 (Client Connection Settings)

控制客户端与 Centrifugo 建立长连接时的全局心跳参数与系统水位线限制。

### 3.1 `client.allow_anonymous_connect_without_token`

* **配置参数**：`client.allow_anonymous_connect_without_token: false`
* **详细解析**：是否允许客户端无需携带任何 JWT 连接 Token 进行建立物理长连接。
* **生产建议**：生产环境**必须锁定为 `false`**。开启匿名连接容易让攻击者恶意建立数万长连接吃满物理带宽与系统句柄。

### 3.2 `client.allowed_origins`

* **配置参数**：`client.allowed_origins: []`（通过环境变量如 `["https://yourdomain.com"]` 动态覆盖）
* **详细解析**：CORS 跨域资源共享白名单。限制允许发起长连接请求的 Web Origin。
* **生产建议**：生产环境必须配置为具体的可信业务域名数组，**绝对禁止**配置为 `["*"]`，防止恶意跨域挟持。

### 3.3 `client.ping_interval` 与 `client.pong_timeout`

* **配置参数**：

    ```yaml
    client:
      ping_interval: 30s
      pong_timeout: 8s
    ```

* **详细解析**：
  * `ping_interval`：心跳检测发送的间隔时间。
  * `pong_timeout`：客户端必须返回心跳回复的最长等待时间，超时未返回将被服务器断开。
* **生产建议**：`30s` 间隔和 `8s` 超时能在“减少网络心跳风暴开销”与“快速发现死连接”之间达到最佳平衡。

### 3.4 `client.connection_limit`

* **配置参数**：`client.connection_limit: 10000`
* **详细解析**：单个 Centrifugo 容器实例允许承载的最大长连接数上限。
* **生产建议**：生产环境应配合宿主机的内存和 FD（文件描述符）限制进行调整。一般 1 核 2G 内存可支撑 1-2 万连接，建议结合系统压测值进行保护设定。

### 3.5 `client.user_connection_limit`

* **配置参数**：`client.user_connection_limit: 10`
* **详细解析**：同一个用户 ID（即 JWT 的 `sub` 字段）在系统中允许同时建立的最大长连接数量。
* **生产建议**：设为 `10` 可以允许多设备登录（手机、Pad、Web、PC等同时在线），同时有效防止恶意用户利用单一凭证写脚本大量并发请求。

### 3.6 `client.queue_max_size`

* **配置参数**：`client.queue_max_size: 1048576`（1MB）
* **详细解析**：每个连接在内存队列中积压消息的最大字节字节限制。
* **生产建议**：防止当客户端处于弱网状态、消息积压发不出时，服务器内存发生崩溃级膨胀。`1MB` 足够常规业务使用。

### 3.7 `client.stale_close_delay`

* **配置参数**：`client.stale_close_delay: "10s"`
* **详细解析**：当客户端被探测到心跳丢失或已被标记为“过期（Stale）”后，延迟关闭连接的缓冲时间。
* **生产建议**：提供 `10s` 的网络波动缓冲，防范短暂的心跳延迟误杀合法连接。

---

## 4. 管理后台与监控 (Admin & Observability)

### 4.1 `admin.enabled` 与 `admin.handler_prefix`

* **配置参数**：

    ```yaml
    admin:
      enabled: true
      handler_prefix: "/admin"
    ```

* **详细解析**：是否开启 Web 管理控制台，以及其 URL 访问路径前缀。
* **生产建议**：生产环境启用时，必须确保配置强随机密码，并**必须在网关层限制该路径**，例如仅限内网 VPN 可访问此路由。

### 4.2 `health.enabled`

* **配置参数**：`health.enabled: true`
* **详细解析**：开启健康检查 HTTP API `/health`，返回 `200 OK`（状态码 `200` 表明服务健康）。
* **生产建议**：必须保持开启。这是 Docker/K8s 和网关 Caddy 监测服务活性（Liveness/Readiness Probe）的关键依据。

### 4.3 `prometheus.enabled`

* **配置参数**：`prometheus.enabled: true`
* **详细解析**：导出 `/metrics` 端点，供 Prometheus 监控系统拉取底层 Go runtime 及推送数据指标。
* **生产建议**：必须开启。但此端点敏感性极高，**必须通过 Caddy 等反代进行外部网络屏蔽拦截**，防止公网拉取系统指标。

---

## 5. 日志配置 (Logging)

### 5.1 `log.level`

* **配置参数**：`log.level: info`
* **详细解析**：运行日志级别，支持 `debug` / `info` / `warn` / `error`。
* **生产建议**：生产环境必须设为 `info`。Centrifugo v6 会自动输出格式整洁的结构化 JSON 日志，可直接对接 EFK/Loki 收集系统。

---

## 6. 通道与命名空间最佳实践配置 (Channels & Namespaces)

这是决定特定频道如何进行性能调优和安全鉴权的核心区域。

### 6.1 `channel.history_meta_ttl`

* **配置参数**：`channel.history_meta_ttl: "720h"` (30天)
* **详细解析**：用于在 Valkey 中记录每个频道元信息（Metadata，如活跃频道缓存等）的存活期限。
* **生产建议**：建议保持 30 天，确保历史状态跟踪元数据的连续性。

---

### 6.2 命名空间配置列表 (Namespaces List)

针对不同通道前缀配置不同的安全和缓存行为：

```yaml
  namespaces:
    - name: public
    - name: private
    - name: user
    - name: notification
```

每个命名空间下的属性解析如下：

#### A. `presence` (在线状态监测)

* **描述**：是否收集当前频道的订阅者列表信息。
* **为什么重要**：
  * 在需要显示用户列表的场景下（如公共聊天室、多人连麦大厅），将其设为 `true`。
  * **性能损耗警告**：如果有 1 万个用户订阅同一个频道且开启了 `presence`，当每个用户进出通道时都会引发大规模状态广播。因此在个人专享通道（如 `user` 命名空间）必须设为 `false`。

#### B. `join_leave` (上下线事件消息)

* **描述**：当用户加入或离开通道时，是否主动群发通知给通道里的其他订阅者。
* **为什么重要**：
  * 与 `presence` 密切相关。设为 `true` 时，频道里其他人会收到如“UserA 订阅了频道”的通知帧。
  * **性能损耗警告**：高并发的通知公告频道（如 `notification` 命名空间）必须设为 `false`，否则上下线通知产生的数据洪峰会直接击垮客户端物理带宽。

#### C. `history_size` (历史队列缓存大小)

* **描述**：保存在底层 Valkey 中的消息条数限制上限。
* **为什么重要**：
  * 对于支持历史恢复重连（`force_recovery`）的频道，此值必须大于 `0`（如设置为 `50` 或 `100`）。
  * 历史容量并不是越大越好。太大会导致 Valkey 内存空间快速耗尽。如果是不需要补发历史的广播类通知（如 `notification`），建议调小（如 `10`），或关闭历史缓存。

#### D. `history_ttl` (历史缓存生存周期)

* **描述**：保存在 Valkey 中的历史消息的有效期限（如 `"300s"` 或 `"60s"`）。
* **为什么重要**：
  * 控制缓存在 Valkey 引擎中消息数据的生命周期，超时后缓存将自动释放，确保内存压力可控。

#### E. `force_recovery` (断线历史消息强制恢复)

* **描述**：当客户端因为弱网抖动等原因断开长连接并重连时，是否由 Centrifugo 根据客户端上次接收的 `epoch` 和 `offset`，从 Valkey 的历史队列中补发所错过的全部消息。
* **为什么重要**：
  * 开启该选项（设为 `true`）可以**完美消除移动端弱网环境下的数据丢失现象**，适合聊天室（`public`）、单聊（`private`）及个人红点推送（`user`）。
  * 但这需要付出 Valkey 存储开销。对于不重要的群发系统公告（`notification`），设为 `false` 关闭恢复机制可以极大减轻网络负载。

#### F. `allow_publish_for_subscriber` (订阅者长连接发布权限)

* **描述**：是否允许订阅了该频道的客户端（前端浏览器或 App）直接通过长连接向该频道推送消息（Publish）。
* **为什么重要**：
  * 如果是自由聊天室，可设为 `true`。
  * **安全性警示**：在生产环境的 `private`（私聊）及 `user`（个人红点）中，必须锁死为 `false`。绝对不允许前端绕过后端服务直接发布，必须由前端向后端的 Go API 接口发起请求，由后端完成鉴权、清洗数据后，从后端向 Centrifugo 推送，保障系统的完整性。

#### G. `allow_subscribe_for_client` (客户端自由订阅权限)

* **描述**：是否允许客户端（前端）不需要提供后端生成的订阅 JWT Token，直接自主发起该频道的订阅（Subscribe）。
* **为什么重要**：
  * 公共公告频道（`notification`）可设为 `true`。
  * **安全性警示**：对于私密频道（`private`）或个人通道（`user`），必须锁死为 `false`。这意味着任何订阅请求都必须携带由 Go 后端计算并签名生成的 `Subscription JWT`。如果 Token 校验不匹配，Centrifugo 会在网关层直接拒掉该订阅，防止恶意监听。

#### H. `allow_subscribe_for_anonymous` & `allow_publish_for_anonymous` (匿名权限)

* **描述**：是否允许没有携带任何连接 JWT（未通过全局握手登录）的游客进行订阅和发布操作。
* **为什么重要**：
  * 生产环境下全命名空间应该统一设为 `false`，确保只有通过全局身份 JWT 握手进来的实名用户才被允许在通道中操作。
