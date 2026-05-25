-- ============================================================
-- MySQL 目标库初始化脚本
-- 容器首次启动时自动执行（docker-entrypoint-initdb.d）
-- ============================================================
-- 说明：目标时间字段使用 DATETIME(3)，存储毫秒精度，
-- 与 Debezium time.precision.mode=connect（输出毫秒/秒级 epoch）匹配。

-- 目标表结构（与 PG 源表字段对齐，时间字段用 DATETIME(3)）
CREATE TABLE IF NOT EXISTS orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    DATETIME(3)   NOT NULL COMMENT '创建时间，毫秒精度',
    updated_at    DATETIME(3)   NOT NULL COMMENT '更新时间，毫秒精度',
    PRIMARY KEY (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 设置会话时区为 UTC（与 Debezium PG Source 的 UTC 输出对齐）
SET time_zone = '+00:00';
