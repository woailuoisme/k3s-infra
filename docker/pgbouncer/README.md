# PgBouncer

事务池化连接池，为 PostgreSQL 18 提供连接复用。面向 Laravel Octane / RoadRunner 等长驻进程模型。

> **当前状态：无消费者。** 应用侧（Laravel / zitadel / chatwoot / casdoor / postgres-exporter /
> telegraf / pgBackRest）均直连 `postgres:5432`。本服务默认启用，但尚无流量经过。
> 「是否把应用流量切到本服务」不属于本文档范围。
> 本文档中的 `docker compose` 命令均需**在仓库根目录执行**。带 `-f database/docker-compose.yml`
> 会把项目目录识别为 `database/`，从而读不到根目录的 `.env`，所有变量都会变成空值。

---

## 1. 池化预算

Postgres `max_connections = 50`（`database/postgres-18/postgresql.conf`），`superuser_reserved_connections = 3`。
此外还有一批**不经池**的直连消费者占用同一份预算，因此池化侧的支出必须严格小于 50。

| 项目 | 连接数 |
|---|---|
| `lunchbox` | 12 |
| `zitadel` | 6 |
| `chatwoot` | 6 |
| `casdoor` | 4 |
| `postgres`（管理与认证锚点） | 2 |
| **池化预算合计** | **30** |
| 直连消费者 + 余量 | 20 |

- `max_user_connections = 30` 是硬总闸（全栈只有 `postgres` 一个角色，因此单用户上限即为总量上限）
- `min_pool_size = 2` → 常态占用 10 条后端连接
- `reserve_pool_size = 5` + `reserve_pool_timeout = 5` 提供突发缓冲

**新增业务库时必须做两件事**：在 `[databases]` 中显式声明 `pool_size`
（`default_pool_size` 故意未设置，上游默认值不会兜底），并从其他库的配额中让出等量预算。

## 2. 后端连接来源：`DATABASE_URL` 与 `pgbouncer.ini` 的分工

后端 Postgres 的参数**故意分两处**，各有明确职责：

| 位置 | 承载什么 | 谁在用 |
|---|---|---|
| `DATABASE_URL`（环境变量） | 后端 Postgres 的完整连接串，含凭据 | `entrypoint.sh` 的启动等待（`pg_isready -d "$DATABASE_URL"`）与 `Dockerfile` 的健康探针 |
| `pgbouncer.ini` 的 `[databases]` | 每个库的 `host` / `port` / `pool_size` | PgBouncer 自身建立后端连接 |

`DATABASE_URL` 由 `docker-compose.yml` 从 `.env` 的 `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`
合成（与 `devtools/dokploy` 的做法一致），不需要新的 env 键。

**为什么不能真正合并成一处**：PgBouncer 的库条目是 libpq 的 `key=value` 形式，**不接受 URL**，
所以 `host` / `port` 必然在两处出现。改动后端主机或端口时必须**同时**改这两处；
健康探针会立刻暴露不一致（探针走 URL）。

### 2.1 健康探针为什么要追加 query 参数

`DATABASE_URL` 指向的是后端 `postgres:5432`，而健康探针必须**走池**才有意义。libpq 的参数优先级为：

- ✅ `?host=127.0.0.1&port=15432` 形式的 **query 参数可以覆盖 authority**（已实测）
- ❌ `psql -h 127.0.0.1 -p 15432 "$DATABASE_URL"` 这类 **命令行关键字不生效**，会被 URL 覆盖

因此探针固定写作 `psql "$DATABASE_URL?host=127.0.0.1&port=15432" -c 'SELECT 1'`。
它同时使用业务凭据，所以也覆盖了 `auth_query` 这条链路。

> 若 `DATABASE_URL` 将来自带查询串（如 `?sslmode=disable`），追加时需改用 `&` 连接。

### 2.2 密码字符集约束（重要）

URL 形态无法表达「密码含未编码特殊字符」，且失败是**静默**的：

