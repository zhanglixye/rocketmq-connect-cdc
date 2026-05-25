# PostgreSQL CDC → MySQL 同步 — 实操部署记录

> **日期**：2026-05-22  
> **环境**：Windows 11，Docker Desktop，PowerShell  
> **状态**：Docker Hub & GitHub 不可达，已完成适配方案，待用户在有网络环境执行

---

## 1. 环境检查

### 1.1 Docker 版本

```powershell
PS> docker --version
Docker version 27.3.1, build ce12230
```

### 1.2 本地已有镜像

```powershell
PS> docker images --format "{{.Repository}}:{{.Tag}}  {{.Size}}"
maven:3.9.9-eclipse-temurin-17  759MB
```

> ⚠️ 仅有一个 Maven 镜像，无 `postgres:16`、`mysql:8.0`、`apache/rocketmq:5.3.2`。

### 1.3 Docker Registry Mirror 配置

```powershell
PS> Get-Content "$env:USERPROFILE\.docker\daemon.json"
{
  "builder": {
    "gc": {
      "defaultKeepStorage": "20GB",
      "enabled": true
    }
  },
  "experimental": false
}
```

> ⚠️ **未配置任何 registry mirror**，直接访问 Docker Hub (`registry-1.docker.io`) 失败。

---

## 2. 实际操作记录

### 2.1 尝试构建 Connect 镜像 — ❌ 失败

```powershell
cd d:\CDC\rocketmq-connect-cdc
docker compose build rmq-connect
```

**错误输出**：

```
#4 ERROR: failed to do request:
Head "https://registry-1.docker.io/v2/library/maven/manifests/3.9-eclipse-temurin-17":
dialing registry-1.docker.io:443 ... connectex:
A connection attempt failed because the connected party did not properly
respond after a period of time, or established connection failed because
connected host has failed to respond.
```

**根因**：Docker Desktop 无法直连 Docker Hub（registry-1.docker.io:443 不通），且未配置国内镜像加速器。

### 2.2 测试 GitHub 连通性 — ❌ 失败

```powershell
PS> git ls-remote --heads https://github.com/apache/rocketmq-connect.git
# 超时，无输出
```

**根因**：宿主机也无法访问 GitHub，导致 Dockerfile 中的 `git clone` 步骤也无法执行。

---

## 3. 问题诊断结论

| 检查项 | 结果 | 影响 |
|--------|------|------|
| Docker Hub 连通 | ❌ 不通 | 无法拉取 `postgres:16`、`mysql:8.0`、`apache/rocketmq:5.3.2`、`eclipse-temurin:17-jre` |
| GitHub 连通 | ❌ 不通 | 无法在 Dockerfile 中 `git clone` 源码 |
| Registry Mirror | ❌ 未配置 | 没有备用镜像源 |
| 本地 Maven 镜像 | ✅ `maven:3.9.9-eclipse-temurin-17` | 可作为编译基础镜像 |

---

## 4. 已执行的适配修改

### 4.1 Dockerfile 适配

已将 `connect/Dockerfile` 中的基础镜像 tag 从无法拉取的版本改为本地已有版本：

**修改前**：
```dockerfile
FROM maven:3.9-eclipse-temurin-17 AS builder
...
FROM eclipse-temurin:17-jre
```

**修改后**：
```dockerfile
FROM maven:3.9.9-eclipse-temurin-17 AS builder
...
FROM maven:3.9.9-eclipse-temurin-17
```

> 当前文件路径：`d:\CDC\rocketmq-connect-cdc\connect\Dockerfile`

---

## 5. 解决方案（按推荐顺序）

### 方案 A：配置 Docker 镜像加速器（推荐，中国大陆用户）

编辑 `C:\Users\<用户名>\.docker\daemon.json`：

```json
{
  "builder": {
    "gc": {
      "defaultKeepStorage": "20GB",
      "enabled": true
    }
  },
  "experimental": false,
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerhub.timeweb.cloud",
    "https://hub.rat.dev"
  ]
}
```

然后重启 Docker Desktop：托盘图标 → `Restart Docker Desktop`。

### 方案 B：手动预下载源码（解决 GitHub 不通）

在**能访问 GitHub 的机器**上执行：

```bash
git clone --depth 1 -b master https://github.com/apache/rocketmq-connect.git
```

