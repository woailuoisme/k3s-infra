#!/bin/sh
set -e

# =============================================================================
# PgBouncer 启动引导
# 职责：校验 DATABASE_URL → 等待后端就绪 → 写入 auth_user 引导凭据 → 前台启动
#
# 说明：DATABASE_URL 承载后端 Postgres 的连接信息，服务于「启动等待」；
#       Dockerfile 的健康探针基于同一变量构造。PgBouncer 真正的后端连接参数在
#       pgbouncer.ini 的 [databases] 段，两处分工见同目录 README.md。
#       除 auth_user 外，所有用户的密码由 auth_query 在 Postgres 侧动态解析，
#       因此 userlist.txt 只需要一行，业务密码轮换无需重启本容器。
# =============================================================================

# 日志工具
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
log() { echo -e "${1}[$(date '+%Y-%m-%d %H:%M:%S %z')] [${2}]${NC} ${3}"; }
log_info() { log "${BLUE}" "INFO" "$1"; }
log_success() { log "${GREEN}" "SUCCESS" "$1"; }
log_warning() { log "${YELLOW}" "WARNING" "$1" >&2; }
log_error() { log "${RED}" "ERROR" "$1" >&2; }

PGBOUNCER_CONFIG="/etc/pgbouncer/pgbouncer.ini"
PGBOUNCER_AUTH_FILE="/etc/pgbouncer/userlist.txt"

# auth_query 的执行主体，必须与 pgbouncer.ini 的 auth_user 一致
AUTH_USER="pgbouncer_auth"

# -----------------------------------------------------------------------------
# 1. 前置校验
# -----------------------------------------------------------------------------
if [ -z "$DATABASE_URL" ]; then
	log_error "DATABASE_URL 未设置（形如 postgres://user:password@host:5432/dbname）"
	exit 1
fi

# 引导凭据是唯一无法由 auth_query 解析的密码，缺失则所有客户端认证都会失败
if [ -z "$PGBOUNCER_AUTH_PASSWORD" ]; then
	log_error "PGBOUNCER_AUTH_PASSWORD 未设置，auth_user ($AUTH_USER) 无法通过后端认证"
	exit 1
fi

# -----------------------------------------------------------------------------
# 2. DATABASE_URL 形态校验
#    URL 形态无法表达「密码含未编码特殊字符」，且失败是静默的：
#      @  → 在最后一个 @ 处切分，凭据与主机错位
#      #  → 被当作 fragment 起点，后半段被整体丢弃
#      /  → 干扰 authority 与路径的切分
#    因此这里强制约束并大声失败，不带病启动。
# -----------------------------------------------------------------------------
case "$DATABASE_URL" in
	postgres://* | postgresql://*) ;;
	*)
		log_error "DATABASE_URL 必须以 postgres:// 或 postgresql:// 开头"
		exit 1
		;;
esac

_url_rest="${DATABASE_URL#*://}"
case "$_url_rest" in
	*@*@*)
		log_error "DATABASE_URL 中出现多个 '@'：密码含未编码的 '@'，会被静默错位解析"
		log_error "请把密码中的 '@' 百分号编码为 %40，或改用不含 @ : / # ? 的密码"
		exit 1
		;;
	*@*) ;;
	*)
		log_error "DATABASE_URL 缺少 '@'，无法区分凭据与主机"
		exit 1
		;;
esac

_url_userinfo="${_url_rest%%@*}"
_url_password="${_url_userinfo#*:}"
case "$_url_password" in
	*[!A-Za-z0-9._~%-]*)
		log_error "DATABASE_URL 的密码段含需百分号编码的字符"
		log_error "仅支持 A-Za-z0-9 . _ ~ - 与 %XX（百分号编码）"
		exit 1
		;;
esac

# -----------------------------------------------------------------------------
# 3. 等待 PostgreSQL 就绪
#    pg_isready 原生接受 URL 形式的 -d 参数（已实测）
# -----------------------------------------------------------------------------
log_info "等待 PostgreSQL 数据库上线..."
attempts=0
max_attempts=30

