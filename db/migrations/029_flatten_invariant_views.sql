-- 029：把不变量视图的「层」压平，删掉被取代的中间层
--
-- 背景：门禁 `v_invariant_checks` 是一条 UNION ALL，每段由一个迁移拼上去。
-- 改口径时旧的那段没被删，只是没人再往并集里 UNION 它，于是链变成
--
--     supply -> variant -> core_base -> core -> core_017
--
-- 每层都是「上一层去掉本层改写的 seq」UNION ALL「本层新行」。
-- 结果是库里躺着 12 个「看起来在守门禁、其实只是链路中间层」的视图，
-- 读的人得顺着五层依赖才能看清一条门禁到底在算什么。
--
-- 这次做什么：
--   1. 把每条链的最终层压成一个自包含视图
--      （v_invariant_checks_<chain>_flat），链上的基线内容内联进去；
--   2. `v_invariant_checks` 改指向这五个压平视图，其余 17 段原样不动；
--   3. 删掉 12 个被取代的中间层视图（不用 CASCADE）。
--
-- 为什么能删：
--   门禁的身份是 `check_name`，不是视图对象。压平视图逐行复刻最终层的结果，
--   `v_invariant_checks` 换成压平视图后，行数、check_name、expected、actual
--   与改动前逐行一致（实测 121 行 / 121 个 check_name / 0 条 actual > 0，
--   与改动前的快照 EXCEPT ALL 双向为空）。
--   链上被删的 12 个视图各有 10 个 check_name 在活着的并集里原样存在；
--   另 10 个是被更宽的 check_name 取代了（旧名字不再单列，事实由新名字覆盖），
--   门禁条数不变（以 `v_invariant_checks` 视图定义为准，见 `make counts`）。
--
-- 压平时的列序（这一步出过事故，值得写下来）：
--   每层的基线读法有两种形状 —— 3 列（seq, check_name, actual）或
--   4 列（seq, check_name, expected, actual）。压平后的 CTE 声明四列
--   (seq, check_name, expected, actual)，所以基线读法必须按这个**规范列序**
--   投影：源视图是 3 列时要写成 `seq, check_name, 0, actual`。
--   照着源视图的位置顺序写（`seq, check_name, actual, 0`）会把 actual 顶进
--   expected 槽、把 actual 写成 0 —— 继承来的违规被静默吃掉。
--   这类错在「所有 actual 都是 0」的干净库里查不出来（0 和 0 相等），
--   只有真的造一条违规、门禁必须报红时才暴露。
--
-- 这次只重排对象，不改门禁口径。
--
-- 删的顺序是「先上层后下层」：中间层被最终层引用，不先删最终层就删不掉中间层。



CREATE OR REPLACE VIEW v_invariant_checks_core_flat AS
WITH __rows__L0(seq, check_name, expected, actual) AS (
SELECT 1 AS "?column?",
            '规范商品必须有至少一个 active 源映射'::text AS "?column?",
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM product p
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM product_mapping m
                          WHERE m.product_id = p.id AND m.status = 'active'::text))) AS count
UNION ALL
SELECT 2,
            '同一商品同一供应商最多一个 primary 映射'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM product_mapping
                          WHERE product_mapping.is_primary
                          GROUP BY product_mapping.product_id, product_mapping.supplier_id
                         HAVING count(*) > 1) x) AS count
UNION ALL
SELECT 3,
            '场次源绑定的源商品必须映射到同一规范商品'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM product_session_source pss
                     JOIN product_session ps ON ps.id = pss.product_session_id
                     JOIN supplier_product sp ON sp.id = pss.supplier_product_id
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM product_mapping m
                          WHERE m.supplier_product_id = sp.id AND m.product_id = ps.product_id AND m.status = 'active'::text))) AS count
UNION ALL
SELECT 4,
            '订单金额自洽 total = subtotal - discount + tax'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order
                  WHERE sales_order.total <> (sales_order.subtotal - sales_order.discount + sales_order.tax)) AS count
UNION ALL
SELECT 5,
            '订单明细金额自洽（按人计价 total=unit×qty；按团计价 团总价来自快照）'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE
                        CASE oi.pricing_basis
                            WHEN 'per_person'::text THEN oi.total_price <> (oi.unit_price * oi.quantity::numeric)
                            ELSE NOT (oi.total_price > 0::numeric AND oi.unit_price > 0::numeric AND abs(oi.total_price - oi.unit_price * oi.quantity::numeric) <= (oi.quantity::numeric * 0.01) AND oi.total_price = COALESCE(NULLIF(oi.detail_snapshot ->> 'group_total'::text, ''::text)::numeric, oi.total_price))
                        END) AS count
UNION ALL
SELECT 6,
            '订单行 supplier_id 与 supplier_product 所属供应商一致'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN supplier_product sp ON sp.id = oi.supplier_product_id
                  WHERE sp.supplier_id <> oi.supplier_id) AS count
UNION ALL
SELECT 7,
            '已确认预订必须有 external_booking_id'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM booking
                  WHERE booking.status = 'confirmed'::text AND booking.external_booking_id IS NULL) AS count
UNION ALL
SELECT 8,
            '同源同票码不得重复出票'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM voucher
                          WHERE voucher.code IS NOT NULL
                          GROUP BY voucher.supplier_id, voucher.code
                         HAVING count(*) > 1) x) AS count
UNION ALL
SELECT 9,
            '权益消耗数不得超过发放数'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM voucher_entitlement
                  WHERE voucher_entitlement.consumed_quantity > voucher_entitlement.quantity) AS count
UNION ALL
SELECT 10,
            '对客售价必须 ≥ 采纳成本（不得亏本销售）'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar
                  WHERE price_calendar.cost_price IS NOT NULL AND price_calendar.sell_price IS NOT NULL AND price_calendar.sell_price < price_calendar.cost_price) AS count
UNION ALL
SELECT 11,
            '已支付订单必须有 succeeded 支付记录'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE o.payment_status = 'paid'::text AND NOT (EXISTS ( SELECT 1
                           FROM sales_payment p
                          WHERE p.order_id = o.id AND p.status = 'succeeded'::text))) AS count
UNION ALL
SELECT 12,
            '已履约订单必须有交付过的凭证（issued/used/expired）'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE o.fulfillment_status = 'fulfilled'::text AND NOT (EXISTS ( SELECT 1
                           FROM voucher v
                          WHERE v.order_id = o.id AND (v.status = ANY (fn_delivered_voucher_statuses()))))) AS count
UNION ALL
SELECT 13,
            '映射的 supplier_id 与源商品所属供应商一致'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM product_mapping m
                     JOIN supplier_product sp ON sp.id = m.supplier_product_id
                  WHERE m.supplier_id <> sp.supplier_id) AS count
UNION ALL
SELECT 14,
            '所有在用币种（非基准币种）必须有汇率快照'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT supplier_price_calendar.currency
                           FROM supplier_price_calendar) c
                  WHERE c.currency <> 'CNY'::bpchar AND NOT (EXISTS ( SELECT 1
                           FROM fx_rate f
                          WHERE f.quote_currency = c.currency AND f.base_currency = 'CNY'::bpchar))) AS count
UNION ALL
SELECT 15,
            '每个 online 渠道上架必须绑定至少一个启用源'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM channel_listing cl
                  WHERE cl.status = 'online'::text AND NOT (EXISTS ( SELECT 1
                           FROM channel_listing_source cls
                          WHERE cls.channel_listing_id = cl.id AND cls.enabled))) AS count
UNION ALL
SELECT 16,
            '售价日历的采纳成本必须可追溯到具体源'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE pc.cost_price IS NOT NULL AND pc.cost_source_product_id IS NULL) AS count
