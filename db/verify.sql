-- =====================================================================================
-- Ticket Center — 验收查询 verify.sql
-- 用法： psql -d ticket_center -f db/verify.sql
--
-- 目标：证明 schema 真的能同时承载 5 类异构 GDS 源，并能支撑
--       多源归一化 → 多源比价 → 自动选源 → 交易 → 履约 → 结算 的完整链路。
-- 每一节都有"期望"注释；最后一节用断言表给出 PASS/FAIL 汇总。
-- =====================================================================================

\pset border 2
\echo '════════════════════════ A. 结构盘点 ════════════════════════'
SELECT
    (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE') AS tables,
    (SELECT count(*) FROM pg_views WHERE schemaname='public')                                      AS views,
    (SELECT count(*) FROM pg_indexes WHERE schemaname='public')                                     AS indexes,
    (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal)                                       AS triggers,
    (SELECT count(*) FROM pg_constraint WHERE contype='c')                                         AS check_constraints;

\echo ''
\echo '════════════════════════ B1. 跨源覆盖度（一个商品几个源在供） ════════════════════════'
-- 期望：P1 香港故宫 supplier_count=3 且 has_redundancy=t；P3/P4/P5 单源
SELECT product_code, title, supplier_count, primary_source_count, has_redundancy, suppliers
FROM v_product_source_coverage
ORDER BY supplier_count DESC, product_code;

\echo ''
\echo '════════════════════════ B2. 多源比价（成本已按汇率归一到 CNY） ════════════════════════'
-- 期望：同一 product 的不同源，min_net_cost_base 可直接比较；跨币种(P1 的 CNY 源 vs HKD 源)可排序
SELECT product_id, supplier_code, external_id, source_currency_hint, min_net_cost_native, min_net_cost_base, priced_days, availability_mode
FROM (
    SELECT c.*, (SELECT min(spc.currency) FROM supplier_price_calendar spc
                  WHERE spc.supplier_product_id = c.supplier_product_id) AS source_currency_hint
    FROM v_product_source_compare c
) t
ORDER BY product_id, min_net_cost_base NULLS LAST;

\echo ''
\echo '════════════════════════ B3. 自动选源路由决策 ════════════════════════'
-- 期望：C2C 渠道 P1 成人票 route_rank=1 的应是成本最低的源（票付通 CNY108 → HKD 等值）
SELECT channel_code, product_title, date, ticket_type_code, supplier_code, source_currency,
       net_price, fx_rate, cost_base, priority, fallback_order, route_rank, availability_mode
FROM v_source_routing_candidates
WHERE product_title LIKE '香港故宫%'
ORDER BY channel_code, date, ticket_type_code, route_rank;

\echo ''
\echo '════════════════════════ B4. 场次级多源冗余（同一可售场次的多个供给源） ════════════════════════'
-- 期望：P1 的 day+5 场次有 3 个源（globaltix 主 / jtb 备 / 票付通 备）
SELECT p.title, ps.session_date, ps.slot_key, sup.code AS supplier, pss.role, pss.priority,
       ss.external_id AS source_session
FROM product_session ps
JOIN product p ON p.id = ps.product_id
JOIN product_session_source pss ON pss.product_session_id = ps.id
JOIN supplier_session ss ON ss.id = pss.supplier_session_id
JOIN supplier sup ON sup.id = pss.supplier_id
ORDER BY p.product_code, ps.session_date, pss.priority;

\echo ''
\echo '════════════════════════ C1. 订单履约漏斗（付了没出票检测） ════════════════════════'
-- 期望：订单3 suspected_lost=t（已付款 30 分钟仍无已出票凭证）
SELECT order_no, order_status, payment_status, booking_count, confirmed_bookings, failed_bookings,
       voucher_count, issued_vouchers, used_vouchers, suspected_lost
FROM v_order_fulfillment_gap
ORDER BY placed_at;

\echo ''
\echo '════════════════════════ C2. 结算缺口 ════════════════════════'
-- 期望：两条已确认预订，票付通那条出现在结算单里，globaltix 那条也在
SELECT supplier_code, booking_no, external_booking_id, order_no, settlement_lines
FROM v_settlement_gap
ORDER BY supplier_code;

\echo ''
\echo '════════════════════════ C3. 结算差异行 ════════════════════════'
SELECT s.statement_no, sup.code AS supplier, sl.external_ref, sl.gross_amount, sl.net_amount,
       sl.discrepancy_type, sl.discrepancy_amount, sl.note
FROM settlement_line sl
JOIN settlement_statement s ON s.id = sl.statement_id
JOIN supplier sup ON sup.id = s.supplier_id
ORDER BY sl.id;

\echo ''
\echo '════════════════════════ C4. 源健康度 ════════════════════════'
SELECT code, name, status, active_products, mapped_products, payloads_1h, last_sync_at, failed_jobs_24h
FROM v_supplier_sync_health
ORDER BY code;

\echo ''
\echo '════════════════════════ D1. 异构源字段落位检查（原样层 vs 规范层） ════════════════════════'
-- 期望：每个源的原始报文风格各异，但都能在 supplier_product 里原样保存，
--       且通过 product_mapping 归一到同一规范商品
SELECT sup.code AS supplier,
       sp.external_id,
       sp.raw_title,
       (SELECT string_agg(DISTINCT p.product_code, ',')
          FROM product_mapping m JOIN product p ON p.id = m.product_id
         WHERE m.supplier_product_id = sp.id AND m.status='active') AS mapped_to,
       (SELECT count(*) FROM jsonb_object_keys(sp.source_attributes)) AS raw_attr_keys
FROM supplier_product sp
JOIN supplier sup ON sup.id = sp.supplier_id
ORDER BY sup.code, sp.external_id;

\echo ''
\echo '════════════════════════ D2. 规范化属性（半 SQL 的落地形态） ════════════════════════'
-- 期望：异构源的同义属性最终收敛到同一组规范键
SELECT p.product_code,
       p.attributes -> 'duration_minutes'      AS duration_minutes,
       p.attributes -> 'age_limit'             AS age_limit,
       p.attributes -> 'instant_confirmation'  AS instant_confirmation,
       p.attributes -> 'free_child_limit'      AS free_child_limit
FROM product p
ORDER BY p.product_code;

\echo ''
\echo '════════════════════════ E. 不变量断言（全部应 passed=t） ════════════════════════'
-- 断言来源：迁移文件里的 v_invariant_checks 视图（条数以视图定义为准，单一事实来源）
SELECT seq, check_name, expected, actual, passed,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM v_invariant_checks
ORDER BY seq;

\echo ''
\echo ''
\echo '════════════════════════ G1. C端列表页直出（读模型，无额外 join） ════════════════════════'
-- 期望：每个渠道每商品一张卡片，带起价、标签、卖点、评分、最近可售日
SELECT channel_code, product_id, title, from_price, list_price, currency, rating, review_count,
       next_available_date, available_days, tag_labels, selling_points, city_name, meeting_point
FROM v_c_listing_feed
ORDER BY channel_code, sort_weight DESC;

\echo ''
\echo '════════════════════════ G2. C端详情页聚合 ════════════════════════'
-- 期望：亮点 / 须知 / 包含项 / 标签 / 评价 一次性聚合出来，不再猜 jsonb 字段名
SELECT product_code, title, address,
       jsonb_array_length(COALESCE(highlights,'[]'::jsonb))          AS n_highlights,
       jsonb_array_length(COALESCE(notes,'[]'::jsonb))               AS n_notes,
       jsonb_array_length(COALESCE(inclusions,'[]'::jsonb))          AS n_inclusions,
       jsonb_array_length(COALESCE(tags,'[]'::jsonb))                AS n_tags,
       jsonb_array_length(COALESCE(reviews,'[]'::jsonb))             AS n_reviews,
       rating, review_count
FROM v_c_product_detail
ORDER BY product_code;

\echo ''
\echo '════════════════════════ G3. C端日历格子 ════════════════════════'
-- 期望：售罄/闭馆日也有格子（前端要画灰），而不是"没有这行"
SELECT c.product_id, p.product_code, c.date, c.price_min, c.price_max, c.status, c.session_count,
       c.ticket_types
FROM c_product_calendar c JOIN product p ON p.id = c.product_id
ORDER BY c.product_id, c.date;

\echo ''
\echo '════════════════════════ G4. 读模型漂移检测 ════════════════════════'
-- 期望：drifted 全为 f，说明刷新作业跟上了价格日历
SELECT channel_id, product_id, card_from_price, truth_min_price, drifted
FROM v_c_readmodel_drift
ORDER BY product_id;

\echo ''
\echo '════════════════════════ G5. 购物车与库存预占 ════════════════════════'
-- 期望：活跃购物车有对应活跃预占；已转化的购物车其预占已被消费
SELECT c.cart_no, c.status, p.product_code, ci.quantity AS cart_qty, ci.unit_price,
       h.hold_no, h.quantity AS hold_qty, h.status AS hold_status, h.expires_at
FROM cart c
JOIN cart_item ci ON ci.cart_id = c.id
JOIN product p ON p.id = ci.product_id
LEFT JOIN inventory_hold h ON h.id = ci.hold_id
ORDER BY c.id;

\echo ''
\echo '════════════════════════ G6. 结算页动态表单规格 ════════════════════════'
-- 期望：C2C 渠道的 P1 成人票要求 姓名+证件号；儿童票同样要求；敏感级别标 sensitive
SELECT product_id, ticket_type_code, field_code, label, data_type, required, min_age, max_age, privacy_level
FROM v_c_checkout_requirements
ORDER BY product_id, ticket_type_code, sort_order;

\echo ''
\echo '════════════════════════ G7. 持票人采集与优惠券核销 ════════════════════════'
-- 期望：订单1 是 2 张票 → 2 组 holder_name；两个用券订单都有核销记录
SELECT o.order_no, oi.id AS item_id, oi.quantity,
       (SELECT count(DISTINCT oh.sequence) FROM order_holder oh
         WHERE oh.order_item_id = oi.id AND oh.field_code = 'holder_name') AS holder_count,
       o.coupon_id, cp.code AS coupon_code,
       (SELECT sum(cr.discount_amount) FROM coupon_redemption cr WHERE cr.order_id = o.id) AS coupon_discount,
       o.discount, o.total
FROM sales_order o
JOIN sales_order_item oi ON oi.order_id = o.id
LEFT JOIN coupon cp ON cp.id = o.coupon_id
ORDER BY o.id, oi.id;

\echo ''
\echo '════════════════════════ G8. 核销端 ════════════════════════'
SELECT vr.id, v.voucher_no, v.code, g.code AS gate_code, g.name AS gate_name,
       go.code AS operator_code, go.name AS operator_name, vr.result, vr.scanned_at
FROM voucher_redemption vr
JOIN voucher v ON v.id = vr.voucher_id
LEFT JOIN gate g ON g.id = vr.gate_id
LEFT JOIN gate_operator go ON go.id = vr.gate_operator_id
ORDER BY vr.id;

\echo ''
\echo '════════════════════════ G9. C端变体差异事实（差异走到读模型） ════════════════════════'
-- 期望：两日票的 valid_days=2、axes 带 pass_type=2d；读模型带出了差异，前端不 join 主数据
SELECT f.channel_id, f.variant_code, f.audience, f.axes, f.valid_days,
       f.refundable, f.refund_fee_percent,
       cal.price_min, cal.price_max, cal.available_days, cal.first_date, cal.last_date
FROM v_c_variant_feed f
JOIN LATERAL (
    SELECT MIN(cvc.price_min) AS price_min, MAX(cvc.price_max) AS price_max,
           COUNT(*) FILTER (WHERE cvc.status = 'available') AS available_days,
           MIN(cvc.date) AS first_date, MAX(cvc.date) AS last_date
      FROM c_variant_calendar cvc
     WHERE cvc.channel_id = f.channel_id AND cvc.product_variant_id = f.product_variant_id
) cal ON true
ORDER BY f.channel_id, f.variant_code;

\echo ''
\echo '════════════════════════ H1. 变体矩阵（一个商品下到底有哪些可售组合） ════════════════════════'
-- 期望：环球影城 8 个变体，人群 × 票种 × 园区范围三个维度；加购件单独成行
SELECT variant_code, variant_role, ticket_type_code, axes, addon_count
FROM v_product_variant_matrix
WHERE product_code = 'SKU-CN-USJ-BEIJING'
ORDER BY sort_order, variant_code;

\echo ''
\echo '════════════════════════ H2. 变体级路由（不同组合的首选源不同） ════════════════════════'
-- 期望：老年票首选 Trip.com（486 < 505），其余多由 Zowoyoo（自由行）胜出；
--       USJ-CHILD-1D-SNW / USJ-CHILD-2D-STD 只有 Zowoyoo 一个候选（Trip.com 没有儿童园区票）
SELECT variant_code, supplier_code, external_variant_id, net_price, cost_base, route_rank, availability_mode
FROM v_variant_routing_candidates
WHERE product_code = 'SKU-CN-USJ-BEIJING'
ORDER BY variant_code, route_rank;

\echo ''
\echo '════════════════════════ H3. 覆盖语义（一个源变体覆盖多个规范变体） ════════════════════════'
-- 期望：Zowoyoo 的 ZWO-1D-BASE 一个源变体覆盖成人/儿童/老年三个规范变体（is_exact=f）；
--       所有 can_fulfil=t，gaps 为空
SELECT variant_code, supplier_code, external_variant_id, is_exact, can_fulfil, gaps
FROM v_variant_source_coverage
WHERE product_code = 'SKU-CN-USJ-BEIJING'
ORDER BY variant_code, supplier_code;

\echo ''
\echo '════════════════════════ H4. 两层结构的表达边界（为什么必须有变体层） ════════════════════════'
-- 期望：商品级路由视图对环球影城输出 0 行 —— 「成人·一日·园区通票」与「儿童·一日·园区通票」
--       在 (product, ticket_type) 这一层无法区分，源侧也没有一一对应的 SKU；
--       变体级路由视图对同一商品输出 14 行并给出首选源
SELECT
  (SELECT count(*) FROM v_source_routing_candidates WHERE product_title LIKE '%环球影城%')      AS old_product_level_rows,
  (SELECT count(*) FROM v_variant_routing_candidates WHERE product_code='SKU-CN-USJ-BEIJING')  AS new_variant_level_rows;

\echo ''
\echo '════════════════════════ H5. 变体级交易链路（明细 / 预订 / 出票 / 实名） ════════════════════════'
-- 期望：订单5 两行明细是同一商品的两个不同变体；两条预订都挂在 Zowoyoo 的同一个源变体上
SELECT o.order_no, p.product_code, pv.variant_code, oi.quantity, oi.unit_price, oi.unit_cost,
       oi.supplier_id, sv.external_variant_id, b.booking_no, b.status AS booking_status,
       v.voucher_no, v.code AS voucher_code
FROM sales_order o
JOIN sales_order_item oi ON oi.order_id = o.id
JOIN product p ON p.id = oi.product_id
JOIN product_variant pv ON pv.id = oi.product_variant_id
LEFT JOIN booking b ON b.order_item_id = oi.id
LEFT JOIN supplier_variant sv ON sv.id = b.supplier_variant_id
LEFT JOIN voucher v ON v.order_item_id = oi.id
WHERE o.id = 5
ORDER BY oi.id;

\echo ''
\echo '════════════════════════ H6. 变体级 C 端日历与实名要求 ════════════════════════'
-- 期望：同一天不同变体价格不同、可履约源数不同（儿童园区通票只有 1 个源）
SELECT cvc.date, pv.variant_code, cvc.price_min, cvc.status, cvc.source_count
FROM c_variant_calendar cvc
JOIN product_variant pv ON pv.id = cvc.product_variant_id
ORDER BY pv.sort_order;

\echo ''
\echo '════════════════════════ H7. 变体覆盖缺口诊断（运营排查用） ════════════════════════'
-- 期望：人为把 Trip.com 成人票的覆盖改成不含 park_scope，覆盖判定立刻翻脸并报出缺口
SELECT pv.variant_code,
       fn_variant_covered('{"axes":{"audience":["adult"],"pass_type":["1d"]},"excludes":[]}', pv.id) AS can_fulfil_without_park,
       fn_variant_coverage_gaps('{"axes":{"audience":["adult"],"pass_type":["1d"]},"excludes":[]}', pv.id) AS gaps
FROM product_variant pv
WHERE pv.product_id = 6 AND pv.variant_code IN ('USJ-ADULT-1D-STD','USJ-ADULT-1D-SNW')
ORDER BY pv.variant_code;

\echo ''
\echo '════════════════════════ H8. 日历格子的有效期终点（前端不自己加一天） ════════════════════════'
-- 期望：两日票的格子 valid_to = 格子日期 + 2；单日票 = 格子日期 + 1
SELECT pv.variant_code, fn_variant_validity_days(pv.id) AS valid_days,
       cvc.date, cvc.valid_to,
       (cvc.valid_to = cvc.date + fn_variant_validity_days(pv.id)) AS valid_to_ok
FROM c_variant_calendar cvc
JOIN product_variant pv ON pv.id = cvc.product_variant_id
ORDER BY pv.sort_order, cvc.date;


\echo ''
\echo '════════════════════════ I1. 按团报价（priceSettingType=4）════════════════════════════'
-- 期望：订单6 一行明细 = 7 人成团，团总价 1200.00，人均分摊 171.43；
--       总价与人头数不成正比（171.43 × 7 = 1200.01，团总价真值在快照 group_total）
SELECT o.order_no, p.product_code, pv.variant_code, oi.pricing_basis,
       oi.quantity AS group_size, oi.unit_price AS unit_price_per_person,
       oi.total_price AS group_total, oi.detail_snapshot->>'group_total' AS snapshot_group_total,
       (oi.unit_price * oi.quantity) AS naive_product,
       oi.total_price - (oi.unit_price * oi.quantity) AS rounding_gap
FROM sales_order o
JOIN sales_order_item oi ON oi.order_id = o.id
JOIN product p ON p.id = oi.product_id
JOIN product_variant pv ON pv.id = oi.product_variant_id
WHERE oi.pricing_basis = 'per_group'
ORDER BY oi.id;

\echo ''
\echo '════════════════════════ I2. 价格保护（isPrivatePrice）═══════════════════════════════'
-- 期望：只有「采纳源是价格保护源」的那一行被锁价，售价原样等于源方挂牌价；
--       同一商品里采纳 Zowoyoo 的变体没有锁价（可自主定价）
SELECT pv.variant_code, sup.code AS source_supplier, sv.external_variant_id AS source_variant,
       sv.is_price_locked AS source_protected,
       pc.cost_source_product_id, pc.sell_price, pc.price_locked,
       spc.supplier_price AS source_list_price, spc.net_price AS source_net_price,
       (pc.sell_price = spc.supplier_price) AS price_equals_source_list
FROM price_calendar pc
JOIN product_variant pv ON pv.id = pc.product_variant_id
JOIN supplier_price_calendar spc ON spc.supplier_product_id = pc.cost_source_product_id
                             AND spc.product_variant_id = pc.product_variant_id
                             AND spc.date = pc.date
                             AND spc.status = 'available'
JOIN supplier_variant sv ON sv.id = spc.supplier_variant_id
JOIN supplier_product sp ON sp.id = sv.supplier_product_id
JOIN supplier sup ON sup.id = sp.supplier_id
WHERE pv.product_id = 6
ORDER BY pv.sort_order, sup.code;

\echo ''
\echo '════════════════════════ I3. 计价基准分布 ═════════════════════════════════════════════'
-- 期望：按人计价 6 行、按团计价 1 行；按团那行的总价 ≠ 单价 × 人数
SELECT pricing_basis,
       count(*) AS item_count,
       sum(quantity) AS total_qty,
       sum(total_price) AS total_amount,
       sum(CASE WHEN pricing_basis = 'per_person'
                THEN (total_price <> unit_price * quantity)::int ELSE 0 END) AS broken_person_rows
FROM sales_order_item
GROUP BY pricing_basis
ORDER BY pricing_basis;

\echo ''
\echo '════════════════════════ K1. 套装供给形态（一个源 SKU 卖整套） ════════════════════════'
-- 套装 = 源侧把整套当一个 SKU 卖。规范侧声明「这套包含什么」，
-- 源侧声明「这套卖多少钱、能用几天」。两边对不上 = 卖不出去。
SELECT pv.variant_code AS canonical_variant,
       sv.external_variant_id AS source_set_sku,
       svb.valid_days AS set_valid_days,
       fn_variant_validity_days(svb.product_variant_id) AS canonical_window_days,
       (svb.valid_days >= fn_variant_validity_days(svb.product_variant_id)) AS covers_window,
       count(svbp.id) AS declared_parts,
       (SELECT count(*) FROM product_variant_relation r
         WHERE r.parent_variant_id = svb.product_variant_id AND r.relation_type = 'included') AS canonical_parts,
       sum(svbp.quantity) AS admissions_per_set
FROM supplier_variant_bundle svb
JOIN product_variant pv ON pv.id = svb.product_variant_id
JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id
LEFT JOIN supplier_variant_bundle_part svbp ON svbp.bundle_id = svb.id
WHERE svb.status = 'active'
GROUP BY 1,2,3,4,5,svb.product_variant_id
ORDER BY 1;

\echo ''
\echo '════════════════════════ K2. 套装成本分摊守恒（分摊之和 = 整套成本） ════════════════════'
-- 套装的成本来自源侧那个整套报价（一笔 1500），不是各成分单价相加。
-- 分摊到成分只是为了对账：Σ 分摊必须精确等于整套成本，一分不能差。
SELECT pv.variant_code, pc.date, pc.sell_price, pc.cost_source_product_id AS adopted_source_product,
       (pc.rule->'combo'->0->>'currency') AS source_currency, pc.fx_rate, pc.fx_as_of,
       (pc.rule->>'bundle')::boolean AS priced_as_bundle,
       jsonb_array_length(pc.rule->'combo') AS parts,
       (SELECT round(sum((e->>'unit_cost')::numeric),2) FROM jsonb_array_elements(pc.rule->'combo') e) AS parts_cost_sum,
       pc.cost_price,
       (SELECT round(sum((e->>'unit_cost')::numeric),2) FROM jsonb_array_elements(pc.rule->'combo') e) = pc.cost_price AS cost_conserved
FROM price_calendar pc
JOIN product_variant pv ON pv.id = pc.product_variant_id
WHERE (pc.rule->>'bundle')::boolean IS TRUE
ORDER BY 1,2;

\echo ''
\echo '════════════════════════ K3. 套装交易链路（一套 → 一条预订 → 三张券 → 一条预占） ═════'
-- 三个单位不许混：
--   售卖单位 = 套（订单明细的 quantity）
--   成分单位 = 预订的单位（一个源 SKU 一条预订，份数是套数）
--   入场份数 = 发的券的张数（成分 × 份数）
-- 判据：booked_sets = 1 而 booked_admissions = 3 —— 买的是一套，进场的是三个人。
SELECT o.order_no, o.status AS order_status, oi.quantity AS sets_ordered,
       oi.total_price,
       (SELECT count(*) FROM booking b WHERE b.order_item_id = oi.id) AS bookings,
       (SELECT b.request_payload->>'quantity' FROM booking b WHERE b.order_item_id = oi.id LIMIT 1) AS booked_sets,
       (SELECT b.request_payload->>'admission_quantity' FROM booking b WHERE b.order_item_id = oi.id LIMIT 1) AS booked_admissions,
       (SELECT count(*) FROM sales_order_item_source s WHERE s.order_item_id = oi.id) AS component_rows,
       (SELECT sum(s.admission_quantity) FROM sales_order_item_source s WHERE s.order_item_id = oi.id) AS admissions,
       (SELECT count(*) FROM voucher v WHERE v.order_item_id = oi.id AND v.status = 'issued') AS issued_vouchers,
       (SELECT count(*) FROM inventory_hold h WHERE h.order_id = o.id AND h.product_variant_id = oi.product_variant_id) AS holds,
       (SELECT sum(h.quantity) FROM inventory_hold h WHERE h.order_id = o.id AND h.product_variant_id = oi.product_variant_id) AS held_sets,
       (SELECT count(*) FROM inventory_hold h WHERE h.order_id = o.id AND h.source_ticket_type_id IS NOT NULL) AS holds_on_source_ticket_type
FROM sales_order o
JOIN sales_order_item oi ON oi.order_id = o.id
JOIN product_variant pv ON pv.id = oi.product_variant_id
WHERE pv.variant_key = 'family:2adult:1child:set'
ORDER BY o.id;

\echo ''
\echo '════════════════════════ K4. 套装退款后的事实（成分层面的事实一起改） ════════════════'
-- 整单退款要把成分的券 / 预订 / 预占一起改掉。
-- 判据：refunded_vouchers = 3、still_issued = 0、cancelled_bookings = 1、voided_keeps_consumed = 1。
-- 最后一项是「卖出的事实不许被改写」：预占收回了，consumed_quantity 仍然是原数。
SELECT o.order_no, o.status AS order_status,
       (SELECT count(*) FROM voucher v JOIN sales_order_item oi2 ON oi2.id = v.order_item_id
         WHERE oi2.order_id = o.id AND v.status = 'refunded') AS refunded_vouchers,
       (SELECT count(*) FROM voucher v JOIN sales_order_item oi2 ON oi2.id = v.order_item_id
         WHERE oi2.order_id = o.id AND v.status = 'issued') AS still_issued,
       (SELECT count(*) FROM booking b WHERE b.order_id = o.id AND b.status = 'cancelled') AS cancelled_bookings,
       (SELECT count(*) FROM inventory_hold h WHERE h.order_id = o.id AND h.status = 'voided') AS voided_holds,
       (SELECT count(*) FROM inventory_hold h WHERE h.order_id = o.id AND h.status = 'voided'
           AND h.consumed_quantity = h.quantity) AS voided_keeps_consumed
FROM sales_order o
JOIN sales_order_item oi ON oi.order_id = o.id
JOIN product_variant pv ON pv.id = oi.product_variant_id
WHERE pv.variant_key = 'family:2adult:1child:set'
  AND o.status = 'refunded'
ORDER BY o.id;

\echo ''
\echo '════════════════════════ K5. 套装缺口诊断（为什么卖不了） ════════════════════════════'
-- 空 reason = 这一天套装是能卖的。
SELECT product_variant_id, supplier_variant_id, date, session_id, source_session_id,
       source_ticket_type_id, set_price, valid_days, union_days, reason
FROM v_bundle_gap
ORDER BY product_variant_id, supplier_variant_id, date;

\echo ''
\echo '════════════════════════ K6. 套装池子上的需求对账（一单要了多少套 vs 落单时还剩多少） ═══════'
-- 逐明细看是看不出来的：每条明细都记着自己那一份。
-- 按池子加总才看得见超卖：需求 > 落单时看到的余量。
SELECT order_id, supplier_session_id, source_ticket_type_id,
       demand_sets, remaining_at_order, known_at_order
FROM v_bundle_pool_demand
ORDER BY order_id, supplier_session_id, source_ticket_type_id;


\echo ''
\echo '════════════════════════ K7. 三种供给形态对照（单张 / 配方 / 套装） ═════════════════════'
-- 同一份交付，不同的供给方式、不同的成本、不同的缺口 —— 放在一张表上才看得见。
-- gaps 为空 = 这一形态当天卖得掉；有 gaps = 说清楚差在哪。
SELECT product_variant_id, variant_code, date, channel_id, supply_form,
       supplier_codes, supplier_count, cost_in_target, currency,
       component_count, admission_quantity, valid_days, can_fulfil, gaps
FROM v_variant_supply_forms
ORDER BY product_variant_id, date, channel_id, supply_form;

\echo ''
\echo '════════════════════════ K8. 声明过的形态不许在对照视图里消失 ═════════════════════'
-- 声明了就必须在对照视图里出现（哪怕当天卖不掉）。
-- 少了 = 有形态声明了却没进对照表 —— 那一路供给在运营侧是隐形的。
SELECT d.product_variant_id, d.date, d.has_single, d.has_recipe, d.has_bundle,
       (SELECT count(*) FROM v_variant_supply_forms f
         WHERE f.product_variant_id = d.product_variant_id AND f.date = d.date) AS rows_in_forms
FROM v_variant_declared_forms d
WHERE d.has_single OR d.has_recipe OR d.has_bundle
ORDER BY d.product_variant_id, d.date;

\echo ''
\echo '════════════════════════ K9. 源 SKU 下架时形态不许缩小（022） ═════════════════════'
-- 源侧把某个 SKU 下架是事实，我们改不了源侧。但规矩是：
--   - 声明过的成分不许消失（成分行留着，只是没有价）；
--   - 形态行不许从对照视图里消失（看得见，只是不可售）；
--   - 缺口要点名「源 SKU 已下架」；
--   - 定价函数不许再给这个套餐定价（少一个成分的套餐不是这个套餐）。
--
-- 这一节在一个事务里做，跑完回滚：验收查询不改数据。
BEGIN;

CREATE TEMP TABLE k9_before ON COMMIT DROP AS
SELECT product_variant_id, supply_form, count(*) AS rows
  FROM v_variant_supply_forms
 GROUP BY product_variant_id, supply_form;

-- 把配方与套装的源 SKU 全部下架。
UPDATE supplier_variant SET status = 'inactive'
 WHERE id IN (
       SELECT supplier_variant_id FROM supplier_variant_composition WHERE status = 'active'
       UNION
       SELECT supplier_variant_id FROM supplier_variant_bundle WHERE status = 'active');

\echo '--- 下架前后形态行数对比（必须一行不少） ---'
SELECT b.product_variant_id, b.supply_form, b.rows AS before_rows,
       COALESCE(a.rows, 0) AS after_rows
  FROM k9_before b
  LEFT JOIN (SELECT product_variant_id, supply_form, count(*) AS rows
               FROM v_variant_supply_forms GROUP BY 1, 2) a
    ON a.product_variant_id = b.product_variant_id
   AND a.supply_form = b.supply_form
 WHERE COALESCE(a.rows, 0) <> b.rows
 ORDER BY b.product_variant_id, b.supply_form;

\echo '--- 下架后的形态行（形态还在，不可售，缺口点名） ---'
SELECT product_variant_id, variant_code, date, channel_id, supply_form,
       cost_in_target, can_fulfil, gaps
  FROM v_variant_supply_forms
 WHERE supply_form IN ('recipe', 'bundle')
 ORDER BY product_variant_id, supply_form;

\echo '--- 缺口点名检查（配方 / 套装各 0 行 = 都点名了） ---'
SELECT (SELECT count(*) FROM v_variant_supply_forms f
         WHERE f.supply_form = 'recipe'
           AND NOT ('成分的源 SKU 已下架' = ANY(f.gaps)))   AS recipe_missing_gap,
       (SELECT count(*) FROM v_variant_supply_forms f
         WHERE f.supply_form = 'bundle'
           AND NOT ('套装的源 SKU 已下架' = ANY(f.gaps)))   AS bundle_missing_gap,
       -- 定价函数不许再给价（少一个成分的套餐不是这个套餐）
       (SELECT count(*) FROM v_variant_supply_forms f
         WHERE f.supply_form IN ('recipe', 'bundle')
           AND EXISTS (SELECT 1 FROM fn_price_variant(f.product_variant_id, f.date,
                                                       f.channel_id, f.channel_id))) AS still_priced;

ROLLBACK;

\echo ''
\echo '════════════════════════ K10. 改派：换源与重新定价是一件事（024） ════════════════════'
-- 改派不是「改一个字段」，是三处事实一起换：明细、履约成分行、库存预占。
-- 少改一处的后果：
--   - 不挪成分行 → 按 A 源的价格卖、按 B 源出票；
--   - 不挪库存预占 → 按新源卖、按旧源占着库存，新源那边多卖一份。
-- 改派过的明细不许把下单时的定价快照改回去 —— 那张快照记的是「当时报给客户的那个价」。
--
-- 这一节是只读的：看种子数据里那笔改派过的订单留下了什么。

\echo '--- 改派留痕（明细快照里的 reassignments） ---'
SELECT oi.id            AS order_item_id,
       o.idempotency_key,
       s->>'reason'                    AS reason,
       s->>'from_supplier_product_id' AS from_sp,
       s->>'to_supplier_product_id'   AS to_sp,
       s->>'from_unit_price'           AS from_price,
       s->>'to_unit_price'             AS to_price,
       s->>'currency'                  AS currency
  FROM sales_order_item oi
  JOIN sales_order o ON o.id = oi.order_id
  CROSS JOIN LATERAL jsonb_array_elements(
          COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb)) s
 ORDER BY oi.id, (s->>'at')::timestamptz;

