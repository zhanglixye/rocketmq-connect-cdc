# PG → RocketMQ → MySQL CDC 数据流全景图

## 一、核心组件关系总览

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    CDC 数据同步流水线                                            │
│                                                                                                │
│   ┌──────────┐     WAL 流      ┌─────────────────┐    RocketMQ 消息     ┌─────────────────┐     │
│   │PostgreSQL│ ───────────────→│  Source Task    │────────────────────→│   Sink Task     │     │
│   │  (源库)  │                 │  (Debezium PG)  │                     │  (JDBC Sink)    │     │
│   │          │                 │                 │                     │                 │     │
│   │ orders表│                 │ 读 WAL → 转 JSON│                     │ 消费消息→写MySQL│     │
│   └────┬─────┘                 └────────┬────────┘                     └────────┬────────┘     │
│        │                                │                                       │              │
│        │                                │                                       │              │
│        ▼                                ▼                                       ▼              │
│  ┌───────────┐                  ┌──────────────┐                        ┌──────────┐           │
│  │复制槽     │                  │connect-store │                        │  MySQL   │           │
│  │pg_orders  │                  │position.json │                        │ (目标库) │           │
│  │_slot      │                  │              │                        │          │           │
│  │           │                  │pg-source 偏移│                        │ orders表 │           │
│  │restart_lsn│                  │mysql-sink偏移│                        └──────────┘           │
│  │confirmed  │                  └──────────────┘                                               │
│  │_flush_lsn │                                                                                 │
│  └───────────┘                                                                                 │
│                                                                                                │
│   ┌───────────┐                                                                                │
│   │  Broker   │  存着 Source 已发但 Sink 未消费的消息队列                                        │
│   │           │  commitlog + consumequeue                                                       │
│   └───────────┘                                                                                │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、WAL 流中三个关键 LSN

```
 PG WAL (一条无限长的字节流)
 ═══════════════════════════════════════════════════════════════════════════════→ 时间

  ... [已清理区] ... │  [保留区: 等待被读取]  │  [积压区: 已读未确认] │  [当前写入] ...
                     ↑                         ↑                        ↑
                 restart_lsn             confirmed_flush_lsn      pg_current_wal_lsn
                (PG 的安全底线)           (Debezium 说"我确认        (PG 正在写的位置)
                再往前 WAL 被           到这了，前面的可以
                VACUUM 清理了)           安全清理")
                     │                         │
                     │←─── 复制槽保留的 WAL ───→│
                     │      (这段绝对不能丢)      │
                     │                         │
                     │← lag_bytes →│            │
                     │  (如果太大说明消费跟不上)   │
                     │                         │
                     │←─── 如果 Connect 挂了 ───→│
                     │    这部分 WAL 还在，重启后  │
                     │    可以续传                  │


  字段对照:
  ┌──────────────────────┬────────────────────┬──────────────────────────────────┐
  │       字段            │      含义           │              类比                │
  ├──────────────────────┼────────────────────┼──────────────────────────────────┤
  │ restart_lsn           │ WAL 保留的起点      │ 水位线—PG 保证这之后的 WAL       │
  │                       │                     │ 都在，前面的可能被清理了          │
  ├──────────────────────┼────────────────────┼──────────────────────────────────┤
  │ confirmed_flush_lsn   │ Debezium 确认到     │ "我收到了，前面的可以清了"        │
  │                       │ 的位置              │ PG 据此移动 restart_lsn          │
  ├──────────────────────┼────────────────────┼──────────────────────────────────┤
  │ pg_current_wal_lsn    │ PG 当前写到的位置    │ 最新数据在的位置                  │
  ├──────────────────────┼────────────────────┼──────────────────────────────────┤
  │ lag_bytes             │ restart→current     │ 复制槽积压量，如果持续增长        │
  │                       │ 之间的字节数         │ 说明消费端出问题了                │
  └──────────────────────┴────────────────────┴──────────────────────────────────┘
```

---

## 三、Source Task 工作流程