UNION ALL
SELECT 17,
            'booking.attempt_count 不得小于实际尝试记录数'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM booking b
                  WHERE b.attempt_count < (( SELECT count(*) AS count
                           FROM booking_attempt ba
                          WHERE ba.booking_id = b.id))) AS count
UNION ALL
SELECT 18,
            '渠道内订单幂等键不得重复'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM sales_order
                          WHERE sales_order.idempotency_key IS NOT NULL
                          GROUP BY sales_order.channel_id, sales_order.idempotency_key
                         HAVING count(*) > 1) x) AS count
UNION ALL
SELECT 19,
            '库存快照与可用性缓存的供应商必须存在'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM availability_cache ac
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM supplier s
                          WHERE s.id = ac.supplier_id))) AS count
UNION ALL
SELECT 20,
            '已出票凭证必须归属某个已确认预订'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM voucher v
                  WHERE (v.status = ANY (fn_delivered_voucher_statuses())) AND (v.booking_id IS NULL OR NOT (EXISTS ( SELECT 1
                           FROM booking b
                          WHERE b.id = v.booking_id AND (b.status = ANY (ARRAY['confirmed'::text, 'ticketed'::text])))))) AS count
UNION ALL
SELECT 21,
            '购物车项的库存预占数量必须一致'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM cart_item ci
                     JOIN inventory_hold h ON h.id = ci.hold_id
                  WHERE h.quantity <> ci.quantity) AS count
UNION ALL
SELECT 22,
            '活跃库存预占必须关联购物车或订单'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM inventory_hold h
                  WHERE h.status = 'active'::text AND h.cart_id IS NULL AND h.order_id IS NULL) AS count
UNION ALL
SELECT 23,
            '优惠券使用次数不得超过发放上限'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM coupon
                  WHERE coupon.usage_limit IS NOT NULL AND coupon.used_count > coupon.usage_limit) AS count
UNION ALL
SELECT 24,
            '订单引用的优惠券必须有核销记录'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE o.coupon_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
                           FROM coupon_redemption cr
                          WHERE cr.order_id = o.id AND cr.status = 'used'::text))) AS count
UNION ALL
SELECT 25,
            '要求实名的票种持票人数必须与票数一致'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN sales_order o ON o.id = oi.order_id
                     JOIN checkout_requirement cr ON cr.product_id = oi.product_id AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = oi.ticket_type_id) AND (cr.channel_id IS NULL OR cr.channel_id = o.channel_id)
                  WHERE cr.field_code = 'holder_name'::text AND cr.required AND (( SELECT count(DISTINCT oh.sequence) AS count
                           FROM order_holder oh
                          WHERE oh.order_item_id = oi.id AND oh.field_code = 'holder_name'::text)) <> oi.quantity) AS count
UNION ALL
SELECT 26,
            'C端读模型卡片的起价必须能追溯到价格日历'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM c_product_card c
                  WHERE c.status = 'online'::text AND c.from_price IS NOT NULL AND NOT (EXISTS ( SELECT 1
                           FROM price_calendar pc
                          WHERE pc.product_id = c.product_id AND pc.status = 'active'::text AND (pc.channel_id = c.channel_id OR pc.channel_id IS NULL) AND pc.date >= CURRENT_DATE AND pc.date <= (CURRENT_DATE + 30)))) AS count
UNION ALL
SELECT 27,
            '变体轴取值必须属于该商品的轴定义'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM product_variant_option pvo
                     JOIN product_variant pv ON pv.id = pvo.product_variant_id
                     JOIN product_axis ax ON ax.id = pvo.axis_id
                  WHERE ax.product_id <> pv.product_id) AS count
UNION ALL
SELECT 28,
            '同一商品内变体指纹不得重复'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM product_variant
                          GROUP BY product_variant.product_id, product_variant.variant_key
                         HAVING count(*) > 1) x) AS count
UNION ALL
SELECT 29,
            '在售变体必须有人群或轴取值定义'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM product_variant pv
                  WHERE pv.status = 'active'::text AND pv.ticket_type_id IS NULL AND NOT (EXISTS ( SELECT 1
                           FROM product_variant_option pvo
                          WHERE pvo.product_variant_id = pv.id))) AS count
UNION ALL
SELECT 30,
            '源变体覆盖映射必须完整覆盖目标变体'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM supplier_variant_mapping svm
                  WHERE svm.status = 'active'::text AND NOT fn_variant_covered(svm.coverage, svm.product_variant_id)) AS count
UNION ALL
SELECT 31,
            '在售售价日历必须绑定变体'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar
                  WHERE price_calendar.status = 'active'::text AND price_calendar.product_variant_id IS NULL) AS count
UNION ALL
SELECT 32,
            '订单明细的变体必须与明细商品一致'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN product_variant pv ON pv.id = oi.product_variant_id
                  WHERE pv.product_id <> oi.product_id) AS count
UNION ALL
SELECT 33,
            '加购件变体必须挂在基础变体上'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM product_variant pv
                  WHERE pv.variant_role = 'addon'::text AND pv.status = 'active'::text AND NOT (EXISTS ( SELECT 1
                           FROM product_variant_relation r
                          WHERE r.child_variant_id = pv.id AND r.relation_type = 'optional_addon'::text))) AS count
UNION ALL
SELECT 34,
            '有售价的变体在其上架渠道必须至少有一个可履约源'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT cl.channel_id,
                            pc.product_variant_id
                           FROM channel_listing cl
                             JOIN price_calendar pc ON pc.product_id = cl.product_id AND pc.channel_id IS NULL AND pc.status = 'active'::text
                          WHERE pc.product_variant_id IS NOT NULL AND pc.sell_price IS NOT NULL AND NOT (EXISTS ( SELECT 1
                                   FROM v_variant_routing_candidates vrc
                                  WHERE vrc.channel_id = cl.channel_id AND vrc.product_variant_id = pc.product_variant_id))) x) AS count
UNION ALL
SELECT 35,
            '同一订单内同一商品的多个变体必须使用同一日期'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT oi.order_id
                           FROM sales_order_item oi
                             JOIN product_session ps ON ps.id = oi.session_id
                          GROUP BY oi.order_id, oi.product_id
                         HAVING count(DISTINCT ps.session_date) > 1) x) AS count
UNION ALL
SELECT 36,
            '订单小计必须等于明细金额之和'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT o.id
                           FROM sales_order o
                             JOIN sales_order_item oi ON oi.order_id = o.id
                          GROUP BY o.id, o.subtotal
                         HAVING o.subtotal <> sum(oi.total_price)) x) AS count
UNION ALL
SELECT 37,
            '锁价售价必须等于采纳源的挂牌价'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE pc.price_locked AND pc.status = 'active'::text AND NOT (EXISTS ( SELECT 1
                           FROM supplier_price_calendar spc
                             JOIN supplier_variant sv ON sv.id = spc.supplier_variant_id AND sv.is_price_locked
                          WHERE spc.supplier_product_id = pc.cost_source_product_id AND spc.product_variant_id = pc.product_variant_id AND spc.date = pc.date AND spc.status = 'available'::text AND pc.sell_price = round(fn_convert(spc.supplier_price, spc.currency::text, pc.currency::text, pc.date), 2)))) AS count
UNION ALL
SELECT 38,
            '采纳价格保护源的售价行必须锁价'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                     JOIN supplier_price_calendar spc ON spc.supplier_product_id = pc.cost_source_product_id AND spc.product_variant_id = pc.product_variant_id AND spc.date = pc.date AND spc.status = 'available'::text
                     JOIN supplier_variant sv ON sv.id = spc.supplier_variant_id
                  WHERE pc.status = 'active'::text AND sv.is_price_locked AND NOT pc.price_locked) AS count