\echo '--- 三处同源（明细 / 成分行 / 库存预占，必须是同一个源） ---'
SELECT oi.id                     AS order_item_id,
       oi.supplier_product_id    AS item_sp,
       src.supplier_product_id   AS source_row_sp,
       oi.supplier_id            AS item_supplier,
       h.supplier_id             AS hold_supplier,
       (oi.supplier_product_id IS NOT DISTINCT FROM src.supplier_product_id) AS item_eq_source_row,
       (oi.supplier_id        IS NOT DISTINCT FROM h.supplier_id)           AS item_eq_hold
  FROM sales_order_item oi
  JOIN sales_order_item_source src ON src.order_item_id = oi.id
  LEFT JOIN inventory_hold h ON h.order_id = oi.order_id
 WHERE oi.detail_snapshot ? 'reassignments'
 ORDER BY oi.id;

\echo '--- 待改派清单（未收款、还没预订过、跟当前世界对不上的明细） ---'
SELECT order_item_id, current_supplier, new_supplier,
       current_unit_price, new_unit_price, stale_reason
  FROM v_reassign_candidates
 ORDER BY order_item_id;

\echo ''
\echo '════════════════════════ K11. 源侧的售卖份数区间（025） ═══════════════════════'
-- 源价行上的 min_qty / max_qty 是源侧的一手事实（最少成团人数 / 单笔上限）。
-- 这一对整数以前全库没有一处读它：客户买 1 张按团价的票，系统按整团价收了 1200，
-- 源侧因为不足 6 人拒单 —— 钱收了、票出不来。
--
-- 口径：份数的单位 = 源侧的售卖单位（单张按人 = 份，按团 = 人，套装 = 套，
-- 配方 = 该源 SKU 的份数）。同一个源 SKU 顶多个成分时比的是这个 SKU 的总份数 ——
-- 源侧收到的是一条预订里的总份数。