| 字符 | 后果 |
|---|---|
| `@` | 解析在最后一个 `@` 处切分，凭据与主机错位 |
| `#` | 被当作 fragment 起点，后半段被整体丢弃 |
| `/` | 干扰 authority 与路径的切分 |

因此 `entrypoint.sh` 在启动时**强制校验**：密码段只允许 `A-Za-z0-9 . _ ~ -` 与 `%XX`（百分号编码），
不合法直接 `exit 1` 并打印原因，不会带病启动。

> 当前 `.env` 中的 `POSTGRES_PASSWORD` 已确认符合该约束（仅含字母数字与 `._~-`）。

## 3. 应用侧契约

### 3.1 禁止使用的会话级特性

`pool_mode = transaction` 下每个事务可能落在不同的后端连接上，以下特性**不可用**：

| 特性 | 替代方案 |
|---|---|
| `SET` / `RESET` | 连接串传参，或服务端 `ALTER ROLE ... SET` |
| `LISTEN`（`NOTIFY` 可用） | 外部消息系统（本栈已有 Mosquitto / Centrifugo / NATS） |
| `WITH HOLD` 游标 | 普通游标（`WITHOUT HOLD` 可用） |
| SQL 级 `PREPARE` / `DEALLOCATE` | 驱动层协议级预处理（见 3.2） |
| 持久化临时表 | `CREATE TEMP TABLE ... ON COMMIT DROP` |
| 会话级 advisory lock | 事务级 advisory lock |
| `LOAD` 语句 | — |

仓库内所有 `*.sql` 均已核查，未使用上述任何特性，因此该契约不影响现有 schema。

### 3.2 预处理语句

`max_prepared_statements = 200` **必须显式非零**，否则事务模式下协议级预处理不可用。
Laravel 的 pgsql 驱动默认走服务端预处理，因此这是硬需求而非优化。

副作用：DDL 迁移后可能出现 `cached plan must not change result type`，处置见 §5。

### 3.3 客户端启动参数

PgBouncer 对启动包里的参数（含 `options` 内部的 `-c` 参数）**逐项**判定，三种结局：

| 参数位置 | 结局 |
|---|---|
| 可跟踪集合内（默认 `client_encoding` / `datestyle` / `timezone` / `standard_conforming_strings`，加 `track_extra_parameters` 默认的 `IntervalStyle`） | 接受**并实际生效** |
| `ignore_startup_parameters` 白名单内（本栈只有 `extra_float_digits`） | 接受但**不应用**（官方语义：声明由管理员处理，即静默丢弃） |
| 其余 | **直接报错**（失败优先） |

因此「`options` 整体被丢弃」是误解，实测：

| 客户端传入 | 结果 |
|---|---|
| `options=-c timezone=UTC` | 生效（`timezone` 属可跟踪集合） |
| `options=-c extra_float_digits=0` | 通过（在白名单内） |
| `options=-c search_path=foo` | `FATAL: unsupported startup parameter in options: search_path` |

`search_path` 故意不白名单 —— 它不在可跟踪集合内，客户端一旦发送就明确报错，而不是静默降级。

**若某客户端报 `unsupported startup parameter in options: search_path`：**

1. 先确认它是否真的依赖——核查结论是仓库内**没有任何 `CREATE SCHEMA`**、
   全部对象都在 `public`，正常情况下不需要 `search_path`
2. 如确实需要，用**服务端固化**（不要改回 `ignore_startup_parameters`）：

   ```sql
   ALTER ROLE <user> SET search_path = <schema>, public;
   ```

   注意：`search_path` 通常不在 Postgres 回传给客户端的参数列表内，
   因此**无法**通过 `track_extra_parameters` 跟踪，只能服务端固化。

## 4. 认证模型

`userlist.txt` **只有一行**：`auth_user` 的引导凭据。其余用户全部由 `auth_query`
动态解析，因此在 Postgres 侧轮换业务密码**无需重启 PgBouncer**。