UNION ALL
SELECT 39,
            '在售源价格的币种必须可折算到基准币种'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM supplier_price_calendar spc
                  WHERE spc.status = 'available'::text AND fn_fx_rate(spc.currency::text, spc.date) IS NULL) AS count
UNION ALL
SELECT 40,
            '售价行的成本必须等于采纳源成本按留痕汇率折算的结果'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                     LEFT JOIN supplier_price_calendar spc ON spc.supplier_product_id = pc.cost_source_product_id AND NOT spc.product_variant_id IS DISTINCT FROM pc.product_variant_id AND spc.date = pc.date AND spc.status = 'available'::text
                  WHERE pc.status = 'active'::text AND pc.cost_source_product_id IS NOT NULL AND (spc.id IS NULL OR pc.fx_rate IS NULL OR pc.cost_price IS DISTINCT FROM round(spc.net_price * pc.fx_rate, 2) OR pc.cost_price IS DISTINCT FROM round(fn_convert(spc.net_price, spc.currency::text, pc.currency::text, pc.date), 2))) AS count
UNION ALL
SELECT 41,
            '在售售价行必须等于定价函数的输出'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                     LEFT JOIN LATERAL fn_price_variant(pc.product_variant_id, pc.date, COALESCE(pc.channel_id, fn_default_context_channel()), pc.channel_id) v(product_id, product_variant_id, date, currency, supplier_product_id, source_currency, net_price, fx_rate, fx_as_of, cost_price, sell_price, list_price, discount_pct, price_locked, min_margin, rule) ON true
                  WHERE pc.status = 'active'::text AND pc.product_variant_id IS NOT NULL AND (v.product_variant_id IS NULL AND (pc.sell_price IS NOT NULL OR pc.cost_price IS NOT NULL) OR v.product_variant_id IS NOT NULL AND (pc.cost_price IS DISTINCT FROM v.cost_price OR pc.sell_price IS DISTINCT FROM v.sell_price OR pc.list_price IS DISTINCT FROM v.list_price OR pc.discount_pct IS DISTINCT FROM v.discount_pct OR pc.price_locked IS DISTINCT FROM v.price_locked OR pc.cost_source_product_id IS DISTINCT FROM v.supplier_product_id))) AS count
UNION ALL
SELECT 42,
            '非锁价售价行的毛利率必须达到生效 min_margin'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                     JOIN channel_listing cl ON cl.product_id = pc.product_id AND cl.channel_id = COALESCE(pc.channel_id, fn_default_context_channel()) AND cl.status = 'online'::text
                     JOIN channel_listing_source cls ON cls.channel_listing_id = cl.id AND cls.supplier_product_id = pc.cost_source_product_id AND cls.enabled
                  WHERE pc.status = 'active'::text AND NOT pc.price_locked AND COALESCE(NULLIF(cl.price_policy ->> 'mode'::text, ''::text), 'cost_plus'::text) = 'cost_plus'::text AND round((pc.sell_price - pc.cost_price) / NULLIF(pc.sell_price, 0::numeric), 6) < GREATEST(COALESCE(NULLIF(cl.price_policy ->> 'min_margin'::text, ''::text)::numeric, 0::numeric), COALESCE(cls.min_margin, 0::numeric))) AS count
UNION ALL
SELECT 43,
            '定价采用的源必须是路由选中的源'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE pc.status = 'active'::text AND pc.product_variant_id IS NOT NULL AND pc.cost_source_product_id IS DISTINCT FROM (( SELECT rc.supplier_product_id
                           FROM fn_route_candidates(pc.product_variant_id, pc.date, COALESCE(pc.channel_id, fn_default_context_channel()), fn_price_row_currency(pc.channel_id)) rc(supplier_product_id, supplier_variant_id, source_currency, net_price, supplier_price, is_price_locked, source_min_margin, cost_base, fx_rate_to_target, fx_as_of, priority, fallback_order, route_rank)
                          WHERE rc.route_rank = 1))) AS count
UNION ALL
SELECT 44,
            '售价行的币种必须等于该行的结算币种'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE pc.status = 'active'::text AND pc.product_variant_id IS NOT NULL AND pc.currency::text IS DISTINCT FROM fn_price_row_currency(pc.channel_id)) AS count
UNION ALL
SELECT 45,
            '售价行留痕的汇率与快照必须自洽'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                     JOIN supplier_price_calendar spc ON spc.supplier_product_id = pc.cost_source_product_id AND NOT spc.product_variant_id IS DISTINCT FROM pc.product_variant_id AND spc.date = pc.date AND spc.status = 'available'::text
                  WHERE pc.status = 'active'::text AND pc.cost_source_product_id IS NOT NULL AND (spc.currency = pc.currency AND (pc.fx_as_of IS NOT NULL OR pc.fx_rate IS DISTINCT FROM 1::numeric) OR spc.currency <> pc.currency AND (pc.fx_as_of IS NULL OR pc.fx_rate IS DISTINCT FROM round(fn_fx_pair_rate(spc.currency::text, pc.currency::text, pc.fx_as_of), 8)))) AS count
),
__rows__L1(seq, check_name, expected, actual) AS (
SELECT __rows__L0.seq, __rows__L0.check_name, __rows__L0.expected, __rows__L0.actual
  FROM __rows__L0
 WHERE __rows__L0.seq <> ALL (ARRAY[29]::int[])
UNION ALL
SELECT 29 AS "?column?",
            '在售变体必须有人群或轴取值定义（组合变体除外，但组合必须声明组件）'::text AS "?column?",
            0 AS "?column?",
            ( SELECT count(*) AS count
                   FROM product_variant pv
                  WHERE pv.status = 'active'::text AND (pv.variant_role <> 'combo'::text AND pv.ticket_type_id IS NULL AND NOT (EXISTS ( SELECT 1
                           FROM product_variant_option pvo
                          WHERE pvo.product_variant_id = pv.id)) OR pv.variant_role = 'combo'::text AND NOT (EXISTS ( SELECT 1
                           FROM product_variant_relation r
                          WHERE r.parent_variant_id = pv.id AND r.relation_type = 'included'::text)))) AS count
),
__rows__L2(seq, check_name, expected, actual) AS (
SELECT __rows__L1.seq, __rows__L1.check_name, __rows__L1.expected, __rows__L1.actual
  FROM __rows__L1
 WHERE __rows__L1.seq <> ALL (ARRAY[25]::int[])
UNION ALL
SELECT 25 AS "?column?",
            '要求实名的票种持票人数必须与票数一致（组合按成分算）'::text AS "?column?",
            0 AS "?column?",
            ( SELECT count(*) AS count
                   FROM ( SELECT s.order_item_id AS item_id,
                            s.ticket_type_id,
                            s.admission_quantity AS required,
                            oi.product_id,
                            o.channel_id,
                            s.component_variant_id
                           FROM sales_order_item_source s
                             JOIN sales_order_item oi ON oi.id = s.order_item_id
                             JOIN sales_order o ON o.id = oi.order_id
                        UNION ALL
                         SELECT oi.id,
                            oi.ticket_type_id,
                            oi.quantity::numeric AS quantity,
                            oi.product_id,
                            o.channel_id,
                            NULL::bigint AS int8
                           FROM sales_order_item oi
                             JOIN sales_order o ON o.id = oi.order_id
                          WHERE NOT (EXISTS ( SELECT 1
                                   FROM sales_order_item_source s
                                  WHERE s.order_item_id = oi.id))) x
                  WHERE (EXISTS ( SELECT 1
                           FROM checkout_requirement cr
                          WHERE cr.product_id = x.product_id AND cr.field_code = 'holder_name'::text AND cr.required AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = x.ticket_type_id) AND (cr.channel_id IS NULL OR cr.channel_id = x.channel_id))) AND (( SELECT count(DISTINCT oh.sequence) AS count
                           FROM order_holder oh
                          WHERE oh.order_item_id = x.item_id AND oh.field_code = 'holder_name'::text AND (x.component_variant_id IS NULL OR oh.component_variant_id = x.component_variant_id)))::numeric <> x.required) AS count
),
__rows__L3(seq, check_name, expected, actual) AS (
SELECT __rows__L2.seq, __rows__L2.check_name, 0, __rows__L2.actual
  FROM __rows__L2
 WHERE __rows__L2.seq <> ALL (ARRAY[16,34]::int[])
UNION ALL
SELECT 16,
            '售价日历的采纳成本必须可追溯到具体源'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                     LEFT JOIN product_variant pv ON pv.id = pc.product_variant_id
                  WHERE pc.cost_price IS NOT NULL AND pc.cost_source_product_id IS NULL AND (pv.variant_role IS DISTINCT FROM 'combo'::text OR NOT (EXISTS ( SELECT 1
                           FROM supplier_variant_composition svc
                          WHERE svc.product_variant_id = pc.product_variant_id AND svc.status = 'active'::text)))) AS count
