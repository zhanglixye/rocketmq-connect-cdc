# PostgreSQL CDC → RocketMQ Connect → MySQL 生产级部署方案

---

## 步骤 1：PostgreSQL 生产前置配置（在 10.0.1.2 执行）

### 1.1 连接 PostgreSQL

```bash
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable"
```

### 1.2 开启逻辑复制（需重启 PG 生效）

```sql
-- 检查当前 wal_level
SHOW wal_level;

-- 如果不是 logical，执行以下修改
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET wal_sender_timeout = '60s';
ALTER SYSTEM SET wal_keep_size = '1024';   -- 保留 1GB WAL，防止槽位断开后 WAL 被清理
ALTER SYSTEM SET max_logical_replication_workers = 8;
ALTER SYSTEM SET max_sync_workers_per_subscription = 4;
```

重启 PostgreSQL 后验证：

```sql
SHOW wal_level;              -- 必须 = logical
SHOW max_replication_slots;  -- 必须 >= 1
```

### 1.3 赋予 litellm 用户 REPLICATION 权限

```sql
-- 检查当前用户权限
\du litellm

-- 赋予 REPLICATION 权限（需要超级用户执行）
ALTER USER litellm WITH REPLICATION;
ALTER USER litellm WITH SUPERUSER;

-- 验证
SELECT rolname, rolreplication, rolsuper FROM pg_roles WHERE rolname = 'litellm';
```

### 1.4 创建永久性复制槽 + Publication

```sql
-- 创建 Publication（全库所有表，或指定具体表）
-- 方案 A：全库所有表同步
CREATE PUBLICATION pg_litellm_pub FOR ALL TABLES;

-- 方案 B：仅同步指定表（按需选择）
-- CREATE PUBLICATION pg_litellm_pub FOR TABLE public."LiteLLM_SpendLogs";

-- 创建永久性复制槽（pgoutput 是 PG 10+ 内置插件，无需额外安装）
SELECT pg_create_logical_replication_slot('pg_litellm_slot', 'pgoutput');

-- 所有需要同步的表必须设置 REPLICA IDENTITY FULL（确保 DELETE 和 UPDATE 能捕获完整旧值）
-- 全库设置方式：
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE 'ALTER TABLE public."' || r.tablename || '" REPLICA IDENTITY FULL';
    END LOOP;
END $$;

-- 验证
SELECT * FROM pg_publication_tables WHERE pubname = 'pg_litellm_pub';
SELECT slot_name, plugin, database, active, restart_lsn 
FROM pg_replication_slots 
WHERE slot_name = 'pg_litellm_slot';
```

### 1.5 检查插件是否安装（pgoutput 是内置的无需检查，wal2json 可选）

```sql
-- pgoutput 是 PG 10+ 内置，无需额外安装
-- 如果坚持使用 wal2json，检查是否安装：
SELECT * FROM pg_available_extensions WHERE name = 'wal2json';

-- 如果未安装 wal2json（需要操作系统层面安装）：
-- apt-get install postgresql-16-wal2json  （Debian/Ubuntu）
-- yum install wal2json16                   （CentOS/RHEL）
-- 安装后在 PG 中：
-- CREATE EXTENSION IF NOT EXISTS wal2json;
```

> **生产建议**：使用 `pgoutput`（PG 内置、稳定、无需额外维护），本文档基于 `pgoutput`。

---

## 步骤 2：生产级 `postgres-source.json`