\echo '--- 源侧声明了区间的价行（min_qty / max_qty） ---'
SELECT spc.supplier_variant_id, spc.product_variant_id, spc.date,
       spc.min_qty, spc.max_qty,
       fn_qty_servable(spc.min_qty, spc.max_qty, spc.min_qty) AS servable_at_min,
       fn_qty_servable(spc.min_qty, spc.max_qty, spc.max_qty) AS servable_at_max
  FROM supplier_price_calendar spc
 WHERE spc.min_qty IS NOT NULL OR spc.max_qty IS NOT NULL
 ORDER BY spc.supplier_variant_id, spc.product_variant_id, spc.date;

\echo '--- 明细快照里记着的区间（当时源侧接不接得住） ---'
SELECT oi.order_id, oi.product_variant_id, oi.quantity,
       l->>'supplier_variant_id' AS source_sku,
       l->'product_variant_ids'  AS canonical_variants,
       l->>'min_qty'              AS min_qty,
       l->>'max_qty'              AS max_qty,
       l->>'quantity'             AS bought_qty,
       fn_qty_servable((l->>'min_qty')::int, (l->>'max_qty')::int,
                       (l->>'quantity')::int) AS servable
  FROM sales_order_item oi
  CROSS JOIN LATERAL jsonb_array_elements(
          COALESCE(oi.detail_snapshot -> 'quantity_limits', '[]'::jsonb)) l
 ORDER BY oi.order_id;