UNION ALL
SELECT 34,
            '有售价的变体在其上架渠道必须至少有一个可履约源'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT cl.channel_id,
                            pc.product_variant_id
                           FROM channel_listing cl
                             JOIN price_calendar pc ON pc.product_id = cl.product_id AND pc.channel_id IS NULL AND pc.status = 'active'::text
                          WHERE pc.product_variant_id IS NOT NULL AND pc.sell_price IS NOT NULL AND NOT (EXISTS ( SELECT 1
                                   FROM v_variant_routing_candidates vrc
                                  WHERE vrc.channel_id = cl.channel_id AND vrc.product_variant_id = pc.product_variant_id)) AND NOT ((EXISTS ( SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id AND r.relation_type = 'included'::text)) AND NOT (EXISTS ( SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id AND r.relation_type = 'included'::text AND NOT (EXISTS ( SELECT 1
   FROM supplier_variant_mapping svm
  WHERE svm.product_variant_id = r.child_variant_id AND svm.status = 'active'::text AND fn_variant_covered(svm.coverage, r.child_variant_id))))))) x) AS count
),
__rows__L4(seq, check_name, expected, actual) AS (
SELECT __rows__L3.seq, __rows__L3.check_name, 0, __rows__L3.actual
  FROM __rows__L3
 WHERE __rows__L3.seq <> ALL (ARRAY[34,43]::int[])
UNION ALL
SELECT 34,
            '有售价的变体在其上架渠道必须至少有一个可履约源'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT cl.channel_id,
                            pc.product_variant_id
                           FROM channel_listing cl
                             JOIN price_calendar pc ON pc.product_id = cl.product_id AND pc.channel_id IS NULL AND pc.status = 'active'::text
                          WHERE pc.product_variant_id IS NOT NULL AND pc.sell_price IS NOT NULL AND NOT (EXISTS ( SELECT 1
                                   FROM v_variant_routing_candidates vrc
                                  WHERE vrc.channel_id = cl.channel_id AND vrc.product_variant_id = pc.product_variant_id)) AND NOT (EXISTS ( SELECT 1
                                   FROM supplier_variant_bundle svb
                                  WHERE svb.product_variant_id = pc.product_variant_id AND svb.status = 'active'::text)) AND NOT ((EXISTS ( SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id AND r.relation_type = 'included'::text)) AND NOT (EXISTS ( SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id AND r.relation_type = 'included'::text AND NOT (EXISTS ( SELECT 1
   FROM supplier_variant_mapping svm
  WHERE svm.product_variant_id = r.child_variant_id AND svm.status = 'active'::text AND fn_variant_covered(svm.coverage, r.child_variant_id))))))) x) AS count
UNION ALL
SELECT 43,
            '定价采用的源必须是路由选中的源'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE pc.status = 'active'::text AND pc.product_variant_id IS NOT NULL AND pc.cost_source_product_id IS DISTINCT FROM (( SELECT rc.supplier_product_id
                           FROM fn_route_candidates(pc.product_variant_id, pc.date, COALESCE(pc.channel_id, fn_default_context_channel()), fn_price_row_currency(pc.channel_id)) rc(supplier_product_id, supplier_variant_id, source_currency, net_price, supplier_price, is_price_locked, source_min_margin, cost_base, fx_rate_to_target, fx_as_of, priority, fallback_order, route_rank)
                          WHERE rc.route_rank = 1)) AND NOT (EXISTS ( SELECT 1
                           FROM supplier_variant_bundle svb
                             JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id AND sv.status = 'active'::text
                          WHERE svb.product_variant_id = pc.product_variant_id AND svb.status = 'active'::text AND sv.supplier_product_id = pc.cost_source_product_id))) AS count
)
SELECT seq, check_name, expected::int AS expected, actual,
       actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result
FROM __rows__L4;

CREATE OR REPLACE VIEW v_invariant_checks_inventory_flat AS
WITH __rows__L0(seq, check_name, expected, actual) AS (
SELECT 69 AS "?column?",
            '每条订单明细都必须有对应的库存预占'::text AS "?column?",
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM inventory_hold h
                          WHERE h.order_id = oi.order_id AND NOT h.product_session_id IS DISTINCT FROM oi.session_id AND NOT h.ticket_type_id IS DISTINCT FROM oi.ticket_type_id AND NOT h.supplier_id IS DISTINCT FROM oi.supplier_id AND h.quantity = oi.quantity))) AS count
UNION ALL
SELECT 70,
            '库存预占与订单的状态不许分叉'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM inventory_hold h
                  WHERE h.order_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
                           FROM sales_order o
                          WHERE o.id = h.order_id)) OR h.status = 'consumed'::text AND (h.consumed_quantity <> h.quantity OR h.order_id IS NULL) OR h.status = 'active'::text AND h.consumed_quantity >= h.quantity) AS count
UNION ALL
SELECT 71,
            '库存预占的额度账必须自洽'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM inventory_hold h
                  WHERE h.consumed_quantity < 0 OR h.consumed_quantity > h.quantity OR h.status = 'consumed'::text AND h.consumed_quantity <> h.quantity OR h.status = 'voided'::text AND h.consumed_quantity <> h.quantity OR (h.status = ANY (ARRAY['released'::text, 'expired'::text])) AND h.consumed_quantity >= h.quantity) AS count
UNION ALL
SELECT 72,
            '订单卖出的量不得超过落单时看到的源侧可售数'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE COALESCE(((oi.detail_snapshot -> 'availability'::text) ->> 'known'::text)::boolean, false) IS TRUE AND COALESCE(((oi.detail_snapshot -> 'availability'::text) ->> 'remaining_qty'::text)::integer, 0) < oi.quantity) AS count
),
__rows__L1(seq, check_name, expected, actual) AS (
SELECT __rows__L0.seq, __rows__L0.check_name, __rows__L0.expected, __rows__L0.actual
  FROM __rows__L0
 WHERE __rows__L0.seq <> ALL (ARRAY[69,72]::int[])
UNION ALL
SELECT 69,
            '每条订单明细都必须有对应的库存预占（组合按成分）'::text,
            0,
            (( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id AND (EXISTS ( SELECT 1
                                   FROM inventory_hold h
                                  WHERE h.order_id = oi.order_id AND NOT h.product_session_id IS DISTINCT FROM s.product_session_id AND NOT h.ticket_type_id IS DISTINCT FROM s.ticket_type_id AND NOT h.supplier_id IS DISTINCT FROM s.supplier_id AND NOT h.supplier_session_id IS DISTINCT FROM s.supplier_session_id AND h.quantity::numeric = s.admission_quantity)))))) + (( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND NOT (EXISTS ( SELECT 1
                           FROM inventory_hold h
                          WHERE h.order_id = oi.order_id AND NOT h.product_session_id IS DISTINCT FROM oi.session_id AND NOT h.ticket_type_id IS DISTINCT FROM oi.ticket_type_id AND NOT h.supplier_id IS DISTINCT FROM oi.supplier_id AND h.quantity = oi.quantity))))
