● 这是个关键的容错性问题。从架构上逐层分析：

  数据会不会丢失？

  取决于 哪个组件挂了 以及 Offset 是否持久化：

  时间线:  ──A(MQ挂)──────────B(MQ恢复)──→
  PG WAL:  ██████████████████████████████  (持续产生变更)
  Slot:    ██████████████████████████████  (保留未消费的 LSN)
  MQ:      ──✗ 停止接收 ───────── ✓ 恢复

  核心机制：PG 复制槽 = 天然的水位标记

  PG 的 Replication Slot 记录了 Debezium 消费到哪个 LSN。MQ 宕机期间：
  - PG 继续产生 WAL 日志
  - 复制槽保留未消费的 WAL（PG 不会回收这部分日志）
  - MQ 恢复后，Source Connector 从上次 Offset（LSN）继续读 → 理论上不会丢

  但当前配置有一个隐患

  看你的 connect-standalone.conf：

  storePathRootDir=/tmp/connect-store

  /tmp 在容器重启后清空。如果 Connect 容器也重启了，Offset 就丢了：

  ┌──────────────────────────┬─────────────┬───────────────────────────────┐
  │         故障场景         │   Offset    │             结果              │
  │                          │   还在？    │                               │
  ├──────────────────────────┼─────────────┼───────────────────────────────┤
  │ 仅 MQ 宕机，Connect      │ ✅ 在内存中 │ Debezium 暂停推送，MQ         │
  │ 保持运行                 │             │ 恢复后继续                    │
  ├──────────────────────────┼─────────────┼───────────────────────────────┤
  │ MQ 宕机 + Connect 也重启 │  ❌ /tmp    │ Offset 丢失，不知道读到哪了   │
  │                          │    清空     │                               │
  ├──────────────────────────┼─────────────┼───────────────────────────────┤
  │ docker compose down + up │ ❌ 容器重建 │ Offset 丢失                   │
  └──────────────────────────┴─────────────┴───────────────────────────────┘

  但当前配置恰好有个"粗暴的补救"

  connectors/pg-src-prod.json 中：

  "snapshot.mode": "always"

  每次 Connector 启动都做全量快照，把 PG 现有数据全部重新同步到 MQ →
  MySQL。这意味着即使 Offset 丢了，重启后全量兜底，A~B 之间的数据不会丢。

  代价是：全量快照耗时，表大了会很慢。

  ---
  更优的方案

  方案 1：持久化 Offset（治本）

  修改 connect-standalone.conf，把 storePathRootDir 改为持久化目录：

  storePathRootDir=/opt/rocketmq-connect/store

  并在 docker-compose.yml 中挂载 volume：

  rmq-connect:
    volumes:
      - connect-store:/opt/rocketmq-connect/store

  同时 snapshot.mode 改为 initial（仅首次全量，重启后增量续传）：

  "snapshot.mode": "initial"

  方案 2：如果 Offset 丢了，手动补数据

  如果 A~B 期间数据确实丢了，可以通过时间范围从 PG 导出差异数据手动写入 MySQL：

  -- PG 端导出 A~B 期间的变更（需要有 updated_at 索引）
  SELECT * FROM public.orders WHERE updated_at >= '2026-06-01 10:00:00';

  -- 或做全表对比
  -- PG:
  SELECT order_id, MD5(ROW(...)::TEXT) FROM public.orders;
  -- MySQL:
  SELECT order_id, MD5(CONCAT(...)) FROM target_db.orders;

  方案 3：监控复制槽积压（预警）

  docker exec pg-source psql -U source_user -d source_db -c "
  SELECT slot_name,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS 
  lag
  FROM pg_replication_slots WHERE slot_name = 'pg_orders_slot'
  "

  如果 lag 持续增长，说明消费端出问题了。

  ---
  总结建议

  ┌────────┬──────────────────────────┬──────────────────────────────────────┐
  │ 优先级 │           操作           │                 效果                 │
  ├────────┼──────────────────────────┼──────────────────────────────────────┤
  │        │ storePathRootDir         │                                      │
  │   🔴   │ 改为持久化目录 + 挂载    │ Offset 持久化，重启不丢              │
  │        │ volume                   │                                      │
  ├────────┼──────────────────────────┼──────────────────────────────────────┤
  │   🟡   │ snapshot.mode 改为       │ 首次全量，后续增量，避免每次重启全扫 │
  │        │ initial                  │                                      │
  ├────────┼──────────────────────────┼──────────────────────────────────────┤
  │   🟢   │ 加复制槽 lag 监控        │ 提前发现问题                         │
  └────────┴──────────────────────────┴──────────────────────────────────────┘

  这样 A~B 期间的数据通过 PG 复制槽天然保留，Connect
  恢复后增量续传，不会丢失，也不需要全量快照兜底。

  需要我帮你改这两处配置吗？

✻ Cooked for 58s

※ recap: PostgreSQL → MySQL CDC 实时同步，6 个 Docker 容器全部正常运行，两个 Connector 状态均为 RUNNING，数据已同步 19 行。

  Connect 重启 → position.json 在哪？
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
      /tmp 清空了，找不到                    /opt volume 持久化，找到了
              │                                 │
              ▼                                 ▼
     Debezium: "我不知道上次读到哪"        Debezium: "上次读到 LSN=26998584"
              │                                 │
              ▼                                 ▼
     snapshot.mode=initial 判断:          snapshot.mode=initial 判断:
     "没有 offset → 这是新部署"            "有 offset → 继续增量"
              │                                 │
              ▼                                 ▼
         触发全量快照                        增量续传
     PG 全表重扫 → 全部重发 MQ            PG WAL 积压部分 → 只发差异
              │                                 │
              ▼                                 ▼
         MySQL UPSERT 覆盖                  MySQL UPSERT 覆盖
          ✅ 数据恢复了                      ✅ 数据恢复了

  结果一样，方式不同：

  ┌──────────┬──────────────────────┬───────────────────┐
  │          │    /tmp + initial    │  /opt + initial   │
  ├──────────┼──────────────────────┼───────────────────┤
  │ 数据恢复 │  ✅ 能（全量快照）   │ ✅ 能（增量续传） │
  ├──────────┼──────────────────────┼───────────────────┤
  │ 恢复方式 │ 扫全表、重发全部消息 │ 只读 WAL 差异部分 │
  ├──────────┼──────────────────────┼───────────────────┤
  │ 恢复速度 │  慢（取决于表大小）  │    快（秒级）     │
  ├──────────┼──────────────────────┼───────────────────┤
  │ PG 压力  │          大          │        小         │
  └──────────┴──────────────────────┴───────────────────┘

  所以准确的说法是：/tmp 丢 position
  后不是数据丢了，而是恢复手段退化成了全量快照。表里有 10 万行就重扫 10
  万行，表里有 1000 万行就重扫 1000 万行。而持久化 volume 的方案只需要追 A~B
  之间几条 WAL 记录。