\echo '--- 落单时当场拦（三种都拦住才算数） ---'
BEGIN;
DO $$
DECLARE
    v_variant BIGINT;
    v_combo   BIGINT;
    v_date    DATE;
    v_cdate   DATE;
    v_msg     TEXT;
    v_case    TEXT;
BEGIN
    SELECT id INTO v_variant FROM product_variant WHERE variant_key = 'standard:1d';
    SELECT id INTO v_combo   FROM product_variant WHERE variant_key = 'family:2adult:1child:studio_only';

    -- 日期跟着种子数据走（种子把按团那张票放在第 13 天、配方放在第 12 天）
    SELECT date INTO v_date
      FROM supplier_price_calendar
     WHERE product_variant_id = v_variant AND min_qty > 1 LIMIT 1;

    SELECT date INTO v_cdate
      FROM supplier_price_calendar
     WHERE product_variant_id = 9 LIMIT 1;

    FOREACH v_case IN ARRAY ARRAY['按团报价 1 个人（源侧最少 6 人成团）',
                                  '按团报价 41 个人（单笔上限 40）',
                                  '配方 7 套（同一个源 SKU 21 份，上限 20）']
    LOOP
        v_msg := NULL;

        BEGIN
            IF v_case LIKE '按团报价 1 个人%' THEN
                PERFORM o.order_id FROM fn_place_order(1, 'verify-k11-under',
                    jsonb_build_array(jsonb_build_object('variant_id', v_variant, 'quantity', 1,
                                                         'visit_date', v_date)),
                    3, jsonb_build_object('name', 'K11 演示'), NULL, '[]'::jsonb) o;
            ELSIF v_case LIKE '按团报价 41 个人%' THEN
                PERFORM o.order_id FROM fn_place_order(1, 'verify-k11-over',
                    jsonb_build_array(jsonb_build_object('variant_id', v_variant, 'quantity', 41,
                                                         'visit_date', v_date)),
                    3, jsonb_build_object('name', 'K11 演示'), NULL, '[]'::jsonb) o;
            ELSE
                PERFORM o.order_id FROM fn_place_order(1, 'verify-k11-combo',
                    jsonb_build_array(jsonb_build_object('variant_id', v_combo, 'quantity', 7,
                                                         'visit_date', v_cdate)),
                    3, jsonb_build_object('name', 'K11 演示'), NULL, '[]'::jsonb) o;
            END IF;
        EXCEPTION WHEN others THEN
            GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        END;

        RAISE NOTICE '% → %', v_case, COALESCE(v_msg, '【没有被拦住 —— 这是问题】');
    END LOOP;
