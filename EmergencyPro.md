# CDC 生产环境应急恢复手册 (EmergencyPro)

> 适用场景：PostgreSQL → RocketMQ Connect → MySQL 数据同步链路
> 部署架构：PG(10.0.1.2) 与 MQ+Connect+MySQL 在不同服务器，通过腾讯云内网互通

---

## 1. 架构与数据安全保障层级

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PostgreSQL 数据源                            │
│  ① WAL 逻辑日志流                                                   │
│  ② 复制槽 (Replication Slot)：保留未消费的 WAL，重启后可续传         │
│                                  │
└────────┬────────────────────────────────────────────────────────────┘
         ▼ WAL 增量流
┌─────────────────────────────────────────────────────────────────────┐
│              RocketMQ Connect Source (Debezium PG)                  │
│  ④ connect-store/position.json：记录 source LSN，重启续传起点       │
└────────┬────────────────────────────────────────────────────────────┘
         ▼ JSON 变更消息
┌─────────────────────────────────────────────────────────────────────┐
│                     RocketMQ Broker (消息队列)                       │
│  ⑤ commitlog 持久化：Source 已发但 Sink 未消费的消息                │
│  ⑥ consumerOffset：Sink 消费位点                                    │
└────────┬────────────────────────────────────────────────────────────┘
         ▼ 增量消费
┌─────────────────────────────────────────────────────────────────────┐
│                RocketMQ Connect Sink (JDBC)                         │
│  ⑦ UPSERT 幂等写入，重复消费不丢数据                                │
└────────┬────────────────────────────────────────────────────────────┘
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          MySQL 目标库                               │
└─────────────────────────────────────────────────────────────────────┘
```

**数据安全保障逐层分析：**

```
层级    持久化内容              挂了之后
────────────────────────────────────────────────────────────────
①-③    PG WAL + 复制槽          ✅ PG 保留未消费 WAL（终极兜底）
④      connect-store 卷         ✅ position.json (lsn) 是续传起点
⑤-⑥    MQ commitlog + offset    ✅ 消息持久化，避免全量快照
⑦      MySQL UPSERT             ✅ 幂等写入，重复数据无害
```

**各层丢失的后果：**

```
丢失的层                     后果                           恢复方案
──────────────────────────────────────────────────────────────────────────
仅 Broker commitlog 丢失     Source 不会重发已提交的消息    方案 A: 全量快照
                             未消费的消息永久丢失             (慢，但数据最终不丢)

仅 broker-store 丢失         Sink 无法从 Broker 续消费      方案 A: 全量快照
(connect-store 完好)          gap 期间消息丢失                (详见第 4 节)

仅 connect-store 丢失        找不到 position.json           方案 A: 全量快照
(broker-store 完好)           Source 触发全量快照              (慢，但数据最终不丢)

connect-store + Broker       新服务找不到位点                方案 A: 全量快照
commitlog 都丢失             Source 全量扫表                  (慢，但数据最终不丢)

PG 复制槽 + 以上全丢          WAL 被清理，无法续传            方案 A: 全量快照
                                                             (慢，但数据最终不丢)

PG 源库数据损毁               WAL 也无法恢复                  方案 E: PITR
                                                             恢复到挂机前
```

**核心结论：**

1. **PG 复制槽是终极兜底**——只要 PG 还在、WAL 没被清，全量快照总能重建完整数据。数据永远不会永久丢失。
2. **connect-store 决定恢复方式**——有它走增量续传（秒级），没它走全量快照（分钟~小时级）。
3. **Broker commitlog 决定恢复速度**——有它 Broker 挂了秒级恢复，没它走全量快照。

**三者关系：不是"可选的性能优化"，而是"逐级决定恢复速度"。都保住 = 最快恢复，缺任意一个 = 回退到下一级的慢速方案，但数据最终不丢。**

---

## 2. 三个关键 LSN 与位点对应关系

```
PG WAL 字节流: ──────────────────────────────────────────────────────→
   [已清理区]  │  [保留区]  │  [积压区:读未确认]  │  [当前写入]
              ↑             ↑                      ↑
         restart_lsn   confirmed_flush_lsn   pg_current_wal_lsn
         (安全底线)     (告知 PG 已处理)      (PG 正在写)
```

```
对应关系：
position.json  lsn          ≈  下次重启续传起点（→PG 请求从这开始发 WAL）
position.json  lsn_commit   ≈  confirmed_flush_lsn（已确认处理完的位置）
restart_lsn                  =  PG 保证 WAL 存在的最早点（低于此值 WAL 被清）
current_wal_lsn              =  PG 最新写入位置

