# PostgreSQL → MySQL 数据同步运维手册（RocketMQ Connect）

> 场景：将 K8s 中 LiteLLM 的 `LiteLLM_SpendLogs` 表从 PostgreSQL 同步到远端 MySQL。  
> 架构：PG（CDC）→ RocketMQ Connect → MySQL。

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│ 43.167.165.174（VM-2-8-tencentos）                              │
│  • RocketMQ 5.3.2（NameServer 9876 + Broker 10911 + Proxy 8081）│
│  • RocketMQ Connect（REST 8082）                                │
│  • Topic: debezium-pg-to-mysql                                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │ JDBC
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ 43.167.192.211                                                  │
│  • Docker: mysql:latest                                         │
│  • 库: litellm  表: LiteLLM_SpendLogs                           │
└─────────────────────────────────────────────────────────────────┘

                            ▲ CDC（Debezium）
                            │
┌─────────────────────────────────────────────────────────────────┐
│ 10.0.1.2:5432（K8s Pod: agent-pilot-postgres-0）                │
│  • 库: litellm  表: public."LiteLLM_SpendLogs"                   │
│  • wal_level=logical  publication: pg_litellm_pub                 │
│  • slot: pg_litellm_slot                                        │
└─────────────────────────────────────────────────────────────────┘
```

| 组件 | 地址 / 说明 |
|------|-------------|
| PostgreSQL | `10.0.1.2:5432`，库 `litellm`，用户 `litellm` |
| RocketMQ | 本机 `127.0.0.1:9876` 或内网 `10.0.2.8:9876` |
| Connect REST | `http://127.0.0.1:8082` |
| MySQL | `43.167.192.211:3306`，库 `litellm`，用户 `root` |
| 同步表 | 仅 `public.LiteLLM_SpendLogs` |

---

## 2. 前置条件

### 2.1 174 机器（RocketMQ + Connect）

| 软件 | 版本建议 |
|------|----------|
| JDK | 64 位，8+（实际使用 17） |
| Maven | 3.8+（编译 Connect 插件时需要） |
| Git | 克隆 rocketmq-connect |

### 2.2 192.211 机器（MySQL）

| 软件 | 说明 |
|------|------|
| Docker | 已安装 `mysql:latest` 镜像 |

### 2.3 PostgreSQL（K8s）

| 项 | 要求 |
|----|------|
| `wal_level` | **logical**（改后需重启 Pod） |
| 用户 `litellm` | Superuser + Replication（本次已满足） |
| 网络 | 174 能访问 `10.0.1.2:5432` |

### 2.4 安全组 / 防火墙

| 路径 | 端口 |
|------|------|
| 174 → 10.0.1.2 | 5432 |
| 174 → 192.211 | 3306 |
| 本机 | 9876、10911、8082 |

---

## 3. 安装 RocketMQ 5.3.2（174）

### 3.1 下载与目录

```bash
# 解压 rocketmq-all-5.3.2-bin-release 到例如：
cd /root/rocketmq-5.3.2
```

### 3.2 启动 NameServer（小内存）

```bash
cd /root/rocketmq-5.3.2

unset JAVA_OPT
export JAVA_OPT_EXT="-server -Xms256m -Xmx256m -Xmn128m"

nohup sh bin/mqnamesrv &
sleep 5
tail -20 ~/logs/rocketmqlogs/namesrv.log
# 期望: The Name Server boot success...
```

### 3.3 启动 Broker + Proxy（5.x 官方推荐）

```bash
export JAVA_OPT_EXT="-server -Xms512m -Xmx512m -Xmn256m"

nohup sh bin/mqbroker -n 127.0.0.1:9876 --enable-proxy &
sleep 10
tail -30 ~/logs/rocketmqlogs/proxy.log
# 期望: boot success...
```

### 3.4 验证

```bash
ps -ef | grep -E 'mqnamesrv|mqbroker' | grep -v grep
ss -lntp | grep -E '9876|10911'
```

> **注意**：`runserver.sh` / `runbroker.sh` 会在你设置的 `JAVA_OPT` 后再追加默认 4g/8g，必须用 **`JAVA_OPT_EXT` 放在最后覆盖**，否则 OOM。

---

## 4. 编译并安装 Connect 插件（174）

### 4.1 克隆与编译 Runtime

```bash
git clone https://github.com/apache/rocketmq-connect.git
cd rocketmq-connect
mvn -Prelease-connect -Dmaven.test.skip=true clean install -U
```