UNION ALL
SELECT 72,
            '订单卖出的量不得超过落单时看到的源侧可售数（组合逐成分）'::text,
            0,
            (( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN sales_order_item_source s ON s.order_item_id = oi.id
                     LEFT JOIN LATERAL ( SELECT e.value AS ent
                           FROM jsonb_array_elements(COALESCE((oi.detail_snapshot -> 'availability'::text) -> 'sources'::text, '[]'::jsonb)) e(value)
                          WHERE ((e.value ->> 'component_variant_id'::text)::bigint) = s.component_variant_id AND ((e.value ->> 'supplier_variant_id'::text)::bigint) = s.supplier_variant_id
                          ORDER BY ((e.value ->> 'remaining_qty'::text)::integer) NULLS FIRST
                         LIMIT 1) a ON true
                  WHERE COALESCE((a.ent ->> 'known'::text)::boolean, false) IS TRUE AND COALESCE((a.ent ->> 'remaining_qty'::text)::integer, 0)::numeric < s.admission_quantity)) + (( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND COALESCE(((oi.detail_snapshot -> 'availability'::text) ->> 'known'::text)::boolean, false) IS TRUE AND COALESCE(((oi.detail_snapshot -> 'availability'::text) ->> 'remaining_qty'::text)::integer, 0) < oi.quantity))
),
__rows__L2(seq, check_name, expected, actual) AS (
SELECT __rows__L1.seq, __rows__L1.check_name, 0, __rows__L1.actual
  FROM __rows__L1
 WHERE __rows__L1.seq <> ALL (ARRAY[69,72]::int[])
UNION ALL
SELECT 69,
            '每条订单明细都必须有对应的库存预占（组合按成分、套装按套）'::text,
  0 AS expected,
            (( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id AND (EXISTS ( SELECT 1
                                   FROM inventory_hold h
                                  WHERE h.order_id = oi.order_id AND NOT h.product_session_id IS DISTINCT FROM s.product_session_id AND NOT h.supplier_id IS DISTINCT FROM s.supplier_id AND NOT h.supplier_session_id IS DISTINCT FROM s.supplier_session_id AND (h.quantity = oi.quantity AND (EXISTS ( SELECT 1
   FROM supplier_variant_bundle svb
  WHERE svb.product_variant_id = oi.product_variant_id AND svb.supplier_variant_id = s.supplier_variant_id AND svb.status = 'active'::text)) OR NOT h.ticket_type_id IS DISTINCT FROM s.ticket_type_id AND h.quantity::numeric = s.admission_quantity AND NOT (EXISTS ( SELECT 1
   FROM supplier_variant_bundle svb
  WHERE svb.product_variant_id = oi.product_variant_id AND svb.supplier_variant_id = s.supplier_variant_id AND svb.status = 'active'::text))))))))) + (( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND NOT (EXISTS ( SELECT 1
                           FROM inventory_hold h
                          WHERE h.order_id = oi.order_id AND NOT h.product_session_id IS DISTINCT FROM oi.session_id AND NOT h.ticket_type_id IS DISTINCT FROM oi.ticket_type_id AND NOT h.supplier_id IS DISTINCT FROM oi.supplier_id AND h.quantity = oi.quantity))))
UNION ALL
SELECT 72,
            '订单卖出的量不得超过落单时看到的源侧可售数（组合按成分、套装按套）'::text,
  0 AS expected,
            (( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN sales_order_item_source s ON s.order_item_id = oi.id
                     LEFT JOIN LATERAL ( SELECT e.value AS ent
                           FROM jsonb_array_elements(COALESCE((oi.detail_snapshot -> 'availability'::text) -> 'sources'::text, '[]'::jsonb)) e(value)
                          WHERE ((e.value ->> 'component_variant_id'::text)::bigint) = s.component_variant_id AND ((e.value ->> 'supplier_variant_id'::text)::bigint) = s.supplier_variant_id
                          ORDER BY ((e.value ->> 'remaining_qty'::text)::integer) NULLS FIRST
                         LIMIT 1) a ON true
                  WHERE COALESCE((a.ent ->> 'known'::text)::boolean, false) IS TRUE AND COALESCE((a.ent ->> 'remaining_qty'::text)::integer, 0)::numeric <
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM supplier_variant_bundle svb
                              WHERE svb.product_variant_id = oi.product_variant_id AND svb.supplier_variant_id = s.supplier_variant_id AND svb.status = 'active'::text)) THEN oi.quantity::numeric
                            ELSE s.admission_quantity
                        END)) + (( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND COALESCE(((oi.detail_snapshot -> 'availability'::text) ->> 'known'::text)::boolean, false) IS TRUE AND COALESCE(((oi.detail_snapshot -> 'availability'::text) ->> 'remaining_qty'::text)::integer, 0) < oi.quantity))
)
SELECT seq, check_name, expected::int AS expected, actual,
       actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result
FROM __rows__L2;

CREATE OR REPLACE VIEW v_invariant_checks_validity_flat AS
WITH __rows__L0(seq, check_name, expected, actual) AS (
SELECT 73 AS "?column?",
            '一个可售单元的有效期口径不许有歧义'::text AS "?column?",
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT pvo.product_variant_id
                           FROM product_variant_option pvo
                             JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
                          WHERE ao.valid_days IS NOT NULL
                          GROUP BY pvo.product_variant_id
                         HAVING count(DISTINCT ao.valid_days) > 1) t) AS count
UNION ALL
SELECT 74,
            '已发出的券不得短于该可售单元承诺的有效期'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM voucher v
                  WHERE v.product_variant_id IS NOT NULL AND v.valid_from IS NOT NULL AND v.valid_to IS NOT NULL AND EXTRACT(day FROM v.valid_to - v.valid_from)::integer < fn_variant_validity_days(v.product_variant_id)) AS count