重启恢复条件: restart_lsn ≤ position.json.lsn ≤ current_wal_lsn
              ✅ 满足 → 断点续传           ❌ 不满足 → 只能全量快照
```

---

## 3. 应急恢复方案速查表

```
┌────────────────────────┬────────────────────┬──────────────┬───────────┐
│        故障场景        │      恢复方案      │   恢复速度   │  数据丢失 │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ MQ 服务器重启(磁盘完好)│ systemd 自动拉起    │    秒级      │   无      │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ MQ 服务器磁盘全损      │ 方案 A: 全量快照   │    慢        │   无      │
│ (connect-store 也丢了) │ snapshot=always    │              │           │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ Broker commitlog 丢失  │ 方案 A: 全量快照   │    慢        │   有⚠️     │
│ (但 connect-store 完好)│ 需删 position.json │              │ (见第4节)  │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ Broker + Connect 崩溃  │ 方案 B: 断点续传   │    快        │   无      │
│ 但两个 store 都完好    │ 复用旧 store 目录  │              │           │
│ (connect+boker 都在)   │                    │              │           │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ PG 服务器重启          │ 自动续传           │    秒级      │   无      │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ PG 服务崩溃/数据损毁   │ 方案 E: PITR 恢复  │    中        │   近零    │
│                        │ 到挂机前时间点     │              │           │
├────────────────────────┼────────────────────┼──────────────┼───────────┤
│ 长时间宕机 WAL 被清    │ 方案 A: 全量快照   │    慢        │   无      │
│ (restart_lsn > lsn)    │                    │              │           │
└────────────────────────┴────────────────────┴──────────────┴───────────┘
```

---

## 4. Broker commitlog 丢失的风险窗口

**为什么 Broker commitlog 丢了会导致数据丢失？**

关键问题在于：Source 更新 position.json 的时机 vs Sink 消费完成的时机之间存在 gap。

```
时间线 ────────────────────────────────────────────────→

   Source 读 WAL LSN=50
        │
        ├→ 转成消息 → 发到 Broker → Broker 写入 commitlog ✅
        │
        ├→ Source 更新 position.json: lsn=50
        │   ("我已经发完了 LSN=50，下次从 50 之后续传")
        │                                         │
        │              ←── 风险窗口 ──→           │
        │                                         │
        │                   Sink 从 Broker 拉取 LSN=50 的消息
        │                                         │
        │                   Sink 写 MySQL         │
        │                                         │
        │                   Sink 更新 position.json: offset+1
        │                   ("我消费完了")
        │
        ▼

   如果 Broker 在「风险窗口」内崩溃且 commitlog 丢失:

   Source 重启 → 读 position.json → lsn=50
             → 告诉 PG: "从 LSN=50 之后开始发 WAL"
             → PG 从 LSN=51 开始推送
             → LSN=50 的消息 → Source 不会重发！永久丢失！

   为什么 Source 不会重发？
   因为 position.json 记录的是 "Source 已经处理到哪了"，不是 "Sink 消费到哪了"。
   Source 认为 LSN=50 已经成功发送，不需要重发。
```

**日常运行时 gap 通常只有几百毫秒，只影响几条消息。但如果 Broker 积压了大量消息（Sink 慢于 Source），gap 窗口内的数据量可能很大。**

**恢复方法：** 走方案 A 全量快照——PG 复制槽还保留着完整 WAL，全量扫表可以重建所有数据。代价是慢。

---

## 5. 方案 A：全量快照恢复（最通用，生产兜底）

**适用场景：** 新服务器从头搭建 / connect-store 卷丢失 / PG 复制槽 WAL 被清理

### 5.1 前提条件

- PG 源库正常运行，`wal_level=logical`
- 新服务器已安装 JDK 17+、RocketMQ 5.3.2、RocketMQ Connect 及插件

### 5.2 操作步骤

```bash
# ==== 步骤 1：PG 上重建复制槽（旧槽必须删掉重建）====
psql postgresql://litellm:model-gateway-pg-pass@10.0.1.2:5432/litellm?sslmode=disable

SELECT pg_drop_replication_slot('pg_litellm_slot');        -- 先尝试删除
SELECT pg_create_logical_replication_slot('pg_litellm_slot', 'pgoutput');

-- 验证
SELECT * FROM pg_replication_slots WHERE slot_name = 'pg_litellm_slot';

# ==== 步骤 2：启动 MQ 组件 ====
systemctl start rocketmq-namesrv
sleep 5
systemctl start rocketmq-broker
sleep 10

