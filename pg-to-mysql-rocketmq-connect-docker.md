# PostgreSQL CDC → RocketMQ Connect → MySQL 数据同步实操文档（全 Docker 部署）

> **架构**：PostgreSQL（CDC Source）→ RocketMQ Connect（Debezium + JDBC）→ MySQL（Sink）  
> **特点**：全部组件 Docker 容器化部署，Docker Compose 统一编排，同一自定义网络互通，本地即可复现。  
> **参考**：[RocketMQ Connect 实战2 官方文档](https://rocketmq.apache.org/zh/docs/connect/05RocketMQ%20Connect%20In%20Action2/)

---

## 目录

- [1. 架构总览](#1-架构总览)
- [2. 组件版本与端口规划](#2-组件版本与端口规划)
- [3. 环境准备](#3-环境准备)
- [4. 项目目录结构](#4-项目目录结构)
- [5. Docker Compose 编排](#5-docker-compose-编排)
- [6. RocketMQ Connect 镜像构建](#6-rocketmq-connect-镜像构建)
- [7. 启动所有服务](#7-启动所有服务)
- [8. PostgreSQL CDC 配置](#8-postgresql-cdc-配置)
- [9. MySQL 目标库准备](#9-mysql-目标库准备)
- [10. 创建 RocketMQ Topic](#10-创建-rocketmq-topic)
- [11. 创建 Connector 连接器](#11-创建-connector-连接器)
- [12. 数据同步测试](#12-数据同步测试)
- [13. 日常运维命令](#13-日常运维命令)
- [14. 常见报错排查](#14-常见报错排查)
- [附录 A：关键配置速查](#附录-a关键配置速查)
- [附录 B：停止与清理](#附录-b停止与清理)

---

## 1. 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│                     Docker Network: cdc-net                   │
│                                                              │
│  ┌─────────────────┐   ┌──────────────────────────────┐     │
│  │ RocketMQ         │   │ RocketMQ Connect             │     │
│  │ • namesrv :9876  │◄──│ • REST API :8082             │     │
│  │ • broker  :10911 │   │ • Debezium PG Plugin          │     │
│  │ • proxy   :8081  │   │ • JDBC Plugin                 │     │
│  └─────────────────┘   └──────────┬───────────────────┘     │
│                                    │                          │
│                    ┌───────────────┼───────────────┐          │
│                    │ CDC (Debezium)│ JDBC Write    │          │
│                    ▼               │               ▼          │
│  ┌──────────────────────┐   ┌──────────────────────────┐    │
│  │ PostgreSQL :5432     │   │ MySQL :3306               │    │
│  │ • 库: source_db      │   │ • 库: target_db           │    │
│  │ • 表: orders         │   │ • 表: orders              │    │
│  │ • wal_level=logical  │   │                           │    │
│  └──────────────────────┘   └──────────────────────────┘    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**数据流向**：  
PostgreSQL `orders` 表发生 INSERT / UPDATE / DELETE → Debezium 捕获 WAL 变更 → 封装为 ConnectRecord → 发送到 RocketMQ Topic `debezium-pg-source` → JDBC Sink Connector 消费 → 写入 MySQL `orders` 表。

---

## 2. 组件版本与端口规划

| 组件 | 镜像 / 版本 | 容器名 | 内部端口 | 宿主机端口 | 说明 |
|------|------------|--------|---------|-----------|------|
| RocketMQ NameServer | `apache/rocketmq:5.3.2` | `rmq-namesrv` | 9876 | 9876 | 路由注册中心 |
| RocketMQ Broker | `apache/rocketmq:5.3.2` | `rmq-broker` | 10911, 10909 | 10911, 10909 | 消息存储与分发 |
| PostgreSQL | `postgres:16` | `pg-source` | 5432 | 15432 | CDC 数据源 |
| MySQL | `mysql:8.0` | `mysql-target` | 3306 | 13306 | 同步目标库 |
| RocketMQ Connect | 自定义构建 | `rmq-connect` | 8082 | 8082 | Connect 运行时 + 插件 |

> **注意**：宿主机端口映射避免与本地已运行服务冲突（如本地 PG 默认 5432、MySQL 默认 3306），这里映射为 `15432` / `13306`。

---

## 3. 环境准备

### 3.1 宿主机要求

| 软件 | 最低版本 | 说明 |
|------|---------|------|
| Docker | 20.10+ | 需支持 Docker Compose v2 |
| Git | 2.x | 克隆 rocketmq-connect 源码编译插件 |
| JDK | 17 | 编译 Connect 插件（只需编译阶段使用） |
| Maven | 3.8+ | 编译 Connect 插件（只需编译阶段使用） |
| curl | 任意 | 调用 Connect REST API |
| 内存 | ≥ 8 GB | RocketMQ Broker 默认占用较大 |

### 3.2 网络要求

所有容器通过自定义 Docker 网络 `cdc-net` 互通，容器间使用 **容器名** 作为主机名访问：

- PostgreSQL：`pg-source:5432`
- MySQL：`mysql-target:3306`
- RocketMQ NameServer：`rmq-namesrv:9876`
- RocketMQ Connect：`rmq-connect:8082`

---

## 4. 项目目录结构

在宿主机上创建如下目录结构：

```
~/rocketmq-connect-cdc/
├── docker-compose.yml          # 所有服务编排
├── connect/
│   ├── Dockerfile              # RocketMQ Connect 镜像构建
│   └── connect-standalone.conf # Connect 运行时配置
├── pg-init/
│   └── init.sql                # PostgreSQL 初始化建表脚本
├── mysql-init/
│   └── init.sql                # MySQL 初始化建表脚本
└── README.md                   # 本说明文档
```

创建目录：

```bash
mkdir -p ~/rocketmq-connect-cdc/{connect,pg-init,mysql-init}
cd ~/rocketmq-connect-cdc
```

---

## 5. Docker Compose 编排

### 5.1 `docker-compose.yml`

```yaml
version: "3.8"

services:
  # ==================== RocketMQ NameServer ====================
  rmq-namesrv:
    image: apache/rocketmq:5.3.2
    container_name: rmq-namesrv
    restart: unless-stopped
    networks:
      - cdc-net
    ports:
      - "9876:9876"
    environment:
      - JAVA_OPT_EXT=-server -Xms256m -Xmx256m -Xmn128m
    command: ["sh", "mqnamesrv"]
    volumes:
      - rmq-namesrv-logs:/home/rocketmq/logs

  # ==================== RocketMQ Broker ====================
  rmq-broker:
    image: apache/rocketmq:5.3.2
    container_name: rmq-broker
    restart: unless-stopped
    depends_on:
      - rmq-namesrv
    networks:
      - cdc-net
    ports:
      - "10911:10911"
      - "10909:10909"
    environment:
      - NAMESRV_ADDR=rmq-namesrv:9876
      - JAVA_OPT_EXT=-server -Xms512m -Xmx512m -Xmn256m
    command: ["sh", "mqbroker", "-n", "rmq-namesrv:9876", "--enable-proxy"]
    volumes:
      - rmq-broker-logs:/home/rocketmq/logs
      - rmq-broker-data:/home/rocketmq/store

  # ==================== PostgreSQL（CDC 数据源） ====================
  pg-source:
    image: postgres:16
    container_name: pg-source
    restart: unless-stopped
    networks:
      - cdc-net
    ports:
      - "15432:5432"
    environment:
      POSTGRES_USER: source_user
      POSTGRES_PASSWORD: source_pass
      POSTGRES_DB: source_db
    command: >
      -c wal_level=logical
      -c max_wal_senders=10
      -c max_replication_slots=4
      -c wal_sender_timeout=60s
    volumes:
      - pg-data:/var/lib/postgresql/data
      - ./pg-init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U source_user -d source_db"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ==================== MySQL（同步目标） ====================
  mysql-target:
    image: mysql:8.0
    container_name: mysql-target
    restart: unless-stopped
    networks:
      - cdc-net
    ports:
      - "13306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: root_pass
      MYSQL_DATABASE: target_db
      MYSQL_USER: target_user
      MYSQL_PASSWORD: target_pass
      TZ: Asia/Shanghai
    command: >
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --default-time-zone=+08:00
      --default-authentication-plugin=mysql_native_password
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-proot_pass"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ==================== RocketMQ Connect ====================
  rmq-connect:
    build:
      context: ./connect
      dockerfile: Dockerfile
    image: rmq-connect:custom
    container_name: rmq-connect
    restart: unless-stopped
    depends_on:
      rmq-namesrv:
        condition: service_started
      rmq-broker:
        condition: service_started
      pg-source:
        condition: service_healthy
      mysql-target:
        condition: service_healthy
    networks:
      - cdc-net
    ports:
      - "8082:8082"
    environment:
      - JAVA_OPT_EXT=-server -Xms512m -Xmx1024m -Xmn256m
    command: ["sh", "bin/connect-standalone.sh", "-c", "conf/connect-standalone.conf"]

# ==================== 网络 ====================
networks:
  cdc-net:
    name: cdc-net
    driver: bridge

# ==================== 持久化卷 ====================
volumes:
  rmq-namesrv-logs:
  rmq-broker-logs:
  rmq-broker-data:
  pg-data:
  mysql-data:
```

---

## 6. RocketMQ Connect 镜像构建

RocketMQ Connect 暂无官方预编译 Docker 镜像，需要自行构建。下面是 Dockerfile 和配置文件。

### 6.1 `connect/Dockerfile`

```dockerfile
# ============================================================
# 阶段1：编译 rocketmq-connect 及插件
# ============================================================
FROM maven:3.9-eclipse-temurin-17 AS builder

WORKDIR /build

# 克隆 rocketmq-connect 源码
RUN git clone --depth 1 -b master https://github.com/apache/rocketmq-connect.git .

# 编译 Connect Runtime（跳过测试）
RUN mvn -Prelease-connect -Dmaven.test.skip=true clean install -U -q

# 编译 Debezium PostgreSQL 插件
WORKDIR /build/connectors/rocketmq-connect-debezium/rocketmq-connect-debezium-postgresql
RUN mvn clean package -Dmaven.test.skip=true -q

# 编译 JDBC 插件
WORKDIR /build/connectors/rocketmq-connect-jdbc
RUN mvn clean package -Dmaven.test.skip=true -q

# ============================================================
# 阶段2：运行镜像
# ============================================================
FROM eclipse-temurin:17-jre

WORKDIR /opt/rocketmq-connect

# 创建插件目录
RUN mkdir -p /usr/local/connector-plugins

# 从构建阶段复制 Connect Runtime
COPY --from=builder /build/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT/ ./

# 复制 Debezium PostgreSQL 插件 jar
COPY --from=builder /build/connectors/rocketmq-connect-debezium/rocketmq-connect-debezium-postgresql/target/rocketmq-connect-debezium-postgresql-*-jar-with-dependencies.jar /usr/local/connector-plugins/

# 复制 JDBC 插件 jar
COPY --from=builder /build/connectors/rocketmq-connect-jdbc/target/rocketmq-connect-jdbc-*-jar-with-dependencies.jar /usr/local/connector-plugins/

# 复制配置文件
COPY connect-standalone.conf conf/connect-standalone.conf
```

### 6.2 `connect/connect-standalone.conf`

```properties
# ==================== Worker 配置 ====================
workerId=DockerWorker01
storePathRootDir=/tmp/connect-store

# ==================== REST API ====================
httpPort=8082

# ==================== RocketMQ 连接 ====================
namesrvAddr=rmq-namesrv:9876
clusterName=DefaultCluster

# ==================== ACL（关闭） ====================
aclEnable=false

# ==================== 插件目录（核心配置） ====================
pluginPaths=/usr/local/connector-plugins
```

---

## 7. 启动所有服务

### 7.1 构建并启动

```bash
cd ~/rocketmq-connect-cdc

# 构建 RocketMQ Connect 镜像（首次约 10-15 分钟）
docker compose build rmq-connect

# 启动全部服务（后台运行）
docker compose up -d
```

### 7.2 检查服务状态

```bash
# 查看容器运行状态
docker compose ps

# 期望输出：5 个容器均为 Up 状态
# NAME           STATUS
# rmq-namesrv    Up (healthy)
# rmq-broker     Up
# pg-source      Up (healthy)
# mysql-target   Up (healthy)
# rmq-connect    Up

# 查看 Connect 日志，确认启动成功
docker compose logs rmq-connect | tail -20
# 期望：The standalone worker boot success.
```

### 7.3 验证各组件连通性

```bash
# 验证 NameServer
docker exec rmq-namesrv sh -c "ss -lntp | grep 9876"

# 验证 Broker
docker exec rmq-broker sh -c "ss -lntp | grep 10911"

# 验证 Connect REST API
curl -s http://localhost:8082/connectors/list
# 期望: {"status":200,"body":{}}

# 验证 PostgreSQL
docker exec pg-source psql -U source_user -d source_db -c "SELECT 1;"

# 验证 MySQL
docker exec mysql-target mysql -uroot -proot_pass -e "SELECT 1;"
```

---

## 8. PostgreSQL CDC 配置

### 8.1 初始化源表（`pg-init/init.sql`）

```sql
-- 创建 schema 和源表
CREATE SCHEMA IF NOT EXISTS public;

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

-- ⚠️ 关键：设置 REPLICA IDENTITY FULL，确保 DELETE 操作能被捕获
ALTER TABLE public.orders REPLICA IDENTITY FULL;

-- 插入初始测试数据
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at) VALUES
(1001, 'Apple iPhone 15',    2, 6999.00, 'pending',   now(), now()),
(1002, 'MacBook Pro 14',     1, 14999.00, 'shipped',  now(), now()),
(1003, 'AirPods Pro',        3, 1999.00,  'delivered', now(), now());
```

### 8.2 创建 Publication 和 Replication Slot

> 容器启动后执行（`init.sql` 已建表，但 Publication/Slot 需单独创建）：

```bash
# 进入 PG 容器
docker exec -it pg-source psql -U source_user -d source_db
```

在 psql 中执行：

```sql
-- 确认 wal_level 为 logical
SHOW wal_level;
-- 期望: logical

-- 创建 Publication（发布 orders 表变更）
CREATE PUBLICATION pg_orders_pub FOR TABLE public.orders;

-- 创建逻辑复制槽
SELECT pg_create_logical_replication_slot('pg_orders_slot', 'pgoutput');

-- 验证
SELECT * FROM pg_publication_tables WHERE pubname = 'pg_orders_pub';
-- 期望: public | orders | pg_orders_pub

SELECT slot_name, plugin, active, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'pg_orders_slot';
-- 期望: pg_orders_slot | pgoutput | f | (lsn 值)

-- 验证初始数据
SELECT * FROM public.orders;
```

退出 psql：

```sql
\q
```

### 8.3 CDC 权限确认

```bash
# source_user 默认有 superuser 权限，验证 replication 权限
docker exec pg-source psql -U source_user -d source_db -c "
SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'source_user';
"
# 期望: source_user | t
```

---

## 9. MySQL 目标库准备

### 9.1 初始化目标表（`mysql-init/init.sql`）

```sql
-- 目标表结构（与 PG 源表对齐）
CREATE TABLE IF NOT EXISTS orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    DATETIME(3)   NOT NULL,
    updated_at    DATETIME(3)   NOT NULL,
    PRIMARY KEY (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

### 9.2 验证目标表

```bash
docker exec mysql-target mysql -uroot -proot_pass target_db -e "
DESC orders;
SELECT COUNT(*) AS row_count FROM orders;
"
# 期望: row_count = 0（初始为空，同步后应有数据）
```

---

## 10. 创建 RocketMQ Topic

> Debezium 消息会发送到同名 Topic，需提前创建。

```bash
# 进入 Broker 容器创建 Topic
docker exec rmq-broker sh -c "
export NAMESRV_ADDR=rmq-namesrv:9876 && \
sh ./bin/mqadmin updatetopic -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster
"

# 验证 Topic 是否创建成功
docker exec rmq-broker sh -c "
export NAMESRV_ADDR=rmq-namesrv:9876 && \
sh ./bin/mqadmin topicList -n rmq-namesrv:9876
" | grep debezium-pg-source
# 期望输出: debezium-pg-source
```

---

## 11. 创建 Connector 连接器

### 11.1 PostgreSQL Source Connector（CDC 捕获）

```bash
curl -X POST -H "Content-Type: application/json" \
  http://localhost:8082/connectors/pg-source-connector \
  -d '{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "debezium-pg-source",

  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": ".*",
  "kafka.transforms.Reroute.topic.replacement": "debezium-pg-source",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
  "kafka.transforms.Unwrap.add.headers": "op,source.db,source.table",

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
}'
```

### 11.2 MySQL Sink Connector（JDBC 写入）

```bash
curl -X POST -H "Content-Type: application/json" \
  http://localhost:8082/connectors/mysql-sink-connector \
  -d '{
  "connector.class": "org.apache.rocketmq.connect.jdbc.connector.JdbcSinkConnector",
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
}'
```

### 11.3 检查 Connector 状态

```bash
# 列出所有连接器
curl -s http://localhost:8082/connectors/list | python3 -m json.tool

# Source 状态
curl -s http://localhost:8082/connectors/pg-source-connector/status | python3 -m json.tool

# Sink 状态
curl -s http://localhost:8082/connectors/mysql-sink-connector/status | python3 -m json.tool
```

期望输出：

```json
{
    "status": 200,
    "body": {
        "connector": {
            "state": "RUNNING",
            "workerId": "DockerWorker01",
            "trace": null
        },
        "tasks": [
            {
                "state": "RUNNING",
                "id": "...",
                "workerId": "DockerWorker01",
                "trace": null
            }
        ]
    }
}
```

如果 `state` 不是 `RUNNING`，查看 `trace` 字段获取错误详情，或执行：

```bash
docker compose logs rmq-connect | grep -i -E 'error|exception|fail'
```

---

## 12. 数据同步测试

### 12.1 初始全量同步验证

```bash
# 查 PG 源表
docker exec pg-source psql -U source_user -d source_db -c "SELECT * FROM public.orders ORDER BY order_id;"

# 查 MySQL 目标表
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders ORDER BY order_id;"
```

**期望**：MySQL 中应出现与 PG 相同的 3 条数据（1001、1002、1003）。

### 12.2 INSERT 增量同步测试

```bash
# 在 PG 插入一条新数据
docker exec pg-source psql -U source_user -d source_db -c "
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at)
VALUES (2001, 'Sony WH-1000XM5', 1, 2499.00, 'pending', now(), now());
"

# 等待 3-5 秒后查 MySQL
sleep 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders WHERE order_id = 2001;"
# 期望: 返回 1 行数据
```

### 12.3 UPDATE 增量同步测试

```bash
# 在 PG 更新数据
docker exec pg-source psql -U source_user -d source_db -c "
UPDATE public.orders SET status = 'shipped', updated_at = now() WHERE order_id = 2001;
"

# 等待 3-5 秒后查 MySQL
sleep 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT order_id, status FROM orders WHERE order_id = 2001;"
# 期望: status = 'shipped'
```

### 12.4 DELETE 增量同步测试

```bash
# 在 PG 删除数据
docker exec pg-source psql -U source_user -d source_db -c "
DELETE FROM public.orders WHERE order_id = 2001;
"

# 等待 3-5 秒后查 MySQL
sleep 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders WHERE order_id = 2001;"
# 期望: Empty set（无数据）
```

### 12.5 批量行数对比

```bash
echo "=== PG 行数 ==="
docker exec pg-source psql -U source_user -d source_db -t -c "SELECT COUNT(*) FROM public.orders;"

echo "=== MySQL 行数 ==="
docker exec mysql-target mysql -uroot -proot_pass target_db -sN -e "SELECT COUNT(*) FROM orders;"
```

---

## 13. 日常运维命令

### 13.1 服务管理

```bash
# 启动全部服务
docker compose up -d

# 停止全部服务
docker compose stop

# 重启全部服务
docker compose restart

# 查看所有容器日志（实时）
docker compose logs -f

# 查看单个容器日志
docker compose logs -f rmq-connect
docker compose logs -f pg-source

# 进入容器
docker exec -it rmq-connect bash
docker exec -it pg-source psql -U source_user -d source_db
docker exec -it mysql-target mysql -uroot -proot_pass target_db
```

### 13.2 Connector 管理

```bash
# 列出所有 Connector
curl -s http://localhost:8082/connectors/list | python3 -m json.tool

# 查看 Connector 状态
curl -s http://localhost:8082/connectors/pg-source-connector/status | python3 -m json.tool
curl -s http://localhost:8082/connectors/mysql-sink-connector/status | python3 -m json.tool

# 查看 Connector 配置
curl -s http://localhost:8082/connectors/pg-source-connector/config | python3 -m json.tool
curl -s http://localhost:8082/connectors/mysql-sink-connector/config | python3 -m json.tool

# 停止 Connector
curl -s http://localhost:8082/connectors/pg-source-connector/stop
curl -s http://localhost:8082/connectors/mysql-sink-connector/stop

# 更新配置（先 stop 再 POST 同名连接器即可覆盖）
```

### 13.3 PostgreSQL 复制槽监控

```bash
docker exec pg-source psql -U source_user -d source_db -c "
SELECT
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'pg_orders_slot';
"
```

| 状态 | 说明 |
|------|------|
| `active = t` | Connect 正在消费，正常 |
| `active = f` | Connect 未运行或未连接 |
| `lag` 持续增大 | 消费速度跟不上产生速度，需排查 |

### 13.4 Topic 管理

```bash
# 查看所有 Topic
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && sh ./bin/mqadmin topicList -n rmq-namesrv:9876"

# 查看 Topic 详情
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && sh ./bin/mqadmin topicStatus -n rmq-namesrv:9876 -t debezium-pg-source"

# 删除 Topic（谨慎操作）
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && sh ./bin/mqadmin deleteTopic -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster"
```

---

## 14. 常见报错排查

### 14.1 Connect 启动失败

| 现象 | 原因 | 解决方案 |
|------|------|----------|
| `Exit 1` / OOM | JVM 内存不足 | 调大 Docker 内存，或减小 `JAVA_OPT_EXT` 中的 `-Xmx` |
| `The worker did not start` | `pluginPaths` 路径错误 | 检查容器内 `/usr/local/connector-plugins/` 是否有 jar |
| 连接 NameServer 超时 | 网络不通 | `docker exec rmq-connect ping rmq-namesrv` |

### 14.2 Source Connector FAILED

| 现象 | 原因 | 解决方案 |
|------|------|----------|
| `Connection refused` | PG 未就绪或网络不通 | `docker exec rmq-connect ping pg-source` |
| `FATAL: no pg_hba.conf entry` | PG 不允许远程连接 | 检查 `pg_hba.conf`，添加 `host all all 0.0.0.0/0 md5` |
| `publication does not exist` | 未创建 Publication | 执行第 8.2 节 SQL |
| `replication slot does not exist` | 未创建 Slot | 执行第 8.2 节 SQL |
| `wal_level is not logical` | PG 未开启逻辑复制 | 重启 PG 带 `-c wal_level=logical` |
| `REPLICA IDENTITY FULL` 未设置 | DELETE 无法捕获 | `ALTER TABLE public.orders REPLICA IDENTITY FULL;` |

### 14.3 Sink Connector FAILED

| 现象 | 原因 | 解决方案 |
|------|------|----------|
| `Communications link failure` | MySQL 不通 | `docker exec rmq-connect ping mysql-target` |
| `Access denied` | MySQL 密码错误 | 检查 `docker-compose.yml` 中的 `MYSQL_ROOT_PASSWORD` |
| `Table doesn't exist` | 目标表未创建 | 执行第 9.1 节 SQL |
| `Duplicate entry` | 主键冲突 | 确认 `insert.mode=UPSERT` 已配置 |
| `Data truncation` | 字段类型不匹配 | 对齐 MySQL 和目标表列类型 |

### 14.4 数据不同步排查步骤

```bash
# 1. 确认 Connector 状态
curl -s http://localhost:8082/connectors/pg-source-connector/status
curl -s http://localhost:8082/connectors/mysql-sink-connector/status

# 2. 确认复制槽活跃
docker exec pg-source psql -U source_user -d source_db -c \
  "SELECT slot_name, active FROM pg_replication_slots WHERE slot_name = 'pg_orders_slot';"

# 3. 确认 Topic 有消息
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && \
  sh ./bin/mqadmin topicStatus -n rmq-namesrv:9876 -t debezium-pg-source"

# 4. 查看 Connect 错误日志
docker compose logs rmq-connect | grep -i -E 'error|exception|warn' | tail -50

# 5. 在 PG 做一次 INSERT 测试
docker exec pg-source psql -U source_user -d source_db -c "
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at)
VALUES (9999, 'Test Product', 1, 9.99, 'test', now(), now());
"

# 6. 验证 MySQL
sleep 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders WHERE order_id = 9999;"
```

### 14.5 重置同步链路

```bash
# 1. 停止 Connector
curl -s http://localhost:8082/connectors/pg-source-connector/stop
curl -s http://localhost:8082/connectors/mysql-sink-connector/stop

# 2. 删除并重建 PG 复制槽
docker exec pg-source psql -U source_user -d source_db -c "
SELECT pg_drop_replication_slot('pg_orders_slot');
SELECT pg_create_logical_replication_slot('pg_orders_slot', 'pgoutput');
"

# 3. 清空 MySQL 目标表
docker exec mysql-target mysql -uroot -proot_pass target_db -e "TRUNCATE TABLE orders;"

# 4. 删除 Topic
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && \
  sh ./bin/mqadmin deleteTopic -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster"

# 5. 重建 Topic
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && \
  sh ./bin/mqadmin updatetopic -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster"

# 6. 重新 POST Source 和 Sink Connector（见第 11 节）
```

---

## 附录 A：关键配置速查

| 配置项 | 值 |
|--------|-----|
| Docker 网络 | `cdc-net` |
| PG 容器名 | `pg-source:5432` |
| PG 用户/库 | `source_user` / `source_db` |
| PG 源表 | `public.orders` |
| Publication | `pg_orders_pub` |
| Slot | `pg_orders_slot` |
| MySQL 容器名 | `mysql-target:3306` |
| MySQL 用户/库 | `root` / `target_db` |
| MySQL 目标表 | `orders` |
| RocketMQ NS | `rmq-namesrv:9876` |
| RocketMQ Broker | `rmq-broker:10911` |
| Connect REST | `http://localhost:8082` |
| Topic | `debezium-pg-source` |
| Source 类 | `org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector` |
| Sink 类 | `org.apache.rocketmq.connect.jdbc.connector.JdbcSinkConnector` |

---

## 附录 B：停止与清理

```bash
# 停止所有服务（保留数据卷）
docker compose down

# 停止所有服务并删除数据卷（完全清理）
docker compose down -v

# 删除自定义网络
docker network rm cdc-net

# 删除构建的镜像
docker rmi rmq-connect:custom
```

---

## 附录 C：实际部署记录（2026-05-22）

> 以下为本次实战操作的完整记录，含所有踩坑与修复。

### C.1 环境适配

| 问题 | 修复 |
|------|------|
| Docker Hub 不可达 | `daemon.json` 添加 `docker.m.daocloud.io` 镜像加速 |
| GitHub 不可达（容器内） | 宿主机可通，Docker 内 `git clone` 正常 |
| Maven Central 慢 | Dockerfile 中配置阿里云 Maven 镜像 |
| `maven:3.9-eclipse-temurin-17` 不存在 | 改为本地已有 `maven:3.9.9-eclipse-temurin-17` |
| Checkstyle 编码规范失败 | 添加 `-Dcheckstyle.skip=true` |
| Debezium 插件缺少父 POM | 添加 `-am` 自动构建依赖模块 |
| `JAVA_OPT_EXT` 在容器中不生效 | 改用 `JAVA_OPT` 直接覆写 JVM 参数 |
| Broker `--enable-proxy` NPE | 去掉 proxy 模式，仅运行 brokker |

### C.2 最终 docker-compose.yml 关键配置

```yaml
# RMQ NameServer
rmq-namesrv:
  image: docker.m.daocloud.io/apache/rocketmq:5.3.2
  environment:
    - JAVA_OPT=-server -Xms256m -Xmx256m -Xmn128m

# RMQ Broker（无 proxy）
rmq-broker:
  image: docker.m.daocloud.io/apache/rocketmq:5.3.2
  environment:
    - JAVA_OPT=-server -Xms512m -Xmx512m -Xmn256m
  command: ["sh", "mqbroker", "-n", "rmq-namesrv:9876"]

# PostgreSQL（wal_level=logical 通过启动参数）
pg-source:
  image: docker.m.daocloud.io/library/postgres:16
  command: >
    -c wal_level=logical
    -c max_wal_senders=10
    -c max_replication_slots=4

# MySQL
mysql-target:
  image: docker.m.daocloud.io/library/mysql:8.0

# RocketMQ Connect（自定义镜像，含 PG CDC + JDBC 插件）
rmq-connect:
  image: rmq-connect:custom
```

### C.3 最终 Dockerfile 关键差异

```dockerfile
FROM maven:3.9.9-eclipse-temurin-17 AS builder
# ↑ 使用本地已有镜像 tag
FROM maven:3.9.9-eclipse-temurin-17
# ↑ 阶段2也复用，避免拉取 eclipse-temurin:17-jre

# Maven 阿里云镜像
RUN mkdir -p /root/.m2 && echo '...' > /root/.m2/settings.xml

# 主构建
RUN mvn -Prelease-connect -Dmaven.test.skip=true clean install -U --no-transfer-progress

# Debezium 父模块（-am 自动构建依赖，-Dcheckstyle.skip=true 跳过格式检查）
WORKDIR /build/connectors/rocketmq-connect-debezium
RUN mvn clean install -Dmaven.test.skip=true -Dcheckstyle.skip=true \
    -pl rocketmq-connect-debezium-core,kafka-connect-adaptor -am --no-transfer-progress

# PostgreSQL 插件
WORKDIR /build/connectors/rocketmq-connect-debezium/rocketmq-connect-debezium-postgresql
RUN mvn clean package -Dmaven.test.skip=true --no-transfer-progress

# JDBC 插件
WORKDIR /build/connectors/rocketmq-connect-jdbc
RUN mvn clean package -Dmaven.test.skip=true --no-transfer-progress
```

### C.4 构建耗时

| 阶段 | 耗时 |
|------|------|
| git clone rocketmq-connect | 4s |
| Maven 主构建 (11模块) | 5分38秒 |
| Debezium 父模块 (3模块) | 21秒 |
| Debezium PostgreSQL 插件 | 46秒 |
| JDBC 插件 | 40秒 |
| 镜像导出 | 27秒 |
| **总耗时** | **~8分钟** |
| 最终镜像大小 | **1.15GB** |

### C.5 服务启动耗时

| 容器 | 拉取耗时 | 启动 |
|------|---------|------|
| `mysql:8.0` | 1006s (~17分钟) | ✅ |
| `postgres:16` | 700s (~12分钟) | ✅ |
| `rocketmq:5.3.2` | 1144s (~19分钟) | ✅ |
| `rmq-connect:custom` | 本地构建 | ✅ |

### C.6 验证清单

```powershell
# 所有容器
docker ps --format "table {{.Names}}\t{{.Status}}"
# 期望: 5个容器全部 Up

# PG CDC
docker exec pg-source psql -U source_user -d source_db -c "SHOW wal_level;"
# 期望: logical

docker exec pg-source psql -U source_user -d source_db -c "SELECT * FROM pg_publication_tables;"
# 期望: pg_orders_pub | orders

# PG 允许远程连接
docker exec pg-source sh -c "grep 'host.*all.*all.*all' /var/lib/postgresql/data/pg_hba.conf"
# 期望: host all all all scram-sha-256

# MySQL 目标表
docker exec mysql-target mysql -uroot -proot_pass target_db -e "DESC orders; SELECT COUNT(*) FROM orders;"
# 期望: row_count = 0
```

### C.7 后续操作（手动执行）

```powershell
# 1. 创建 Replication Slot（如果未创建）
docker exec pg-source psql -U source_user -d source_db -c "SELECT pg_create_logical_replication_slot('pg_orders_slot', 'pgoutput');"

# 2. 等待 Connect 就绪（约60秒后）
Start-Sleep 60
curl -s http://localhost:8082/connectors/list

# 3. 创建 RocketMQ Topic
docker exec rmq-broker sh -c "cd /home/rocketmq/rocketmq-5.3.2 && export NAMESRV_ADDR=rmq-namesrv:9876 && sh bin/mqadmin updatetopic -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster"

# 4. 创建 Source Connector
curl -X POST -H "Content-Type: application/json" http://localhost:8082/connectors/pg-source-connector -d '{...}'

# 5. 创建 Sink Connector
curl -X POST -H "Content-Type: application/json" http://localhost:8082/connectors/mysql-sink-connector -d '{...}'

# 6. 检查状态
curl -s http://localhost:8082/connectors/pg-source-connector/status
curl -s http://localhost:8082/connectors/mysql-sink-connector/status

# 7. 同步测试
docker exec pg-source psql -U source_user -d source_db -c "INSERT INTO public.orders (order_id,product_name,quantity,price,status,created_at,updated_at) VALUES (2001,'Test',1,99,'pending',now(),now());"
Start-Sleep 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders WHERE order_id=2001;"
```

---

> **文档版本**：v1.1  
> **最后更新**：2026-05-23（新增附录C：实际部署记录）  
> **参考**：[Apache RocketMQ Connect 实战2](https://rocketmq.apache.org/zh/docs/connect/05RocketMQ%20Connect%20In%20Action2/)