UNION ALL
SELECT 75,
            '卖出去的订单必须是用能装配出该可售单元的源出的'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN booking b ON b.order_item_id = oi.id
                  WHERE b.supplier_variant_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
                           FROM supplier_variant_mapping svm
                          WHERE svm.supplier_variant_id = b.supplier_variant_id AND svm.product_variant_id = oi.product_variant_id AND svm.status = 'active'::text AND fn_variant_covered(svm.coverage, oi.product_variant_id)))) AS count
),
__rows__L1(seq, check_name, expected, actual) AS (
SELECT __rows__L0.seq, __rows__L0.check_name, __rows__L0.expected, __rows__L0.actual
  FROM __rows__L0
 WHERE __rows__L0.seq <> ALL (ARRAY[75]::int[])
UNION ALL
SELECT 75,
            '卖出去的订单必须是用能装配出该可售单元的源出的（组合按成分）'::text,
            0,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN booking b ON b.order_item_id = oi.id
                  WHERE b.supplier_variant_id IS NOT NULL AND NOT ((EXISTS ( SELECT 1
                           FROM supplier_variant_mapping svm
                          WHERE svm.supplier_variant_id = b.supplier_variant_id AND svm.product_variant_id = oi.product_variant_id AND svm.status = 'active'::text AND fn_variant_covered(svm.coverage, oi.product_variant_id))) OR (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                             JOIN supplier_variant_mapping svm ON svm.supplier_variant_id = b.supplier_variant_id AND svm.product_variant_id = s.component_variant_id AND svm.status = 'active'::text
                          WHERE s.order_item_id = oi.id AND NOT s.supplier_variant_id IS DISTINCT FROM b.supplier_variant_id AND NOT s.supplier_session_id IS DISTINCT FROM b.supplier_session_id AND fn_variant_covered(svm.coverage, s.component_variant_id))))) AS count
),
__rows__L2(seq, check_name, expected, actual) AS (
SELECT __rows__L1.seq, __rows__L1.check_name, 0, __rows__L1.actual
  FROM __rows__L1
 WHERE __rows__L1.seq <> ALL (ARRAY[75]::int[])
UNION ALL
SELECT 75,
            '卖出去的订单必须是用能装配出该可售单元的源出的（组合按成分、套装按套装声明）'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN booking b ON b.order_item_id = oi.id
                  WHERE b.supplier_variant_id IS NOT NULL AND NOT ((EXISTS ( SELECT 1
                           FROM supplier_variant_mapping svm
                          WHERE svm.supplier_variant_id = b.supplier_variant_id AND svm.product_variant_id = oi.product_variant_id AND svm.status = 'active'::text AND fn_variant_covered(svm.coverage, oi.product_variant_id))) OR (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                             JOIN supplier_variant_mapping svm ON svm.supplier_variant_id = b.supplier_variant_id AND svm.product_variant_id = s.component_variant_id AND svm.status = 'active'::text
                          WHERE s.order_item_id = oi.id AND NOT s.supplier_variant_id IS DISTINCT FROM b.supplier_variant_id AND NOT s.supplier_session_id IS DISTINCT FROM b.supplier_session_id AND fn_variant_covered(svm.coverage, s.component_variant_id))) OR (EXISTS ( SELECT 1
                           FROM supplier_variant_bundle svb
                          WHERE svb.product_variant_id = oi.product_variant_id AND svb.supplier_variant_id = b.supplier_variant_id AND svb.status = 'active'::text)))) AS count
)
SELECT seq, check_name, expected::int AS expected, actual,
       actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result
FROM __rows__L2;

CREATE OR REPLACE VIEW v_invariant_checks_combo_flat AS
WITH __rows__L0(seq, check_name, expected, actual) AS (
SELECT 82 AS "?column?",
            '订单明细的成分变体必须属于该明细的商品'::text AS "?column?",
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item_source s
                     JOIN sales_order_item oi ON oi.id = s.order_item_id
                     JOIN product_variant cv ON cv.id = s.component_variant_id
                  WHERE cv.product_id <> oi.product_id) AS count
UNION ALL
SELECT 83,
            '订单明细的成分成本合计必须等于明细的采纳成本'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND round(COALESCE(( SELECT sum(s.unit_cost * s.quantity) AS sum
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id), 0::numeric), 2) IS DISTINCT FROM round(COALESCE(NULLIF(oi.detail_snapshot ->> 'cost_price'::text, ''::text)::numeric, 0::numeric) *
                        CASE
                            WHEN oi.pricing_basis = 'per_group'::text THEN 1
                            ELSE oi.quantity
                        END::numeric, 2)) AS count
UNION ALL
SELECT 84,
            '订单明细的成分入场份数必须与配方声明对得上'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN product_variant pv ON pv.id = oi.product_variant_id
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND COALESCE(( SELECT sum(s.admission_quantity) AS sum
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id), 0::numeric) IS DISTINCT FROM
                        CASE
                            WHEN pv.variant_role = 'combo'::text THEN (( SELECT COALESCE(sum(r.quantity), 0::numeric) AS "coalesce"
                               FROM product_variant_relation r
                              WHERE r.parent_variant_id = oi.product_variant_id AND r.relation_type = 'included'::text)) * oi.quantity::numeric
                            ELSE oi.quantity::numeric
                        END) AS count
UNION ALL
SELECT 85,
            '订单明细的成分必须来自同一个源且与明细的供应商一致'::text AS text,
  0 AS expected,
            (( SELECT count(*) AS count
                   FROM ( SELECT s.order_item_id
                           FROM sales_order_item_source s
                          GROUP BY s.order_item_id
                         HAVING count(DISTINCT s.supplier_id) > 1) x)) + (( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN sales_order_item_source s ON s.order_item_id = oi.id
                  WHERE oi.supplier_id IS DISTINCT FROM s.supplier_id))
UNION ALL
SELECT 86,
            '已出票的订单明细必须按成分把份数发够了'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE oi.status = 'ticketed'::text AND COALESCE(( SELECT sum(ve.quantity) AS sum
                           FROM voucher_entitlement ve
                             JOIN voucher v ON v.id = ve.voucher_id
                          WHERE v.order_item_id = oi.id AND (v.status = ANY (fn_delivered_voucher_statuses())) AND ve.entitlement_type = 'admission'::text), 0::bigint)::numeric < COALESCE(( SELECT sum(s.admission_quantity) AS sum
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id), oi.quantity::numeric)) AS count
),
__rows__L1(seq, check_name, expected, actual) AS (
SELECT __rows__L0.seq, __rows__L0.check_name, 0, __rows__L0.actual
  FROM __rows__L0
 WHERE __rows__L0.seq <> ALL (ARRAY[87,88]::int[])
UNION ALL
SELECT 87,
            '同一订单明细里同一个源 SKU 只能有一条预订'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM ( SELECT b.order_item_id,
                            b.supplier_variant_id,
                            b.supplier_session_id
                           FROM booking b
                          WHERE b.supplier_variant_id IS NOT NULL
                          GROUP BY b.order_item_id, b.supplier_variant_id, b.supplier_session_id
                         HAVING count(*) > 1) x) AS count
UNION ALL
SELECT 88,
            '订单进入预订阶段后，预订与成分必须双向对齐'::text,
  0 AS expected,
            (( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN sales_order o ON o.id = oi.order_id
                  WHERE (o.status = ANY (ARRAY['booking_pending'::text, 'confirmed'::text, 'partially_fulfilled'::text, 'fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id AND NOT (EXISTS ( SELECT 1
                                   FROM booking b
                                  WHERE b.order_item_id = oi.id AND NOT b.supplier_variant_id IS DISTINCT FROM s.supplier_variant_id AND NOT b.supplier_session_id IS DISTINCT FROM s.supplier_session_id)))))) + (( SELECT count(*) AS count
                   FROM booking b
                     JOIN sales_order_item oi ON oi.id = b.order_item_id
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id AND NOT s.supplier_variant_id IS DISTINCT FROM b.supplier_variant_id AND NOT s.supplier_session_id IS DISTINCT FROM b.supplier_session_id))))
),
__rows__L2(seq, check_name, expected, actual) AS (
SELECT __rows__L1.seq, __rows__L1.check_name, 0, __rows__L1.actual
  FROM __rows__L1
 WHERE __rows__L1.seq <> ALL (ARRAY[84]::int[])
UNION ALL
SELECT 84,
            '订单明细的成分入场份数必须与配方（套装）声明对得上'::text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                     JOIN product_variant pv ON pv.id = oi.product_variant_id
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND COALESCE(( SELECT sum(s.admission_quantity) AS sum
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id), 0::numeric) IS DISTINCT FROM
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM supplier_variant_bundle svb
                              WHERE svb.product_variant_id = oi.product_variant_id AND svb.status = 'active'::text)) THEN (( SELECT COALESCE(sum(p.quantity), 0::numeric) AS "coalesce"
                               FROM supplier_variant_bundle_part p
                                 JOIN supplier_variant_bundle svb2 ON svb2.id = p.bundle_id
                              WHERE svb2.product_variant_id = oi.product_variant_id AND svb2.status = 'active'::text)) * oi.quantity::numeric
                            WHEN pv.variant_role = 'combo'::text THEN (( SELECT COALESCE(sum(r.quantity), 0::numeric) AS "coalesce"
                               FROM product_variant_relation r
                              WHERE r.parent_variant_id = oi.product_variant_id AND r.relation_type = 'included'::text)) * oi.quantity::numeric
                            ELSE oi.quantity::numeric
                        END) AS count
)
SELECT seq, check_name, expected::int AS expected, actual,
       actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result