```
     ┌─────────┐
     │ PG 复制槽│
     │pg_orders │
     │  _slot   │
     └────┬─────┘
          │
          │ 流式推送 WAL (从上次记录的 LSN 开始)
          ▼
┌───────────────────────────────────────────────────────┐
│                  Source Task (Debezium)                │
│                                                       │
│  1. 启动时: 读 position.json → 拿到上次的 LSN          │
│             向 PG 请求从 LSN 开始流式推送               │
│                                                       │
│  2. 运行中: 接收 WAL 事件                              │
│             解析 → INSERT/UPDATE/DELETE                │
│             转成 JSON 消息                              │
│             发布到 RocketMQ Topic: debezium-pg-source    │
│                                                       │
│  3. 定期:   发送 standby status update 给 PG            │
│             → PG 更新 confirmed_flush_lsn               │
│             写入 position.json (更新 source offset)      │
│                                                       │
│  4. 崩溃恢复: position.json 中的 lsn 是续传起点        │
│              │                                         │
│              ├─ lsn ≥ restart_lsn → ✅ 增量续传         │
│              └─ lsn < restart_lsn → ❌ 全量重扫         │
└───────────────────────────────────────────────────────┘
          │
          │ 发布 JSON 消息
          ▼
┌──────────────────┐      ┌──────────────────────┐
│  RocketMQ Broker │      │ connect-store 卷     │
│                  │      │                      │
│  Topic:          │      │ position.json:       │
│  debezium-pg-    │      │ {                    │
│  source          │      │   "lsn": 687865952,  │ ← "我读到这了"
│                  │      │   "lsn_commit":...,  │ ← "我确认到这了"
│  [msg1][msg2]... │      │   "txId": 1002       │
│                  │      │ }                    │
└────────┬─────────┘      └──────────────────────┘
         │
         │ Sink Task 从这里消费
         ▼
┌───────────────────────────────────────────────────────┐
│                  Sink Task (JDBC)                      │
│                                                       │
│  1. 消费 Topic: debezium-pg-source 中的消息             │
│                                                       │
│  2. 解析 JSON → 生成 SQL                               │
│     INSERT → UPSERT (INSERT ON DUPLICATE KEY UPDATE)   │
│     UPDATE → UPSERT                                    │
│     DELETE → DELETE                                    │
│                                                       │
│  3. 定期: 写入 position.json (更新 sink offset)         │
│                                                       │
│  4. 写入 MySQL                                         │
└───────────────────────────────────────────────────────┘
          │
          ▼
   ┌──────────┐
   │  MySQL   │
   │ orders 表│
   └──────────┘
```

---

## 四、Broker 在中间的角色

```
                        RocketMQ Broker
                  ┌─────────────────────────┐
                  │  Topic: debezium-pg-    │
                  │         source           │
                  │                         │
  Source ────────→│ [msg_a][msg_b][msg_c]   │────────→ Sink
  发布             │                         │          消费
                  │  commitlog (持久化)      │
                  │  consumequeue (索引)     │
                  │                         │
                  │ ←── Source 已发          │
                  │      Sink 未消费 ──→      │
                  └─────────────────────────┘

  关键窗口: Source offset 推进了 ≠ Sink offset 也推进了

  时间线:
  ═══════════════════════════════════════════════════════→
  t1: Source 读 WAL → 转 msg_a → 发到 Broker
  t2: Source 写 position.json: lsn=N+1 (source offset 推进)
  t3: Sink 从 Broker 拉取 msg_a
  t4: Sink 写 MySQL
  t5: Sink 写 position.json: offset+1 (sink offset 推进)
  
        t2             t5
        │←── gap ───→│
        │             │
   Source 已推进       Sink 才追上
   如果 Broker 在 t2~t5 之间崩溃且卷丢失:
   → msg_a 丢失
   → Source 不会再重发 (position.json 认为已经发了)
   → MySQL 少了这条数据
```

---

## 五、重启恢复决策树

```
                      新 Connect 启动
                           │
                           ▼
              读 connect-store/position.json
                           │
                           ▼
                 拿到上次的 source lsn
                           │
                           ▼
           向 PG 请求从 source lsn 开始流式推送
                           │
                           ▼
                 PG 检查: restart_lsn ≤ source lsn ?
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
             是                         否
             │                          │
             ▼                          ▼
   WAL 还在，直接续传            WAL 已被清理
             │                          │
             ▼                          ▼
   从 source lsn 开始            snapshot.mode 决定:
   流式推送增量                  │
             │                  ├─ initial → 触发全量快照
             ▼                  │   (因为"没有 offset 能匹配")
   ✅ 断点续传成功               │
   只同步 crash 期间             ├─ always → 每次都全量快照
   积压的 WAL 数据               │
                                └─ never → 只从当前 WAL 往后读
                                              (crash 期间数据丢失)


  重启成功的必要条件:
  ┌──────────────────────────────────────────────────┐
  │  1. connect-store 卷  →  position.json 没丢      │
  │  2. workerId 不变      →  能找到 position.json   │
  │  3. database.server    →  position.json key 匹配 │
  │     .name 不变                                    │
  │  4. slot.name 不变     →  同一复制槽，WAL 还在   │
  │  5. restart_lsn ≤      →  PG 复制槽里 WAL 没被清 │
  │     source lsn                                    │
  │  6. snapshot.mode      →  必须是 initial，不能是  │
  │     = initial            always (会跳过续传直接    │
  │                          全量扫)                  │
  └──────────────────────────────────────────────────┘
```

