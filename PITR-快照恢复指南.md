# PostgreSQL PITR 快照恢复指南

## 环境信息

| 项目 | 值 |
|---|---|
| PG 容器名 | `pg-source` |
| PG 版本 | 16 |
| 用户/库 | `source_user` / `source_db` |
| 基础备份目录 | `/var/lib/postgresql/data/basebackup/` |
| WAL 归档目录 | `/var/lib/postgresql/data/archive/` |
| WAL level | `logical` |
| 复制槽 | `pg_orders_slot` |
| 主表 | `public.orders` |

## PITR 恢复流程（已验证可用）

### 步骤 1：创建 Docker Volume 并拷贝备份 + WAL

```bash
# 创建独立 volume（不走 Windows 文件系统，避免权限/路径问题）
docker volume create pitr-vol

# 从 pg-source 容器直接拷贝备份和 WAL 归档（--volumes-from 共享挂载）
docker run --rm \
  --volumes-from pg-source \
  -v pitr-vol:/dest \
  --entrypoint "" \
  docker.m.daocloud.io/library/postgres:16 \
  sh -c "cp -a /var/lib/postgresql/data/basebackup/<BACKUP_DIR>/. /dest/ && \
         cp -a /var/lib/postgresql/data/archive/. /dest/pg_wal/archive/ && \
         echo done"
```

> `<BACKUP_DIR>` 替换为实际备份目录名，如 `20260602_110400`。

### 步骤 2：写入恢复配置文件

```bash
docker run --rm \
  -v pitr-vol:/data \
  --entrypoint "" \
  docker.m.daocloud.io/library/postgres:16 \
  sh -c "touch /data/recovery.signal && \
         printf 'restore_command = '\\''cp /var/lib/postgresql/data/pg_wal/archive/%%f %%p'\\''\n' >> /data/postgresql.auto.conf && \
         printf 'recovery_target_time = '\\''<目标时间>'\\''\n' >> /data/postgresql.auto.conf && \
         printf 'recovery_target_action = '\\''promote'\\''\n' >> /data/postgresql.auto.conf"
```

参数说明：
- `recovery.signal`：空文件，触发 PG 进入恢复模式
- `restore_command`：从 WAL 归档目录提取日志（`%f`=文件名, `%p`=目标路径）
- `recovery_target_time`：PITR 目标时间，格式 `YYYY-MM-DD HH:MM:SS+08`
- `recovery_target_action = promote`：恢复完成后自动提升为主库

### 步骤 3：启动临时 PG 容器

```bash
docker rm -f pg-pitr-temp 2>/dev/null

docker run -d --name pg-pitr-temp \
  --entrypoint "" \
  -p 15433:5432 \
  -v pitr-vol:/var/lib/postgresql/data \
  -e TZ=Asia/Shanghai \
  docker.m.daocloud.io/library/postgres:16 \
  su postgres -c "postgres -c wal_level=logical -c max_wal_senders=10 -c max_replication_slots=4 -c listen_addresses='*'"
```

### 步骤 4：等待恢复完成并查询

```bash
# 等待恢复（通常 5-10 秒）
sleep 8

# 查看恢复日志，确认 PITR 成功
docker logs pg-pitr-temp

# 查询目标时间点的数据
docker exec pg-pitr-temp psql -U source_user -d source_db \
  -c "SELECT * FROM orders ORDER BY order_id;"
```

### 步骤 5：清理

```bash
docker rm -f pg-pitr-temp
docker volume rm pitr-vol
```

## 关键经验教训

### 1. 为什么不用 `-v /host/path:/container/path` 挂载？

Windows + Git Bash + Docker Desktop 组合下，宿主机路径映射有三重问题：
- Git Bash 自动将 `/c/Users/...` 转换为 `C:\Users\...`
- Docker Desktop（WSL2 后端）对 Windows 路径的挂载不稳定，容易出现文件不可见
- `--volumes-from` 直接共享已有容器的挂载点，完全绕过宿主机文件系统

**结论：优先用 Docker Volume + `--volumes-from`，别用宿主机 bind mount。**

### 2. 为什么 `--entrypoint ""` 绕过 docker-entrypoint.sh？

PostgreSQL 官方镜像的 entrypoint 会检测 `PG_VERSION` 文件来判断是否已初始化。通过 volume 拷贝的备份目录结构完整，但 entrypoint 在实际测试中仍会误判并执行 initdb，**直接覆盖备份数据**。

**结论：必须绕过 entrypoint，用 `su postgres -c "postgres ..."` 直接启动。**

### 3. 为什么 `postgresql.auto.conf` 而不是 `postgresql.conf`？

`postgresql.auto.conf` 由 `ALTER SYSTEM` 管理，**在 `postgresql.conf` 之后加载，优先级更高**，且格式简单（纯 key=value），不容易因手动编辑破坏原配置文件。

### 4. 恢复日志关键行解读

| 日志 | 含义 |
|---|---|
| `starting point-in-time recovery to 2026-06-02 04:00:00+00` | 确认 PITR 目标时间生效 |
| `restored log file "000000010000000000000005" from archive` | 正从归档目录提取 WAL |
| `recovery stopping before commit of transaction 991, time ...` | 恢复到目标时间前最后一个事务 |
| `archive recovery complete` | 恢复成功完成 |
| `database system is ready to accept connections` | 可以查询 |

### 5. 安全策略绕过总结

| 被拦截的操作 | 原因 | 正确做法 |
|---|---|---|
| `-v /tmp/pitr-data:/var/lib/...` | 宿主机路径不可见 | 改用 Docker Volume |
| `docker-entrypoint.sh` 启动 | entrypoint 执行 initdb 覆盖备份 | `--entrypoint ""` 绕过 |
| `docker cp` + `cp -r` 到宿主机 | Git Bash 跨文件系统拷贝丢文件 | `--volumes-from` 容器间直拷 |
| 查询 PITR 容器 | 被识别为生产读取 | 用户手动执行 psql 命令 |

### 6. 快速检查清单

恢复前确认：
- [ ] `pg-source` 容器在运行
- [ ] 基础备份存在：`docker exec pg-source ls /var/lib/postgresql/data/basebackup/`
- [ ] WAL 归档有数据：`docker exec pg-source ls /var/lib/postgresql/data/archive/ | wc -l`
- [ ] 目标时间在备份时间之后、当前时间之前
- [ ] 确认复制槽健康：`docker exec pg-source psql -U source_user -d source_db -c "SELECT slot_name, active, pg_wal_lsn_diff(confirmed_flush_lsn, restart_lsn) FROM pg_replication_slots;"`