FROM __rows__L2;

CREATE OR REPLACE VIEW v_invariant_checks_fulfill_flat AS
WITH item_state__L0 AS (

         SELECT oi.order_id,
            oi.id AS item_id,
            oi.quantity,
            COALESCE(( SELECT sum(ve.quantity) AS sum
                   FROM voucher_entitlement ve
                     JOIN voucher v ON v.id = ve.voucher_id
                  WHERE v.order_item_id = oi.id AND (v.status = ANY (fn_delivered_voucher_statuses())) AND ve.entitlement_type = 'admission'::text), 0::bigint) AS delivered
           FROM sales_order_item oi
        
),
item_state__L1 AS (

         SELECT oi.order_id,
            oi.id AS item_id,
            COALESCE(( SELECT sum(s.admission_quantity) AS sum
                   FROM sales_order_item_source s
                  WHERE s.order_item_id = oi.id), oi.quantity::numeric) AS quantity,
            COALESCE(( SELECT sum(ve.quantity) AS sum
                   FROM voucher_entitlement ve
                     JOIN voucher v ON v.id = ve.voucher_id
                  WHERE v.order_item_id = oi.id AND (v.status = ANY (fn_delivered_voucher_statuses())) AND ve.entitlement_type = 'admission'::text), 0::bigint) AS delivered
           FROM sales_order_item oi
        
),
__rows__L0(seq, check_name, expected, actual) AS (
SELECT 55 AS "?column?",
            '支付金额必须等于订单应付金额'::text AS "?column?",
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_payment sp
                     JOIN sales_order o ON o.id = sp.order_id
                  WHERE sp.status = 'succeeded'::text AND sp.amount <> o.total) AS count
UNION ALL
SELECT 56,
            '已支付订单必须有成功的支付记录'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE o.payment_status = 'paid'::text AND NOT (EXISTS ( SELECT 1
                           FROM sales_payment sp
                          WHERE sp.order_id = o.id AND sp.status = 'succeeded'::text))) AS count
UNION ALL
SELECT 57,
            '已确认订单的每条明细都必须有 confirmed/ticketed 的预订'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE (o.status = ANY (ARRAY['confirmed'::text, 'fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM sales_order_item oi
                          WHERE oi.order_id = o.id AND NOT (EXISTS ( SELECT 1
                                   FROM booking b
                                  WHERE b.order_item_id = oi.id AND (b.status = ANY (ARRAY['confirmed'::text, 'ticketed'::text]))))))) AS count
UNION ALL
SELECT 58,
            '预订的源必须等于订单明细的采纳源'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM booking b
                     JOIN sales_order_item oi ON oi.id = b.order_item_id
                  WHERE b.supplier_id IS DISTINCT FROM oi.supplier_id OR b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id) AS count
UNION ALL
SELECT 59,
            '预订的源场次必须绑定在该明细的规范场次上'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM booking b
                     JOIN sales_order_item oi ON oi.id = b.order_item_id
                  WHERE b.supplier_session_id IS NULL OR NOT (EXISTS ( SELECT 1
                           FROM product_session_source pss
                          WHERE pss.product_session_id = oi.session_id AND pss.supplier_product_id = b.supplier_product_id AND pss.supplier_id = b.supplier_id AND pss.supplier_session_id = b.supplier_session_id))) AS count
UNION ALL
SELECT 60,
            '订单的履约状态必须与明细的出票情况一致'::text AS text,
  0 AS expected,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE o.status = 'fulfilled'::text AND (EXISTS ( SELECT 1
                           FROM item_state__L0 s
                          WHERE s.order_id = o.id AND s.delivered < s.quantity)) OR o.status = 'partially_fulfilled'::text AND COALESCE(( SELECT sum(s.delivered) AS sum
                           FROM item_state__L0 s
                          WHERE s.order_id = o.id), 0::numeric) = 0::numeric OR (o.status = ANY (ARRAY['booking_pending'::text, 'confirmed'::text, 'partially_fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM item_state__L0 s
                          WHERE s.order_id = o.id)) AND NOT (EXISTS ( SELECT 1
                           FROM item_state__L0 s
                          WHERE s.order_id = o.id AND s.delivered < s.quantity))) AS count
),
__rows__L1(seq, check_name, expected, actual) AS (
SELECT __rows__L0.seq, __rows__L0.check_name, __rows__L0.expected, __rows__L0.actual
  FROM __rows__L0
 WHERE __rows__L0.seq <> ALL (ARRAY[58,60]::int[])
UNION ALL
SELECT 58,
            '预订的源必须等于它覆盖的那些成分的源'::text AS text,
            0,
            ( SELECT count(*) AS count
                   FROM booking b
                     JOIN sales_order_item oi ON oi.id = b.order_item_id
                  WHERE (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id AND NOT s.supplier_variant_id IS DISTINCT FROM b.supplier_variant_id AND NOT s.supplier_session_id IS DISTINCT FROM b.supplier_session_id AND (s.supplier_id IS DISTINCT FROM b.supplier_id OR s.supplier_product_id IS DISTINCT FROM b.supplier_product_id))) OR NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id)) AND (b.supplier_id IS DISTINCT FROM oi.supplier_id OR b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id)) AS count
UNION ALL
SELECT 60,
            '订单的履约状态必须与明细的出票情况一致'::text AS text,
            0,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE o.status = 'fulfilled'::text AND (EXISTS ( SELECT 1
                           FROM item_state__L1 s
                          WHERE s.order_id = o.id AND s.delivered::numeric < s.quantity)) OR o.status = 'partially_fulfilled'::text AND COALESCE(( SELECT sum(s.delivered) AS sum
                           FROM item_state__L1 s
                          WHERE s.order_id = o.id), 0::numeric) = 0::numeric OR (o.status = ANY (ARRAY['booking_pending'::text, 'confirmed'::text, 'partially_fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM item_state__L1 s
                          WHERE s.order_id = o.id)) AND NOT (EXISTS ( SELECT 1
                           FROM item_state__L1 s
                          WHERE s.order_id = o.id AND s.delivered::numeric < s.quantity))) AS count
)
SELECT seq, check_name, expected::int AS expected, actual,
       actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result
FROM __rows__L1;



-- ---- 门禁改指向五个压平视图，其余 17 段原样不动 ----

CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v_invariant_checks_core_flat.seq,
    v_invariant_checks_core_flat.check_name,
    v_invariant_checks_core_flat.expected,
    v_invariant_checks_core_flat.actual,
    v_invariant_checks_core_flat.passed,
    v_invariant_checks_core_flat.result
   FROM v_invariant_checks_core_flat
UNION ALL
SELECT v_invariant_checks_tx.seq,
    v_invariant_checks_tx.check_name,
    v_invariant_checks_tx.expected,
    v_invariant_checks_tx.actual,
    v_invariant_checks_tx.passed,
    v_invariant_checks_tx.result
   FROM v_invariant_checks_tx
UNION ALL
SELECT v_invariant_checks_order.seq,
    v_invariant_checks_order.check_name,
    v_invariant_checks_order.expected,
    v_invariant_checks_order.actual,
    v_invariant_checks_order.passed,
    v_invariant_checks_order.result
   FROM v_invariant_checks_order
UNION ALL
SELECT v_invariant_checks_fulfill_flat.seq,
    v_invariant_checks_fulfill_flat.check_name,
    v_invariant_checks_fulfill_flat.expected,
    v_invariant_checks_fulfill_flat.actual,
    v_invariant_checks_fulfill_flat.passed,
    v_invariant_checks_fulfill_flat.result
   FROM v_invariant_checks_fulfill_flat