---

## 六、五个 LSN 的位置关系全景图

```
PG WAL 字节流: [0]────[restart_lsn]────[confirmed_flush_lsn]────[position.json lsn]────[current_wal_lsn]────→

                │          │                      │                        │                    │
                │    ┌─────┘                      │                        │                    │
                │    │          ┌─────────────────┘                        │                    │
                │    │          │              ┌───────────────────────────┘                    │
                │    │          │              │              ┌─────────────────────────────────┘
                │    │          │              │              │
                ▼    ▼          ▼              ▼              ▼

┌───────────────┬────┬──────────────────────┬─────────────────────┬──────────────┬──────────────────┐
│   WAL 区域    │已清理│    保留区            │    积压区            │  position   │   未读区         │
│               │     │  (WAL 保证存在)       │  (读到但未确认)      │  .json 已   │   (PG 新写入)    │
│               │     │                      │                     │  记录        │                  │
├───────────────┼────┼──────────────────────┼─────────────────────┼──────────────┼──────────────────┤
│  负责组件     │ PG │     PG 复制槽          │   Source Task       │ Source Task │      PG          │
│               │    │   (pg_orders_slot)    │   (Debezium)        │ (connect-   │                  │
│               │    │                      │                     │   store)    │                  │
├───────────────┼────┼──────────────────────┼─────────────────────┼──────────────┼──────────────────┤
│  对应 LSN     │ <  │   restart_lsn        │ confirmed_flush_lsn │ lsn (position│ pg_current_wal_  │
│               │    │                      │                     │   .json)    │ lsn              │
├───────────────┼────┼──────────────────────┼─────────────────────┼──────────────┼──────────────────┤
│  SQL 查询     │ —  │ restart_lsn          │ confirmed_flush_lsn │ — (查        │ pg_current_wal_  │
│               │    │                      │                     │ position.json│ lsn()            │
├───────────────┼────┼──────────────────────┼─────────────────────┼──────────────┼──────────────────┤
│  作用         │ —  │ WAL 安全底线          │ 告诉 PG 可以        │ 重启续传的    │ PG 最新数据       │
│               │    │ 低于此的 WAL 可能     │ 清理到哪了           │ 起点          │ 位置             │
│               │    │ 已被 VACUUM 回收      │                     │              │                  │
└───────────────┴────┴──────────────────────┴─────────────────────┴──────────────┴──────────────────┘
```

---

## 七、数据一致性保障层级

```
            Layer 1: PG 复制槽 (restart_lsn ~ current_wal_lsn)
            ════════════════════════════════════════════════════
            最底层保障。只要 WAL 没被清，所有数据都能重放。

            Layer 2: connect-store position.json (source offset)
            ════════════════════════════════════════════════════
            记录 Source "WAL 读到哪了"。重启时从这里续传。
            → 丢了 = 只能全量重扫

            Layer 3: RocketMQ Broker (commitlog)
            ════════════════════════════════════════════════════
            存着 Source 已发但 Sink 未消费的消息。
            → 丢了 = source-sink offset gap 期间数据丢失

            Layer 4: connect-store position.json (sink offset)
            ════════════════════════════════════════════════════
            记录 Sink "消息消费到哪了"。重启时避免重复消费。
            → 丢了 = 可能重复消费 (UPSERT 天然幂等，问题不大)

            Layer 5: MySQL 目标库
            ════════════════════════════════════════════════════
            最终目的地。数据到这就算"交付完成"。
```

---

## 八、关键 SQL 与 position.json 对照速查

```sql
-- 查看复制槽状态 (在 PG 容器内执行)
SELECT
    slot_name,
    restart_lsn,                                 -- PG 保留 WAL 的起点
    confirmed_flush_lsn,                          -- Debezium 确认的位置
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS pending_bytes
FROM pg_replication_slots
WHERE slot_name = 'pg_orders_slot';
```

```bash
# 查看 Connect 记录的位置 (在宿主机执行)
docker exec rmq-connect cat /opt/rocketmq-connect/store/DockerWorker01/pg-source/position.json
```

对照关系：
```
position.json 里的 lsn_commit  ≈  confirmed_flush_lsn
position.json 里的 lsn          =  下次重启的续传起点
restart_lsn                     =  安全底线 (lsn 必须 ≥ restart_lsn 才能续传)
pg_current_wal_lsn()            =  PG 当前写到的位置
```