while ! pg_isready -d "$DATABASE_URL" > /dev/null 2>&1; do
	attempts=$((attempts + 1))
	if [ "$attempts" -ge "$max_attempts" ]; then
		log_error "等待 PostgreSQL 超时 (${max_attempts}s)，启动失败"
		exit 1
	fi
	log_info "PostgreSQL 尚未就绪，等待中... (${attempts}/${max_attempts})"
	sleep 1
done

log_success "PostgreSQL 数据库已成功上线！"

# -----------------------------------------------------------------------------
# 4. 预检：引导凭据与 Postgres 侧角色密码是否同步
#    04-pgbouncer-auth.sh 位于 /docker-entrypoint-initdb.d/，该目录只在数据目录
#    为空时被执行一次（重启时会打印 Skipping initialization），因此轮换
#    PGBOUNCER_AUTH_PASSWORD 后必须手动重跑该脚本。若不同步，这里立刻失败并给出
#    可操作步骤，而不是等 60 秒后的健康检查以「unhealthy」这种含糊形式暴露。
#    注意：本探针直连后端（校验角色密码），与走池的健康探针是两件事。
# -----------------------------------------------------------------------------
_backend_scheme="${DATABASE_URL%%://*}"
_backend_target="${DATABASE_URL#*@}" # URL 已校验只含一个 @，故此处切分唯一
_preflight_url="${_backend_scheme}://${AUTH_USER}@${_backend_target}"

log_info "预检 auth_user ($AUTH_USER) 与 Postgres 侧角色密码是否同步..."
_preflight_ok=false

for _attempt in 1 2 3; do
	if _preflight_msg=$(PGPASSWORD="$PGBOUNCER_AUTH_PASSWORD" psql "$_preflight_url" -tAc 'SELECT 1' 2>&1); then
		_preflight_ok=true
		break
	fi
	# 轻微重试以吸收瞬时抖动，但密码真的不对时三次都会失败
	if [ "$_attempt" -lt 3 ]; then sleep 2; fi
done

if [ "$_preflight_ok" != "true" ]; then
	log_error "auth_user ($AUTH_USER) 无法通过后端认证：引导凭据与 Postgres 侧角色密码不同步"
	log_error "后端返回：$(printf '%s' "$_preflight_msg" | head -1)"
	log_error "修复顺序（第 1 步不可省，否则脚本读到的是 postgres 容器内的旧变量）："
	log_error "  1) docker compose up -d postgres"
	log_error "  2) docker compose exec -T postgres bash < database/postgres-18/docker-entrypoint-initdb.d/04-pgbouncer-auth.sh"
	log_error "  3) docker compose up -d pgbouncer"
	exit 1
fi

log_success "auth_user 凭据与 Postgres 侧角色已同步"

# -----------------------------------------------------------------------------
# 5. 生成引导凭据
#    userlist.txt 语法为 "user" "password"，需转义反斜杠与双引号
# -----------------------------------------------------------------------------
log_info "生成 auth_user 引导凭据..."
rm -f "$PGBOUNCER_AUTH_FILE"

escaped_password=$(printf '%s' "$PGBOUNCER_AUTH_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '"%s" "%s"\n' "$AUTH_USER" "$escaped_password" > "$PGBOUNCER_AUTH_FILE"

chmod 600 "$PGBOUNCER_AUTH_FILE"
log_success "已写入引导凭据：$AUTH_USER（其余用户由 auth_query 动态解析）"

# -----------------------------------------------------------------------------
# 6. 优雅停机信号处理
# -----------------------------------------------------------------------------
trap 'log_info "收到终止信号，正在停止 PgBouncer..."; kill -TERM "$PGBOUNCER_PID" 2>/dev/null || true; wait "$PGBOUNCER_PID"' TERM INT QUIT

# -----------------------------------------------------------------------------
# 7. 前台启动 PgBouncer
# -----------------------------------------------------------------------------
log_info "正在前台启动 PgBouncer 服务..."

pgbouncer "$PGBOUNCER_CONFIG" &
PGBOUNCER_PID=$!

log_success "PgBouncer 已就绪，进程 PID: $PGBOUNCER_PID"
wait "$PGBOUNCER_PID"
