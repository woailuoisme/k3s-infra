# Centrifugo v6 接口测试与长连接手动配置指南

本指南将 [centrifugo_postman_collection.json](file:///Users/seaside/Projects/docker/development/centrifugo/centrifugo_postman_collection.json) 集合中的每一个请求拆解，方便您在 Postman 或 Hoppscotch.app 中**逐个手动创建和配置**。

---

## 0. 准备工作：配置全局变量 (Variables)

在 Postman 的 **Collection Variables**（集合变量）或 Hoppscotch 的 **Environments**（环境）中添加以下预设变量，以实现一键切换测试环境：

| 变量键名 (Key) | 推荐默认值 (开发环境) | 描述 |
| :--- | :--- | :--- |
| `fiber_url` | `http://localhost:3000` | Go Fiber 后端服务地址 |
| `centrifugo_url` | `https://push.test.local` | Centrifugo 网关 HTTP/SSE 访问域名 |
| `centrifugo_ws_url` | `wss://push.test.local` | Centrifugo 网关 WebSocket 访问域名 |
| `centrifugo_api_key` | `aef5a17a-fdeb-48aa-b2c1-d490c62ff950` | 对应 `.env` 中的 `CENTRIFUGO_API_KEY` |

---

## 1. 第一部分：Fiber Backend API (应用服务器接口)

这些接口由本地运行的 Go Fiber 实例提供，主要处理业务层的鉴权与推送路由。

### 1.1 获取客户端长连接 Token

* **功能说明**：客户端建立 WebSocket 或 SSE 长连接前，向应用服务器申请 JWT 连接凭证。
* **方法 (Method)**：`GET`
* **URL**：

    ```text
    {{fiber_url}}/api/centrifugo/connect-token
    ```

* **Headers**：无
* **Body**：无（None）

---

### 1.2 获取私有通道订阅 Token

* **功能说明**：客户端订阅私有命名空间（`private:*`）时，向后端申请该专属通道的订阅凭证（绑定了连接的 `client` ID 防止重放劫持）。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{fiber_url}}/api/centrifugo/subscribe-token
    ```

* **Headers**：
  * `Content-Type`: `application/json`
* **Body (raw JSON)**：

    ```json
    {
        "channel": "private:secure_chat_1",
        "client": "94747a82-fbc2-4e4b-bb99-317414df9abf"
    }
    ```

---

### 1.3 通过 Go 后端模拟业务推送 (Publish)

* **功能说明**：模拟业务流程。后端接收业务请求后，在代码内通过 `gocent` 推送消息至 Centrifugo。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{fiber_url}}/api/centrifugo/publish
    ```

* **Headers**：
  * `Content-Type`: `application/json`
* **Body (raw JSON)**：

    ```json
    {
        "namespace": "public",
        "channel_id": "chat_room_1",
        "message": {
            "text": "来自 Go 后端的一条测试消息！",
            "status": "success"
        }
    }
    ```

---

## 2. 第二部分：Centrifugo Direct API (直连 HTTP API)

这些接口直接请求 Centrifugo 服务。所有请求必须发送至统一端点 `/api`，并携带管理员秘钥。

* **统一 Headers（适用于本节所有接口）**：
  * `Content-Type`: `application/json`
  * `Authorization`: `apikey {{centrifugo_api_key}}`

---

### 2.1 Publish (向指定频道推送消息)

* **功能说明**：直接向 Centrifugo 推送单频道消息。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{centrifugo_url}}/api
    ```

* **Body (raw JSON)**：

    ```json
    {
        "method": "publish",
        "params": {
            "channel": "public:chat_room_1",
            "data": {
                "text": "从 Postman 直连 API 发送的广播消息",
                "timestamp": "{{$timestamp}}"
            }
        }
    }
    ```

---

### 2.2 Broadcast (向多个频道广播消息)

* **功能说明**：单次推送同时向多个不同的频道分发消息。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{centrifugo_url}}/api
    ```

* **Body (raw JSON)**：

    ```json
    {
        "method": "broadcast",
        "params": {
            "channels": [
                "public:chat_room_1",
                "notification:system_announce"
            ],
            "data": {
                "text": "这是一条全局多频道的同步广播通知",
                "timestamp": "{{$timestamp}}"
            }
        }
    }
    ```

---

### 2.3 Channels (获取活跃频道列表)

* **功能说明**：获取当前有客户端订阅的活跃频道。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{centrifugo_url}}/api
    ```

* **Body (raw JSON)**：

    ```json
    {
        "method": "channels",
        "params": {
            "pattern": "public:*"
        }
    }
    ```

---

### 2.4 Presence (查询通道当前在线人员列表)

* **功能说明**：获取当前频道内所有长连接实例的信息（要求频道命名空间开启了 `presence: true`）。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{centrifugo_url}}/api
    ```

* **Body (raw JSON)**：

    ```json
    {
        "method": "presence",
        "params": {
            "channel": "public:chat_room_1"
        }
    }
    ```

---

### 2.5 History (获取通道在 Valkey 中的消息历史记录)

* **功能说明**：拉取缓存在底层 Valkey 中最近发送的几条消息记录（要求对应命名空间开启了 `history_size` 大于 0）。
* **方法 (Method)**：`POST`
* **URL**：

    ```text
    {{centrifugo_url}}/api
    ```

* **Body (raw JSON)**：

    ```json
    {
        "method": "history",
        "params": {
            "channel": "public:chat_room_1",
            "limit": 20
        }
    }
    ```

---

## 3. 第三部分：Real-time Connections (长连接测试接口)

### 3.1 单向 WebSocket 订阅 (uni_websocket)

* **功能说明**：用于调试长连接握手升级与通道连通性。
* **调试类型**：**WebSocket Request** (Postman 新增的 WS 类型面板)
* **WebSocket URL**（复制并填入）：

    ```text
    {{centrifugo_ws_url}}/connection/uni_websocket?cf_connect=%7B%22subs%22%3A%7B%22public%3Achat_room_1%22%3A%7B%7D%7D%7D
    ```

  *(注：`cf_connect` 携带的参数原文为：`{"subs":{"public:chat_room_1":{}}}`，由于要规避 SSL 验证，请确保关闭 Postman 的 SSL 证书校验选项)*

---

### 3.2 单向 SSE 实时监听 (uni_sse)

* **功能说明**：使用 HTTP 请求直连 Server-Sent Events 协议，接收流式推送帧。
* **方法 (Method)**：`GET`
* **URL**：

    ```text
    {{centrifugo_url}}/connection/uni_sse?cf_connect=%7B%22channels%22%3A%5B%22public%3Achat_room_1%22%5D%7D
    ```

  *(注：`cf_connect` 携带的参数原文为：`{"channels":["public:chat_room_1"]}`)*
* **Headers**：
  * `Accept`: `text/event-stream`
* **Hoppscotch/Postman 现象**：发送 GET 后，连接会保持 Open 状态，每次服务器有推送时，响应面板中会自动流式展现新数据帧。