```json
{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "debezium-pg",

  "comment.transforms": "===== SMT 转换链：Reroute 统一主题 → Unwrap 展平 → 时间转换 =====",
  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": "(.*)",
  "kafka.transforms.Reroute.topic.replacement": "debezium-pg",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
  "kafka.transforms.Unwrap.add.headers": "op,source.db,source.table",
  "kafka.transforms.Unwrap.drop.tombstones": "false",

  "comment.snapshot": "===== Snapshot：initial 模式首次全量，后续增量 =====",
  "snapshot.mode": "initial",
  "snapshot.fetch.size": "10240",
  "snapshot.lock.timeout.ms": "30000",
  "snapshot.max.threads": "4",

  "comment.debezium": "===== Debezium 核心参数 =====",
  "database.server.name": "pg_litellm",
  "database.port": "5432",
  "database.hostname": "10.0.1.2",
  "database.user": "litellm",
  "database.dbname": "litellm",
  "database.password": "model-gateway-pg-pass",
  "database.connectionTimeZone": "UTC",
  "database.sslmode": "disable",
  "plugin.name": "pgoutput",
  "publication.name": "pg_litellm_pub",
  "slot.name": "pg_litellm_slot",
  "database.history.skip.unparseable.ddl": true,
  "database.history.store.only.captured.tables.ddl": true,

  "comment.whitelist": "===== 全表同步：不设 table.whitelist 或用通配 =====",
  "table.include.list": "public\\..*",

  "comment.time": "===== 时间精度：connect 模式，秒级 epoch =====",
  "time.precision.mode": "connect",

  "comment.heartbeat": "===== 心跳与超时（防止复制槽断连） =====",
  "heartbeat.interval.ms": "10000",
  "heartbeat.action.query": "SELECT 1",
  "poll.interval.ms": "1000",
  "connect.keep.alive.ms": "30000",
  "database.initial.statements": "SET statement_timeout = '60000'",

  "comment.retry": "===== 错误重试 =====",
  "errors.retry.delay.max.ms": "60000",
  "errors.retry.timeout": "-1",
  "errors.log.enable": "true",
  "errors.log.include.messages": "true",
  "errors.tolerance": "none",

  "comment.batch": "===== 批量拉取 =====",
  "max.batch.size": "4096",
  "max.queue.size": "8192",
  "offset.flush.interval.ms": "30000",
  "offset.flush.timeout.ms": "10000",

  "comment.converter": "===== 序列化 =====",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```

---

## 步骤 3：生产级 postgres-sink.json（MySQL 写入）

```json
{
  "connector.class": "org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector",
  "max.task": "2",
  "connect.topicnames": "debezium-pg",
  "task.group.id": "debezium-pg-group",

  "comment.connection": "===== MySQL 连接（10.0.2.6:3306） =====",
  "connection.url": "jdbc:mysql://10.0.2.6:3306/litellm?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai&nullCatalogMeansCurrent=true&useSSL=false&allowPublicKeyRetrieval=true&rewriteBatchedStatements=true&cachePrepStmts=true&prepStmtCacheSize=256&prepStmtCacheSqlLimit=2048",
  "connection.user": "root",
  "connection.password": "Xiaomai001!",

  "comment.pk": "===== 主键策略：从 Record Key 中提取（Debezium 自动设置） =====",
  "pk.mode": "record_key",
  "pk.fields": "id",

  "comment.insert": "===== UPSERT 模式：INSERT 冲突时 UPDATE（幂等写入） =====",
  "insert.mode": "UPSERT",
  "delete.enabled": "true",

  "comment.table": "===== 表名从 Header 中自动获取（支持多表同步） =====",
  "table.name.from.header": "true",
  "table.types": "TABLE",
  "auto.create": "true",
  "auto.evolve": "true",

  "comment.db": "===== 时区与类型映射 =====",
  "db.timezone": "UTC",

  "comment.batch": "===== 批量写入（性能优化） =====",
  "batch.size": "2000",
  "max.retries": "10",
  "retry.backoff.ms": "3000",

  "comment.error": "===== 容错：死信队列 + 错误日志 =====",
  "errors.deadletterqueue.topic.name": "dlq-debezium-pg",
  "errors.deadletterqueue.context.headers.enable": "true",
  "errors.log.enable": "true",
  "errors.log.include.messages": "true",
  "errors.tolerance": "ALL",
  "errors.retry.delay.max.ms": "60000",
  "errors.retry.timeout": "-1",

  "comment.converter": "===== 序列化 =====",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```

> **注意**：MySQL 密码 `Xiaomai001!` 来自你工作区已有的 postgres-sink.json 配置。如果实际不同，替换 `connection.password` 和 `connection.url` 中的库名。

---

## 步骤 4：43.167.164.225 部署命令（按顺序）

### 4.1 SSH 登录部署机

```bash
ssh root@43.167.164.225
```

### 4.2 创建配置目录并上传配置文件

```bash
# 创建配置目录
mkdir -p /opt/rocketmq-connect-config

# 在本地（非 225）上传配置文件
# scp postgres-source.json root@43.167.164.225:/opt/rocketmq-connect-config/
# scp postgres-sink.json  root@43.167.164.225:/opt/rocketmq-connect-config/
```

