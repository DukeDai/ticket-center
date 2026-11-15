-- =====================================================================================
-- 036 — 运营台的商品详情：读模型
--
-- 运营台已经有商品目录（v_ops_product_catalog，一行一个「商品 × 渠道」），
-- 但**看不到一个商品内部长什么样**：绑了哪些源、判定依据是什么、
-- 有哪些可售单元、每个变体挂在哪些渠道、价格怎么配、给客户看的文案写了什么。
--
-- 这份迁移补上那一层：
--
--   ⓪ v_ops_product_head —— 商品头（一行一个商品，不是「商品 × 渠道」）。
--   ① v_ops_product_source —— 这个商品的源绑定与判定依据（映射审核队列）。
--   ② v_ops_product_variant —— 可售单元（变体）与其轴取值。
--   ③ v_ops_product_listing —— 这个商品在各渠道的上架配置。
--   ④ v_ops_product_price —— 售价行（按变体 × 日期）。
--   ⑤ v_ops_product_content —— 给客户看的文案（亮点 / 包含 / 须知）。
--
-- 口径纪律（与 spec/22-b-side-console.md §5.28 一致）：
--   - **不重算任何事实。** 成本与份数由库里的定价函数与读模型算好，
--     这里只带出来；本视图不碰价格。
--   - **金额一律 NUMERIC，视图里 ::text 出**（前端不许用浮点）。
--   - **跨渠道**：运营台要看的是「全部渠道在一屏里比」，
--     所以这些视图不带 channel_id 过滤 —— 过滤是调用方的事。
--
-- 为什么读模型而不是请求链路里 join：
--   同硬约束 10 的精神。请求链路里 join 主数据会在商品量上来之后拖慢主库，
--   而且读侧口径会各写一份。运营台的口径集中在视图里定义一次，各端点只读视图。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ⓪ 商品头（一个商品一行）
-- -------------------------------------------------------------------------------------
--
-- 目录视图 v_ops_product_catalog 是「商品 × 渠道」一行 ——
-- 拿它当商品头会在两个地方出错：
--   - 同一个商品在两个渠道上架时，它有两行，详情页的头该取哪一行是猜的；
--   - 还没上架任何渠道的商品**一行都没有**，于是详情页打不开 ——
--     而「刚同步进来还没上架」恰恰是运营最需要看的商品。
--
-- 所以商品头单开一个视图：一行一个商品。
CREATE VIEW v_ops_product_head AS
SELECT p.id                AS product_id,
       p.product_code,
       p.title             AS product_title,
       p.subtitle,
       p.status            AS product_status,
       c.name              AS category_name,
       ct.name             AS city_name,
       -- 有几个变体、几个源绑定、几行售价 —— 一眼看出这个商品的家底。
       (SELECT count(*) FROM product_variant pv
         WHERE pv.product_id = p.id)                             AS variant_count,
       (SELECT count(*) FROM product_mapping pm
         WHERE pm.product_id = p.id)                             AS mapping_count,
       (SELECT count(*) FROM price_calendar pc
         WHERE pc.product_id = p.id)                             AS price_row_count,
       -- 挂在几个渠道上（含没上架的渠道）。
       (SELECT count(DISTINCT cl.channel_id) FROM channel_listing cl
         WHERE cl.product_id = p.id)                             AS channel_count
  FROM product p
  LEFT JOIN category c  ON c.id = p.category_id
  LEFT JOIN city ct     ON ct.id = p.city_id;

COMMENT ON VIEW v_ops_product_head IS
    '运营台商品头：一行一个商品，带分类、城市与家底计数（与目录视图的「商品 × 渠道」区分开）';

-- -------------------------------------------------------------------------------------
-- ① 源绑定与判定依据
-- -------------------------------------------------------------------------------------
--
-- 运营看这一块是为了**审映射**：这个商品对应的是哪几个源的哪些条目、
-- 谁判的、判的依据是什么、有没有还在等人审的。
--
-- 「判定依据」带出来是这一块的核心：人工判过的映射，最怕的是机器下一次同步
-- 把依据洗掉（写路径门禁 internal/writelint 守的就是这一条）。
-- 运营看不到依据，就只能凭感觉点「通过」。
--
-- 注意 pending_review 单独标出来 —— 那是**队列**，不是异常：
-- 目录同步作业抓回来的新商品没人审，就停在那儿等。
CREATE VIEW v_ops_product_source AS
SELECT pm.id                AS mapping_id,
       pm.product_id,
       p.product_code,
       p.title            AS product_title,
       pm.supplier_id,
       s.code               AS supplier_code,
       s.name               AS supplier_name,
       sp.id                AS supplier_product_id,
       sp.external_id,
       sp.external_code,
       sp.external_url,
       sp.raw_title,
       sp.availability_mode,
       sp.status            AS supplier_product_status,
       sp.last_synced_at::text AS last_synced_at,
       pm.match_type,
       pm.confidence::text  AS confidence,
       pm.match_evidence::text AS match_evidence,
       pm.is_primary,
       pm.status            AS mapping_status,
       pm.created_by,
       pm.created_at::text   AS created_at,
       pm.updated_at::text   AS updated_at
  FROM product_mapping pm
  JOIN product p           ON p.id = pm.product_id
  JOIN supplier s          ON s.id = pm.supplier_id
  JOIN supplier_product sp ON sp.id = pm.supplier_product_id;

