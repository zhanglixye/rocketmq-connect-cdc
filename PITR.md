# PostgreSQL PITR（时间点恢复）配置与操作指南

## 一、原理

```
基础备份 (base backup) + WAL 归档日志 → 恢复到任意时间点
```

- **WAL (Write-Ahead Log)**：PG 将所有数据变更先写入 WAL，再写入数据文件
- **archive_command**：每写完一个 WAL 段（16MB），自动执行命令将其复制到持久化存储
- **PITR**：拿到基础备份 + 从备份时间到目标时间的所有 WAL，PG 就能回放到指定时刻

---

## 二、当前配置（docker-compose.yml）

```yaml
pg-source:
  command: >
    -c wal_level=logical
    -c max_wal_senders=10
    -c max_replication_slots=4
    -c wal_sender_timeout=60s
    -c archive_mode=on
    -c archive_command='test ! -f /var/lib/postgresql/data/archive/%f && cp %p /var/lib/postgresql/data/archive/%f'
    -c archive_timeout=60
```

| 参数 | 说明 |
|------|------|
| `archive_mode=on` | 开启 WAL 归档 |
| `archive_command` | 将每个完成的 WAL 段复制到 `pg-data` 卷的 `archive/` 目录 |
| `archive_timeout=60s` | 即使 WAL 段未写满，60 秒后也强制归档（避免低流量时 WAL 长时间不归档） |

关键点：
- `archive/` 目录在命名卷 `pg-data` 上，容器删除重建不会丢失
- `test ! -f ...` 防止重复归档覆盖已有文件

---

## 三、验证 WAL 归档是否正常

```bash
# 1. 确认 archive_mode 已开启
docker exec pg-source psql -U source_user -d source_db -c "SHOW archive_mode;"
# 预期：on

# 2. 查看已归档的 WAL 文件
docker exec pg-source ls -la /var/lib/postgresql/data/archive/
# 预期：有一系列 0000000100000000000000xx 文件

# 3. 手动触发 WAL 切换，确认新文件出现
docker exec pg-source psql -U source_user -d source_db -c "SELECT pg_switch_wal();"
docker exec pg-source ls -la /var/lib/postgresql/data/archive/
```

---

## 四、创建基础备份

PITR 需要一份基础备份作为恢复起点。基础备份记录了某个时刻的完整数据快照。

### 首次创建

```bash
docker exec pg-source bash -c "
  mkdir -p /var/lib/postgresql/data/basebackup && \
  chown postgres:postgres /var/lib/postgresql/data/basebackup && \
  su - postgres -c 'PGPASSWORD=source_pass pg_basebackup \
    -U source_user \
    -D /var/lib/postgresql/data/basebackup/$(date +%Y%m%d_%H%M%S) \
    -Fp -Xs -P'
"
```

参数说明：
| 参数 | 说明 |
|------|------|
| `-D <dir>` | 备份目标目录（加时间戳便于管理） |
| `-Fp` | 普通文件格式（plain），可直接用作 PG 数据目录 |
| `-Xs` | 备份期间产生的 WAL 也一并归档（streaming） |
| `-P` | 显示进度 |

### 后续不需要重复这一步

每次执行会在 `basebackup/` 下生成新的时间戳目录，旧的可手动清理。

---

## 五、挂机后执行 PITR 恢复（核心流程）

假设挂机时间：**2026-06-02 09:00:00**

### 5.1 准备基础备份 + WAL 归档

基础备份和 WAL 都在 `pg-data` 命名卷中，即使 pg-source 容器挂了也能拿到：

```bash
# 确认基础备份存在
docker run --rm -v pg-data:/pgdata alpine ls /pgdata/basebackup/

# 确认 WAL 归档存在（覆盖挂机时间之前的 WAL）
docker run --rm -v pg-data:/pgdata alpine ls /pgdata/archive/
```

### 5.2 用基础备份启动一个恢复容器