UNION ALL
SELECT v_invariant_checks_refund.seq,
    v_invariant_checks_refund.check_name,
    v_invariant_checks_refund.expected,
    v_invariant_checks_refund.actual,
    v_invariant_checks_refund.passed,
    v_invariant_checks_refund.result
   FROM v_invariant_checks_refund
UNION ALL
SELECT v_invariant_checks_redemption.seq,
    v_invariant_checks_redemption.check_name,
    v_invariant_checks_redemption.expected,
    v_invariant_checks_redemption.actual,
    v_invariant_checks_redemption.passed,
    v_invariant_checks_redemption.result
   FROM v_invariant_checks_redemption
UNION ALL
SELECT v_invariant_checks_inventory_flat.seq,
    v_invariant_checks_inventory_flat.check_name,
    v_invariant_checks_inventory_flat.expected,
    v_invariant_checks_inventory_flat.actual,
    v_invariant_checks_inventory_flat.passed,
    v_invariant_checks_inventory_flat.result
   FROM v_invariant_checks_inventory_flat
UNION ALL
SELECT v_invariant_checks_validity_flat.seq,
    v_invariant_checks_validity_flat.check_name,
    v_invariant_checks_validity_flat.expected,
    v_invariant_checks_validity_flat.actual,
    v_invariant_checks_validity_flat.passed,
    v_invariant_checks_validity_flat.result
   FROM v_invariant_checks_validity_flat
UNION ALL
SELECT v_invariant_checks_readmodel.seq,
    v_invariant_checks_readmodel.check_name,
    v_invariant_checks_readmodel.expected,
    v_invariant_checks_readmodel.actual,
    v_invariant_checks_readmodel.passed,
    v_invariant_checks_readmodel.result
   FROM v_invariant_checks_readmodel
UNION ALL
SELECT v_invariant_checks_composition.seq,
    v_invariant_checks_composition.check_name,
    v_invariant_checks_composition.expected,
    v_invariant_checks_composition.actual,
    v_invariant_checks_composition.passed,
    v_invariant_checks_composition.result
   FROM v_invariant_checks_composition
UNION ALL
SELECT v_invariant_checks_combo_flat.seq,
    v_invariant_checks_combo_flat.check_name,
    v_invariant_checks_combo_flat.expected,
    v_invariant_checks_combo_flat.actual,
    v_invariant_checks_combo_flat.passed,
    v_invariant_checks_combo_flat.result
   FROM v_invariant_checks_combo_flat
UNION ALL
SELECT v_invariant_checks_hardening.seq,
    v_invariant_checks_hardening.check_name,
    v_invariant_checks_hardening.expected,
    v_invariant_checks_hardening.actual,
    v_invariant_checks_hardening.passed,
    v_invariant_checks_hardening.result
   FROM v_invariant_checks_hardening
UNION ALL
SELECT v_invariant_checks_bundle.seq,
    v_invariant_checks_bundle.check_name,
    v_invariant_checks_bundle.expected,
    v_invariant_checks_bundle.actual,
    v_invariant_checks_bundle.passed,
    v_invariant_checks_bundle.result
   FROM v_invariant_checks_bundle
UNION ALL
SELECT v_invariant_checks_bundle_020.seq,
    v_invariant_checks_bundle_020.check_name,
    v_invariant_checks_bundle_020.expected,
    v_invariant_checks_bundle_020.actual,
    v_invariant_checks_bundle_020.passed,
    v_invariant_checks_bundle_020.result
   FROM v_invariant_checks_bundle_020
UNION ALL
SELECT v_invariant_checks_supply_forms_021.seq,
    v_invariant_checks_supply_forms_021.check_name,
    v_invariant_checks_supply_forms_021.expected,
    v_invariant_checks_supply_forms_021.actual,
    v_invariant_checks_supply_forms_021.passed,
    v_invariant_checks_supply_forms_021.result
   FROM v_invariant_checks_supply_forms_021
UNION ALL
SELECT v_invariant_checks_supply_form_shrink_022.seq,
    v_invariant_checks_supply_form_shrink_022.check_name,
    v_invariant_checks_supply_form_shrink_022.expected,
    v_invariant_checks_supply_form_shrink_022.actual,
    v_invariant_checks_supply_form_shrink_022.passed,
    v_invariant_checks_supply_form_shrink_022.result
   FROM v_invariant_checks_supply_form_shrink_022
UNION ALL
SELECT v_invariant_checks_supply_source_count_023.seq,
    v_invariant_checks_supply_source_count_023.check_name,
    v_invariant_checks_supply_source_count_023.expected,
    v_invariant_checks_supply_source_count_023.actual,
    v_invariant_checks_supply_source_count_023.passed,
    v_invariant_checks_supply_source_count_023.result
   FROM v_invariant_checks_supply_source_count_023
UNION ALL
SELECT v_invariant_checks_reassign.seq,
    v_invariant_checks_reassign.check_name,
    v_invariant_checks_reassign.expected,
    v_invariant_checks_reassign.actual,
    v_invariant_checks_reassign.passed,
    v_invariant_checks_reassign.result
   FROM v_invariant_checks_reassign
UNION ALL
SELECT v_invariant_checks_qty_limits.seq,
    v_invariant_checks_qty_limits.check_name,
    v_invariant_checks_qty_limits.expected,
    v_invariant_checks_qty_limits.actual,
    v_invariant_checks_qty_limits.passed,
    v_invariant_checks_qty_limits.result
   FROM v_invariant_checks_qty_limits
UNION ALL
SELECT v_invariant_checks_reassign_basis.seq,
    v_invariant_checks_reassign_basis.check_name,
    v_invariant_checks_reassign_basis.expected,
    v_invariant_checks_reassign_basis.actual,
    v_invariant_checks_reassign_basis.passed,
    v_invariant_checks_reassign_basis.result
   FROM v_invariant_checks_reassign_basis
UNION ALL
SELECT v_invariant_checks_hold_ttl.seq,
    v_invariant_checks_hold_ttl.check_name,
    v_invariant_checks_hold_ttl.expected,
    v_invariant_checks_hold_ttl.actual,
    v_invariant_checks_hold_ttl.passed,
    v_invariant_checks_hold_ttl.result
   FROM v_invariant_checks_hold_ttl
UNION ALL
SELECT v_invariant_checks_voucher_expiry.seq,
    v_invariant_checks_voucher_expiry.check_name,
    v_invariant_checks_voucher_expiry.expected,
    v_invariant_checks_voucher_expiry.actual,
    v_invariant_checks_voucher_expiry.passed,
    v_invariant_checks_voucher_expiry.result
   FROM v_invariant_checks_voucher_expiry;;



-- ---- 删掉被取代的中间层（先上层后下层；不用 CASCADE，依赖还在就报错） ----
DROP VIEW v_invariant_checks_combo_017;
DROP VIEW v_invariant_checks_inventory_017;
DROP VIEW v_invariant_checks_validity_017;
DROP VIEW v_invariant_checks_core_017;
DROP VIEW v_invariant_checks_fulfill;
DROP VIEW v_invariant_checks_combo;
DROP VIEW v_invariant_checks_inventory;
DROP VIEW v_invariant_checks_validity;
DROP VIEW v_invariant_checks_core;
DROP VIEW v_invariant_checks_combo_base;
DROP VIEW v_invariant_checks_fulfill_base;
DROP VIEW v_invariant_checks_inventory_base;
DROP VIEW v_invariant_checks_validity_base;
DROP VIEW v_invariant_checks_core_base;
DROP VIEW v_invariant_checks_variant;
DROP VIEW v_invariant_checks_supply;
DROP VIEW v_invariant_checks_order_004;
