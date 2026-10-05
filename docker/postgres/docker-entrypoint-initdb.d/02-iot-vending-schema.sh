#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# IoT 售货机业务 Schema 初始化 - 02-iot-vending-schema.sh
# 职责：创建业务表结构、配置 TimescaleDB 超表、索引与数据生命周期策略
# 策略：默认不初始化（按需使用），仅当 ENABLE_IOT_VENDING_SCHEMA=true 时执行
#
# 传感器体系总览 (6 大类 / 13 种物理与感知采集通道)：
#   1. 温控传感器组 (5 通道)：4 路冷冻温区探头 (freezer_temp_0~3) + 1 路机外环境温度 (ambient_temp)
#   2. 电气监测传感器 (2 通道)：市电输入电压 (voltage) + 整机总工作电流 (current)
#   3. 结构与安全开关 (1 通道)：机门门磁行程微动开关 (door_closed)
#   4. 防暴力与位移传感器 (1 通道)：3 轴 MEMS 加速度计/瞬时冲击 G 值 (vibration_g)
#   5. 通信与定位模组 (3 通道)：无线射频信号 RSSI (rssi) + GPS/北斗 GNSS 经纬度 (lat, lng)
#   6. 业务与取证感知 (事件驱动)：出货红外光栅 (channel_id) + 微波温控门联锁 (oven_id) + 抓拍相机 (image_url/video_url)
# =============================================================================

if [ "${ENABLE_IOT_VENDING_SCHEMA:-false}" != "true" ]; then
	echo "ENABLE_IOT_VENDING_SCHEMA is not set to 'true'. Skipping IoT vending schema initialization (按需启用)."
	exit 0
fi

# 如果创建了独立的 lunchbox 业务库则优先初始化至 lunchbox，否则初始化至默认库
if [ "$(psql -XtA -c "SELECT 1 FROM pg_database WHERE datname='lunchbox'" --username "$POSTGRES_USER" --dbname "postgres")" = '1' ]; then
	TARGET_DB="lunchbox"
else
	TARGET_DB="${POSTGRES_DB:-postgres}"
fi

