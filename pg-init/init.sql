-- ============================================================
-- PostgreSQL 源库初始化脚本
-- 容器首次启动时自动执行（docker-entrypoint-initdb.d）
-- ============================================================

-- 创建源表
CREATE TABLE IF NOT EXISTS public.orders (
    order_id      BIGINT        NOT NULL,
    product_name  VARCHAR(255)  NOT NULL,
    quantity      INT           NOT NULL DEFAULT 1,
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status        VARCHAR(50)   NOT NULL DEFAULT 'pending',
    created_at    TIMESTAMP     NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP     NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id)
);

-- ⚠️ 关键：设置 REPLICA IDENTITY FULL，确保 DELETE 操作能被 Debezium 捕获
ALTER TABLE public.orders REPLICA IDENTITY FULL;

-- 插入初始测试数据
INSERT INTO public.orders (order_id, product_name, quantity, price, status, created_at, updated_at) VALUES
(1001, 'Apple iPhone 15',    2, 6999.00, 'pending',   now(), now()),
(1002, 'MacBook Pro 14',     1, 14999.00, 'shipped',  now(), now()),
(1003, 'AirPods Pro',        3, 1999.00,  'delivered', now(), now());
