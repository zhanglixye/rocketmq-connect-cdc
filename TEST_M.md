  手动验证步骤

  第一步：重建 Connect 容器（使配置生效）

  cd D:/zlx_program/rockermq-connect/rocketmq-connect-cdc

  # 停止并删除旧 Connect 容器
  docker compose stop rmq-connect
  docker compose rm -f rmq-connect

  # 重新启动（会使用新配置和挂载 volume）
  docker compose up -d rmq-connect

  # 等待启动完成
  sleep 30

  第二步：确认 volume 已挂载 + 配置生效

  # 检查 store 目录是否存在（不再在 /tmp 下）
  docker exec rmq-connect ls -la /opt/rocketmq-connect/store/

  # 确认 connect-store volume 已挂载
  docker volume ls | grep connect-store

  第三步：重建 Connector（使用新配置 snapshot.mode=initial）

  # 删除旧 Connector
  curl -s -X DELETE http://localhost:8082/connectors/pg-source
  curl -s -X DELETE http://localhost:8082/connectors/mysql-sink

  # 重建 Source（snapshot.mode=initial，首次启动会做全量快照）
  curl -s -X POST -H "Content-Type: application/json" \
    -d @connectors/pg-src-prod.json \
    http://localhost:8082/connectors/pg-source

  sleep 15

  # 重建 Sink
  curl -s -X POST -H "Content-Type: application/json" \
    -d @connectors/mysql-sink-prod.json \
    http://localhost:8082/connectors/mysql-sink

  sleep 15

  第四步：确认状态正常

  # 两个 Connector 都 RUNNING
  curl -s http://localhost:8082/connectors/pg-source/status
  curl -s http://localhost:8082/connectors/mysql-sink/status

  # 复制槽激活
  docker exec pg-source psql -U source_user -d source_db -c \
    "SELECT slot_name, active FROM pg_replication_slots WHERE slot_name = 
  'pg_orders_slot'"

  # PG 和 MySQL 行数一致
  docker exec pg-source psql -U source_user -d source_db -t -c "SELECT COUNT(*) 
  FROM public.orders"
  docker exec mysql-target mysql -uroot -proot_pass target_db -sN -e "SELECT 
  COUNT(*) FROM orders"

  第五步：验证 Offset 持久化（核心验证）

  5.1 记录当前 Offset：

  docker exec rmq-connect ls -la /opt/rocketmq-connect/store/

  应该看到类似 DockerWorker01 目录，里面有持久化的 offset 文件。

  5.2 模拟 MQ 宕机 — 只停 Broker：

  docker compose stop rmq-broker rmq-proxy

  此时 Source Connector 会暂停推送（连不上 Broker），但 Debezium 仍连着 PG
  复制槽。

  5.3 在 PG 写入 A~B 期间的测试数据：

  docker exec pg-source psql -U source_user -d source_db -c "
  INSERT INTO public.orders (order_id, product_name, quantity, price, status, 
  created_at, updated_at)
  VALUES (7001, 'MQ-Down-Test-A', 1, 1.00, 'pending', now(), now())
  "

  5.4 查看 PG 复制槽积压（MQ 宕机期间的数据暂存在 WAL 中）：

  docker exec pg-source psql -U source_user -d source_db -c "
  SELECT slot_name, active,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS 
  lag
  FROM pg_replication_slots WHERE slot_name = 'pg_orders_slot'
  "

  lag 应该不为 0，说明数据积压在复制槽中等待消费。

  5.5 恢复 MQ：

  docker compose up -d rmq-broker rmq-proxy
  sleep 30

  5.6 等待 Connect 重新连上 Broker 后，验证数据追上：

  # 等 30 秒让增量同步追上来
  sleep 30

  # PG 和 MySQL 行数应恢复一致
  docker exec pg-source psql -U source_user -d source_db -t -c "SELECT COUNT(*) 
  FROM public.orders"
  docker exec mysql-target mysql -uroot -proot_pass target_db -sN -e "SELECT 
  COUNT(*) FROM orders"

  # 确认 MQ 宕机期间插入的数据已同步
  docker exec mysql-target mysql -uroot -proot_pass target_db -e \
    "SELECT * FROM orders WHERE order_id = 7001"

  期望：返回 7001 | MQ-Down-Test-A | ...

  第六步：验证容器重建后 Offset 不丢（终极验证）

  # 6.1 记录最新 order_id 作为标记
  docker exec pg-source psql -U source_user -d source_db -c "
  INSERT INTO public.orders (order_id, product_name, quantity, price, status, 
  created_at, updated_at)
  VALUES (7002, 'Reboot-Test-B', 1, 2.00, 'pending', now(), now())
  "

  sleep 10

  # 确认同步了
  docker exec mysql-target mysql -uroot -proot_pass target_db -e "SELECT * FROM 
  orders WHERE order_id = 7002"

  # 6.2 只停 MQ + Connect，保留 PG 和 MySQL 继续运行
  docker compose stop rmq-namesrv rmq-broker rmq-proxy rmq-connect

  # 6.3 PG 在"宕机"期间继续产生数据
  docker exec pg-source psql -U source_user -d source_db -c "
  INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at)
  VALUES (7003, 'Downtime-Test', 1, 5.00, 'pending', now(), now())
  "

  # 查看复制槽积压
  docker exec pg-source psql -U source_user -d source_db -c "
  SELECT slot_name, active,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
  FROM pg_replication_slots WHERE slot_name = 'pg_orders_slot'
  "

  # 6.4 恢复 MQ + Connect
  docker compose up -d rmq-namesrv rmq-broker rmq-proxy rmq-connect
  sleep 60

  # 6.5 重建 Connector（容器重启后需重新创建）
  curl.exe -s -X POST -H "Content-Type: application/json" -d @connectors/pg-src-prod.json http://localhost:8082/connectors/pg-source
  sleep 15
  curl.exe -s -X POST -H "Content-Type: application/json" -d @connectors/mysql-sink-prod.json http://localhost:8082/connectors/mysql-sink

  # 6.6 验证 Connector 自动恢复
  curl.exe -s http://localhost:8082/connectors/pg-source/status
  curl.exe -s http://localhost:8082/connectors/mysql-sink/status

  # 6.7 验证宕机期间的数据追上了
  docker exec mysql-target mysql -uroot -proot_pass target_db -e \
    "SELECT order_id, product_name FROM orders WHERE order_id IN (7002, 7003)"

  期望：7002 和 7003 都在 MySQL 中，宕机期间插入的 7003 没有丢，说明 PG 复制槽保留了变更，Connect 恢复后增量续传成功。

  ---
  验证通过的标准

  ┌─────────────────────┬───────────────────────────────────────────────────┐
  │       验证点        │                     通过条件                      │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │ volume 挂载         │ docker exec rmq-connect ls                        │
  │                     │ /opt/rocketmq-connect/store/ 有内容               │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │ MQ 宕机期间数据不丢 │ 7001 在 MySQL 中出现                              │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │ 容器重建后 Offset   │ 7010/7011 增量同步正常，而非全量快照              │
  │ 恢复                │                                                   │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │ 复制槽 lag 恢复     │ lag 归零或接近 0                                  │
  └─────────────────────┴───────────────────────────────────────────────────┘

✻ Crunched for 59s

※ recap: 目标：将 Connect 的 Offset 从 `/tmp` 改为持久化 volume，防止重启丢进度。

  已完成 3 处配置修改（storePathRootDir、volume 挂载、snapshot.mode=initial），待你执行验证步骤——先重建容器使配置生效，再模拟 MQ 宕机验证数据不丢。