END $$;
ROLLBACK;

\echo ''
\echo '════════════════════════ K12. 按团报价的单位价口径（026） ═════════════════════════'
-- 按团报价的源价行给的是**团总价 / 团成本**（整团 1200 / 1100），
-- 明细里记的单位价与单位成本是**分摊到人**的（171.43 / 157.14）。
-- 分摊口径只有一个实现：fn_unit_amount(basis, total, quantity)。
--
-- 这一节回答三个问题：
--   1. 写路径分摊对不对？
--   2. 读路径（待改派清单）的成本比较与写路径同口径吗？
--   3. 口径没修好时，不变量 118 会不会当场报警？

\echo '--- 按团明细：团总价 / 团成本 → 分摊到人 ---'
SELECT oi.id AS order_item_id,
       oi.pricing_basis,
       oi.quantity,
       (oi.detail_snapshot ->> 'group_total')::numeric AS group_total,
       oi.unit_price,
       fn_unit_amount(oi.pricing_basis, (oi.detail_snapshot ->> 'group_total')::numeric, oi.quantity) AS expect_unit_price,
       (oi.detail_snapshot ->> 'cost_price')::numeric AS group_cost,
       oi.unit_cost,
       fn_unit_amount(oi.pricing_basis, (oi.detail_snapshot ->> 'cost_price')::numeric, oi.quantity) AS expect_unit_cost,
       (oi.unit_price IS NOT DISTINCT FROM fn_unit_amount(oi.pricing_basis, (oi.detail_snapshot ->> 'group_total')::numeric, oi.quantity)
        AND oi.unit_cost  IS NOT DISTINCT FROM fn_unit_amount(oi.pricing_basis, (oi.detail_snapshot ->> 'cost_price')::numeric, oi.quantity))
       AS allocated_ok
  FROM sales_order_item oi
 WHERE oi.pricing_basis = 'per_group'
 ORDER BY oi.id;

