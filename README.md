# PostgreSQL CDC → RocketMQ Connect → MySQL 数据同步

> **架构**：PostgreSQL（CDC Source）→ RocketMQ Connect（Debezium + JDBC）→ MySQL（Sink）  
> **部署**：全 Docker Compose 容器化，一键启动，无需本地安装任何组件  
> **验证**：全量快照 + 增量 INSERT/UPDATE/DELETE 均已通过测试

---

## 目录

- [1. 项目介绍](#1-项目介绍)
- [2. 环境要求](#2-环境要求)
- [3. 快速开始](#3-快速开始)
- [4. 架构与组件](#4-架构与组件)
- [5. PostgreSQL 配置](#5-postgresql-配置)
- [6. MySQL 配置](#6-mysql-配置)
- [7. RocketMQ 配置](#7-rocketmq-配置)
- [8. 创建 Connector](#8-创建-connector)
- [9. 数据同步验证](#9-数据同步验证)
- [10. 常用管理命令](#10-常用管理命令)
- [11. 常见问题排查](#11-常见问题排查)
- [12. RocketMQ Broker 端口说明](#12-rocketmq-broker-端口说明)
- [附录：关键配置速查](#附录关键配置速查)

---

## 1. 项目介绍

本项目实现 PostgreSQL 到 MySQL 的实时 CDC 数据同步，基于 Apache RocketMQ Connect 作为中间消息通道。

**数据流向**：

```
PostgreSQL (orders 表)
    │ INSERT / UPDATE / DELETE
    ▼
Debezium PG Connector (捕获 WAL 变更)
    │ ConnectRecord
    ▼
RocketMQ Topic (debezium-pg-source)
    │ 消息消费
    ▼
JDBC Sink Connector (UPSERT 写入)
    │
    ▼
MySQL (orders 表)
```

**核心特性**：

- 🐳 全 Docker Compose 部署，一键启动 6 个容器
- 📦 无需本地安装 PostgreSQL / MySQL / RocketMQ
- 🔄 支持全量快照 + 增量实时同步
- ✅ 支持 INSERT、UPDATE、DELETE 操作
- 🛡️ 错误容忍配置，单条失败不影响整体

---

## 2. 环境要求

| 软件 | 最低版本 | 说明 |
|------|---------|------|
| Docker | 20.10+ | 需支持 Docker Compose v2 |
| Git | 2.x | 克隆项目（需编译 Connect 镜像时） |
| JDK 17 + Maven 3.8+ | — | 仅编译阶段需要，运行时不需要 |
| 内存 | ≥ 8 GB | RocketMQ Broker 默认占用较大 |
| 磁盘 | ≥ 10 GB | 含 Docker 镜像存储 |

> **中国大陆用户**：如果 Docker Hub 访问慢，请在 Docker Desktop 设置中配置镜像加速器（如 `https://docker.m.daocloud.io`）。

---

## 3. 快速开始

### 3.1 克隆项目

```bash
git clone <your-repo-url> rocketmq-connect-cdc
cd rocketmq-connect-cdc
```

### 3.2 构建 Connect 镜像（仅首次，约 10 分钟）

```bash
docker compose build rmq-connect
```

### 3.3 启动全部服务

```bash
docker compose up -d
```

等待约 60 秒，确认所有容器运行：

```bash
docker compose ps
```

期望输出：

```
NAME           STATUS
rmq-namesrv    Up (healthy)
rmq-broker     Up
rmq-proxy      Up
pg-source      Up (healthy)
mysql-target   Up (healthy)
rmq-connect    Up
```

### 3.4 验证初始化表结构

```bash
# PG 源表（应有 3 条初始数据）
docker exec pg-source psql -U source_user -d source_db -c "SELECT order_id, product_name FROM public.orders ORDER BY order_id"

# MySQL 目标表（应为空，created_at/updated_at 是 BIGINT）
docker exec mysql-target mysql -uroot -proot_pass -e "DESC target_db.orders; SELECT COUNT(*) FROM target_db.orders"

### 3.5 创建 PG Publication + Replication Slot

```bash
docker exec pg-source psql -U source_user -d source_db -c "CREATE PUBLICATION pg_orders_pub FOR TABLE public.orders" -c "SELECT pg_create_logical_replication_slot('pg_orders_slot', 'pgoutput')"
```

### 3.6 创建 RocketMQ Topic

```bash
docker exec rmq-broker sh -c "
/home/rocketmq/rocketmq-5.3.2/bin/mqadmin updatetopic \
  -n rmq-namesrv:9876 \
  -t debezium-pg-source \
  -c DefaultCluster
"
```

### 3.7 创建 Connector

```bash
# Source Connector（CDC 采集）
curl.exe -s -X POST -H "Content-Type: application/json" \
  -d @connectors/pg-src-prod.json \
  http://localhost:8082/connectors/pg-source

# 等待 Source 连上 PG（复制槽激活）
sleep 15

# Sink Connector（写入 MySQL）
curl.exe -s -X POST -H "Content-Type: application/json" \
  -d @connectors/mysql-sink-prod.json \
  http://localhost:8082/connectors/mysql-sink
```

### 3.8 验证同步

```bash
# 等待全量快照完成（约 30 秒）
sleep 30

# PG 源表
docker exec pg-source psql -U source_user -d source_db -c "SELECT order_id, product_name FROM public.orders ORDER BY order_id"

# MySQL 目标表（应与 PG 一致）
docker exec mysql-target mysql -uroot -proot_pass -e "SELECT order_id, product_name FROM target_db.orders ORDER BY order_id"

```

期望 MySQL 输出：

```
order_id  product_name
1001      Apple iPhone 15
1002      MacBook Pro 14
1003      AirPods Pro
```

---

## 4. 架构与组件

### 4.1 容器拓扑

```
┌──────────────────────────────────────────────────────┐
│              Docker Network: cdc-net                  │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │ rmq-namesrv  │  │ rmq-proxy    │  │ rmq-broker │ │
│  │   :9876      │  │ :8080,:8081  │  │   :10911   │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                │         │
│         └────────┬────────┴────────────────┘         │
│                  │                                    │
│          ┌───────┴────────┐                          │
│          │  rmq-connect   │                          │
│          │    :8082        │                          │
│          │  Debezium PG    │                          │
│          │  JDBC Sink      │                          │
│          └───┬─────────┬──┘                          │
│              │ CDC      │ JDBC                        │
│              ▼          ▼                             │
│  ┌──────────────┐  ┌──────────────┐                  │
│  │  pg-source   │  │ mysql-target │                  │
│  │   :5432      │  │   :3306      │                  │
│  │  source_db   │  │  target_db   │                  │
│  │  orders 表   │  │  orders 表    │                  │
│  └──────────────┘  └──────────────┘                  │
└──────────────────────────────────────────────────────┘
```

### 4.2 端口规划

| 容器 | 内部端口 | 宿主机端口 | 用途 |
|------|---------|-----------|------|
| `rmq-namesrv` | 9876 | 9876 | RocketMQ 路由注册 |
| `rmq-broker` | 10911 | 10911 | RocketMQ 消息存储 |
| `rmq-proxy` | 8080,8081 | 8080,8081 | RocketMQ gRPC 代理 |
| `pg-source` | 5432 | 15432 | PostgreSQL CDC 源 |
| `mysql-target` | 3306 | 13306 | MySQL 同步目标 |
| `rmq-connect` | 8082 | 8082 | Connect REST API |

### 4.3 账号密码

| 服务 | 用户名 | 密码 | 数据库 |
|------|--------|------|--------|
| PostgreSQL | `source_user` | `source_pass` | `source_db` |
| MySQL | `root` | `root_pass` | `target_db` |

---

## 5. PostgreSQL 配置

### 5.1 启动参数

`docker-compose.yml` 中 PG 容器已配置：

```yaml
command: >
  -c wal_level=logical
  -c max_wal_senders=10
  -c max_replication_slots=4
  -c wal_sender_timeout=60s
```

### 5.2 初始化脚本（`pg-init/init.sql`）

容器首次启动自动执行，创建源表并插入测试数据：

```sql
CREATE TABLE IF NOT EXISTS public.orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    TIMESTAMP     NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP     NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id)
);

-- REPLICA IDENTITY FULL：确保 DELETE 操作能被 Debezium 捕获
ALTER TABLE public.orders REPLICA IDENTITY FULL;

-- 初始测试数据（全量快照会同步到 MySQL）
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at) VALUES
(1001, 'Apple iPhone 15',  2, 6999.00, 'pending',   now(), now()),
(1002, 'MacBook Pro 14',   1, 14999.00, 'shipped',  now(), now()),
(1003, 'AirPods Pro',      3, 1999.00,  'delivered', now(), now());
```

### 5.3 创建 Publication 和 Replication Slot

> 容器启动后手动执行（以下命令在宿主机终端运行）：

```bash
# 创建 Publication
docker exec pg-source psql -U source_user -d source_db -c \
  "CREATE PUBLICATION pg_orders_pub FOR TABLE public.orders"

# 创建逻辑复制槽
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT pg_create_logical_replication_slot('pg_orders_slot', 'pgoutput')"

# 验证
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT * FROM pg_publication_tables WHERE pubname = 'pg_orders_pub'"

docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT slot_name, active FROM pg_replication_slots WHERE slot_name = 'pg_orders_slot'"
```

### 5.4 PG 直接访问（可选）

```bash
# 通过宿主机端口连接
psql -h localhost -p 15432 -U source_user -d source_db

# 或进入容器
docker exec -it pg-source psql -U source_user -d source_db
```

---

## 6. MySQL 配置

### 6.1 初始化脚本（`mysql-init/init.sql`）

> ⚠️ **重要**：时间字段必须使用 `BIGINT` 而非 `DATETIME`。  
> Debezium 将 PG 的 `TIMESTAMP` 输出为 epoch 微秒整数（如 `1779516189760795`），MySQL `DATETIME` 无法直接接受此格式。

```sql
CREATE TABLE IF NOT EXISTS orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    BIGINT        NOT NULL DEFAULT 0,
    updated_at    BIGINT        NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

> **时间戳查询方法**：MySQL 中可用 `FROM_UNIXTIME(created_at / 1000000)` 将 epoch 微秒转为可读时间。

### 6.2 验证目标表

```bash
docker exec mysql-target mysql -uroot -proot_pass -e "DESC target_db.orders"
docker exec mysql-target mysql -uroot -proot_pass -e "SELECT COUNT(*) FROM target_db.orders"
# 期望: COUNT(*) = 0（同步前为空）
```

### 6.3 MySQL 直接访问（可选）

```bash
# 通过宿主机端口连接
mysql -h 127.0.0.1 -P 13306 -uroot -proot_pass target_db

# 或进入容器
docker exec -it mysql-target mysql -uroot -proot_pass target_db
```

---

## 7. RocketMQ 配置

### 7.1 容器说明

| 容器 | 镜像 | 说明 |
|------|------|------|
| `rmq-namesrv` | `apache/rocketmq:5.3.2` | NameServer，路由注册中心 |
| `rmq-broker` | `apache/rocketmq:5.3.2` | Broker，消息存储与分发 |
| `rmq-proxy` | `apache/rocketmq:5.3.2` | gRPC Proxy（5.x 新增） |

### 7.2 创建 Topic

> 见 [3.6 创建 RocketMQ Topic](#36-创建-rocketmq-topic)，命令相同。

### 7.3 Topic 管理命令

```bash
# 查看所有 Topic
docker exec rmq-broker sh -c "
/home/rocketmq/rocketmq-5.3.2/bin/mqadmin topicList -n rmq-namesrv:9876
"

# 查看 Topic 详情
docker exec rmq-broker sh -c "
/home/rocketmq/rocketmq-5.3.2/bin/mqadmin topicStatus \
  -n rmq-namesrv:9876 -t debezium-pg-source
"

# 删除 Topic（谨慎）
docker exec rmq-broker sh -c "
/home/rocketmq/rocketmq-5.3.2/bin/mqadmin deleteTopic \
  -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster
"
```

---

## 8. 创建 Connector

### 8.1 Source Connector（Debezium PG → RocketMQ）

配置文件：`connectors/pg-src-prod.json`

```json
{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "debezium-pg-source",

  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": "(.*)",
  "kafka.transforms.Reroute.topic.replacement": "debezium-pg-source",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
  "kafka.transforms.Unwrap.add.headers": "op,source.db,source.table",

  "database.history.skip.unparseable.ddl": true,
  "database.server.name": "pgserver",
  "database.port": "5432",
  "database.hostname": "pg-source",
  "database.connectionTimeZone": "UTC",
  "database.user": "source_user",
  "database.dbname": "source_db",
  "database.password": "source_pass",

  "plugin.name": "pgoutput",
  "publication.name": "pg_orders_pub",
  "slot.name": "pg_orders_slot",

  "table.whitelist": "public.orders",

  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```

**关键配置说明**：

| 配置 | 说明 |
|------|------|
| `kafka.transforms: Reroute,Unwrap` | **必须**同时使用两个 Transform |
| `Reroute` | 将 Debezium 默认 Topic（含 `.`）重路由到合法 Topic 名 |
| `Unwrap` | 将 Debezium 复杂消息体展平为简单行数据 |
| `add.headers` | 添加 `source.table` 等 Header，供 Sink 提取表名 |

> ⚠️ **不要设置 `time.precision.mode`**：使用默认值即可。`connect` 模式与 JsonConverter 不兼容。

---

### 8.2 Sink Connector（RocketMQ → JDBC MySQL）

配置文件：`connectors/mysql-sink-prod.json`

```json
{
  "connector.class": "org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector",
  "max.task": "1",
  "connect.topicnames": "debezium-pg-source",

  "connection.url": "jdbc:mysql://mysql-target:3306/target_db?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai&nullCatalogMeansCurrent=true",
  "connection.user": "root",
  "connection.password": "root_pass",

  "pk.fields": "order_id",
  "pk.mode": "record_key",
  "insert.mode": "UPSERT",
  "delete.enabled": "true",

  "table.name.from.header": "true",
  "db.timezone": "UTC",
  "table.types": "TABLE",

  "errors.deadletterqueue.topic.name": "dlq-topic",
  "errors.log.enable": "true",
  "errors.tolerance": "ALL",

  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```

**关键配置说明**：

| 配置 | 说明 |
|------|------|
| `connector.class` | ⚠️ 必须是 `jdbc.sink.JdbcSinkConnector`，不是 `jdbc.connector.JdbcSinkConnector` |
| `table.name.from.header: true` | 从消息 Header（`source.table`）提取目标表名 |
| `insert.mode: UPSERT` | INSERT 或 UPDATE（主键冲突时更新） |
| `pk.mode: record_key` | 主键从 Debezium 消息 Key 中提取 |
| `errors.tolerance: ALL` | 单条失败不中断同步 |
| `nullCatalogMeansCurrent: true` | JDBC URL 参数，使用当前数据库作为 Catalog |

> ⚠️ **不要使用 `table.name.format`**：RocketMQ Connect 的 JDBC Connector 忽略此配置，表名只能从 Header 或 Topic 名推导。

---

### 8.3 创建命令

```bash
# Source
curl.exe -s -X POST -H "Content-Type: application/json" \
  -d @connectors/pg-src-prod.json \
  http://localhost:8082/connectors/pg-source

# 等待 Source 连上 PG（复制槽激活）
sleep 15
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT slot_name, active FROM pg_replication_slots"
# 期望: active = t

# Sink
curl.exe -s -X POST -H "Content-Type: application/json" \
  -d @connectors/mysql-sink-prod.json \
  http://localhost:8082/connectors/mysql-sink
```

### 8.4 查看 Connector 状态

```bash
# 列出所有 Connector
curl.exe -s http://localhost:8082/connectors/list

# Source 状态
curl.exe -s http://localhost:8082/connectors/pg-source/status

# Sink 状态
curl.exe -s http://localhost:8082/connectors/mysql-sink/status
```

期望：`connector.state = "RUNNING"`，`tasks[].state = "RUNNING"`，`trace = null`。

---

## 9. 数据同步验证

### 9.1 全量快照验证

> 见 [3.8 验证同步](#38-验证同步)，命令相同。

### 9.2 INSERT 增量测试

```bash
docker exec pg-source psql -U source_user -d source_db -c "
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at)
VALUES (2001, 'Sony WH-1000XM5', 1, 2499.00, 'pending', now(), now())
"

sleep 5

docker exec mysql-target mysql -uroot -proot_pass -e \
  "SELECT * FROM target_db.orders WHERE order_id = 2001"
# 期望: 返回 1 行
```

### 9.3 UPDATE 增量测试

```bash
docker exec pg-source psql -U source_user -d source_db -c "
UPDATE public.orders SET status = 'shipped', updated_at = now() WHERE order_id = 2001
"

sleep 5

docker exec mysql-target mysql -uroot -proot_pass -e \
  "SELECT order_id, status FROM target_db.orders WHERE order_id = 2001"
# 期望: status = 'shipped'
```

### 9.4 DELETE 增量测试

```bash
docker exec pg-source psql -U source_user -d source_db -c "
DELETE FROM public.orders WHERE order_id = 2001
"

sleep 5

docker exec mysql-target mysql -uroot -proot_pass -e \
  "SELECT * FROM target_db.orders WHERE order_id = 2001"
# 期望: Empty set
```

---

## 10. 常用管理命令

### 10.1 服务管理

```bash
# 启动所有服务
docker compose up -d

# 停止所有服务（保留数据）
docker compose stop

# 重启所有服务
docker compose restart

# 重启单个服务
docker compose restart rmq-connect

# 停止并删除所有数据（完全清理）
docker compose down -v
```

### 10.2 日志查看

```bash
# 查看所有容器日志（实时跟踪）
docker compose logs -f

# 查看 Connect 日志
docker compose logs rmq-connect --tail 100

# 查看 Connect 运行时日志（非 GC 日志）
docker exec rmq-connect sh -c \
  "tail -50 /root/logs/rocketmqconnect/connect_runtime.log"

# 查看 Connect 业务日志
docker exec rmq-connect sh -c \
  "tail -50 /root/logs/rocketmqconnect/connect_default.log"

# 查看 PG 日志
docker compose logs pg-source --tail 50

# 查看 RocketMQ Broker 日志
docker compose logs rmq-broker --tail 50
```

### 10.3 Connector 管理

```bash
# 停止 Connector
curl.exe -s http://localhost:8082/connectors/pg-source/stop
curl.exe -s http://localhost:8082/connectors/mysql-sink/stop

# 更新配置（先 stop，再 POST 同名 Connector 覆盖）
curl.exe -s -X POST -H "Content-Type: application/json" \
  -d @connectors/pg-src-prod.json \
  http://localhost:8082/connectors/pg-source
```

### 10.4 PG 复制槽监控

```bash
docker exec pg-source psql -U source_user -d source_db -c "
SELECT
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'pg_orders_slot'
"
```

| active | lag | 状态 |
|--------|-----|------|
| `t` | 稳定 | ✅ 正常 |
| `f` | — | Connect 未连接 |
| `t` | 持续增大 | 消费跟不上 |

### 10.5 容器内调试

```bash
# 进入 Connect 容器
docker exec -it rmq-connect bash

# 进入 PG 容器
docker exec -it pg-source bash

# 测试容器间网络
docker exec rmq-connect ping pg-source
docker exec rmq-connect ping mysql-target
docker exec rmq-connect ping rmq-namesrv
```

---

## 11. 常见问题排查

### 11.1 PG 复制槽未激活（`active = f`）

**现象**：Source Connector 显示 RUNNING，但 PG 复制槽 `active = f`

**排查**：

```bash
# 检查 Connector 是否只有一个（多个 Source 抢 slot）
curl.exe -s http://localhost:8082/connectors/list

# 查看 Source task 是否有报错
curl.exe -s http://localhost:8082/connectors/pg-source/status
```

**解决**：重启 Connect 容器，重建 Connector：

```bash
docker compose restart rmq-connect
sleep 30
# 重新 POST Connector（见 8.3 节）
```

### 11.2 MySQL 无数据（全量快照失败）

**现象**：Source 和 Sink 都 RUNNING，但 MySQL 无数据

**排查步骤**：

```bash
# 1. 确认 Sink task 无报错
curl.exe -s http://localhost:8082/connectors/mysql-sink/status
# 查看 trace 字段

# 2. 查看 Connect 业务日志
docker exec rmq-connect sh -c \
  "grep -i 'error\|exception\|JdbcWriter\|table.*missing' \
  /root/logs/rocketmqconnect/connect_default.log | tail -20"
```

**常见错误**：

| 错误 | 原因 | 解决 |
|------|------|------|
| `Table "...Value" is missing` | JDBC 从 Topic 名推导了错误的表名 | Sink 必须设置 `table.name.from.header: true` |
| `Data truncation: Incorrect datetime value` | PG TIMESTAMP 被转为 epoch 微秒整数 | MySQL 时间字段改用 `BIGINT`（见 6.1 节） |
| `NullPointerException: fqn is null` | 旧消息缺少 `source.table` Header | 重启 Connect + 重建 Sink Connector |
| `Invalid Java object for schema type INT64` | 错误使用了 `time.precision.mode=connect` | 去掉此配置 |

### 11.3 Source Connector 创建失败

**现象**：POST Source 返回错误或 Task 状态 FAILED

**排查**：

```bash
# 检查 PG 连通性
docker exec rmq-connect sh -c "nc -zv pg-source 5432"

# 检查 Publication 和 Slot 是否存在
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT * FROM pg_publication_tables"
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT slot_name FROM pg_replication_slots"
```

**常见错误**：

| 错误 | 解决 |
|------|------|
| `Connection refused` | 等待 PG 健康检查通过 |
| `publication does not exist` | 执行 5.3 节创建 Publication |
| `replication slot does not exist` | 执行 5.3 节创建 Slot |
| `topic contains illegal characters` | 确认使用了 `Reroute` Transform |
| `JdbcSinkConnector not found` | 类名改为 `jdbc.sink.JdbcSinkConnector` |

### 11.4 Topic 无消息

**现象**：PG 有数据变更，但 MySQL 不同步

**排查**：

```bash
# 确认复制槽活跃
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT slot_name, active FROM pg_replication_slots"

# 确认 Source Connector 正在发送消息（查看日志）
docker exec rmq-connect sh -c \
  "grep 'Successful send message' /root/logs/rocketmqconnect/connect_default.log | tail -5"
```

### 11.5 Connect 容器反复重启

**现象**：`docker ps` 显示 `rmq-connect` 状态为 `Restarting`

**解决**：

```bash
# 查看启动失败原因
docker compose logs rmq-connect --tail 50

# 常见原因：JVM 内存不足
# 解决：修改 docker-compose.yml 中 JAVA_OPT，降低 -Xmx
```

### 11.6 完全重置链路

```bash
# 1. 停止 Connector
curl.exe -s http://localhost:8082/connectors/pg-source/stop
curl.exe -s http://localhost:8082/connectors/mysql-sink/stop

# 2. 停止所有服务并清理数据卷
docker compose down -v

# 3. 重新启动
docker compose up -d

# 4. 重新执行 3.5 → 3.8 节
```

---

## 附录：关键配置速查

### Connector JSON 文件位置

| 文件 | 路径 |
|------|------|
| Source 配置 | `connectors/pg-src-prod.json` |
| Sink 配置 | `connectors/mysql-sink-prod.json` |

### 核心可复制命令

```bash
# ===== 一键检查状态 =====
echo "=== 容器 ===" && docker compose ps
echo "=== Connector ===" && curl.exe -s http://localhost:8082/connectors/list
echo "=== PG Slot ===" && docker exec pg-source psql -U source_user -d source_db -c "SELECT slot_name, active FROM pg_replication_slots"
echo "=== PG 行数 ===" && docker exec pg-source psql -U source_user -d source_db -t -c "SELECT COUNT(*) FROM public.orders"
echo "=== MySQL 行数 ===" && docker exec mysql-target mysql -uroot -proot_pass target_db -sN -e "SELECT COUNT(*) FROM orders"
```

### 账号密码速查

| 组件 | 地址 | 用户名 | 密码 |
|------|------|--------|------|
| PG | `localhost:15432` | `source_user` | `source_pass` |
| MySQL | `localhost:13306` | `root` | `root_pass` |
| Connect API | `http://localhost:8082` | — | — |
| RocketMQ NS | `localhost:9876` | — | — |

### 容器间访问地址

| 从 | 到 | 地址 |
|----|-----|------|
| rmq-connect | PostgreSQL | `pg-source:5432` |
| rmq-connect | MySQL | `mysql-target:3306` |
| rmq-connect | RocketMQ NS | `rmq-namesrv:9876` |

---

> **文档版本**：v2.0  
> **最后更新**：2026-05-23  
> **验证状态**：✅ 全量快照 + INSERT + UPDATE + DELETE 全部通过  
> **参考**：[Apache RocketMQ Connect 实战2](https://rocketmq.apache.org/zh/docs/connect/05RocketMQ%20Connect%20In%20Action2/)

---

## 12. RocketMQ Broker 端口说明

### 12.1 端口总览

| 端口 | 名称 | 用途 | 单机是否需要 |
|------|------|------|:---:|
| `10911` | 核心通信端口 | Producer/Consumer 直连，消息收发、心跳、路由 | ✅ 必须 |
| `10909` | VIP Channel 端口 | 消费者重试消息专用通道，分流重试流量，减轻 10911 压力 | ✅ 推荐 |
| `10912` | HA 同步端口 | 主从 Broker 之间数据同步（Master ↔ Slave） | ❌ 单机不需要 |

### 12.2 各端口详细说明

**10911 — 核心通信端口**

```
Producer ──► 10911 ──► Broker 接收消息、存储、分发
Consumer ◄── 10911 ◄── Broker 推送消息、心跳、Offset
```

- RocketMQ 最重要的端口，所有消息收发都经过此端口
- NameServer 返回给客户端的就是 Broker 的 10911 地址

**10909 — VIP Channel（特权通道）**

```
Consumer 重试消息 ──► 10909 ──► 独立线程池处理
普通消费消息     ──► 10911 ──► 正常线程池处理
```

- 消费失败的消息需要反复重试，走独立通道避免阻塞正常消息
- RocketMQ 5.x 中 Connect 通过 Proxy（8080/8081）通信，不直连 Broker 10909

**10912 — HA 同步端口**

```
Master Broker ◄── 10912 ──► Slave Broker（数据同步/心跳）
```

- 仅主从部署时使用，Master 通过 10912 将消息实时同步给 Slave
- 单 Broker 部署无需映射此端口

### 12.3 docker-compose.yml 配置

```yaml
rmq-broker:
  ports:
    - "10911:10911"   # 核心通信，必须
    - "10909:10909"   # VIP 通道，推荐
    - "10912:10912"   # HA 同步，单机可省略
```

### 12.4 本项目的端口映射

```yaml
rmq-broker:
  ports:
    - "10911:10911"
    - "10909:10909"
    # 未映射 10912：单 Broker 无主从，不需要
```

### 12.5 注意事项

- ⚠️ **不要混淆 10909 和 10911**：客户端业务代码连 10911，不是 10909
- ⚠️ **安全组/防火墙**：只对外开放 10911 即可，10909/10912 保持内网访问
- 📌 **CDC 架构中**：RocketMQ Connect 通过 NameServer（9876）发现 Broker，不手工指定 Broker 端口
- 📌 **推荐阅读**：[RocketMQ 官方 Docker Compose 部署](https://rocketmq.apache.org/zh/docs/quickStart/03quickstartWithDockercompose)