echo "Initializing IoT vending schema for database: ${TARGET_DB}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$TARGET_DB" <<- 'EOSQL'
	-- 确保扩展已启用
	CREATE EXTENSION IF NOT EXISTS timescaledb;

	-- 1. 遥测数据表 (vm_telemetry) - 周期性传感器采样数据集 (QoS 0)
	CREATE TABLE IF NOT EXISTS vm_telemetry (
	    time            TIMESTAMPTZ NOT NULL,
	    device_no       TEXT NOT NULL,
	    voltage         DOUBLE PRECISION,
	    current         DOUBLE PRECISION,
	    uptime          INTEGER,
	    door_closed     BOOLEAN,
	    freezer_temp_0  DOUBLE PRECISION,
	    freezer_temp_1  DOUBLE PRECISION,
	    freezer_temp_2  DOUBLE PRECISION,
	    freezer_temp_3  DOUBLE PRECISION,
	    ambient_temp    DOUBLE PRECISION,
	    vibration_g     DOUBLE PRECISION,
	    rssi            INTEGER,
	    lat             DOUBLE PRECISION,
	    lng             DOUBLE PRECISION
	);

	-- 添加注释 (详细说明各传感器硬件与采集物理量)
	COMMENT ON TABLE vm_telemetry IS '售货机高频遥测历史数据集 (TimescaleDB 超表)';
	COMMENT ON COLUMN vm_telemetry.time IS '数据上报/采样时间戳 (UTC)';
	COMMENT ON COLUMN vm_telemetry.device_no IS '设备唯一编号 (格式: VM-地区-编号)';
	COMMENT ON COLUMN vm_telemetry.voltage IS '【电气传感器】当前主板输入电压 (V，用于电网波动与欠压保护)';
	COMMENT ON COLUMN vm_telemetry.current IS '【电气传感器】系统总工作电流 (A，用于压缩机/微波炉过载与能耗计算)';
	COMMENT ON COLUMN vm_telemetry.uptime IS '【系统指标】自上次主板启动以来的持续运行秒数';
	COMMENT ON COLUMN vm_telemetry.door_closed IS '【门磁开关】机门行程开关状态: true=关闭, false=打开';
	COMMENT ON COLUMN vm_telemetry.freezer_temp_0 IS '【温控传感器 1/5】冷冻底层温区0温度 (℃，食品 -18℃ 达标监测)';
	COMMENT ON COLUMN vm_telemetry.freezer_temp_1 IS '【温控传感器 2/5】冷冻中下温区1温度 (℃)';
	COMMENT ON COLUMN vm_telemetry.freezer_temp_2 IS '【温控传感器 3/5】冷冻中上温区2温度 (℃)';
	COMMENT ON COLUMN vm_telemetry.freezer_temp_3 IS '【温控传感器 4/5】冷冻顶层温区3温度 (℃)';
	COMMENT ON COLUMN vm_telemetry.ambient_temp IS '【温控传感器 5/5】机柜外部环境气温 (℃，用于温控制冷动态调功)';
	COMMENT ON COLUMN vm_telemetry.vibration_g IS '【防破坏传感器】3 轴 MEMS 加速度计瞬时冲击 G 值 (踢砸/撬机告警)';
	COMMENT ON COLUMN vm_telemetry.rssi IS '【通信模组】4G/5G/WiFi 移动网络无线信号强度 (dBm)';
	COMMENT ON COLUMN vm_telemetry.lat IS '【GNSS 定位】GPS/北斗卫星定位纬度 (电子围栏防盗与资产盘点)';
	COMMENT ON COLUMN vm_telemetry.lng IS '【GNSS 定位】GPS/北斗卫星定位经度';

	-- 转换为超表 (按时间自动分区)
	SELECT create_hypertable('vm_telemetry', 'time', if_not_exists => TRUE);

	-- 创建索引
	CREATE INDEX IF NOT EXISTS idx_telemetry_device ON vm_telemetry (device_no, time DESC);

	-- 2. 事件数据表 (vm_events)
	CREATE TABLE IF NOT EXISTS vm_events (
	    time            TIMESTAMPTZ NOT NULL,
	    device_no       TEXT NOT NULL,
	    event_type      TEXT NOT NULL,
	    order_id        TEXT,
	    channel_id      TEXT,
	    oven_id         TEXT,
	    error_code      TEXT,
	    image_url       TEXT,
	    video_url       TEXT,
	    raw_data        JSONB
	);

	-- 添加注释
	COMMENT ON TABLE vm_events IS '售货机业务与异常告警事件记录表';
	COMMENT ON COLUMN vm_events.time IS '事件触发时刻';
	COMMENT ON COLUMN vm_events.device_no IS '设备唯一编号';
	COMMENT ON COLUMN vm_events.event_type IS '事件类型 (DISPENSE_SUCCESS/CHANNEL_JAM等)';
	COMMENT ON COLUMN vm_events.order_id IS '关联订单ID (如果有)';
	COMMENT ON COLUMN vm_events.channel_id IS '出货或发生异常的货道ID';
	COMMENT ON COLUMN vm_events.oven_id IS '关联微波炉ID (OVEN_A/OVEN_B)';
	COMMENT ON COLUMN vm_events.error_code IS '故障码，详见附录定义';
	COMMENT ON COLUMN vm_events.image_url IS '云端生成的抓拍图片URL';
	COMMENT ON COLUMN vm_events.video_url IS '异常现场抓拍短视频URL';
	COMMENT ON COLUMN vm_events.raw_data IS '原始事件Payload副本 (JSONB格式)';

	SELECT create_hypertable('vm_events', 'time', if_not_exists => TRUE);
	CREATE INDEX IF NOT EXISTS idx_events_device ON vm_events (device_no, time DESC);
	CREATE INDEX IF NOT EXISTS idx_events_type ON vm_events (event_type, time DESC);

	-- 3. 状态数据表 (vm_status)
	CREATE TABLE IF NOT EXISTS vm_status (
	    time            TIMESTAMPTZ NOT NULL,
	    device_no       TEXT NOT NULL,
	    status          TEXT NOT NULL,
	    firmware        TEXT,
	    hardware        TEXT
	);

	-- 添加注释
	COMMENT ON TABLE vm_status IS '设备在线与硬件版本追踪表';
	COMMENT ON COLUMN vm_status.time IS '在线状态变更时间';
	COMMENT ON COLUMN vm_status.device_no IS '设备唯一编号';
	COMMENT ON COLUMN vm_status.status IS '当前状态: online=在线, offline=离线';
	COMMENT ON COLUMN vm_status.firmware IS '上报时的固件版本号';
	COMMENT ON COLUMN vm_status.hardware IS '机器底层硬件版本';

	SELECT create_hypertable('vm_status', 'time', if_not_exists => TRUE);
	CREATE INDEX IF NOT EXISTS idx_status_device ON vm_status (device_no, time DESC);

	-- 4. 数据保留策略 (可选启用的策略)
	-- SELECT add_retention_policy('vm_telemetry', INTERVAL '30 days', if_not_exists => TRUE);
	-- SELECT add_retention_policy('vm_events', INTERVAL '90 days', if_not_exists => TRUE);
EOSQL

echo "IoT vending schema initialization completed."