| 键 | 值 |
|---|---|
| `auth_type` | `scram-sha-256` |
| `auth_user` | `pgbouncer_auth`（仅用于执行 auth_query，无业务权限） |
| `auth_dbname` | `postgres` |
| `auth_query` | `SELECT usename, passwd FROM pgbouncer_auth_lookup($1)` |

`auth_dbname` 存在的唯一原因是消解「auth_query 在**目标库**内执行」这一官方语义——
不设它，`SECURITY DEFINER` 函数就必须装进每一个客户端会连的库，将来新增库一旦遗漏就会全体登录失败。

**关键耦合**：`PGBOUNCER_AUTH_PASSWORD` 必须同时注入 `pgbouncer` 与 `postgres-18` 两个服务：

- `pgbouncer` 的 `entrypoint.sh` 用它写出 userlist.txt 的那一行
- `postgres-18` 的 `docker-entrypoint-initdb.d/04-pgbouncer-auth.sh` 用它 `CREATE ROLE pgbouncer_auth LOGIN PASSWORD`

### 密码变更不会自动同步

`04-pgbouncer-auth.sh` 位于官方的 `/docker-entrypoint-initdb.d/`，而该目录**只在数据目录为空时**被执行
（重启时日志会打印 `PostgreSQL Database directory appears to contain a database; Skipping initialization`）。
因此 Postgres 侧的 `pgbouncer_auth` 密码**永远不会自动跟着环境变量变**——两处副本的写入时机本就不同：

| 位置 | 何时写入 |
|---|---|
| Postgres 侧 `pgbouncer_auth` 角色密码 | 仅首次初始化（init 脚本），之后永不重跑 |
| `pgbouncer` 容器内 `userlist.txt` | 每次容器启动（`entrypoint.sh` 重写） |

所以只改环境变量再重建 `pgbouncer`，会得到「userlist 是新密码、角色还是旧密码」的错配，
后果是 `auth_query` 失败 → **所有客户端认证失败**。

`entrypoint.sh` 启动时会**预检**这一点：用 `PGBOUNCER_AUTH_PASSWORD` 向后端以
`pgbouncer_auth` 身份认证一次，失败则 `exit 1` 并打印修复步骤。

> 没有这道预检时，症状是「容器启动一切正常、60 秒后变成 `unhealthy`」，且 `pg_isready`
> 不校验认证，所以启动阶段毫无提示——这正是预检要消除的含糊状态。

### 已有数据卷需手动补装

`04-pgbouncer-auth.sh` 由官方 entrypoint 在**数据目录为空**时执行。若 `postgres18`
数据卷已存在，需手动跑一次（在仓库根目录执行）：

```bash
docker compose exec -T postgres \
  bash < database/postgres-18/docker-entrypoint-initdb.d/04-pgbouncer-auth.sh
```

## 5. 运维动作