COMMENT ON VIEW v_ops_product_source IS
    '运营台商品源绑定：一行一个映射（商品 ← 源条目），带判定依据与审核状态';

-- -------------------------------------------------------------------------------------
-- ② 可售单元（变体）与轴取值
-- -------------------------------------------------------------------------------------
--
-- 变体这一层是「一个商品到底有哪些可卖的规格」。轴取值（人群、票种、园区范围…）
-- 拼成一行 —— 前端不自己 join 那三张表拼字符串。
--
-- 轴取值用 string_agg 拼，**顺序按 sort_order**：
-- 变体的轴取值顺序变了就是「换了一个变体」，
-- 不排序的话同一个变体每次拼出来的字符串顺序不一样，对不上就是没法比。
--
-- valid_days 从轴选项上取（有效期长度住在轴选项上，硬约束 23）——
-- 但这里**只带出来**，不重算：有效期的唯一读法是 fn_variant_validity_days。
-- 这里带的是「轴选项上声明的天数」，供运营核对声明与实际券是否一致。
CREATE VIEW v_ops_product_variant AS
SELECT pv.id                AS product_variant_id,
       pv.product_id,
       p.product_code,
       pv.variant_code,
       pv.variant_key,
       pv.title             AS variant_title,
       pv.variant_role,
       pv.ticket_type_id,
       tt.code              AS ticket_type_code,
       tt.name              AS ticket_type_name,
       pv.status            AS variant_status,
       pv.sort_order,
       -- 轴取值拼成一行：人群 / 票种 / 园区范围…
       (SELECT string_agg(a.axis_code || '=' || o.option_code, ' · ' ORDER BY a.sort_order, o.sort_order)
          FROM product_variant_option pvo
          JOIN product_axis a        ON a.id = pvo.axis_id
          JOIN product_axis_option o ON o.id = pvo.axis_option_id
         WHERE pvo.product_variant_id = pv.id)                     AS axis_values,
       -- 轴选项声明的有效期天数（声明，不是算出来的）
       (SELECT max(o.valid_days)
          FROM product_variant_option pvo
          JOIN product_axis_option o ON o.id = pvo.axis_option_id
         WHERE pvo.product_variant_id = pv.id)                     AS axis_valid_days,
       -- 组合的成分数（不是「这个变体是组合」而是「它有几个成分」）
       (SELECT count(*) FROM product_variant_relation r
         WHERE r.parent_variant_id = pv.id)                       AS component_count,
       -- 绑了几个源能供（方向 A 的覆盖）
       (SELECT count(*) FROM supplier_variant_mapping svm
         WHERE svm.product_variant_id = pv.id)                    AS supplier_mapping_count,
       -- 售价行数（这个变体有几天的价格）
       (SELECT count(*) FROM price_calendar pc
         WHERE pc.product_variant_id = pv.id)                     AS price_row_count
  FROM product_variant pv
  JOIN product p ON p.id = pv.product_id
  LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id;

COMMENT ON VIEW v_ops_product_variant IS
    '运营台可售单元：一行一个变体，带轴取值、成分数、源绑定数与售价行数';

-- -------------------------------------------------------------------------------------
-- ③ 各渠道的上架配置
-- -------------------------------------------------------------------------------------
--
-- 一个商品可能在多个渠道上架，各渠道的价格 / 库存 / 预订 / 退款策略不一样。
-- 运营要一眼看出「哪个渠道挂着、什么状态、策略怎么配的」。
--
-- 策略是 jsonb，::text 出（调用方自己解释，不在视图里猜）。
CREATE VIEW v_ops_product_listing AS
SELECT cl.id                AS channel_listing_id,
       cl.product_id,
       p.product_code,
       p.title            AS product_title,
       cl.channel_id,
       ch.code              AS channel_code,
       ch.name              AS channel_name,
       ch.channel_type,
       ch.default_currency,
       cl.status            AS listing_status,
       cl.price_policy::text   AS price_policy,
       cl.stock_policy::text   AS stock_policy,
       cl.booking_policy::text AS booking_policy,
       cl.refund_policy_override::text AS refund_policy_override,
       cl.min_order_qty,
       cl.max_order_qty,
       cl.sort_weight,
       cl.published_at::text   AS published_at,
       cl.created_at::text     AS created_at,
       -- 绑了几个源（路由候选）
       (SELECT count(*) FROM channel_listing_source cls
         WHERE cls.channel_listing_id = cl.id AND cls.enabled)         AS source_count
  FROM channel_listing cl
  JOIN product p ON p.id = cl.product_id
  JOIN channel ch ON ch.id = cl.channel_id;

