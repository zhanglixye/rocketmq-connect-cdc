-- ============================================================
-- PostgreSQL 源库初始化脚本
-- 容器首次启动时自动执行（docker-entrypoint-initdb.d）
-- ============================================================
-- 说明：TIMESTAMP(6) 模拟 timestamp(4-6) 精度场景，
-- 用于测试 Debezium time.precision.mode 时间精度转换。

-- 创建源表（timestamp 精度 6，触发 Debezium 微秒输出）
CREATE TABLE IF NOT EXISTS public.orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    TIMESTAMP(3)  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP(3)  NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id)
);

-- ⚠️ 关键：设置 REPLICA IDENTITY FULL，确保 DELETE 操作能被 Debezium 捕获
ALTER TABLE public.orders REPLICA IDENTITY FULL;

-- 插入初始测试数据（含毫秒精度，验证转换后精度保留情况）
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at) VALUES
(1001, 'Apple iPhone 15',    2, 6999.00,  'pending',   '2026-05-25 12:00:00.500000', '2026-05-25 12:00:00.500000'),
(1002, 'MacBook Pro 14',     1, 14999.00, 'shipped',   '2026-05-25 12:30:15.250000', '2026-05-25 13:00:00.750000'),
(1003, 'AirPods Pro',        3, 1999.00,  'delivered', '2026-05-25 14:00:00.999999', '2026-05-25 14:30:00.123456');
