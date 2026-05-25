## PostgreSQL → MySQL CDC 同步原理

### 整体架构与数据流

```
┌──────────┐    CDC(WAL)     ┌──────────────────┐    RocketMQ消息     ┌──────────────────┐    JDBC     ┌──────────┐
│PostgreSQL│ ───────────────► │  RocketMQ Connect │ ───────────────► │  RocketMQ Connect │ ─────────► │  MySQL   │
│ (源端)   │                 │  Source Connector  │                  │  Sink Connector   │            │ (目标端) │
│ orders表 │                 │  (Debezium PG)     │                  │  (JDBC Sink)      │            │ orders表 │
└──────────┘                 └────────┬───────────┘                  └────────┬──────────┘            └──────────┘
                                      │                                       │
                                      ▼                                       ▼
                              ┌──────────────┐                         ┌──────────────┐
                              │   RocketMQ   │ ◄─── consume ────────── │   RocketMQ   │
                              │   Broker     │                         │    Topic     │
                              │  (消息存储)   │                         │debezium-pg-  │
                              └──────────────┘                         │   source     │
                                                                       └──────────────┘
```

**核心原理分四步**：

### 第一步：CDC 捕获变更（Source Connector）

PostgreSQL 开启了 **WAL（Write-Ahead Log）逻辑解码**（`wal_level=logical`），通过创建 **Publication（发布）** 和 **Replication Slot（复制槽）**，PG 将 `orders` 表的所有 INSERT/UPDATE/DELETE 操作以逻辑日志形式暴露出来。

RocketMQ Connect 内置的 **Debezium PG Connector** 连接到 PG 的复制槽，实时读取 WAL 变更，将其转换为结构化的 `ConnectRecord`（包含操作类型、前后数据镜像等）。

### 第二步：消息投递（RocketMQ）

Source Connector 将 `ConnectRecord` 序列化为 JSON，通过 **NameServer** 发现 Broker 地址，将消息发送到 RocketMQ 的 Topic（`debezium-pg-source`）。消息持久化存储在 Broker 磁盘上，保证不丢失。

### 第三步：消息消费（Sink Connector）

Sink Connector 从 RocketMQ 消费 Topic 中的消息。由于 Source 端使用了 **Unwrap** 和 **Reroute** Transform，消息已经是展平的行级 JSON，Sink 端可直接解析出表名（从 Header 中取 `source.table`）、主键（从消息 Key 中取 `order_id`）和字段值。

### 第四步：写入目标（JDBC → MySQL）

JDBC Sink Connector 使用 **UPSERT 模式**（`INSERT ... ON DUPLICATE KEY UPDATE`）写入 MySQL：
- **INSERT**：直接插入新行
- **UPDATE**：主键冲突时更新字段
- **DELETE**：按主键删除对应行（`delete.enabled: true`）

---

### 各 Docker 服务的作用

| 容器 | 镜像 | 作用 |
|------|------|------|
| **`pg-source`** | PostgreSQL | **CDC 数据源**。存储 `orders` 表，开启 WAL 逻辑解码，向 Debezium 提供变更事件流 |
| **`mysql-target`** | MySQL | **同步目标库**。接收 Sink Connector 写入的数据，最终数据落盘到此 |
| **`rmq-namesrv`** | `apache/rocketmq:5.3.2` | **RocketMQ 路由注册中心**。维护 Broker 的地址列表和 Topic 路由信息，所有客户端（Producer/Consumer）先连 NameServer 发现 Broker 位置 |
| **`rmq-broker`** | `apache/rocketmq:5.3.2` | **RocketMQ 消息存储与分发**。接收 Source 发来的消息并持久化到磁盘，同时将消息推送给 Sink 消费者。端口 10911 是核心通信口，10909 是重试消息专用通道 |
| **`rmq-proxy`** | `apache/rocketmq:5.3.2` | **RocketMQ 5.x gRPC 代理**。Connect 框架通过 Proxy（8080/8081）与 Broker 通信，而非直连 Broker，提供协议转换和负载均衡 |
| **`rmq-connect`** | `rmq-connect:custom`（自构建） | **RocketMQ Connect 运行时**。承载两个 Connector：一个 Debezium PG Source（CDC 采集），一个 JDBC Sink（写入 MySQL）。REST API 端口 8082 用于创建/管理 Connector |

---

### 一句话总结

> **PG 开 WAL → Debezium 读变更 → 投 RocketMQ Topic → JDBC 消费写 MySQL**，六个容器各司其职：PG/MySQL 是数据两端，NameServer 做路由发现，Broker 做消息中转，Proxy 做协议代理，Connect 是核心引擎承载 Source 和 Sink 两个连接器。