### 4.3 进入 Connect 运行目录

```bash
# 假设 RocketMQ Connect 安装在以下路径（根据实际情况调整）
cd /root/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT
```

### 4.4 创建 RocketMQ Topic

```bash
# 先确认 NameServer 可达
curl -s http://127.0.0.1:9876/ 2>&1 || echo "NameServer 需要先启动"

# 创建 Topic（在 RocketMQ 安装目录执行）
cd /root/rocketmq-5.3.2
export NAMESRV_ADDR=127.0.0.1:9876
sh bin/mqadmin updatetopic -n 127.0.0.1:9876 -t debezium-pg -c DefaultCluster

# 创建 DLQ Topic
sh bin/mqadmin updatetopic -n 127.0.0.1:9876 -t dlq-debezium-pg -c DefaultCluster
```

### 4.5 检查 Connect 服务状态

```bash
# 确认 Connect REST API 可访问
curl -s http://127.0.0.1:8082/connectors/list
# 期望: {"status":200,"body":{}}
```

### 4.6 启动 PostgreSQL Source Connector

```bash
curl -s -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-source \
  -d @/opt/rocketmq-connect-config/postgres-source.json | python3 -m json.tool
```

### 4.7 等待 Source 就绪后启动 Sink Connector

```bash
# 等待 10 秒让 Source 完成初始化和 snapshot
sleep 10

# 检查 Source 状态
curl -s http://127.0.0.1:8082/connectors/postgres-source/status | python3 -m json.tool

# 启动 MySQL Sink Connector
curl -s -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-sink \
  -d @/opt/rocketmq-connect-config/postgres-sink.json | python3 -m json.tool
```

### 4.8 查看所有 Connector 状态

```bash
# 列表
curl -s http://127.0.0.1:8082/connectors/list | python3 -m json.tool

# Source 状态
curl -s http://127.0.0.1:8082/connectors/postgres-source/status | python3 -m json.tool

# Sink 状态
curl -s http://127.0.0.1:8082/connectors/postgres-sink/status | python3 -m json.tool
```

期望输出：

```json
{
  "status": {
    "connector": { "state": "RUNNING", "worker_id": "...", "trace": null },
    "tasks": [ { "state": "RUNNING", "id": 0, "trace": null } ]
  }
}
```

### 4.9 查看实时日志

```bash
# Connect 主日志
tail -f /root/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT/connect-nohup.log

# 或者如果是 systemd 管理
journalctl -u rocketmq-connect -f

# 搜索关键日志
grep -E 'ERROR|WARN|RUNNING|FAILED' connect-nohup.log | tail -50
```

### 4.10 重启 / 停止命令

```bash
# 停止 Source
curl -s http://127.0.0.1:8082/connectors/postgres-source/stop

# 停止 Sink
curl -s http://127.0.0.1:8082/connectors/postgres-sink/stop

# 重启 Source（先停止，再创建覆盖）
curl -s http://127.0.0.1:8082/connectors/postgres-source/stop
sleep 3
curl -s -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-source \
  -d @/opt/rocketmq-connect-config/postgres-source.json

# 重启 Sink
curl -s http://127.0.0.1:8082/connectors/postgres-sink/stop
sleep 3
curl -s -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-sink \
  -d @/opt/rocketmq-connect-config/postgres-sink.json

# 删除 Connector（彻底清理）
curl -s -X DELETE http://127.0.0.1:8082/connectors/postgres-source
```

---

## 步骤 5：生产高可用优化

### 5.1 connect-standalone.conf 生产配置

```properties
# ==================== Worker 配置 ====================
workerId=prod-worker-01
storePathRootDir=/data/connect-store

# ==================== REST API ====================
httpPort=8082

# ==================== RocketMQ 连接 ====================
namesrvAddr=127.0.0.1:9876
clusterName=DefaultCluster

# ==================== ACL ====================
aclEnable=false

# ==================== 插件目录 ====================
pluginPaths=/usr/local/connector-plugins

# ==================== Offset 持久化 ====================
offset.flush.interval.ms=10000
offset.flush.timeout.ms=5000

# ==================== 连接池配置 ====================
rest.advertised.host.name=43.167.164.225
rest.advertised.port=8082

# ==================== 任务恢复 ====================
task.shutdown.graceful.timeout.ms=30000
```