# ==== 步骤 3：创建 Topic ====
export ROCKETMQ_HOME=/opt/rocketmq-5.3.2
$ROCKETMQ_HOME/bin/mqadmin updatetopic -n 127.0.0.1:9876 \
  -t debezium-pg -c DefaultCluster

# ==== 步骤 4：启动 Connect ====
systemctl start rocketmq-connect
sleep 15

# ==== 步骤 5：Source 配置——关键：snapshot.mode=always ====
cat > /opt/connect-config/postgres-source.json << 'EOF'
{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "debezium-pg",
  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": ".*",
  "kafka.transforms.Reroute.topic.replacement": "debezium-pg",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
  "kafka.transforms.Unwrap.add.headers": "op,source.db,source.table",
  "snapshot.mode": "always",
  "database.server.name": "pg_litellm",
  "database.port": "5432",
  "database.hostname": "10.0.1.2",
  "database.connectionTimeZone": "UTC",
  "database.user": "litellm",
  "database.dbname": "litellm",
  "database.password": "<生产密码>",
  "plugin.name": "pgoutput",
  "publication.name": "pg_litellm_pub",
  "slot.name": "pg_litellm_slot",
  "table.whitelist": "public.LiteLLM_SpendLogs",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
EOF

# ==== 步骤 6：注册 Source + Sink ====
curl -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-source \
  -d @/opt/connect-config/postgres-source.json

curl -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/mysql-sink \
  -d @/opt/connect-config/postgres-sink.json

# ==== 步骤 7：等待全量快照完成 ====
watch -n 5 'curl -s http://127.0.0.1:8082/connectors/postgres-source/status'

# ==== 步骤 8：全量完成后改回 initial（可选，推荐）====
# 将 snapshot.mode 从 always 改为 initial，重新 POST 一次
# 这样后续重启走增量续传，不再全量扫表
```

**缺点：** 表越大全量快照越慢。百万级表约 5-10 分钟，千万级表可能数十分钟。

---

## 6. 方案 B：断点续传（connect-store + broker-store 都完好）

**适用场景：** MQ/Broker/Connect 崩溃或误删，但两个关键目录都完好：
- `/data/connect-store` — position.json（Source + Sink 位点）
- `/root/store` — commitlog + consumequeue（Broker 消息持久化）

**核心原理：**

```
         ┌─────────────────────────────────────────────────────────┐
         │                    两个 store 的分工                      │
         │                                                         │
         │  connect-store                    broker-store           │
         │  ┌──────────────────┐             ┌──────────────────┐   │
         │  │ position.json     │             │ commitlog        │   │
         │  │ ├─ source: lsn    │  ←──→     │ [msg_81..msg_100]│   │
         │  │ └─ sink:  offset  │             │                  │   │
         │  │                   │             │ consumequeue     │   │
         │  │ "我读到/消费到哪"  │             │ (索引+位点)      │   │
         │  └──────────────────┘             └──────────────────┘   │
         │         ↓                                  ↓              │
         │   Source 从 PG WAL               Sink 从 Broker          │
         │   LSN=100 续传                    offset=80 续消费       │
         └─────────────────────────────────────────────────────────┘

新 Connect 启动:
  ① 读 connect-store/position.json → Source lsn=100, Sink offset=80
  ② Source 向 PG 请求从 LSN=100 开始发 WAL
  ③ Sink 从 Broker commitlog offset=80 开始继续消费
  ④ 两边无缝衔接，无数据丢失，秒级恢复
```

**如果只有 connect-store 没有 broker-store：**

```
Source 能从正确 LSN 续传，但 Broker 里没有消息给 Sink 消费。
Source offset 和 Sink offset 之间的 gap 数据丢失 → 只能走方案 A 全量快照。
详见第 4 节「Broker commitlog 丢失的风险窗口」。
```

### 6.1 断点续传成功必要条件

```
┌────────────────────────┬──────────────────────┬──────────────────────────────┐
│         参数            │      配置位置         │            说明              │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ connect-store 目录      │ /data/connect-store/ │ 必须有旧 position.json       │
│                         │                      │ (Source + Sink 位点)         │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ broker-store 目录       │ /root/store/         │ 必须有旧 commitlog +         │
│                         │                      │ consumequeue                 │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ storePathRootDir        │ conf/connect-        │ 必须指向旧 connect-store     │
│                         │ standalone.conf      │ 目录                         │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ workerId                │ conf/connect-        │   
│                         │ standalone.conf      │     
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ database.server.name    │ postgres-source.json │ position.json key 包含它      │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ slot.name               │ postgres-source.json │ 同一复制槽，WAL 还在          │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ publication.name        │ postgres-source.json │ 同一发布                      │
├────────────────────────┼──────────────────────┼──────────────────────────────┤
│ snapshot.mode           │ postgres-source.json │ 必须是 initial (不能是 always)│
└────────────────────────┴──────────────────────┴──────────────────────────────┘

⚠️ 如果 broker-store 丢失但 connect-store 完好 → 不走方案 B，走方案 A（全量快照）
   原因：Source 能从正确 LSN 续传，但 Sink 在 Broker 里找不到 gap 期间的消息
```

### 6.2 生产环境 (systemd) 操作步骤

```bash
# ==== 步骤 1：确认两个关键目录都完好 ====
# 1a. connect-store (Source + Sink 位点)
ls -la /data/connect-store/
cat /data/connect-store/config/position.json
# 记录下 LSN 值，后续验证用

# 1b. broker-store (commitlog + consumequeue) — 必须存在！
ls -la /root/store/
# 预期看到: commitlog/  consumequeue/ 等目录
# 如果这个目录是空的或不存在 → broker-store 丢失 → 不走方案 B
# → 改为方案 A 全量快照（见第 5 节）

# ==== 步骤 2：确认 connect-standalone.conf 指向正确路径 ====
grep -E 'storePathRootDir|workerId' \
  /opt/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT/conf/connect-standalone.conf

# 必须输出:
#   workerId=<与旧配置一致的值>
#   storePathRootDir=/data/connect-store

# ==== 步骤 3：确认四项关键参数与旧配置一致 ====
# database.server.name、slot.name、publication.name、snapshot.mode
cat /opt/connect-config/postgres-source.json | grep -E 'database.server.name|slot.name|publication.name|snapshot.mode'

# ==== 步骤 4：按顺序启动服务 ====
systemctl start rocketmq-namesrv
sleep 5
systemctl start rocketmq-broker
sleep 10
systemctl start rocketmq-connect
sleep 15

# ==== 步骤 5：查看 Connect 日志，确认读到旧 position.json ====
journalctl -u rocketmq-connect -n 50 --no-pager

# 预期日志中出现:
#   found position file, restoring offsets ...
#   starting incremental streaming from LSN=<旧 position.json 中记录的值>
#   (不应出现 "taking a new snapshot of the whole database")

# ==== 步骤 6：注册 Connector ====
curl -s -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/postgres-source \
  -d @/opt/connect-config/postgres-source.json

curl -s -X POST -H "Content-Type: application/json" \
  http://127.0.0.1:8082/connectors/mysql-sink \
  -d @/opt/connect-config/postgres-sink.json

# ==== 步骤 7：验证状态 ====
curl -s http://127.0.0.1:8082/connectors/postgres-source/status
curl -s http://127.0.0.1:8082/connectors/mysql-sink/status
# 期望: connector 和 tasks 状态均为 RUNNING

# ==== 步骤 8：验证数据追上 ====
# PG 行数
psql "postgresql://litellm:<密码>@10.0.1.2:5432/litellm?sslmode=disable" \
  -c 'SELECT COUNT(*) FROM public."LiteLLM_SpendLogs";'

# MySQL 行数
mysql -h <mysql-host> -uroot -p<密码> litellm \
  -e "SELECT COUNT(*) FROM LiteLLM_SpendLogs;"

# 确认停机期间的 INSERT/UPDATE/DELETE 都已同步

# ==== 步骤 9：验证 PG 复制槽 LSN 已推进 ====
psql "postgresql://litellm:<密码>@10.0.1.2:5432/litellm?sslmode=disable" -c "
SELECT slot_name, restart_lsn, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots WHERE slot_name = 'pg_litellm_slot';
"
# confirmed_flush_lsn 应该已经大于步骤 1 中记录的值
```

### 6.3 断点续传验证清单

```
┌────────────────────────┬──────────────────────────────────────────┐
│        验证点           │                 成功标志                  │
├────────────────────────┼──────────────────────────────────────────┤
│ 旧 position.json 被找到 │ 日志中出现 "found position file"          │
├────────────────────────┼──────────────────────────────────────────┤
│ 增量续传，非全量快照    │ 日志中无 "taking a new snapshot" 字样     │
├────────────────────────┼──────────────────────────────────────────┤
│ 停机期间 INSERT 追上    │ 新数据出现在 MySQL                       │
├────────────────────────┼──────────────────────────────────────────┤
│ 停机期间 UPDATE 追上    │ 字段值一致                               │
├────────────────────────┼──────────────────────────────────────────┤
│ 停机期间 DELETE 追上    │ 被删的记录在 MySQL 也不存在               │
├────────────────────────┼──────────────────────────────────────────┤
│ 复制槽推进              │ confirmed_flush_lsn > 旧值               │
└────────────────────────┴──────────────────────────────────────────┘
```

---

## 7. 方案 C：PG 服务器重启或短暂挂机

**结论：PG 重启后自动增量续传，数据不丢。**

### 7.1 发生了什么

```
PG WAL 时间线:
  ──[正常运行]──[PG 挂了/重启]──[PG 恢复]──→
                    ↑
           复制槽保留未确认的 WAL
           PG 不会回收这部分日志
```

- **复制槽是持久化的**，PG 重启后依然存在，restart_lsn 不变
- **WAL 日志不会被清理**，PG 重启后复制槽继续保留未确认的部分
- PG 重启本身不会导致数据丢失

### 7.2 Connect 恢复时判断逻辑

```
Connect 重连 PG → 读 position.json 拿到上次的 lsn
                        ↓
          PG 检查: restart_lsn ≤ source_lsn ?
            ↓                        ↓
        ✅ 是                      ❌ 否
    增量续传成功              全量快照兜底
  (只追 PG 挂掉期间的        (重扫全表，耗时但
   WAL 差异，秒级恢复)       数据不会丢)
```

### 7.3 需要关注的风险

**PG 长时间挂机导致 WAL 被清理：**

```sql
-- 监控复制槽积压（在 PG 上执行）
SELECT
    slot_name,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'pg_litellm_slot';
```

如果 lag 持续增长且 Connect 无法恢复，PG 的 WAL 可能因为以下原因被清理：
- `wal_keep_size` 达到上限
- 磁盘满触发紧急清理
- 手动执行 `VACUUM` 或删除复制槽

**一旦 restart_lsn > position.json 的 lsn → 只能走方案 A 全量快照**

### 7.4 PG 挂机时 Connect 一直尝试重连

Debezium PG connector 内置重连机制：
- 连接断开后自动重试
- 重连成功后从 position.json 记录的 LSN 续传
- PG 挂机期间积压的 WAL 变更，重连后一次性追上

---

## 8. 方案 D：MQ 服务器重启（systemd 托管，磁盘完好）

**最简单场景——开机就行。**

```bash
# 启动顺序不能错: NameServer → Broker → Connect
systemctl start rocketmq-namesrv
sleep 5
systemctl start rocketmq-broker
sleep 10
systemctl start rocketmq-connect

# 验证 Connector 自动恢复
curl -s http://127.0.0.1:8082/connectors/postgres-source/status
curl -s http://127.0.0.1:8082/connectors/mysql-sink/status

# 查看日志确认增量追赶
journalctl -u rocketmq-connect -n 20 --no-pager
```

systemd 配置了 `Restart=on-failure` 和 `RestartSec`，通常服务器重启后会自动拉起。

---

## 9. 方案 E：PG 数据损毁——PITR 时间点恢复

**适用场景：** PG 数据被误删、表被 DROP、需要恢复到某个历史时间点

### 9.1 原理

```
不会影响生产库！整个恢复过程在独立临时实例上进行。

你的生产库:   正常读写，完全不触碰
基础备份+WAL: 历史数据的「副本」
临时实例:     全新的、独立的 PG 库，仅用于恢复历史快照

PITR 恢复时:
基础备份 + 逐条回放 WAL → 每遇到一条 WAL，检查其时间戳
→ 时间戳 < recovery_target_time → 应用这条变更
→ 时间戳 >= recovery_target_time → 停止
```

### 9.2 前置条件

PG 已开启 WAL 归档（生产 PG 上 `wal_level=logical` 且已启用 archive_mode）：

```sql
-- 在 PG (10.0.1.2) 上验证
SHOW wal_level;           -- 必须是 logical
SHOW archive_mode;        -- 必须是 on
SHOW archive_command;     -- 必须有有效的归档命令

-- 查看归档目录中已有 WAL 文件
SELECT * FROM pg_ls_waldir() ORDER BY modification DESC LIMIT 10;
```

定期执行基础备份（生产环境中应配置 cron 或 pg_basebackup 定时任务）。

### 9.3 恢复步骤

```bash
# ==== 步骤 1：确认备份可用 ====
ls -la pitr_backups/
# 找到挂机时间点之前最新的备份目录

# ==== 步骤 2：准备恢复目录 ====
cp -a pitr_backups/挂机前最新备份 recovery_data

# ==== 步骤 3：创建恢复信号文件 ====
touch recovery_data/recovery.signal

# ==== 步骤 4：配置恢复参数 ====
echo "restore_command = 'cp /var/lib/postgresql/data/archive/%f %p'" \
  >> recovery_data/postgresql.conf

echo "recovery_target_time = '2026-06-03 09:00:00'" \
  >> recovery_data/postgresql.conf

echo "recovery_target_action = 'pause'" \
  >> recovery_data/postgresql.conf

# ==== 步骤 5：启动恢复实例（不同端口，避免冲突）====
su - postgres -c 'pg_ctl -D recovery_data -p 5433 start'

# ==== 步骤 6：查询快照数据 ====
psql -p 5433 -c "SELECT * FROM LiteLLM_SpendLogs ORDER BY startTime DESC LIMIT 100;"

# ==== 步骤 7：查看数据后导出或删除临时实例 ====
pg_dump -p 5433 ... > recovery_dump.sql

# 用完删除临时实例
su - postgres -c 'pg_ctl -D recovery_data stop'
rm -rf recovery_data
```

### 9.4 有 created_at 字段时的精确快照

如果表有 `created_at` 字段，直接查时间点数据：

```sql
-- 在临时恢复实例上执行
SELECT * FROM LiteLLM_SpendLogs
WHERE "startTime" <= '2026-06-03 09:00:00'
ORDER BY "startTime" DESC;
```

---

## 10. PostgreSQL 复制槽监控

### 10.1 日常监控命令

```sql
-- 查看所有复制槽详细信息
SELECT * FROM pg_replication_slots;

-- 查看活跃的 WAL 发送进程
SELECT * FROM pg_stat_replication;

-- 查看复制槽积压（核心监控）
SELECT
    slot_name,
    restart_lsn,
    confirmed_flush_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_pretty
FROM pg_replication_slots
WHERE slot_name = 'pg_litellm_slot';
```

### 10.2 积压告警阈值

```
lag < 100MB   →  正常
lag 100MB-1GB →  关注，检查 Connect 状态
lag > 1GB     →  告警，Connect 可能已挂
lag > 10GB    →  紧急，PG 磁盘有撑爆风险
```

### 10.3 应急措施——积压过大时

```bash
# 如果 Connect 短期无法恢复，且 PG 磁盘告急：
# 删除复制槽释放磁盘（数据不会丢，WAL 在 PG 数据文件里安全）

psql -h 10.0.1.2 -U litellm -d litellm -c \
  "SELECT pg_drop_replication_slot('pg_litellm_slot');"

# 之后恢复时走方案 A 全量快照重建
```

---

## 11. 日常运维检查清单

### 11.1 每日检查

```bash
# 1. 检查服务状态
systemctl status rocketmq-namesrv rocketmq-broker rocketmq-connect

# 2. 检查 Connector 状态
curl -s http://127.0.0.1:8082/connectors/list
curl -s http://127.0.0.1:8082/connectors/postgres-source/status
curl -s http://127.0.0.1:8082/connectors/mysql-sink/status

# 3. 行数对比
# PG:
psql -h 10.0.1.2 -U litellm -d litellm \
  -c 'SELECT COUNT(*) FROM public."LiteLLM_SpendLogs";'
# MySQL:
mysql -h <mysql-host> -uroot -p<pass> litellm \
  -e "SELECT COUNT(*) FROM LiteLLM_SpendLogs;"
```

### 11.2 每周检查

```bash
# 备份 position.json (替换 <workerId> 为实际值)
cp /data/connect-store/config/position.json \
   /backup/position_$(date +%Y%m%d).json

# 备份 MySQL
mysqldump -h <mysql-host> -uroot -p<pass> litellm \
  > /backup/mysql_litellm_$(date +%Y%m%d).sql
```

### 11.3 监控日志

```bash
journalctl -u rocketmq-namesrv -n 20 --no-pager
journalctl -u rocketmq-broker -n 20 --no-pager
journalctl -u rocketmq-connect -n 50 --no-pager
```

---

## 12. 生产配置关键参数速查

```
┌────────────────────────────┬──────────────────────────────────────────┐
│           配置项            │                  值                      │
├────────────────────────────┼──────────────────────────────────────────┤
│ PG host                    │ 10.0.1.2:5432                             │
│ PG 库/用户                 │ litellm / litellm                        │
│ PG 复制槽                  │ pg_litellm_slot                          │
│ PG 发布                    │ pg_litellm_pub                           │
│ PG 目标表                  │ public.LiteLLM_SpendLogs                  │
│ RocketMQ Topic             │ debezium-pg                     │
│ Connect REST               │ http://127.0.0.1:8082                    │
│ connect-store 路径         │ /data/connect-store                      │
│ MQ 安装路径                │ /opt/rocketmq-5.3.2                      │
│ Connector 插件路径         │ /usr/local/connector-plugins              │
│ Source Connector 类        │ ...debezium.postgres.DebeziumPostgresConnector │
│ Sink Connector 类          │ ...jdbc.sink.JdbcSinkConnector            │
│ Sink 写入模式              │ UPSERT（幂等）                            │
└────────────────────────────┴──────────────────────────────────────────┘
```

---

## 13. 建议的备份策略

```
┌─────────────────┬──────────────────┬─────────────────────────────┐
│     备份内容     │      频率        │          说明               │
├─────────────────┼──────────────────┼─────────────────────────────┤
│ position.json   │ 每天             │ 20KB 小文件，异地保存        │
├─────────────────┼──────────────────┼─────────────────────────────┤
│ MySQL 全量备份   │ 每天             │ mysqldump，保留 7 天         │
├─────────────────┼──────────────────┼─────────────────────────────┤
│ PG 基础备份     │ 每天 (cron)      │ pg_basebackup 定时任务       │
├─────────────────┼──────────────────┼─────────────────────────────┤
│ /data/connect-  │ 每天             │ 整个 connect-store 目录      │
│ store 目录       │                  │ tar + 异地保存               │
├─────────────────┼──────────────────┼─────────────────────────────┤
│ /root/store     │ 每周 / 变更前    │ Broker commitlog + consumeq  │
│                 │                  │                              │
└─────────────────┴──────────────────┴─────────────────────────────┘
```

---

## 14. 应急决策流程图

```
                              ┌─────────────────────┐
                              │   同步链路出问题了    │
                              └──────────┬──────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
             PG 挂了？            MQ 服务器挂了？         MySQL 挂了？
                    │                    │                    │
          ┌─────────┴────────┐    ┌─────┴─────┐      ┌─────┴─────┐
          ▼                  ▼    ▼           ▼      ▼           ▼
       PG 重启           PG损毁  能自动     需要手动   重启MySQL  数据损毁
          │                  │   重启？     恢复？       │           │
          ▼                  ▼    │           │        ▼           ▼
   自动增量续传          方案 E   ▼           ▼    自动恢复    从 PG
  (slot+WAL 都在)       PITR恢复  方案 D       │   (UPSERT    全量快照
   Connect 重连后        到挂机前 systemd      │    幂等)      重建
   自动追上积压WAL        时间点  自动拉起     │
                        (见第9节) (见第8节)    ▼
                                        ┌──────────────┐
                                        │ 检查两个 store │
                                        └──────┬───────┘
                                               │
                              ┌────────────────┴────────────────┐
                              ▼                                 ▼
                    connect-store + broker-store     只 connect-store 完好
                        都完好                              │
                              │                      broker-store 丢失
                              ▼                                 │
                          方案 B                               ▼
                     断点续传(第6节)                       方案 A
                   Source 读 position.json            全量快照(第5节)
                   Sink 读 commitlog                 删 position.json
                   秒级恢复，零丢失                  snapshot=always
                                                     慢但数据不丢
```

---

## 附录 A：RocketMQ 安装脚本（systemd）

```bash
# 安装 RocketMQ 5.3.2
cd /opt
wget https://archive.apache.org/dist/rocketmq/5.3.2/rocketmq-all-5.3.2-bin-release.zip
unzip rocketmq-all-5.3.2-bin-release.zip
ln -s rocketmq-all-5.3.2-bin-release rocketmq-5.3.2

# 创建 rocketmq-namesrv.service
cat > /etc/systemd/system/rocketmq-namesrv.service << 'EOF'
[Unit]
Description=Apache RocketMQ NameServer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rocketmq-5.3.2

Environment=JAVA_HOME=/usr/lib/jvm/java-21-konajdk-21.0.10-1.oc9
Environment=PATH=/usr/lib/jvm/java-21-konajdk-21.0.10-1.oc9/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
Environment=ROCKETMQ_HOME=/opt/rocketmq-5.3.2
Environment="JAVA_OPT_EXT=-server -Xms512m -Xmx512m -Xmn256m"

ExecStart=/bin/sh -c 'unset JAVA_OPT; exec /opt/rocketmq-5.3.2/bin/mqnamesrv'

Restart=on-failure
RestartSec=10
LimitNOFILE=655350
TimeoutStopSec=120

StandardOutput=journal
StandardError=journal
SyslogIdentifier=rocketmq-namesrv

[Install]
WantedBy=multi-user.target
EOF

# 创建 rocketmq-broker.service
cat > /etc/systemd/system/rocketmq-broker.service << 'EOF'
[Unit]
Description=Apache RocketMQ Broker with Proxy
After=network-online.target rocketmq-namesrv.service
Wants=network-online.target
Requires=rocketmq-namesrv.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rocketmq-5.3.2

Environment=JAVA_HOME=/usr/lib/jvm/java-21-konajdk-21.0.10-1.oc9
Environment=PATH=/usr/lib/jvm/java-21-konajdk-21.0.10-1.oc9/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
Environment=ROCKETMQ_HOME=/opt/rocketmq-5.3.2
Environment=NAMESRV_ADDR=127.0.0.1:9876
Environment="JAVA_OPT_EXT=-server -Xms1g -Xmx1g -Xmn512m"

ExecStart=/bin/sh -c 'unset JAVA_OPT; exec /opt/rocketmq-5.3.2/bin/mqbroker -n 127.0.0.1:9876 --enable-proxy'

Restart=on-failure
RestartSec=15
LimitNOFILE=655350
TimeoutStopSec=120
KillMode=control-group

StandardOutput=journal
StandardError=journal
SyslogIdentifier=rocketmq-broker

[Install]
WantedBy=multi-user.target
EOF

# 创建 rocketmq-connect.service
cat > /etc/systemd/system/rocketmq-connect.service << 'EOF'
[Unit]
Description=Apache RocketMQ Connect Standalone
After=network-online.target rocketmq-broker.service
Wants=network-online.target
Requires=rocketmq-broker.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rocketmq-connect/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT

Environment=JAVA_HOME=/usr/lib/jvm/java-21-konajdk-21.0.10-1.oc9
Environment=PATH=/usr/lib/jvm/java-21-konajdk-21.0.10-1.oc9/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
Environment="JAVA_OPT_EXT=-server -Xms512m -Xmx1g -Xmn256m"

ExecStart=/bin/sh -c 'unset JAVA_OPT; exec bin/connect-standalone.sh -c conf/connect-standalone.conf'

Restart=on-failure
RestartSec=20
LimitNOFILE=655350
TimeoutStopSec=120

StandardOutput=journal
StandardError=journal
SyslogIdentifier=rocketmq-connect

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动
systemctl daemon-reload
systemctl enable rocketmq-namesrv rocketmq-broker rocketmq-connect
systemctl start rocketmq-namesrv
```

---

## 附录 B：connector 注册报文

### Source (PG)
```json
{
  "connector.class": "org.apache.rocketmq.connect.debezium.postgres.DebeziumPostgresConnector",
  "max.task": "1",
  "connect.topicname": "debezium-pg",
  "kafka.transforms": "Reroute,Unwrap",
  "kafka.transforms.Reroute.type": "io.debezium.transforms.ByLogicalTableRouter",
  "kafka.transforms.Reroute.topic.regex": ".*",
  "kafka.transforms.Reroute.topic.replacement": "debezium-pg",
  "kafka.transforms.Unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "kafka.transforms.Unwrap.delete.handling.mode": "none",
  "kafka.transforms.Unwrap.add.headers": "op,source.db,source.table",
  "snapshot.mode": "initial",
  "database.server.name": "pg_litellm",
  "database.port": "5432",
  "database.hostname": "10.0.1.2",
  "database.connectionTimeZone": "UTC",
  "database.user": "litellm",
  "database.dbname": "litellm",
  "database.password": "<生产密码>",
  "plugin.name": "pgoutput",
  "publication.name": "pg_litellm_pub",
  "slot.name": "pg_litellm_slot",
  "table.whitelist": "public.LiteLLM_SpendLogs",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```

### Sink (MySQL)
```json
{
  "connector.class": "org.apache.rocketmq.connect.jdbc.sink.JdbcSinkConnector",
  "max.task": "1",
  "connect.topicnames": "debezium-pg",
  "connection.url": "jdbc:mysql://<mysql-host>:3306/litellm?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Shanghai&nullCatalogMeansCurrent=true",
  "connection.user": "root",
  "connection.password": "<生产密码>",
  "pk.fields": "request_id",
  "pk.mode": "record_key",
  "insert.mode": "UPSERT",
  "delete.enabled": "true",
  "table.name.from.header": "true",
  "db.timezone": "UTC",
  "table.types": "TABLE",
  "task.group.id": "mysql-sink-group",
  "errors.deadletterqueue.topic.name": "dlq-topic",
  "errors.log.enable": "true",
  "errors.tolerance": "ALL",
  "key.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter",
  "value.converter": "org.apache.rocketmq.connect.runtime.converter.record.json.JsonConverter"
}
```