\echo '--- 读路径与写路径同口径：待改派清单里的成本比较 ---'
-- 清单现在为空：按团的那一单（订单 12 / 明细 13）什么都没变，
-- 修复前它会被误报成「成本变了」（团成本 1100 vs 人均成本 157.14）。
SELECT count(*) AS stale_candidates FROM v_reassign_candidates;

\echo '--- 不变量 118 在口径没修好时会不会报警（把读路径改回有 bug 的版本看一眼） ---'
BEGIN;
CREATE OR REPLACE VIEW v_reassign_candidates AS
SELECT o.id AS order_id, o.order_no, o.channel_id, oi.id AS order_item_id, oi.product_id,
       oi.product_variant_id, (oi.detail_snapshot ->> 'visit_date')::date AS visit_date,
       oi.quantity, oi.supplier_product_id AS current_supplier_product_id, cur.name AS current_supplier,
       oi.unit_price AS current_unit_price, oi.unit_cost AS current_unit_cost,
       p.supplier_product_id AS new_supplier_product_id, nsup.name AS new_supplier,
       CASE WHEN oi.pricing_basis = 'per_group' THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2) ELSE p.sell_price END AS new_unit_price,
       p.cost_price AS new_unit_cost,
       (p.sell_price IS NOT NULL) AS can_reassign,
       CASE WHEN p.sell_price IS NULL THEN '当天没有可用报价'
            WHEN p.supplier_product_id IS DISTINCT FROM oi.supplier_product_id THEN '源变了'
            WHEN (CASE WHEN oi.pricing_basis = 'per_group' THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2) ELSE p.sell_price END) IS DISTINCT FROM oi.unit_price THEN '价变了'
            WHEN p.cost_price IS DISTINCT FROM oi.unit_cost THEN '成本变了'
       END AS stale_reason
  FROM sales_order o
  JOIN sales_order_item oi ON oi.order_id = o.id
  LEFT JOIN LATERAL fn_price_variant(oi.product_variant_id, (oi.detail_snapshot ->> 'visit_date')::date, o.channel_id, o.channel_id) p ON true
  LEFT JOIN supplier_product curp ON curp.id = oi.supplier_product_id
  LEFT JOIN supplier cur ON cur.id = curp.supplier_id
  LEFT JOIN supplier_product nsp ON nsp.id = p.supplier_product_id
  LEFT JOIN supplier nsup ON nsup.id = nsp.supplier_id
 WHERE o.status IN ('created','awaiting_payment') AND oi.status = 'pending'
   AND oi.product_variant_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sales_payment sp WHERE sp.order_id = o.id AND sp.status = 'succeeded')
   AND COALESCE((SELECT pv.variant_role FROM product_variant pv WHERE pv.id = oi.product_variant_id), 'base') <> 'combo'
   AND (SELECT count(*) FROM sales_order_item_source s WHERE s.order_item_id = oi.id) <= 1
   AND NOT EXISTS (SELECT 1 FROM booking b WHERE b.order_item_id = oi.id)
   AND NOT EXISTS (SELECT 1 FROM voucher v WHERE v.order_item_id = oi.id AND v.status IN ('issued','used'))
   AND (p.sell_price IS NULL OR p.supplier_product_id IS DISTINCT FROM oi.supplier_product_id
        OR (CASE WHEN oi.pricing_basis = 'per_group' THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2) ELSE p.sell_price END) IS DISTINCT FROM oi.unit_price
        OR p.cost_price IS DISTINCT FROM oi.unit_cost);