运行目录：

```bash
cd distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT
```

### 4.2 Debezium PostgreSQL 插件

```bash
cd rocketmq-connect/connectors/rocketmq-connect-debezium/rocketmq-connect-debezium-postgresql
mvn clean package -Dmaven.test.skip=true

mkdir -p /usr/local/connector-plugins
cp target/rocketmq-connect-debezium-postgresql-*-jar-with-dependencies.jar \
   /usr/local/connector-plugins/
```

### 4.3 JDBC 插件（目录包，非单 jar）

```bash
cd ../rocketmq-connect-jdbc
mvn clean package -Dmaven.test.skip=true

cd target
tar -zxvf rocketmq-connect-jdbc-*-package.tar.gz
cp -r share/java/rocketmq-connect-jdbc /usr/local/connector-plugins/
```

确认：

```bash
ls /usr/local/connector-plugins/rocketmq-connect-jdbc/mysql-connector-java*.jar
```

### 4.4 配置 `conf/connect-standalone.conf`

```properties
workerId=standalone-worker
storePathRootDir=/data/connect-store

httpPort=8082
namesrvAddr=127.0.0.1:9876

aclEnable=false
clusterName=DefaultCluster

pluginPaths=/usr/local/connector-plugins
```

### 4.5 启动 Connect

```bash
mkdir -p /data/connect-store

unset JAVA_OPT
export JAVA_OPT_EXT="-server -Xms256m -Xmx512m -Xmn128m"

nohup sh bin/connect-standalone.sh -c conf/connect-standalone.conf > connect-nohup.log 2>&1 &
sleep 25

ss -lntp | grep 8082
curl -s http://127.0.0.1:8082/connectors/list
# 期望: {"status":200,"body":{}} 或已有连接器
tail -30 connect-nohup.log
# 期望: The standalone worker boot success.
```

---

## 5. PostgreSQL 准备（10.0.1.2）

### 5.1 连接串

```bash
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable"
```

### 5.2 开启逻辑复制（K8s 自建 PG）

在 Pod 内用 `litellm` 超级用户：

```sql
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 4;
```

重启 StatefulSet Pod `agent-pilot-postgres-0` 后验证：

```sql
SHOW wal_level;  -- logical
```

### 5.3 Publication + Replication Slot

```sql
CREATE PUBLICATION pg_litellm_pub FOR TABLE public."LiteLLM_SpendLogs";

SELECT pg_create_logical_replication_slot('pg_litellm_slot', 'pgoutput');

ALTER TABLE public."LiteLLM_SpendLogs" REPLICA IDENTITY FULL;

-- 验证
SELECT * FROM pg_publication_tables WHERE pubname = 'pg_litellm_pub';
SELECT slot_name, plugin, active FROM pg_replication_slots;
```

### 5.4 连通性（在 174 上）

```bash
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/10.0.1.2/5432' && echo OK
```

---

## 6. MySQL 准备（192.211）

### 6.1 启动容器

```bash
docker run -d \
  --name mysql-litellm \
  --restart unless-stopped \
  -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=12345678 \
  -e MYSQL_DATABASE=litellm \
  -e TZ=Asia/Shanghai \
  -v mysql-litellm-data:/var/lib/mysql \
  mysql:latest \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci \
  --default-time-zone=+08:00
```

### 6.2 创建目标表

在 192.211 或从 174 用 mysql 客户端执行（结构需与 PG 对齐，主键 `request_id`）。  
建表 SQL 见本文档附录 A。

### 6.3 允许远程连接（174 访问）

```sql
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '12345678';
GRANT ALL PRIVILEGES ON litellm.* TO 'root'@'%';
FLUSH PRIVILEGES;
```

安全组：仅放行 **174 的 IP → 3306**。

### 6.4 连通性（在 174 上）

```bash
mysql -h 43.167.192.211 -P 3306 -uroot -p12345678 -e "SELECT 1;"
```

---

## 7. 创建 RocketMQ Topic

Debezium 默认 Topic 名含 `.`（非法），需统一为 `debezium-pg-to-mysql`：

```bash
cd /root/rocketmq-5.3.2
export NAMESRV_ADDR=127.0.0.1:9876
sh bin/mqadmin updatetopic -n 127.0.0.1:9876 -t debezium-pg-to-mysql -c DefaultCluster
```

---

## 8. 创建 Connector

