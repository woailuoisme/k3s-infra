#!/bin/sh
set -e

echo "[INFO] Mosquitto MQTT Broker 启动配置初始化与验证"

# 1. 检查并处理空挂载目录遮蔽问题
if [ ! -f /mosquitto/config/mosquitto.conf ]; then
	echo "[WARN] 未检测到 /mosquitto/config/mosquitto.conf，正在从模板初始化配置..."
	cp /etc/mosquitto.templates/mosquitto.conf /mosquitto/config/mosquitto.conf
	echo "[SUCCESS] 默认 mosquitto.conf 已复制"
fi

if [ ! -f /mosquitto/config/acl ]; then
	echo "[INFO] 未检测到 /mosquitto/config/acl，正在初始化默认 acl 策略..."
	cp /etc/mosquitto.templates/acl /mosquitto/config/acl
	echo "[SUCCESS] 默认 acl 已复制"
fi

# 确保文件权限
chmod 644 /mosquitto/config/mosquitto.conf
chmod 644 /mosquitto/config/acl

# 2. 配置验证函数
validate_config() {
	# 检查 MQTT_ALLOW_ANONYMOUS 配置
	if [ -z "$MQTT_ALLOW_ANONYMOUS" ]; then
		echo "[WARN] MQTT_ALLOW_ANONYMOUS 未设置，默认为 false"
		MQTT_ALLOW_ANONYMOUS="false"
	fi

	# 如果禁用匿名访问，必须设置主用户名密码或配置了多用户
	if [ "$MQTT_ALLOW_ANONYMOUS" = "false" ]; then
		if [ -z "$MQTT_USERNAME" ] && [ -z "$MQTT_USERS" ]; then
			echo "[ERROR] 禁用匿名访问时，必须设置主管理员（MQTT_USERNAME）或配置多账户（MQTT_USERS）"
			exit 1
		else
			echo "[SUCCESS] 认证配置: 账号密码验证已启用"
		fi
	else
		echo "[WARN] 匿名访问已启用，这在生产环境存在极高安全风险"
	fi
}

# 执行配置验证
validate_config

# 3. 创建与生成密码文件
touch /mosquitto/config/passwd
chmod 0640 /mosquitto/config/passwd 2> /dev/null || chmod 0600 /mosquitto/config/passwd
chown mosquitto:mosquitto /mosquitto/config/passwd 2> /dev/null || true
true > /mosquitto/config/passwd # 清空旧数据

# 写入主账号（如果存在）
if [ -n "$MQTT_USERNAME" ] && [ -n "$MQTT_PASSWORD" ]; then
	echo "[INFO] 正在生成主管理员账户..."
	mosquitto_passwd -b /mosquitto/config/passwd "$MQTT_USERNAME" "$MQTT_PASSWORD"
	echo "[SUCCESS] 主管理员账号 $MQTT_USERNAME 写入完成"

	# 若主管理员不是默认的 admin，在 acl 中自动补充完全管理权限
	if [ "$MQTT_USERNAME" != "admin" ] && [ -f /mosquitto/config/acl ]; then
		if ! grep -q "^user $MQTT_USERNAME" /mosquitto/config/acl; then
			printf "\n# 动态注入主管理员权限\nuser %s\ntopic readwrite #\ntopic readwrite \$SYS/#\n" "$MQTT_USERNAME" >> /mosquitto/config/acl
			echo "[SUCCESS] 已在 ACL 中为用户 $MQTT_USERNAME 授予管理权限"
		fi
	fi
fi

# 解析并写入环境变量指定的多用户（格式：u1:p1,u2:p2）
if [ -n "$MQTT_USERS" ]; then
	echo "[INFO] 正在生成多账户配置..."
	# 将逗号转换成换行以支持安全的循环读取
	echo "$MQTT_USERS" | tr ',' '\n' | while read -r user_pair; do
		if [ -n "$user_pair" ]; then
			# 使用 Shell 内置的参数替换切分语法，替代外部 cut 进程
			u="${user_pair%%:*}"
			p="${user_pair#*:}"
			if [ -n "$u" ] && [ -n "$p" ]; then
				mosquitto_passwd -b /mosquitto/config/passwd "$u" "$p"
				echo "[SUCCESS] 已成功添加用户: $u"
			fi
		fi
	done
fi

echo "[INFO] 启动 Mosquitto MQTT Broker..."

# 启动 Mosquitto（移交控制权，自动处理降权逻辑）
exec /docker-entrypoint.sh "$@"