### 5.2 JVM 内存配置（生产级）

在 Connect 启动脚本中设置：

```bash
# 编辑启动命令或创建启动脚本
cat > /opt/rocketmq-connect/start-connect.sh << 'EOF'
#!/bin/bash

ROCKETMQ_CONNECT_HOME=/root/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT

cd $ROCKETMQ_CONNECT_HOME

# 生产级 JVM 配置
export JAVA_OPT_EXT="-server \
  -Xms2g -Xmx4g -Xmn1g \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:InitiatingHeapOccupancyPercent=45 \
  -XX:G1ReservePercent=10 \
  -XX:+ParallelRefProcEnabled \
  -XX:+DisableExplicitGC \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/data/connect-store/heapdump.hprof \
  -Duser.timezone=Asia/Shanghai \
  -Dfile.encoding=UTF-8"

mkdir -p /data/connect-store

nohup sh bin/connect-standalone.sh -c conf/connect-standalone.conf > connect-nohup.log 2>&1 &
echo "Connect PID: $!"
EOF

chmod +x /opt/rocketmq-connect/start-connect.sh
```

### 5.3 RocketMQ Consumer 限流配置

Sink 作为 RocketMQ Consumer，在 Broker 端控制消费速率：

```bash
cd /root/rocketmq-5.3.2
export NAMESRV_ADDR=127.0.0.1:9876

# 设置消费组参数
sh bin/mqadmin updateSubGroup -n 127.0.0.1:9876 \
  -g debezium-pg-group \
  -c DefaultCluster \
  --consumeEnableBroadcast false \
  --consumeMessageOrderly false \
  --maxRetryTimes 16 \
  --retryQueueNums 1
```

### 5.4 开机自启（Systemd）

```bash
cat > /etc/systemd/system/rocketmq-connect.service << 'EOF'
[Unit]
Description=RocketMQ Connect Standalone
After=network.target
Wants=network.target

[Service]
Type=forking
User=root
Group=root
WorkingDirectory=/root/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="JAVA_OPT_EXT=-server -Xms2g -Xmx4g -Xmn1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/data/connect-store/heapdump.hprof"
ExecStart=/bin/sh bin/connect-standalone.sh -c conf/connect-standalone.conf
ExecStop=/bin/kill -SIGTERM $MAINPID
Restart=on-failure
RestartSec=30
LimitNOFILE=65536
LimitNPROC=32768
StandardOutput=append:/var/log/rocketmq-connect/connect.log
StandardError=append:/var/log/rocketmq-connect/connect-error.log

[Install]
WantedBy=multi-user.target
EOF

# 创建日志目录
mkdir -p /var/log/rocketmq-connect

# 启用并启动
systemctl daemon-reload
systemctl enable rocketmq-connect
systemctl start rocketmq-connect
systemctl status rocketmq-connect
```

### 5.5 Connector 自动恢复脚本

```bash
cat > /opt/rocketmq-connect/auto-restore-connectors.sh << 'EOF'
#!/bin/bash
# Connector 自动恢复脚本 — 加入 crontab，每分钟检查

REST_URL="http://127.0.0.1:8082"
CONFIG_DIR="/opt/rocketmq-connect-config"
LOG_FILE="/var/log/rocketmq-connect/connector-monitor.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

check_and_restore() {
    local name=$1
    local config_file=$2
    
    status=$(curl -s "${REST_URL}/connectors/${name}/status" 2>/dev/null)
    
    if echo "$status" | grep -q '"state":"RUNNING"'; then
        return 0
    fi
    
    log "WARN: ${name} 非 RUNNING，尝试恢复..."
    
    # 先停止再创建
    curl -s "${REST_URL}/connectors/${name}/stop" > /dev/null 2>&1
    sleep 2
    curl -s -X POST -H "Content-Type: application/json" \
         "${REST_URL}/connectors/${name}" \
         -d @"${CONFIG_DIR}/${config_file}" > /dev/null 2>&1
    sleep 5
    
    new_status=$(curl -s "${REST_URL}/connectors/${name}/status" 2>/dev/null)
    if echo "$new_status" | grep -q '"state":"RUNNING"'; then
        log "OK: ${name} 已恢复 RUNNING"
    else
        log "ERROR: ${name} 恢复失败！状态: ${new_status}"
    fi
}

check_and_restore "postgres-source" "postgres-source.json"
check_and_restore "postgres-sink" "postgres-sink.json"
EOF

chmod +x /opt/rocketmq-connect/auto-restore-connectors.sh

# 添加 crontab（每分钟检查）
echo "* * * * * /opt/rocketmq-connect/auto-restore-connectors.sh" | crontab -
```