COMMENT ON VIEW v_ops_product_listing IS
    '运营台商品上架配置：一行一个「商品 × 渠道」，带状态与四类策略';

-- -------------------------------------------------------------------------------------
-- ④ 售价行
-- -------------------------------------------------------------------------------------
--
-- 售价行是「这个变体哪天卖多少钱」。**这里不重算售价**：
-- 售价是定价函数（fn_price_variant）在下单时定的，
-- 售价行（price_calendar）是**声明**（我们打算这么卖），
-- 两者不一致是正常的 —— 真正的成交价在订单明细的快照里。
--
-- 所以这里带的是「我们对外报的价」，对账要对着订单明细看。
-- 成本那一列带的是**源侧成本**（cost_price），带 source 标记它是哪儿来的。
-- 折算因子 fx_rate 与快照日期 fx_as_of 一并带出 ——
-- 没折算过就不留汇率快照（同币种因子 1、快照日期为空），所以这两列可能为空。
--
-- channel_id 与 session_id 可能为空：售价行可以按渠道定，也可以按场次定。
-- 这里带出来，运营看得出「这一行是哪个范围的价格」。
CREATE VIEW v_ops_product_price AS
SELECT pc.id                AS price_calendar_id,
       pc.product_id,
       p.product_code,
       pc.product_variant_id,
       pv.variant_code,
       pv.title             AS variant_title,
       pc.date::text        AS price_date,
       pc.session_id,
       pc.channel_id,
       ch.code              AS channel_code,
       pc.cost_source_product_id,
       s.code               AS cost_supplier_code,
       pc.sell_price::text  AS sell_price,
       pc.list_price::text  AS list_price,
       pc.discount_pct::text AS discount_pct,
       pc.cost_price::text  AS cost_price,
       pc.currency,
       pc.fx_rate::text     AS fx_rate,
       pc.fx_as_of::text    AS fx_as_of,
       pc.price_locked,
       pc.source,
       pc.status,
       pc.rule::text        AS price_rule,
       pc.synced_at::text   AS synced_at,
       pc.updated_at::text  AS updated_at
  FROM price_calendar pc
  JOIN product p ON p.id = pc.product_id
  LEFT JOIN product_variant pv ON pv.id = pc.product_variant_id
  LEFT JOIN channel ch ON ch.id = pc.channel_id
  LEFT JOIN supplier s ON s.id = pc.cost_source_product_id;

COMMENT ON VIEW v_ops_product_price IS
    '运营台售价行：一行一条对外报价（不是成交价 —— 成交价在订单明细快照里）';

-- -------------------------------------------------------------------------------------
-- ⑤ 给客户看的文案
-- -------------------------------------------------------------------------------------
--
-- 硬约束 9：展示文案一律行级表 + locale 列。
-- 所以这里是三张行级表并起来，每行带自己那一块的种类。
--
-- 这一块对运营有用是因为「改了文案但没人看见生效」是个常见问题：
-- 亮点 / 包含 / 须知 各写在哪、什么 locale、什么顺序，一屏看得清。
CREATE VIEW v_ops_product_content AS
SELECT 'highlight'::text      AS content_kind,
       h.id                   AS content_id,
       h.product_id,
       p.product_code,
       h.locale,
       NULL::text             AS kind,
       h.content,
       NULL::text             AS title,
       h.sort_order
  FROM product_highlight h
  JOIN product p ON p.id = h.product_id
UNION ALL
SELECT 'inclusion'::text,
       i.id,
       i.product_id,
       p.product_code,
       i.locale,
       i.kind,
       i.content,
       NULL::text,
       i.sort_order
  FROM product_inclusion i
  JOIN product p ON p.id = i.product_id
UNION ALL
SELECT 'note'::text,
       n.id,
       n.product_id,
       p.product_code,
       n.locale,
       n.kind,
       n.content,
       n.title,
       n.sort_order
  FROM product_note n
  JOIN product p ON p.id = n.product_id;

COMMENT ON VIEW v_ops_product_content IS
    '运营台展示文案：一行一条（亮点 / 包含项 / 须知），带 locale 与顺序';
