-- ============================================================
-- MySQL 目标库初始化脚本
-- 容器首次启动时自动执行（docker-entrypoint-initdb.d）
-- ============================================================

-- 目标表结构（与 PG 源表字段对齐）
CREATE TABLE IF NOT EXISTS orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    BIGINT        NOT NULL DEFAULT 0,
    updated_at    BIGINT        NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