---

## 步骤 6：生产故障排查手册

### 6.1 任务启动失败

| 现象 | 诊断命令 | 解决方案 |
|------|---------|---------|
| `http_code=000` | `ss -lntp \| grep 8082` | Connect 未启动，查看 `connect-nohup.log` |
| `HTTP 500 / 404` | `curl -v http://127.0.0.1:8082/connectors/list` | REST API 路径错误，确认用 `/connectors/list` |
| `ClassNotFoundException` | `ls /usr/local/connector-plugins/` | 插件未复制到 `pluginPaths`，检查 jar 是否存在 |
| `No suitable driver` | `ls /usr/local/connector-plugins/rocketmq-connect-jdbc/mysql-connector*` | MySQL JDBC 驱动缺失 |

**快速诊断脚本**：

```bash
#!/bin/bash
echo "=== 1. 端口检查 ==="
ss -lntp | grep -E '9876|10911|8082' || echo "有端口未监听！"

echo "=== 2. Connect 进程 ==="
ps -ef | grep connect-standalone | grep -v grep || echo "Connect 进程不存在！"

echo "=== 3. Connector 状态 ==="
curl -s http://127.0.0.1:8082/connectors/list 2>/dev/null || echo "REST API 不通！"

echo "=== 4. 最近错误日志 ==="
grep -i 'error\|exception\|failed' connect-nohup.log 2>/dev/null | tail -20
```

### 6.2 PostgreSQL CDC 无法连接

```bash
# 1. 网络连通性测试（在 43.167.164.225 上）
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/10.0.1.2/5432' && echo "PG 5432 端口可达" || echo "PG 5432 端口不可达！"

# 2. 用 psql 测试连接
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable" -c "SELECT 1;"

# 3. 检查 PG 端配置
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable" << 'SQL'
SHOW wal_level;
SHOW max_replication_slots;
SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
SELECT * FROM pg_publication_tables WHERE pubname = 'pg_litellm_pub';
SELECT count(*) AS table_count FROM pg_publication_tables WHERE pubname = 'pg_litellm_pub';
SQL

# 4. 检查 pg_hba.conf 是否允许复制连接
# 确保 pg_hba.conf 包含：
# host    replication    litellm    43.167.164.225/32    md5
```

### 6.3 MySQL 写入失败

```bash
# 1. MySQL 连通性（在 43.167.164.225 上）
mysql -h 10.0.2.6 -P 3306 -uroot -p'Xiaomai001!' -e "SELECT 1;"

# 2. 检查 MySQL 目标库是否存在
mysql -h 10.0.2.6 -P 3306 -uroot -p'Xiaomai001!' -e "SHOW DATABASES LIKE 'litellm';"

# 3. 如果库不存在，创建
mysql -h 10.0.2.6 -P 3306 -uroot -p'Xiaomai001!' -e "CREATE DATABASE IF NOT EXISTS litellm DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 4. 检查 MySQL 配置
mysql -h 10.0.2.6 -P 3306 -uroot -p'Xiaomai001!' -e "
SELECT VERSION();
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'max_allowed_packet';
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW VARIABLES LIKE 'sql_mode';
"

# 5. 查看 Sink 错误
curl -s http://127.0.0.1:8082/connectors/postgres-sink/status | python3 -m json.tool
# 重点看 trace 字段

# 6. 查看死信队列消息
# （需要消费 dlq-debezium-pg topic 查看失败消息）
```

**常见 MySQL 写入错误**：