DO $$
DECLARE
  v_bad INT;
BEGIN
  -- 按 check_name 找，不按 seq 找：seq 会随着加条重新编号，
  -- 按序号定位的那天，重排一次就静悄悄指到别的门禁上去了。
  SELECT actual INTO v_bad FROM v_invariant_checks
   WHERE check_name = '待改派清单说「成本变了」的按团明细：按人均口径算也必须真的变了';
  IF v_bad IS NULL THEN
    RAISE EXCEPTION '  找不到这条不变量（check_name 变了？门禁本身丢了）';
  END IF;
  IF v_bad > 0 THEN
    RAISE NOTICE '  口径没修好时，「按团明细按人均口径算也必须真的变了」报警（actual=%）—— 门禁是活的', v_bad;
  ELSE
    RAISE NOTICE '  口径没修好时，「按团明细按人均口径算也必须真的变了」也没报警 —— 这是问题：门禁是死的';
  END IF;
END $$;
ROLLBACK;

\echo ''
\echo '════════════════════════ J. 序列对齐（应用第一次 INSERT 会不会撞主键） ═════════════════════'
-- 种子数据用了显式 id，identity 序列必须同步推进。
-- 序列停在 max(id) 之前时，应用第一次 INSERT 就报 duplicate key —— 这是「设计正确但跑不起来」的典型。
-- 判定：序列将要发出的下一个值必须大于该表当前 max(id)。
DO $$
DECLARE
  v_bad  text := '';
  v_seen int  := 0;
  r      record;
  v_max  bigint;
  v_last bigint;
  v_called boolean;