然后将 `rocketmq-connect/` 目录拷贝到 `d:\CDC\rocketmq-connect-cdc\connect\rocketmq-connect-source\`。

修改 Dockerfile，用 `COPY` 替代 `git clone`：

```dockerfile
FROM maven:3.9.9-eclipse-temurin-17 AS builder
WORKDIR /build

# 改为从本地复制源码（替代 git clone）
COPY rocketmq-connect-source /build

RUN mvn -Prelease-connect -Dmaven.test.skip=true clean install -U -q
# ... 后续不变
```

### 方案 C：使用 VPN / 代理

如果有代理，配置 Docker Desktop 代理：

Settings → Resources → Proxies → 填写 HTTP/HTTPS 代理地址。

### 方案 D：离线预下载所有镜像

在**能访问 Docker Hub 的机器**上：

```bash
# 拉取所有需要的镜像
docker pull apache/rocketmq:5.3.2
docker pull postgres:16
docker pull mysql:8.0
docker pull eclipse-temurin:17-jre
docker pull maven:3.9-eclipse-temurin-17

# 导出为 tar
docker save -o rocketmq-5.3.2.tar apache/rocketmq:5.3.2
docker save -o postgres-16.tar postgres:16
docker save -o mysql-8.0.tar mysql:8.0
docker save -o temurin-17-jre.tar eclipse-temurin:17-jre
docker save -o maven-3.9.tar maven:3.9-eclipse-temurin-17

# 拷贝到目标机器后导入
docker load -i rocketmq-5.3.2.tar
docker load -i postgres-16.tar
docker load -i mysql-8.0.tar
docker load -i temurin-17-jre.tar
docker load -i maven-3.9.tar
```

---

## 6. 网络就绪后的完整操作流程

> 当 Docker Hub 和 GitHub 均可访问后，按以下步骤操作：

### Step 1：进入项目目录

```powershell
cd d:\CDC\rocketmq-connect-cdc
```

### Step 2：构建 RocketMQ Connect 镜像（10-20 分钟）

```powershell
docker compose build rmq-connect
```

期望看到：
```
[+] Building 600.0s (15/15) FINISHED
 => [builder] git clone ...
 => [builder] mvn -Prelease-connect ...
 => [stage-1] COPY --from=builder ...
 => exporting to image
 => naming to rmq-connect:custom
```

### Step 3：启动全部服务

```powershell
docker compose up -d
```

等待约 30-60 秒后检查：

```powershell
docker compose ps
```

期望输出：
```
NAME           STATUS
rmq-namesrv    Up (healthy)
rmq-broker     Up
pg-source      Up (healthy)
mysql-target   Up (healthy)
rmq-connect    Up
```

### Step 4：验证组件

```powershell
# Connect REST API
curl -s http://localhost:8082/connectors/list

# PostgreSQL
docker exec pg-source psql -U source_user -d source_db -c "SELECT 1;"

# MySQL
docker exec mysql-target mysql -uroot -proot_pass -e "SELECT 1;"
```

### Step 5：创建 PG Publication + Slot

```powershell
docker exec -it pg-source psql -U source_user -d source_db
```

```sql
SHOW wal_level;  -- 确认 logical

CREATE PUBLICATION pg_orders_pub FOR TABLE public.orders;
SELECT pg_create_logical_replication_slot('pg_orders_slot', 'pgoutput');

-- 验证
SELECT * FROM pg_publication_tables WHERE pubname = 'pg_orders_pub';
SELECT slot_name, active FROM pg_replication_slots WHERE slot_name = 'pg_orders_slot';
\q
```

### Step 6：验证 MySQL 目标表

```powershell
docker exec mysql-target mysql -uroot -proot_pass target_db -e "DESC orders; SELECT COUNT(*) FROM orders;"
# 期望: row_count = 0
```

### Step 7：创建 RocketMQ Topic

```powershell
docker exec rmq-broker sh -c "export NAMESRV_ADDR=rmq-namesrv:9876 && sh ./bin/mqadmin updatetopic -n rmq-namesrv:9876 -t debezium-pg-source -c DefaultCluster"
```

### Step 8：创建 Source Connector

```powershell
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

### Step 9：创建 Sink Connector

```powershell
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

### Step 10：检查 Connector 状态

```powershell
curl -s http://localhost:8082/connectors/pg-source-connector/status
curl -s http://localhost:8082/connectors/mysql-sink-connector/status
# 期望: state=RUNNING, trace=null
```

### Step 11：全量同步验证

```powershell
# PG 源表
docker exec pg-source psql -U source_user -d source_db -c "SELECT * FROM public.orders ORDER BY order_id;"