> **RocketMQ Connect REST 与 Kafka Connect 不同**：  
> - 列表：`GET /connectors/list`（不是 `GET /connectors`）  
> - 创建：`POST /connectors/{连接器名称}`（名称在 URL 里）

### 8.1 PostgreSQL Source

```bash
curl -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-source \
  -d '{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "debezium-pg-to-mysql",
  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": ".*",
  "kafka.transforms.Reroute.topic.replacement": "debezium-pg-to-mysql",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.add.headers": "op,source.db,source.table",
  "database.server.name": "pg_litellm",
  "database.port": "5432",
  "database.hostname": "10.0.1.2",
  "database.connectionTimeZone": "UTC",
  "database.user": "litellm",
  "database.dbname": "litellm",
  "database.password": "model-gateway-pg-pass",
  "plugin.name": "pgoutput",
  "publication.name": "pg_litellm_pub",
  "slot.name": "pg_litellm_slot",
  "table.whitelist": "public.LiteLLM_SpendLogs",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}'
```

### 8.2 MySQL Sink

> **类名注意**：本环境为 `jdbc.sink`，不是文档里的 `jdbc.connector`。

```bash
curl -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/mysql-sink \
  -d '{
  "connector.class": "org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector",
  "max.task": "1",
  "connect.topicnames": "debezium-pg-to-mysql",
  "connection.url": "jdbc:mysql://43.167.192.211:3306/litellm?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai&nullCatalogMeansCurrent=true",
  "connection.user": "root",
  "connection.password": "12345678",
  "pk.fields": "request_id",
  "pk.mode": "record_key",
  "insert.mode": "UPSERT",
  "delete.enabled": "true",
  "table.name.from.header": "true",
  "db.timezone": "UTC",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}'
```

### 8.3 检查状态

```bash
curl -s http://127.0.0.1:8082/connectors/list
curl -s http://127.0.0.1:8082/connectors/postgres-source/status
curl -s http://127.0.0.1:8082/connectors/mysql-sink/status
```

期望：`connector` 与 `tasks` 均为 **`RUNNING`**，`trace` 为 `null`。

### 8.4 验证数据

```bash
# PG 行数
psql "postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable" \
  -c 'SELECT COUNT(*) FROM public."LiteLLM_SpendLogs";'

# MySQL 行数
mysql -h 43.167.192.211 -P 3306 -uroot -p12345678 litellm \
  -e "SELECT COUNT(*) FROM LiteLLM_SpendLogs;"
```

---

## 9. 日常运维

### 9.1 常用 REST 命令

| 操作 | 命令 |
|------|------|
| 列表 | `curl -s http://127.0.0.1:8082/connectors/list` |
| Source 状态 | `curl -s http://127.0.0.1:8082/connectors/postgres-source/status` |
| Sink 状态 | `curl -s http://127.0.0.1:8082/connectors/mysql-sink/status` |
| 查看配置 | `curl -s http://127.0.0.1:8082/connectors/postgres-source/config` |
| 停止 | `curl -s http://127.0.0.1:8082/connectors/postgres-source/stop` |

更新配置：再次 `POST` 同名连接器（覆盖配置），必要时先 `stop`。

### 9.2 174 重启后启动顺序

```bash
# 1. RocketMQ NameServer
cd /root/rocketmq-5.3.2
export JAVA_OPT_EXT="-server -Xms256m -Xmx256m -Xmn128m"
nohup sh bin/mqnamesrv &

# 2. Broker
export JAVA_OPT_EXT="-server -Xms512m -Xmx512m -Xmn256m"
nohup sh bin/mqbroker -n 127.0.0.1:9876 --enable-proxy &

# 3. Connect
cd /root/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT
export JAVA_OPT_EXT="-server -Xms256m -Xmx512m -Xmn128m"
nohup sh bin/connect-standalone.sh -c conf/connect-standalone.conf > connect-nohup.log 2>&1 &

# 4. 若 /data/connect-store 无持久化配置，需重新 POST 两个 Connector
```

### 9.3 PG 复制槽监控

```sql
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'pg_litellm_slot';
```

- `active = f` 且 Connect 未运行：正常  
- Connect **RUNNING** 时应为 `active = t`  
- lag 持续增大：消费跟不上，检查 Connect / 网络

### 9.4 增量同步抽检

在 PG 插入或更新后，稍等数秒查 MySQL 同一 `request_id`。

### 9.5 停止整条链路