| 场景 | 动作 |
|---|---|
| DDL 迁移后出现 `cached plan must not change result type` | 迁移完成后执行 `RECONNECT`（见下） |
| 轮换业务密码 | 在 Postgres 侧 `ALTER ROLE ... PASSWORD`，PgBouncer 无需重启。但 `.env` 的 `POSTGRES_PASSWORD` 变化会改变 `DATABASE_URL`，需重建 `pgbouncer` 容器才会生效 |
| 轮换 `pgbouncer_auth` 密码 | 必须按此顺序执行，**第 2 步不可省**（否则脚本读到的是 postgres 容器里的旧变量，同步等于没做）：<br>1) 改 `.env` 的 `PGBOUNCER_AUTH_PASSWORD`<br>2) `docker compose up -d postgres`<br>3) 重跑 `04-pgbouncer-auth.sh`（命令见 §4）<br>4) `docker compose up -d pgbouncer` |
| 排查连接来源 | `application_name_add_host = 1` 已开启，`pg_stat_activity` / `SHOW CLIENTS` 可见来源主机 |
| 查看池状态 | 见下面的 admin console 命令 |
| GUI 客户端连控制台 | **不可用**，且不是配置问题。官方 usage 文档原话：*"The admin console currently only supports the simple query protocol. Some drivers use the extended query protocol for all commands; these drivers will not work for this."* 实际表现：`extended query protocol not supported by admin console` + `closing because: bad packet` 断连（客户端侧常表现为「SET timezone failed after connecting: connection closed」）。出路只有两条：**控制台改用 `psql`**，或 JDBC 系客户端加 `preferQueryMode=simple`（原生驱动如 dbx 用的 Rust `sqlx` 没有等价开关）。GUI 里的日常操作请连真实业务库 |
| 控制台库名 | 固定为 **`pgbouncer`**，无法改名：它是 PgBouncer 保留的虚拟数据库，官方无任何重命名配置（`admin_users` / `stats_users` 只管「谁能连」，不管「叫什么」）。若要短名 URL，请让它指向**真实库** |
| 连了不存在的库名 | 报的是 `FATAL: SASL authentication failed`，**不是** `database ... does not exist`（已实测，pgbouncer 侧错误信息，容易误判为密码问题） |
| 会话级 `SET` | 分两类。**可跟踪参数**（`client_encoding` / `datestyle` / `timezone` / `standard_conforming_strings`，加 `track_extra_parameters` 默认的 `IntervalStyle`）由 PgBouncer 记录并在每次取用后端连接时重放，**可靠生效** —— dbx 连接后自动执行的 `SET timezone` 正属此类。**其它 GUC**（如 `statement_timeout`、`search_path`）在事务池化下不要依赖，请走服务端固化（`ALTER DATABASE ... SET` / `ALTER ROLE ... SET`），见 `database/postgres-18/docker-entrypoint-initdb.d/` |

```bash
# 控制台需要 admin 口令（.env 的 POSTGRES_PASSWORD）；不导出会报 fe_sendauth: no password supplied
export PGPASSWORD="$(rg --no-filename -o '^POSTGRES_PASSWORD=(.*)$' -r '$1' .env)"

# RECONNECT：重建所有后端连接，清掉缓存计划
docker compose exec -T -e PGPASSWORD="$PGPASSWORD" pgbouncer \
  psql -h /var/run/pgbouncer -p 15432 -U postgres -d pgbouncer -c 'RECONNECT'

# 池状态
docker compose exec -T -e PGPASSWORD="$PGPASSWORD" pgbouncer \
  psql -h /var/run/pgbouncer -p 15432 -U postgres -d pgbouncer -c 'SHOW POOLS'

# 等价做法（走 Caddy 的对外入口，省掉 docker exec；库名 pgbouncer 即控制台虚拟库）
# psql "postgresql://postgres@pgp.test.local/pgbouncer?sslmode=require" -c 'SHOW POOLS'
```

## 6. 有意未做的事

| 项 | 原因 |
|---|---|
| `client_tls_*` / `server_tls_*` | 后端不自己终止 TLS：对外入口由 `gateways/caddy/layer4/postgres.conf` 的 `pgp.<域名>` 提供（Caddy 终止 TLS）；容器本身仍只在 `backend` 内网明文可达 |
| 宿主机端口发布 | 已删除 `ports`。对外访问统一走 Caddy 的 5432（按 SNI 分流，客户端不必写端口）；Caddy ↔ pgbouncer 走 `backend` 内网 |
| 多进程 `so_reuseport` | 单实例、2 核 1G 规模下不需要 |
| `logfile` | 只写 stderr，交给 Docker 日志驱动（Dozzle / Loki）统一采集 |
| `server_reset_query` | 事务模式下永不执行，写了就是误导性配置 |
| `max_db_connections` | 与 per-db `pool_size` 语义重叠，多库场景下易被误读 |
