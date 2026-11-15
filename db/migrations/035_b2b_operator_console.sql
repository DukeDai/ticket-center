-- =====================================================================================
-- 035 — B 端内部运营台：操作员身份 + 运营读模型
--
-- 这份迁移做两件事：
--
--   ① 运营操作员表（b2b_operator）—— 内部运营台的身份。
--      票到我们这里就自营，没有分销商自助这一层，所以操作员是**内部**的：
--      一个人、一个凭证、一套角色。分销商自助不在本期范围。
--
--   ② 运营读模型（v_ops_*）—— 给运营台看的几张视图。
--      运营台是跨渠道的（要看 C 端、B 端、企业客户各自的目录与订单），
--      所以它的视图不带 channel_id 过滤，由调用方按需筛。
--
-- 为什么读模型要用视图而不是请求链路里 join：
--   硬约束 10「C 端列表/日历只读读模型」讲的是 C 端，但同一条纪律对运营台一样成立 ——
--   请求链路里 join 主数据会在订单量上来之后拖慢主库，而且读侧口径会各写一份。
--   运营台的口径集中在视图里定义一次，各端点只读视图。
--
-- 口径纪律（与 spec/09-pricing.md §4.6、spec/00-overview.md §4.7 一致）：
--   - 金额一律 NUMERIC，视图里 ::text 出（前端与 API 都不许用浮点）；
--   - 选源与定价同源：成本取定价函数那个，不在视图里另算一遍；
--   - 事实只写一处：读模型可重建，主数据是唯一真相。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 运营操作员
-- -------------------------------------------------------------------------------------
--
-- 为什么建表而不是用环境变量里的一个密码：
--   写操作要能记「谁干的」。退款放行走 fn_approve_refund(approved_by)，
--   改派要往明细快照的 reassignments 里留痕 —— 留痕里写的是一个身份，
--   不是「某某」。共用一个密码的话，追责就断了。
--
-- 明文不落库：只存 sha256 哈希。凭证只在创建时显示一次。
-- 哈希不是加密（密码错了不能取回），但它挡住的是「库被读走 ⇒ 凭证可用」这件事。
CREATE TABLE b2b_operator (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code          TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    -- 明文凭证的 sha256 十六进制小写。校验时对收到的明文取同样的哈希比对。
    key_hash      TEXT NOT NULL,
    -- admin：可做放行/改派这类要记操作人的动作；
    -- operator：可下单、可发起退款、可出券；
    -- viewer：只读。
    role          TEXT NOT NULL DEFAULT 'viewer'
                  CHECK (role IN ('admin','operator','viewer')),
    status        TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','disabled')),
    -- 会话签发用：随机盐。HMAC 签名用「key_hash + salt」，
    -- 撤销时换 salt，已签发的会话立刻失效（改 key_hash 要重新发凭证）。
    session_salt  TEXT NOT NULL,
    last_login_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE b2b_operator IS
    'B 端内部运营台的操作员。票到我们这里就自营，没有分销商自助 —— 操作员是内部的人。凭证只存哈希，明文创建时显示一次。';

CREATE TRIGGER trg_b2b_operator_updated BEFORE UPDATE ON b2b_operator
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -------------------------------------------------------------------------------------
-- ② 运营读模型
-- -------------------------------------------------------------------------------------

-- ②.1 渠道总览：每个渠道的目录规模、订单规模、履约缺口。
--
-- 运营台的第一屏是「现在什么情况」，所以这张视图一行一个渠道，
-- 把订单状态分布与履约漏斗的条数摊平 —— 运营一眼看到哪个渠道有堆积。
CREATE VIEW v_ops_channel_overview AS
SELECT ch.id                AS channel_id,
       ch.code              AS channel_code,
       ch.name              AS channel_name,
       ch.channel_type,
       ch.status            AS channel_status,
       ch.settlement_mode,
       ch.commission_rate::text AS commission_rate,
       ch.default_currency,
       ch.tax_policy::text  AS tax_policy,
       ch.config::text      AS channel_config,
       -- 上架规模：这个渠道在卖几个商品。
       (SELECT count(*) FROM channel_listing cl
         WHERE cl.channel_id = ch.id AND cl.status = 'online')              AS online_listings,
       (SELECT count(*) FROM channel_listing cl
         WHERE cl.channel_id = ch.id AND cl.status = 'draft')               AS draft_listings,
       -- 订单规模与状态分布。
       (SELECT count(*) FROM sales_order o WHERE o.channel_id = ch.id)     AS order_count,
       (SELECT count(*) FROM sales_order o
         WHERE o.channel_id = ch.id AND o.payment_status = 'paid')         AS paid_order_count,
       (SELECT count(*) FROM sales_order o
         WHERE o.channel_id = ch.id AND o.payment_status = 'unpaid')       AS unpaid_order_count,
       -- 履约缺口：已付款但还没出票的。
       (SELECT count(*) FROM v_order_fulfillment_gap g
         WHERE g.channel_id = ch.id AND g.suspected_lost)                  AS suspected_lost_count
  FROM channel ch;

COMMENT ON VIEW v_ops_channel_overview IS
    '运营台渠道总览：一行一个渠道，带上架规模、订单规模与履约缺口条数';

-- ②.2 商品目录：跨渠道的商品与它在各渠道的上架状态。
--
-- 与 C 端卡片（c_product_card）不同，这张视图不物化卡片 —— 它直接看主数据。
-- 运营台看的是「这个商品现在什么状态」，不是「C 端长什么样」，
-- 所以它跨渠道列出商品的每个渠道副本，各渠道的价格策略与货币都在行里。
--
-- 价格不在这里算 —— 定价函数的唯一实现是 fn_price_variant，
-- 视图里自己按成本加价就会出现「运营看到的价」与「真下单的价」两套。
CREATE VIEW v_ops_product_catalog AS
SELECT p.id                AS product_id,
       p.product_code,
       p.title             AS product_title,
       p.subtitle,
       p.status            AS product_status,
       c.id                AS category_id,
       c.name              AS category_name,
       ct.name             AS city_name,
       -- 这个商品有几个变体（可售单元）。
       (SELECT count(*) FROM product_variant pv
         WHERE pv.product_id = p.id AND pv.status = 'active')             AS variant_count,
       cl.id               AS channel_listing_id,
       cl.channel_id,
       ch.code             AS channel_code,
       ch.name             AS channel_name,
       ch.channel_type,
       ch.default_currency,
       cl.status           AS listing_status,
       cl.price_policy::text   AS price_policy,
       cl.stock_policy::text   AS stock_policy,
       cl.booking_policy::text AS booking_policy,
       cl.refund_policy_override::text AS refund_policy_override,
       cl.min_order_qty,
       cl.max_order_qty,
       cl.sort_weight,
       cl.published_at::text   AS published_at,
       -- 绑了几个源（路由候选数）。
       (SELECT count(*) FROM channel_listing_source cls
         WHERE cls.channel_listing_id = cl.id AND cls.enabled)           AS source_count
  FROM product p
  JOIN channel_listing cl ON cl.product_id = p.id
  JOIN channel ch          ON ch.id = cl.channel_id
  LEFT JOIN category c     ON c.id = p.category_id
  LEFT JOIN city ct        ON ct.id = p.city_id;

COMMENT ON VIEW v_ops_product_catalog IS
    '运营台商品目录：一个商品 × 一个渠道一行，带上架状态与价格策略（价格由定价函数算，不在这里另算）';

-- ②.3 订单列表：运营台看单的主视图。
--
-- 订单状态与履约状态都由库里的唯一实现推导（fn_apply_order_fulfillment），
-- 这里只把它们带出来，不重算。
CREATE VIEW v_ops_order_list AS
SELECT o.id                AS order_id,
       o.order_no,
       o.channel_id,
       ch.code             AS channel_code,
       ch.name             AS channel_name,
       o.customer_id,
       cu.name             AS customer_name,
       cu.member_code,
       o.status            AS order_status,
       o.payment_status,
       o.fulfillment_status,
       o.currency,
       o.subtotal::text    AS subtotal,
       o.discount::text    AS discount,
       o.tax::text         AS tax,
       o.total::text       AS total,
       o.cost_total::text  AS cost_total,
       o.commission_amount::text AS commission_amount,
       o.idempotency_key,
       o.buyer_note,
       o.placed_at::text    AS placed_at,
       o.confirmed_at::text AS confirmed_at,
       o.completed_at::text AS completed_at,
       (SELECT count(*) FROM sales_order_item oi WHERE oi.order_id = o.id) AS item_count,
       (SELECT count(*) FROM voucher v WHERE v.order_id = o.id)          AS voucher_count,
       (SELECT count(*) FROM booking b WHERE b.order_id = o.id)          AS booking_count
  FROM sales_order o
  JOIN channel ch ON ch.id = o.channel_id
  LEFT JOIN customer cu ON cu.id = o.customer_id;

COMMENT ON VIEW v_ops_order_list IS
    '运营台订单列表：一行一单，带渠道、客户、金额、状态与履约规模';

-- ②.4 履约漏斗：已付款未出票的单。
--
-- 这张视图直接取 v_order_fulfillment_gap —— 漏斗口径是那里定义的唯一一份，
-- 这里不重算（重算就会出现两个「漏斗」）。
CREATE VIEW v_ops_fulfillment_gap AS
SELECT g.order_id,
       g.order_no,
       g.channel_id,
       ch.code             AS channel_code,
       g.order_status,
       g.payment_status,
       g.placed_at::text   AS placed_at,
       g.booking_count,
       g.confirmed_bookings,
       g.failed_bookings,
       g.voucher_count,
       g.issued_vouchers,
       g.used_vouchers,
       g.suspected_lost
  FROM v_order_fulfillment_gap g
  JOIN channel ch ON ch.id = g.channel_id;

COMMENT ON VIEW v_ops_fulfillment_gap IS
    '运营台履约漏斗：suspected_lost=true 表示已付款 30 分钟仍未出票（口径取自 v_order_fulfillment_gap）';

-- ②.5 供给形态与缺口：跨渠道看「谁能供、差在哪」。
--
-- 直接取 v_variant_supply_forms —— 三种形态（单张/配方/套装）在同一张表上对齐，
-- 这里不重算成本、不重算份数（硬约束 30）。
CREATE VIEW v_ops_supply_forms AS
SELECT sf.product_variant_id,
       sf.variant_code,
       sf.variant_title,
       sf.variant_role,
       sf.product_id,
       sf.product_code,
       sf.product_title,
       sf.date::text       AS date,
       sf.channel_id,
       sf.supply_form,
       sf.supplier_codes,
       sf.supplier_count,
       sf.source_currencies,
       sf.cost_in_target::text AS cost_in_target,
       sf.currency,
       sf.base_currency,
       sf.component_count,
       sf.admission_quantity,
       sf.audience_codes,
       sf.valid_days,
       sf.can_fulfil,
       sf.gaps,
       sf.candidates
  FROM v_variant_supply_forms sf;

COMMENT ON VIEW v_ops_supply_forms IS
    '运营台供给形态对照：可售单元 × 一天 × 渠道 × 形态（单张/配方/套装），带缺口（口径取自 v_variant_supply_forms）';

-- ②.6 退款台账：跨渠道看退款单与承诺。
--
-- 退款承诺（可退 / 截止时长 / 手续费）是发起时定下的快照 —— 历史不可变，
-- 所以这里带出来的是承诺本身，不是今天的政策。
CREATE VIEW v_ops_refund_ledger AS
SELECT r.id                AS refund_id,
       r.refund_no,
       r.order_id,
       o.order_no,
       o.channel_id,
       ch.code             AS channel_code,
       o.customer_id,
       r.status            AS refund_status,
       r.amount::text      AS refund_amount,
       r.currency,
       r.reason,
       r.requested_by,
       r.approved_by,
       r.previous_order_status,
       r.error_code,
       r.error_message,
       r.idempotency_key,
       r.created_at::text  AS requested_at,
       r.approved_at::text  AS approved_at,
       r.completed_at::text AS completed_at
  FROM sales_refund r
  JOIN sales_order o ON o.id = r.order_id
  JOIN channel ch ON ch.id = o.channel_id;

COMMENT ON VIEW v_ops_refund_ledger IS
    '运营台退款台账：一行一笔退款，带放行人与失败原因';

-- ②.7 核销记录：谁在哪儿扫的票。
CREATE VIEW v_ops_redemption_log AS
SELECT vr.id                AS redemption_id,
       vr.voucher_id,
       v.voucher_no,
       v.code              AS ticket_code,
       o.id                AS order_id,
       o.order_no,
       o.channel_id,
       ch.code             AS channel_code,
       vr.result,
       vr.reason,
       vr.gate_id,
       g.name              AS gate_name,
       vr.gate_operator_id,
       vr.operator_id,
       vr.consumed_quantity,
       vr.scanned_at::text  AS scanned_at
  FROM voucher_redemption vr
  JOIN voucher v  ON v.id = vr.voucher_id
  JOIN sales_order o ON o.id = v.order_id
  JOIN channel ch ON ch.id = o.channel_id
  LEFT JOIN gate g ON g.id = vr.gate_id;

COMMENT ON VIEW v_ops_redemption_log IS
    '运营台核销记录：一行一次扫票（核销记录永远追加，这里不做去重）';

-- ②.8 库存预占：谁占着票、占多久。
CREATE VIEW v_ops_inventory_hold AS
SELECT h.id                AS hold_id,
       h.hold_no,
       h.channel_id,
       ch.code             AS channel_code,
       h.product_session_id,
       h.ticket_type_id,
       h.supplier_id,
       h.quantity,
       h.status            AS hold_status,
       h.cart_id,
       h.order_id,
       h.created_at::text  AS created_at,
       h.expires_at::text  AS expires_at,
       h.released_at::text AS released_at
  FROM inventory_hold h
  JOIN channel ch ON ch.id = h.channel_id;

COMMENT ON VIEW v_ops_inventory_hold IS
    '运营台库存预占：一行一个预占，带到期时间（TTL 口径在库里）';

-- ②.9 源健康度与结算缺口：跨渠道的供给侧与财务侧。
--
-- 这两张直接取已有的视图 —— 源健康度与结算缺口的口径各只有一份，
-- 运营台只是把它们摆出来。
CREATE VIEW v_ops_supplier_health AS
SELECT s.supplier_id,
       s.code,
       s.name,
       s.status,
       s.active_products,
       s.mapped_products,
       s.payloads_1h,
       s.last_sync_at::text AS last_sync_at,
       s.failed_jobs_24h
  FROM v_supplier_sync_health s;

COMMENT ON VIEW v_ops_supplier_health IS
    '运营台源健康度：一眼看哪个源在掉链子（口径取自 v_supplier_sync_health）';

CREATE VIEW v_ops_settlement_gap AS
SELECT sg.supplier_id,
       sg.supplier_code,
       sg.booking_id,
       sg.booking_no,
       sg.external_booking_id,
       sg.booking_status,
       sg.confirmed_at::text AS confirmed_at,
       sg.order_no,
       sg.settlement_lines
  FROM v_settlement_gap sg;

COMMENT ON VIEW v_ops_settlement_gap IS
    '运营台结算缺口：已确认预订但没进结算单（口径取自 v_settlement_gap）';

-- ②.10 待改派清单：未收款且成本变了/源下架的单。
--
-- 这张直接取 v_reassign_candidates —— 「待改派」的口径在那边算，
-- 运营台不重算（重算就会出现两个「该改派」的清单）。
CREATE VIEW v_ops_reassign_candidates AS
SELECT rc.order_id,
       rc.order_no,
       rc.order_item_id,
       rc.channel_id,
       ch.code             AS channel_code,
       rc.product_id,
       rc.product_variant_id,
       rc.visit_date::text  AS visit_date,
       rc.quantity,
       rc.current_supplier_product_id,
       rc.current_supplier,
       rc.current_unit_price::text AS current_unit_price,
       rc.current_unit_cost::text  AS current_unit_cost,
       rc.new_supplier_product_id,
       rc.new_supplier,
       rc.new_unit_price::text AS new_unit_price,
       rc.new_unit_cost::text  AS new_unit_cost,
       rc.can_reassign,
       rc.stale_reason
  FROM v_reassign_candidates rc
  JOIN channel ch ON ch.id = rc.channel_id;

COMMENT ON VIEW v_ops_reassign_candidates IS
    '运营台待改派清单：未收款且成本/源变了或源下架的单（口径取自 v_reassign_candidates）';
