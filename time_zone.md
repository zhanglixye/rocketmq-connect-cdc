## 实测结论

### 数据对比一览

| 环节 | `created_at` 值 | 说明 |
|------|----------------|------|
| **PG 原始值** | `2026-05-25 12:00:00.5` | `timestamp without time zone`，无时区 |
| **PG TimeZone** | `Etc/UTC` | PG 服务器时区 |
| **MySQL BIGINT** | `1779710400500000` | Debezium 输出的**微秒**级 epoch |
| **MySQL `+00:00` 转换** | `2026-05-25 12:00:00.500000` ✅ | **与 PG 原始值完全一致** |
| **MySQL `+08:00` 转换** | `2026-05-25 20:00:00.500000` ❌ | 多了 8 小时 |

### 关键发现

1. **PG `created_at` / `updated_at` 不带时区** — 类型是 `timestamp without time zone`，PG 的 `TimeZone=Etc/UTC` 只是会话显示设置，不影响存储值。

2. **Debezium 输出的是微秒（10⁶），不是毫秒（10³）** — 因为默认 `time.precision.mode=adaptive_time_microseconds`，所以 MySQL 存的是 `1779710400500000`（16 位），除数是 **`1000000`**。

3. **`SET time_zone = '+00:00'` + `FROM_UNIXTIME(col / 1000000)` 与 PG 原始值完全一致** ✅ — `12:00:00.500000` vs `12:00:00.5`，精度完全保留。

4. **不设时区直接用 `FROM_UNIXTIME` 会偏移 8 小时** — 因为 MySQL 默认 `+08:00`，UTC epoch → 北京时间 = `20:00:00.500000`。

### 最终推荐用法

```sql
-- 查询时设置会话时区为 UTC，除以 1000000（微秒→秒）
SET time_zone = '+00:00';
SELECT 
    request_id,
    FROM_UNIXTIME(startTime / 1000000, '%Y-%m-%d %H:%i:%s.%f') AS startTime,
    FROM_UNIXTIME(endTime / 1000000, '%Y-%m-%d %H:%i:%s.%f') AS endTime
FROM LiteLLM_SpendLogs;

或者应用程序层转换

// TypeHandler 自动转换
public class EpochMicroToLocalDateTimeHandler extends BaseTypeHandler<LocalDateTime> {
    private static final ZoneOffset UTC = ZoneOffset.UTC;

    @Override
    public LocalDateTime getNullableResult(ResultSet rs, String columnName) {
        long micros = rs.getLong(columnName);
        if (rs.wasNull()) return null;
        return LocalDateTime.ofEpochSecond(
            micros / 1_000_000, 
            (int)(micros % 1_000_000) * 1000, 
            UTC
        );
    }
}
```

> ⚠️ **注意**：之前说的除数 `1000` 是错误的，实际是 `1000000`（Debezium 默认输出微秒）。