```bash
curl -s http://127.0.0.1:8082/connectors/postgres-source/stop
curl -s http://127.0.0.1:8082/connectors/mysql-sink/stop

# 可选：删除 slot（确认不再需要 CDC）
# SELECT pg_drop_replication_slot('pg_litellm_slot');
```

---

## 10. 故障排查

| 现象 | 原因 | 处理 |
|------|------|------|
| `http_code=000` | Connect 未启动 | 看 `connect-nohup.log`，调小 JVM |
| `Exit 127` | 目录错 / 无 java | 进正确发行目录，设 `JAVA_HOME` |
| `GET /connectors` 404 | API 路径不对 | 用 `/connectors/list` |
| Topic 含 `.` 报错 | RocketMQ 不允许 | `ByLogicalTableRouter` + 预建 Topic |
| `JdbcSinkConnector` 找不到 | 类名错误 | 用 `jdbc.sink.JdbcSinkConnector` |
| Source FAILED 连不上 PG | IP/安全组/slot | 测 `10.0.1.2:5432`，查 publication |
| MySQL 无数据 | Sink 未 RUNNING | 查 `mysql-sink/status` trace |
| PG `wal_level=replica` | 未开 logical | `ALTER SYSTEM` + 重启 Pod |
| slot `active=f` 长期 | Connect 未消费 | 启动 postgres-source |

日志位置：

| 组件 | 日志 |
|------|------|
| RocketMQ NS | `~/logs/rocketmqlogs/namesrv.log` |
| RocketMQ Broker | `~/logs/rocketmqlogs/proxy.log` |
| Connect | `connect-nohup.log` |

---

## 11. PG 地址变更 checklist

1. 174 能连新 IP：`psql ... -h 新IP`  
2. `wal_level=logical`、publication、slot 仍在  
3. `POST /connectors/postgres-source`，改 `database.hostname`  
4. 无需改 Sink（除非 MySQL 也变）

---

## 附录 A：MySQL 建表 SQL（LiteLLM_SpendLogs）

```sql
CREATE TABLE IF NOT EXISTS `LiteLLM_SpendLogs` (
  `request_id` VARCHAR(255) NOT NULL,
  `call_type` VARCHAR(255) NOT NULL,
  `api_key` TEXT NOT NULL,
  `spend` DOUBLE NOT NULL DEFAULT 0,
  `total_tokens` INT NOT NULL DEFAULT 0,
  `prompt_tokens` INT NOT NULL DEFAULT 0,
  `completion_tokens` INT NOT NULL DEFAULT 0,
  `startTime` DATETIME(3) NOT NULL,
  `endTime` DATETIME(3) NOT NULL,
  `completionStartTime` DATETIME(3) NULL,
  `model` TEXT NOT NULL,
  `model_id` TEXT NULL,
  `model_group` TEXT NULL,
  `custom_llm_provider` TEXT NULL,
  `api_base` TEXT NULL,
  `user` TEXT NULL,
  `metadata` JSON NULL,
  `cache_hit` TEXT NULL,
  `cache_key` TEXT NULL,
  `request_tags` JSON NULL,
  `team_id` TEXT NULL,
  `end_user` TEXT NULL,
  `requester_ip_address` TEXT NULL,
  `messages` JSON NULL,
  `response` JSON NULL,
  `proxy_server_request` JSON NULL,
  `session_id` TEXT NULL,
  `status` TEXT NULL,
  `mcp_namespaced_tool_name` TEXT NULL,
  `organization_id` TEXT NULL,
  `agent_id` TEXT NULL,
  `request_duration_ms` INT NULL,
  PRIMARY KEY (`request_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## 附录 B：关键配置速查

| 配置项 | 值 |
|--------|-----|
| PG host | `10.0.1.2` |
| PG 表 | `public.LiteLLM_SpendLogs` |
| Topic | `debezium-pg-to-mysql` |
| MySQL JDBC | `jdbc:mysql://43.167.192.211:3306/litellm?...` |
| Source 类 | `...debezium.postgres.DebeziumPostgresConnector` |
| Sink 类 | `...jdbc.sink.JdbcSinkConnector` |
| Connect REST | `http://127.0.0.1:8082` |

---

## 附录 C：密码与生产建议

- 文档中的密码仅作示例，生产请轮换并改用 Secret 管理。  
- 不要将 MySQL `3306` 对公网 `0.0.0.0/0` 开放。  
- 长期运行建议：Connect 与 RocketMQ 分机或升配内存；监控 PG WAL 与磁盘。

---

*文档版本：基于 2026-05-22 实际部署整理*