# MySQL 目标表
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders ORDER BY order_id;"
# 期望: 3 条初始数据（1001/1002/1003）
```

### Step 12：增量同步测试

```powershell
# INSERT
docker exec pg-source psql -U source_user -d source_db -c "INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at) VALUES (2001, 'Test', 1, 99.00, 'pending', now(), now());"
Start-Sleep -Seconds 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders WHERE order_id = 2001;"

# UPDATE
docker exec pg-source psql -U source_user -d source_db -c "UPDATE public.orders SET status = 'done' WHERE order_id = 2001;"
Start-Sleep -Seconds 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT order_id, status FROM orders WHERE order_id = 2001;"

# DELETE
docker exec pg-source psql -U source_user -d source_db -c "DELETE FROM public.orders WHERE order_id = 2001;"
Start-Sleep -Seconds 5
docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM orders WHERE order_id = 2001;"
# 期望: Empty set
```

---

## 7. 当前项目文件清单

```
d:\CDC\rocketmq-connect-cdc\
├── docker-compose.yml              ✅ 已创建
├── connect\
│   ├── Dockerfile                  ✅ 已适配本地镜像 tag
│   └── connect-standalone.conf     ✅ 已创建
├── pg-init\
│   └── init.sql                    ✅ 已创建
├── mysql-init\
│   └── init.sql                    ✅ 已创建
├── DEPLOYMENT-LOG.md               ✅ 本文件（实操记录）
└── pg-to-mysql-rocketmq-connect-docker.md  （参考文档在 d:\CDC\）
```

---

## 8. 快速问题排查

| 现象 | 检查命令 | 解决 |
|------|---------|------|
| `docker compose build` 卡住 | 看是否在 pulling 阶段超时 | 配置 registry-mirrors（方案 A） |
| `git clone` 超时 | `git ls-remote --heads https://github.com/apache/rocketmq-connect.git` | 使用方案 B 预下载源码 |
| `mvn` 下载依赖超时 | 看 Maven 是否卡在 downloading | 配置 Maven 阿里云镜像（见下文） |
| Connect 日志 ERROR | `docker compose logs rmq-connect` | 见参考文档第 14 节 |

### Maven 阿里云镜像（加速依赖下载）

如果 Maven 依赖下载慢，可在 Dockerfile 的 Maven 构建前添加镜像配置：

```dockerfile
# 在 RUN mvn ... 之前添加
RUN mkdir -p /root/.m2 && \
    echo '<?xml version="1.0" encoding="UTF-8"?><settings><mirrors><mirror><id>aliyun</id><mirrorOf>central</mirrorOf><name>Aliyun</name><url>https://maven.aliyun.com/repository/public</url></mirror></mirrors></settings>' > /root/.m2/settings.xml
```

---

## 9. 实际部署后排查记录（2026-05-23）

> 网络问题解决后成功部署，但数据不同步。经过逐环节排查，发现 **4 个关键问题**。

### 9.1 问题 1：Connector 类名错误 🔴

**现象**：Sink Connector 创建失败，报 `Failed to find any class that implements Connector`

**根因**：文档中 JDBC Sink 类名为 `org.apache.rocketmq.connect.jdbc.connector.JdbcSinkConnector`（多了一层 `connector`），实际类名是 `org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector`

**修复**：
```diff
- "connector.class": "org.apache.rocketmq.connect.jdbc.connector.JdbcSinkConnector"
+ "connector.class": "org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector"
```

### 9.2 问题 2：缺少 Reroute Transform 导致 Topic 名含非法字符 🔴

**现象**：Source Connector 报 `CODE: 29 - topic contains illegal characters, allowing only ^[%|a-zA-Z0-9_-]+$`

**根因**：去掉 `Reroute` Transform 后，Debezium 自动生成 Topic 名为 `pgserver.public.orders`，含 `.` 被 RocketMQ 拒绝

**修复**：必须保留 `Reroute` + `Unwrap` 双 Transform：
```json
"kafka.transforms": "Reroute,Unwrap",
"kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
"kafka.transforms.Reroute.topic.regex": "(.*)",
"kafka.transforms.Reroute.topic.replacement": "orders"
```

### 9.3 问题 3：`table.name.from.header=true` 导致 NPE 🔴