| 错误信息 | 原因 | 解决 |
|---------|------|------|
| `Table doesn't exist` | 目标表不存在 | 设置 `auto.create: true` 或手动建表 |
| `Data too long for column` | 字段长度不匹配 | PG TEXT → MySQL TEXT 对齐，或调整 `auto.evolve: true` |
| `Duplicate entry for key` | UPSERT 主键冲突 | 检查 `pk.mode: record_key` 且 PK 正确 |
| `Connection refused` | MySQL 端口/防火墙 | 检查安全组，`10.0.2.6:3306` 是否对 `43.167.164.225` 放行 |
| `Packet too large` | `max_allowed_packet` 太小 | MySQL 端设置 `SET GLOBAL max_allowed_packet=256M` |

### 6.4 数据延迟 / 消息堆积

```bash
# 1. 查看 Topic 消费堆积（在 RocketMQ 安装目录）
cd /root/rocketmq-5.3.2
export NAMESRV_ADDR=127.0.0.1:9876

sh bin/mqadmin consumerProgress -n 127.0.0.1:9876 -g debezium-pg-group

# 2. 查看 Topic 消息量
sh bin/mqadmin statsAll -n 127.0.0.1:9876

# 3. PG 端检查复制槽 lag
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable" << 'SQL'
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 AS lag_mb
FROM pg_replication_slots 
WHERE slot_name = 'pg_litellm_slot';
SQL

# 4. 如果堆积严重，临时调大 Sink 并发
# 停止 Sink
curl -s http://127.0.0.1:8082/connectors/postgres-sink/stop
# 修改 postgres-sink.json 中 max.task 为更大的值（如 4）
# 重新创建 Sink
```

### 6.5 复制槽异常

```bash
# 1. 检查复制槽状态
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable" << 'SQL'
SELECT 
    slot_name,
    plugin,
    slot_type,
    database,
    active,
    active_pid,
    xmin,
    catalog_xmin,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots;
SQL

# 2. 槽位 inactive 超过预期 → Connect 没有正常消费
#    检查 Connect 日志，重启 Source Connector

# 3. 槽位 lag 持续增长 → 消费速度跟不上
#    增大 Connect JVM、增加 Sink 并发

# 4. 槽位丢失（WAL 被清理）→ 重建
#    先停止 Source，删除旧槽位，重建
SELECT pg_drop_replication_slot('pg_litellm_slot');
SELECT pg_create_logical_replication_slot('pg_litellm_slot', 'pgoutput');
```

### 6.6 日志快速定位

```bash
# Connect 主日志
CONNECT_LOG="/root/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT/connect-nohup.log"

# 最近错误（含时间戳）
grep -i -E 'ERROR|Exception|FAILED|FATAL' $CONNECT_LOG | tail -30

# 搜索关键字
grep -i 'slot' $CONNECT_LOG | tail -20          # 复制槽相关
grep -i 'connection.*refused' $CONNECT_LOG       # 连接失败
grep -i 'timeout' $CONNECT_LOG | tail -20        # 超时
grep -i 'dead.letter' $CONNECT_LOG | tail -10    # 死信队列

# 按时间范围查看（如最近 1 小时）
awk -v now="$(date +%s)" '
  /^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    gsub(/[-:]/," ",$1" "$2); 
    t=mktime($1); 
    if (now-t < 3600) print
  }
' $CONNECT_LOG

# RocketMQ 日志
tail -50 ~/logs/rocketmqlogs/namesrv.log    # NameServer
tail -50 ~/logs/rocketmqlogs/proxy.log      # Broker/Proxy
tail -50 ~/logs/rocketmqlogs/broker.log     # Broker
```

---

## 附录：关键参数速查表

| 参数 | 值 | 说明 |
|------|-----|------|
| PG 地址 | `10.0.1.2:5432` | CDC 源端 |
| PG 用户/密码 | `litellm` / `model-gateway-pg-pass` | |
| PG 库名 | `litellm` | |
| MySQL 地址 | `10.0.2.6:3306` | 同步目标 |
| RocketMQ NS | `127.0.0.1:9876` | |
| Topic | `debezium-pg` | 固定 |
| 消费组 | `debezium-pg-group` | |
| Source Connector | `DebeziumPostgresConnector` | pgoutput |
| Sink Connector | `JdbcSinkConnector` | JDBC → MySQL |
| Connect REST | `http://127.0.0.1:8082` | |
| 部署机 | `43.167.164.225` | |

---

> **文档版本**：基于 2026-05-26 生产环境定制，所有 IP、账号、密码、Topic 均为你的固定参数，可直接复制执行。