```bash
# 1. 创建恢复用的临时数据目录并拷入基础备份（选一个挂机时间之前的备份）
docker run --rm \
  -v pg-data:/pgdata \
  alpine \
  cp -a /pgdata/basebackup/20260602_110400 /pgdata/recovery_data

# 2. 配置恢复参数
docker run --rm \
  -v pg-data:/pgdata \
  alpine sh -c "
    touch /pgdata/recovery_data/recovery.signal && \
    echo \"restore_command = 'cp /pgdata/archive/%f %p'\" >> /pgdata/recovery_data/postgresql.conf && \
    echo \"recovery_target_time = '2026-06-02 09:00:00'\" >> /pgdata/recovery_data/postgresql.conf && \
    echo \"recovery_target_action = 'pause'\" >> /pgdata/recovery_data/postgresql.conf
  "
```

参数说明：
| 配置 | 说明 |
|------|------|
| `recovery.signal` | 空文件，告知 PG 启动时进入恢复模式 |
| `restore_command` | PG 恢复时从哪取 WAL 文件，`%f`=文件名，`%p`=目标路径 |
| `recovery_target_time` | 恢复到哪个时间点（你的挂机时间） |
| `recovery_target_action = pause` | 恢复到目标时间后暂停，方便查询（此时 PG 只读） |

### 5.3 启动恢复容器

```bash
docker run -d \
  --name pg-recovery \
  -v pg-data:/pgdata \
  -e PGDATA=/pgdata/recovery_data \
  -p 15433:5432 \
  postgres:16
```

PG 启动时会自动识别 `recovery.signal`，开始回放 WAL，到达 `2026-06-02 09:00:00` 后暂停。

### 5.4 验证恢复结果

```bash
# 检查恢复日志，确认恢复到了目标时间
docker logs pg-recovery 2>&1 | grep "recovery stopping"

# 连接查询（端口 15433，不会影响生产 15432）
docker exec pg-recovery psql -U source_user -d source_db -c "
  SELECT COUNT(*) FROM orders;
  SELECT * FROM orders ORDER BY created_at DESC LIMIT 10;
"
```

### 5.5 比对数据，找出丢失的记录

```bash
# PG 恢复实例中挂机时间之前的数据
docker exec pg-recovery psql -U source_user -d source_db -c "
  SELECT order_id, product_name, updated_at 
  FROM orders 
  WHERE updated_at < '2026-06-02 09:00:00' 
  ORDER BY updated_at;
"

# 生产 MySQL 中挂机时间之前的数据
docker exec mysql-target mysql -uroot -proot_pass -e "
  SELECT order_id, product_name, updated_at 
  FROM target_db.orders 
  WHERE updated_at < '2026-06-02 09:00:00' 
  ORDER BY updated_at;
"
```

用 diff 工具比对两个结果集，差异即为丢失的数据。

### 5.6 清理恢复容器

```bash
docker rm -f pg-recovery
docker run --rm -v pg-data:/pgdata alpine rm -rf /pgdata/recovery_data
```

**整个过程中，生产 PG (pg-source) 和 MySQL (mysql-target) 完全不受影响。**

---

## 六、日常维护

### 定期更新基础备份

基础备份越旧，恢复时需要回放的 WAL 越多，恢复越慢。建议每天或每周更新：

```bash
# 每次执行会在 basebackup/ 下生成新的时间戳目录
docker exec pg-source bash -c "
  su - postgres -c 'PGPASSWORD=source_pass pg_basebackup \
    -U source_user \
    -D /var/lib/postgresql/data/basebackup/$(date +%Y%m%d_%H%M%S) \
    -Fp -Xs -P'
"

# 清理 7 天前的旧备份（保留最近几个即可）
docker exec pg-source bash -c "
  ls -dt /var/lib/postgresql/data/basebackup/*/ | tail -n +4 | xargs rm -rf
"
```

### 监控 WAL 归档积压

```bash
# 查看当前 WAL 位置和归档状态
docker exec pg-source psql -U source_user -d source_db -c "
  SELECT 
    pg_current_wal_lsn() AS current_wal,
    last_archived_wal,
    last_archived_time,
    failed_count
  FROM pg_stat_archiver;
"
```

- `last_archived_time` 距今超过 60 秒：归档可能卡住
- `failed_count > 0`：归档命令执行失败，检查 `archive/` 目录权限

### 磁盘空间

```bash
# 监控 pg-data 卷占用
docker system df -v | grep pg-data
```

WAL 归档文件每个 16MB，每 60 秒最多产生一个。按此速率日均 ~1.4GB，需要定期清理过期 WAL（或配合 `pg_archivecleanup` 工具）。