**现象**：Sink Connector 报 `NullPointerException: Cannot invoke "String.startsWith(String)" because "fqn" is null`

**根因**：设置 `table.name.from.header=true` 后，JDBC Connector 尝试从消息 Header 提取表名，但 Debezium 的 `add.headers=op,source.db,source.table` 产生的 Header 格式不被 JDBC Connector 识别

**修复**：设置 `"table.name.from.header": "false"`

### 9.4 问题 4：`table.name.format` 被 JDBC Connector 忽略 🔴🔴🔴

**现象**：Sink 消费了消息（offset 递增）但 MySQL 无数据。日志报：
```
TableAlterOrCreateException: Table "debezium_pg_source"."Value" is missing
```

**根因**：RocketMQ Connect 的 JDBC Connector **忽略 `table.name.format` 配置**，直接从 Topic 名推导 schema.table：
- Topic `debezium-pg-source` → schema=`debezium_pg_source`，table=`Value`（来自 Record Schema 名）

**修复（最终方案）**：让 Source Connector 的 Reroute 直接把 Topic 设为目标表名 `orders`：
```json
// Source Connector
"connect.topicname": "orders",
"kafka.transforms.Reroute.topic.replacement": "orders"

// Sink Connector
"connect.topicnames": "orders",
"table.name.from.header": "false"
```

### 9.5 问题 5：PG TIMESTAMP → MySQL DATETIME 类型不兼容 🔴🔴

**现象**：Sink 写 MySQL 时报 `Data truncation: Incorrect datetime value: '1779515976727751'`

**根因**：Debezium 将 PG `TIMESTAMP` 输出为 `io.debezium.time.MicroTimestamp`（epoch 微秒整数），MySQL `DATETIME(3)` 无法接受

**修复**：MySQL 的 `created_at` 和 `updated_at` 从 `DATETIME(3)` 改为 `BIGINT`：
```sql
ALTER TABLE orders MODIFY created_at BIGINT NOT NULL, MODIFY updated_at BIGINT NOT NULL;
```

### 9.6 问题 6：`time.precision.mode=connect` 与 JsonConverter 冲突 🟡

**现象**：`Invalid Java object for schema type INT64: class java.util.Date`

**根因**：`time.precision.mode=connect` 产生 `java.util.Date` 对象，但 `JsonConverter`（schemaless）期望 INT64

**修复**：不使用 `time.precision.mode=connect`，保持默认（epoch 微秒），配合 MySQL BIGINT

---

## ✅ 最终成功配置（2026-05-23 验证通过）

**现象**：Connect 容器重启后所有 Connector 状态丢失

**根因**：`connect-standalone.conf` 中 `storePathRootDir=/tmp/connect-store`，`/tmp` 在容器重启后清空

**修复**：修改 `connect-standalone.conf`：
```properties
storePathRootDir=/opt/rocketmq-connect/store
```

---

## 10. 最终正确的 Connector 配置

### Source Connector（`pg-src-v3`）

```json
{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "orders",
  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": "(.*)",
  "kafka.transforms.Reroute.topic.replacement": "orders",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
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

### Sink Connector（`mysql-sink-v3`）

```json
{
  "connector.class": "org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector",
  "max.task": "1",
  "connect.topicnames": "orders",
  "connection.url": "jdbc:mysql://mysql-target:3306/target_db?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai&nullCatalogMeansCurrent=true",
  "connection.user": "root",
  "connection.password": "root_pass",
  "pk.fields": "order_id",
  "pk.mode": "record_key",
  "insert.mode": "UPSERT",
  "delete.enabled": "true",
  "table.name.from.header": "false",
  "table.name.format": "orders",
  "db.timezone": "UTC",
  "table.types": "TABLE",
  "errors.deadletterqueue.topic.name": "dlq-topic",
  "errors.log.enable": "true",
  "errors.tolerance": "ALL",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```

> ⚠️ **核心教训**：RocketMQ Connect 的 JDBC Sink Connector 从 **Topic 名**推导目标表名（schema=Topic名，table=Record Schema名`Value`），因此 Source Connector 的 `Reroute` 必须将 Topic 设为与目标**表名相同**的值。

---

> **结论**：所有配置文件和脚本已就绪，当前阻塞点仅为网络访问 Docker Hub/GitHub。按第 5 节方案解决网络问题后，按第 6 节步骤即可一键完成全部部署与测试。