BEGIN
  FOR r IN
    SELECT s.relname AS seq,
           c.relname AS tbl,
           a.attname AS col
    FROM pg_class s
    JOIN pg_depend d
      ON d.objid = s.oid
     AND d.classid = 'pg_class'::regclass
     AND d.deptype IN ('a', 'i')
    JOIN pg_class c ON c.oid = d.refobjid
    JOIN pg_attribute a
      ON a.attrelid = c.oid
     AND a.attnum = d.refobjsubid
     AND NOT a.attisdropped
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND s.relkind = 'S'
  LOOP
    v_seen := v_seen + 1;
    EXECUTE format('SELECT COALESCE(max(%I),0) FROM %I', r.col, r.tbl) INTO v_max;
    EXECUTE format('SELECT last_value FROM %s', r.seq) INTO v_last;
    EXECUTE format('SELECT is_called FROM %s', r.seq) INTO v_called;
    -- is_called = true  → 下一个值是 last_value + 1
    -- is_called = false → 下一个值就是 last_value
    IF (v_called AND v_last < v_max) OR (NOT v_called AND v_last <= v_max) THEN
      v_bad := v_bad || r.tbl || '(seq=' || r.seq || ') ';
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION '序列未对齐，应用无法插入：%', v_bad;
  END IF;
  RAISE NOTICE '序列对齐检查：% 张表的 identity 序列均可正常发号', v_seen;
END $$;


\echo '════════════════════════ F. 汇总 ════════════════════════'
DO $$
DECLARE v_total int; v_failed int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT passed) INTO v_total, v_failed FROM v_invariant_checks;
  RAISE NOTICE '';
  RAISE NOTICE '════════════════════════════════════════════';
  RAISE NOTICE '  不变量断言：% 项，失败 % 项', v_total, v_failed;
  RAISE NOTICE '════════════════════════════════════════════';
  IF v_failed > 0 THEN
    RAISE EXCEPTION '不变量断言失败 % 项', v_failed;
  END IF;
END $$;
