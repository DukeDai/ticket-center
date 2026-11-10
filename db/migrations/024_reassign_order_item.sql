-- =====================================================================================
-- 024 改派写路径（换源重定价）
--
-- SPEC.md §7 一直挂着一条未落项：
--   「改派写路径（不变量 58 的口径是「改派要重下明细并重新定价」，写路径未落地）」。
--
-- 改派是什么：
--   一条明细在**下单之后、支付之前**跟当前的世界对不上了 ——
--   源侧把那个 SKU 下架了、源场次取消了、报价变了、或者出现了更便宜��源。
--   这时明细还钉在原来的源和原来的价上：按旧价卖出去的东西，
--   要么出不了票，要么按一个已经过期的价卖（选源与定价必须同源，硬约束 15）。
--
-- 口径写在这里，改口径 = 改这份文件 + 同步 SPEC.md §5.20。
--
--   ① **改派是重新选源 + 重新定价**：
--      源与价都取自唯一实现（fn_price_variant —— 它既选源又定价）。
--      Go 侧不重排一次源、不重算一次钱（硬约束 15、18）。
--   ② **只发生在未收款的时候**。
--      已收款的订单切换采纳源，已成交的金额就失去依据了 ——
--      差价退不退、怎么收，是业务决策（行级退款还没落地），不是这里能编的规则。
--      已收款 = 不改派，让它走退款流程。
--   ③ **只对单张形态**。
--      配方与套装的源是**声明**的（源侧那个配方 / 源侧那个整套 SKU），
--      不是选出来的；它们的换源是重新声明，不是改派。
--      判定用 product_variant.variant_role —— 下单与定价这两条路也是用它分
--      「源是选出来的」还是「源是声明出来的」（013/017 的同一个口径）。
--   ④ **只对还没预订过的明细**。
--      预订是事实：已经发到源侧的预订不能靠换源把它抹掉（不变量 58）。
--   ⑤ **成分行跟着明细一起走**。
--      sales_order_item_source 那一行才是履约真正用的源（建预订按它建，
--      不变量 58 也按它判）。改了明细不挪这一行 =
--      「按 A 源的价格卖、按 B 源出票」，那正是这个项目最不许发生的事。
--   ⑥ **库存预占跟着源走**。
--      预占记的是「我们承诺了多少」：钉在旧源上 = 旧池子继续被占着、
--      新池子没被占 —— 「按新源卖、按旧源占库存」（硬约束 22）。
--      挪之前先查新源的池子：明知不够当场报错（超卖比少卖更贵）。
--   ⑦ **留痕**：改派把「从哪个源、哪个价，换到哪个源、哪个价」写进明细快照的
--      reassignments 数组（018 的那条纪律：事实不许被一次调用洗掉）。
--      下单时的定价快照是**冻结**的，不许跟着改 ——
--      它记的是「当时报给客户的那个价」，改派不改写历史，改派写自己的留痕。
--
-- 读侧给一个视图：v_reassign_candidates ——
--   哪些明细跟当前的选源与定价对不上了（该改派）。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 改派的唯一实现
--
-- 返回 outcome：
--   'reassigned' —— 换源或重新定价成功
--   'no_change'  —— 当前源与当前价已经是对的那个（幂等：重复调用不改第二次）
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_reassign_order_item(
    p_order_id      BIGINT,
    p_order_item_id BIGINT,
    p_reason        TEXT DEFAULT NULL
)
RETURNS TABLE (
    order_item_id                BIGINT,
    outcome                      TEXT,
    previous_supplier_product_id BIGINT,
    previous_supplier_id         BIGINT,
    new_supplier_product_id     BIGINT,
    new_supplier_id              BIGINT,
    previous_unit_price          NUMERIC,
    new_unit_price               NUMERIC,
    previous_unit_cost           NUMERIC,
    new_unit_cost                NUMERIC,
    previous_total_price         NUMERIC,
    new_total_price              NUMERIC,
    currency                     TEXT,
    reason                       TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_order      RECORD;
    v_item       RECORD;
    v_price      RECORD;
    v_new_sp     BIGINT;
    v_new_sid    BIGINT;
    v_new_unit   NUMERIC;
    v_new_cost   NUMERIC;
    v_new_total  NUMERIC;
    v_basis      TEXT;
    v_qty        INT;
    v_channel    BIGINT;
    v_variant    BIGINT;
    v_date       DATE;
    v_currency   TEXT;
    v_trail      JSONB;
    v_role       TEXT;
    v_sv         BIGINT;
    v_hold_id    BIGINT;
    v_new_sess   BIGINT;
    v_subtotal   NUMERIC := 0;
    v_cost_total NUMERIC := 0;
    v_total      NUMERIC := 0;
BEGIN
    -- ---------------------------------------------------------------------------------
    -- ① 锁住订单与明细
    --
    -- 先锁订单再锁明细：两个改派同时进来时，后到的那个等一下，
    -- 拿到锁时看到的已经是改完之后的价（不会基于旧价再算一次）。
    -- ---------------------------------------------------------------------------------
    SELECT o.id, o.order_no, o.status, o.currency, o.channel_id, o.discount, o.tax
      INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    SELECT oi.id, oi.order_id, oi.product_id, oi.product_variant_id,
           oi.supplier_product_id, oi.supplier_id, oi.quantity,
           oi.unit_price, oi.unit_cost, oi.total_price,
           oi.currency, oi.status, oi.pricing_basis, oi.detail_snapshot,
           oi.session_id, oi.ticket_type_id
      INTO v_item
      FROM sales_order_item oi
     WHERE oi.id = p_order_item_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单明细 % 不存在', p_order_item_id;
    END IF;

    IF v_item.order_id <> p_order_id THEN
        RAISE EXCEPTION '订单明细 % 不属于订单 %', p_order_item_id, p_order_id;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ② 口径：只发生在未收款的时候
    -- ---------------------------------------------------------------------------------
    IF v_order.status NOT IN ('created', 'awaiting_payment') THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不能改派（改派只发生在未收款时：切换已支付订单的采纳源会让已成交的金额失去依据）',
            v_order.order_no, v_order.status;
    END IF;

    IF EXISTS (SELECT 1 FROM sales_payment sp
                WHERE sp.order_id = p_order_id AND sp.status = 'succeeded') THEN
        RAISE EXCEPTION '订单 % 有成功的支付记录，不能改派（已成交的金额不能失去依据；这类订单走退款）',
            v_order.order_no;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ③ 口径：单张形态、还没预订、还没出票
    -- ---------------------------------------------------------------------------------
    IF v_item.status <> 'pending' THEN
        RAISE EXCEPTION '订单明细 % 当前状态 % 不能改派（只允许还没进入预订的明细）',
            p_order_item_id, v_item.status;
    END IF;

    -- 形态：只对单张形态。
    --
    -- 配方与套装的源是**声明**的（源侧那个配方 / 源侧那个整套 SKU），
    -- 不是选出来的 —— 换源要重新声明配方，不是改派。
    --
    -- 判定用 product_variant.variant_role：下单与定价这两条路也是用它分
    -- 「源是选出来的」还是「源是声明出来的」（013/017 的同一个口径）。
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = v_item.product_variant_id;

    IF v_role = 'combo' THEN
        RAISE EXCEPTION '订单明细 % 是组合/套装形态：它的源是声明的（配方/套装），不是选出来的，换源要重新声明，不走改派',
            p_order_item_id;
    END IF;

    -- 多条成分行的明细同样是声明出来的源（成分拆开了）。
    IF (SELECT count(*) FROM sales_order_item_source s
         WHERE s.order_item_id = p_order_item_id) > 1 THEN
        RAISE EXCEPTION '订单明细 % 有多条成分行：它的源是声明出来的，不是选出来的，换源要重新声明，不走改派',
            p_order_item_id;
    END IF;

    IF EXISTS (SELECT 1 FROM booking b WHERE b.order_item_id = p_order_item_id) THEN
        RAISE EXCEPTION '订单明细 % 已经预订过：改派要在预订之前做（已经发出去的预订是事实，不能靠换源把它抹掉）',
            p_order_item_id;
    END IF;

    IF EXISTS (SELECT 1 FROM voucher v
                WHERE v.order_item_id = p_order_item_id
                  AND v.status IN ('issued', 'used')) THEN
        RAISE EXCEPTION '订单明细 % 已经出票：改派不能改掉已经发出去的票，这类订单走退款',
            p_order_item_id;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ④ 重新选源 + 重新定价
    --
    -- 源与价都从 fn_price_variant 取 —— 它既选源又定价（硬约束 15）。
    -- 这里不另排一次序、不另算一次钱。
    -- ---------------------------------------------------------------------------------
    v_variant := v_item.product_variant_id;
    v_date    := NULLIF(v_item.detail_snapshot ->> 'visit_date', '')::date;
    v_qty     := v_item.quantity;
    v_channel := v_order.channel_id;

    IF v_variant IS NULL OR v_date IS NULL THEN
        RAISE EXCEPTION '订单明细 % 的明细快照不完整（缺变体或访客日），不能改派', p_order_item_id;
    END IF;

    SELECT * INTO v_price
      FROM fn_price_variant(v_variant, v_date, v_channel, v_channel);

    IF NOT FOUND THEN
        RAISE EXCEPTION '变体 % 在 % 没有可售价格（当天没有可用报价 / 商品未上架 / 成本无法折算）：改派不成',
            v_variant, v_date;
    END IF;

    v_currency := v_price.currency;

    IF v_currency <> TRIM(v_order.currency) THEN
        RAISE EXCEPTION '改派后的币种 % 与订单币种 % 不一致（一单一个币种）', v_currency, TRIM(v_order.currency);
    END IF;

    -- 定价口径：按团报价的总价是团总价，与人数不成正比（§4.5）。
    v_basis := COALESCE(NULLIF(v_price.rule ->> 'mode', ''), 'cost_plus');

    IF v_basis = 'per_group' THEN
        v_new_total := v_price.sell_price;
        v_new_unit  := round(v_price.sell_price / v_qty, 2);
        v_new_cost  := round(v_price.cost_price / v_qty, 2);
    ELSE
        v_new_unit  := v_price.sell_price;
        v_new_total := round(v_price.sell_price * v_qty, 2);
        v_new_cost  := v_price.cost_price;
    END IF;

    v_new_sp := v_price.supplier_product_id;

    IF v_new_sp IS NULL THEN
        RAISE EXCEPTION '变体 % 在 % 的定价结果没有单一采纳源：改派不成（这种形态的源不是选出来的）',
            v_variant, v_date;
    END IF;

    SELECT sp.supplier_id INTO v_new_sid
      FROM supplier_product sp
     WHERE sp.id = v_new_sp;

    -- 采纳的源变体：与定价同一个排序函数的第一名（选源与定价同源，硬约束 15）。
    -- 成分行要记源变体，建预订按源 SKU 建（不变量 87/88），所以这里一并取出来。
    SELECT rc.supplier_variant_id INTO v_sv
      FROM fn_route_candidates(v_variant, v_date, v_channel, v_price.currency) rc
     WHERE rc.route_rank = 1;

    -- ---------------------------------------------------------------------------------
    -- ⑤ 幂等：源没变、价没变、成本没变 → 什么都不做
    --
    -- 重复调用同一个改派不会改第二次（幂等键就是「这一条明细 + 当前的世界」）。
    -- ---------------------------------------------------------------------------------
    IF v_new_sp IS NOT DISTINCT FROM v_item.supplier_product_id
       AND v_new_unit IS NOT DISTINCT FROM v_item.unit_price
       AND v_new_cost IS NOT DISTINCT FROM v_item.unit_cost THEN
        order_item_id                := p_order_item_id;
        outcome                      := 'no_change';
        previous_supplier_product_id := v_item.supplier_product_id;
        previous_supplier_id         := v_item.supplier_id;
        new_supplier_product_id     := v_item.supplier_product_id;
        new_supplier_id              := v_item.supplier_id;
        previous_unit_price          := v_item.unit_price;
        new_unit_price               := v_item.unit_price;
        previous_unit_cost           := v_item.unit_cost;
        new_unit_cost                := v_item.unit_cost;
        previous_total_price         := v_item.total_price;
        new_total_price              := v_item.total_price;
        currency                     := v_currency;
        reason                       := p_reason;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ⑥ 落库：明细（留痕）+ 订单的钱
    --
    -- 明细就地改（重下一行明细 = 把这一行重新按当前的世界下一次），
    -- 旧值进快照的 reassignments —— 事实不许被一次调用洗掉（018）。
    -- ---------------------------------------------------------------------------------
    v_trail := jsonb_build_array(jsonb_build_object(
        'at',                       now(),
        'reason',                   p_reason,
        'from_supplier_product_id', v_item.supplier_product_id,
        'from_supplier_id',         v_item.supplier_id,
        'to_supplier_product_id',   v_new_sp,
        'to_supplier_id',           v_new_sid,
        'from_unit_price',          v_item.unit_price,
        'to_unit_price',            v_new_unit,
        'from_unit_cost',           v_item.unit_cost,
        'to_unit_cost',             v_new_cost,
        'from_total_price',         v_item.total_price,
        'to_total_price',           v_new_total,
        'currency',                 v_currency,
        'fx_rate',                  v_price.fx_rate,
        'fx_as_of',                 v_price.fx_as_of));

    UPDATE sales_order_item
       SET supplier_product_id = v_new_sp,
           supplier_id         = v_new_sid,
           unit_price          = v_new_unit,
           unit_cost           = v_new_cost,
           total_price         = v_new_total,
           currency            = v_currency,
           detail_snapshot     = (v_item.detail_snapshot
                || jsonb_build_object(
                       'unit_price',           v_new_unit,
                       'total_price',          v_new_total,
                       'cost_price',           v_new_cost,
                       'fx_rate',              v_price.fx_rate,
                       'fx_as_of',             v_price.fx_as_of,
                       'rule',                 v_price.rule,
                       'cost_source_product_id', v_new_sp)
                || jsonb_build_object(
                       'reassignments',
                       COALESCE(v_item.detail_snapshot -> 'reassignments', '[]'::jsonb) || v_trail))
     WHERE id = p_order_item_id;

    -- 成分行跟着明细一起走。
    --
    -- sales_order_item_source 那一行才是履约真正用的源：建预订按它建，
    -- 不变量 58 也按它判。改了明细不挪这一行 =
    -- 「按 A 源的价格卖、按 B 源出票」——
    -- 这是本项目最不许发生的事，所以改派必须两处一起改。
    --
    -- 挪的是源相关的字段：源变体 / 源商品 / 供应商 / 源场次 / 成本 / 币种 / 汇率。
    -- 规范场次与票种不动 —— 那是这个变体在这天的属性，不是源的属性，
    -- 换了源它也不变（源场次是「规范场次 ↔ 源商品」的绑定，绑定表说了算）。
    UPDATE sales_order_item_source s
       SET supplier_variant_id = v_sv,
           supplier_product_id = v_new_sp,
           supplier_id         = v_new_sid,
           supplier_session_id = fn_bound_supplier_session(s.product_session_id, v_new_sp),
           unit_cost           = v_price.cost_price,
           currency            = v_price.source_currency,
           fx_rate             = v_price.fx_rate,
           fx_as_of            = v_price.fx_as_of
     WHERE s.order_item_id = p_order_item_id;

    -- 库存预占跟着源走。
    --
    -- 预占记的是「我们承诺了多少」：钉在旧源上 = 旧池子继续被占着、新池子没被占 ——
    -- 那就是「按新源卖、按旧源占库存」（硬约束 22）。
    --
    -- 先查新源的池子：明知不够还改派 = 超卖，当场报错（fn_reserve_qty 是唯一实现）。
    -- 「不知道」（源侧没报这个池子的库存）时不拦 —— 返回 0 意味着「卖完了」，
    -- 那比超卖更贵（硬约束 22）。
    SELECT h.id INTO v_hold_id
      FROM inventory_hold h
     WHERE h.order_id = p_order_id
       AND h.status = 'consumed'
       AND h.product_session_id IS NOT DISTINCT FROM v_item.session_id
       AND h.ticket_type_id IS NOT DISTINCT FROM v_item.ticket_type_id
       AND h.supplier_id IS NOT DISTINCT FROM v_item.supplier_id
       AND h.quantity = v_item.quantity
     ORDER BY h.id
     LIMIT 1
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单明细 % 没有对应的库存预占，改派不成（预占是事实，不能凭空造一条）',
            p_order_item_id;
    END IF;

    v_new_sess := fn_bound_supplier_session(
        COALESCE(v_item.session_id,
                 (SELECT s.product_session_id
                    FROM sales_order_item_source s
                   WHERE s.order_item_id = p_order_item_id
                   LIMIT 1)),
        v_new_sp);

    PERFORM * FROM fn_reserve_qty(v_new_sess, v_item.ticket_type_id, v_item.quantity,
                                   '改派到源商品 ' || v_new_sp::text);

    UPDATE inventory_hold
       SET supplier_id         = v_new_sid,
           supplier_session_id = v_new_sess
     WHERE id = v_hold_id;

    -- 订单的钱跟着明细走（不变量 53：小计 = 明细合计）。
    -- 成本按明细自己记的口径还原：按团报价的成本是团成本，不是人均 × 人数。
    SELECT COALESCE(sum(oi.total_price), 0),
           COALESCE(sum(CASE WHEN oi.pricing_basis = 'per_group'
                               THEN COALESCE((oi.detail_snapshot ->> 'cost_price')::numeric, 0)
                               ELSE COALESCE(oi.unit_cost, 0) * oi.quantity END), 0)
      INTO v_subtotal, v_cost_total
      FROM sales_order_item oi
     WHERE oi.order_id = p_order_id;

    v_total := round(v_subtotal - COALESCE(v_order.discount, 0) + COALESCE(v_order.tax, 0), 2);

    UPDATE sales_order
       SET subtotal    = v_subtotal,
           total       = v_total,
           cost_total  = v_cost_total
     WHERE id = p_order_id;

    -- ---------------------------------------------------------------------------------
    -- ⑦ 领域事件
    --
    -- 状态没变（订单还在等付款），但价变了 —— 报价变了是件要通知出去的事，
    -- 所以显式落一条事件（SPEC.md §6）。
    -- ---------------------------------------------------------------------------------
    INSERT INTO event_outbox (aggregate_type, aggregate_id, event_type, payload)
    VALUES ('order', p_order_id, 'OrderItemReassigned', jsonb_build_object(
        'aggregate_type',            'order',
        'aggregate_id',              p_order_id,
        'order_no',                  v_order.order_no,
        'order_item_id',             p_order_item_id,
        'from_supplier_product_id',  v_item.supplier_product_id,
        'to_supplier_product_id',    v_new_sp,
        'from_unit_price',           v_item.unit_price,
        'to_unit_price',             v_new_unit,
        'reason',                    p_reason));

    order_item_id                := p_order_item_id;
    outcome                      := 'reassigned';
    previous_supplier_product_id := v_item.supplier_product_id;
    previous_supplier_id         := v_item.supplier_id;
    new_supplier_product_id     := v_new_sp;
    new_supplier_id              := v_new_sid;
    previous_unit_price          := v_item.unit_price;
    new_unit_price               := v_new_unit;
    previous_unit_cost           := v_item.unit_cost;
    new_unit_cost                := v_new_cost;
    previous_total_price         := v_item.total_price;
    new_total_price              := v_new_total;
    currency                     := v_currency;
    reason                       := p_reason;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_reassign_order_item(BIGINT, BIGINT, TEXT) IS
    '改派的唯一实现：重新选源 + 重新定价（源与价都取自 fn_price_variant），只在未收款、还没预订过的单张明细上做，改派留痕写进明细快照';

-- -------------------------------------------------------------------------------------
-- ② 读侧：哪些明细该改派
--
-- 这一行只回答「跟当前的世界对不上了」：
--   源变了（源侧下架 / 出现了别的源）、
--   价变了（报价动了）、
--   成本变了（价没变但成本动了）、
--   当天根本没有可用报价了（源侧全撤了）。
--
-- 口径与 fn_reassign_order_item 一致：同一批排除条件（未收款 / 没预订 / 没出票 / 单张形态）。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_reassign_candidates AS
SELECT o.id                AS order_id,
       o.order_no,
       o.channel_id,
       oi.id               AS order_item_id,
       oi.product_id,
       oi.product_variant_id,
       (oi.detail_snapshot ->> 'visit_date')::date AS visit_date,
       oi.quantity,
       oi.supplier_product_id AS current_supplier_product_id,
       cur.name            AS current_supplier,
       oi.unit_price       AS current_unit_price,
       oi.unit_cost        AS current_unit_cost,
       p.supplier_product_id AS new_supplier_product_id,
       nsup.name           AS new_supplier,
       CASE WHEN oi.pricing_basis = 'per_group'
            THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2)
            ELSE p.sell_price END AS new_unit_price,
       p.cost_price        AS new_unit_cost,
       (p.sell_price IS NOT NULL) AS can_reassign,
       CASE WHEN p.sell_price IS NULL THEN '当天没有可用报价'
            WHEN p.supplier_product_id IS DISTINCT FROM oi.supplier_product_id
                THEN '源变了：' || COALESCE(cur.name, '?') || ' → ' || COALESCE(nsup.name, '?')
            WHEN (CASE WHEN oi.pricing_basis = 'per_group'
                       THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2)
                       ELSE p.sell_price END) IS DISTINCT FROM oi.unit_price
                THEN '价变了：' || oi.unit_price::text || ' → ' ||
                     (CASE WHEN oi.pricing_basis = 'per_group'
                           THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2)
                           ELSE p.sell_price END)::text
            WHEN p.cost_price IS DISTINCT FROM oi.unit_cost THEN '成本变了'
       END AS stale_reason
  FROM sales_order o
  JOIN sales_order_item oi ON oi.order_id = o.id
  LEFT JOIN LATERAL fn_price_variant(oi.product_variant_id,
                                      (oi.detail_snapshot ->> 'visit_date')::date,
                                      o.channel_id, o.channel_id) p
    ON true
  LEFT JOIN supplier_product curp ON curp.id = oi.supplier_product_id
  LEFT JOIN supplier cur        ON cur.id = curp.supplier_id
  LEFT JOIN supplier_product nsp ON nsp.id = p.supplier_product_id
  LEFT JOIN supplier nsup       ON nsup.id = nsp.supplier_id
 WHERE o.status IN ('created', 'awaiting_payment')
   AND oi.status = 'pending'
   AND oi.product_variant_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sales_payment sp
                    WHERE sp.order_id = o.id AND sp.status = 'succeeded')
   -- 排除配方/套装形态：它们的源是声明的，不是选出来的（口径与 fn_reassign_order_item 一致）。
   AND COALESCE((SELECT pv.variant_role
                   FROM product_variant pv
                  WHERE pv.id = oi.product_variant_id), 'base') <> 'combo'
   AND (SELECT count(*) FROM sales_order_item_source s
         WHERE s.order_item_id = oi.id) <= 1
   AND NOT EXISTS (SELECT 1 FROM booking b WHERE b.order_item_id = oi.id)
   AND NOT EXISTS (SELECT 1 FROM voucher v
                    WHERE v.order_item_id = oi.id AND v.status IN ('issued', 'used'))
   AND (p.sell_price IS NULL
        OR p.supplier_product_id IS DISTINCT FROM oi.supplier_product_id
        OR (CASE WHEN oi.pricing_basis = 'per_group'
                 THEN round(p.sell_price / NULLIF(oi.quantity, 0), 2)
                 ELSE p.sell_price END) IS DISTINCT FROM oi.unit_price
        OR p.cost_price IS DISTINCT FROM oi.unit_cost);

COMMENT ON VIEW v_reassign_candidates IS
    '待改派明细：与当前选源/定价对不上的未收款明细（源变了 / 价变了 / 成本变了 / 当天没有报价了）';

-- -------------------------------------------------------------------------------------
-- ③ 不变量 54 修订：改派过的行由留痕解释
--
-- 原来那条只比「明细单价 = 下单时的定价快照单价」。
-- 改派之后明细的单价会动（那正是改派要做的事），
-- 而下单时的定价快照是冻结的 —— 它记的是「当时报给客户的那个价」，不许跟着改。
--
-- 所以这条改成：明细的单价要么等于下单时的定价快照（没改派过的行），
-- 要么等于改派留痕里的新单价（改派过的行）。
-- 留痕自己另外有一条不变量（109）把住。
-- -------------------------------------------------------------------------------------
DROP VIEW v_invariant_checks;

ALTER VIEW v_invariant_checks_order RENAME TO v_invariant_checks_order_004;

COMMENT ON VIEW v_invariant_checks_order_004 IS
    '下单侧不变量旧版（54）：明细单价必须等于定价函数输出（024 之前）';

CREATE VIEW v_invariant_checks_order AS
WITH raw (seq, check_name, actual) AS (
    -- 54：订单明细的单价必须等于定价函数在同一天的输出。
    --     没被改派过的行：单价 = 下单时的定价快照（那份快照就是定价函数的输出）。
    --     被改派过的行：单价 = 改派留痕里的新单价（改派重新定价，价动是改派的目的）。
    --
    --     两样都没有的行不查：变体层之前下的老订单没有定价快照，
    --     拿一个空快照去比，比出来的红是假的（这条门禁要抓的是「算歪了」，不是「没记录」）。
    SELECT 54, '订单明细单价必须等于定价函数输出',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN sales_order o ON o.id = oi.order_id
             WHERE oi.product_variant_id IS NOT NULL
               AND EXISTS (
                     SELECT 1
                       FROM jsonb_array_elements(COALESCE(o.pricing_snapshot -> 'items', '[]'::jsonb)) it
                      WHERE (it ->> 'variant_id')::bigint = oi.product_variant_id
                        AND it ->> 'visit_date' = oi.detail_snapshot ->> 'visit_date'
                   UNION ALL
                     SELECT 1
                       FROM jsonb_array_elements(COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb)))
               AND oi.unit_price IS DISTINCT FROM COALESCE(
                   -- 改派留痕的最后一跳
                   (SELECT (r.val ->> 'to_unit_price')::numeric
                      FROM jsonb_array_elements(COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb))
                           WITH ORDINALITY AS r(val, ord)
                     ORDER BY r.ord DESC
                     LIMIT 1),
                   -- 下单时的定价快照
                   (SELECT (it ->> 'unit_price')::numeric
                      FROM jsonb_array_elements(COALESCE(o.pricing_snapshot -> 'items', '[]'::jsonb)) it
                     WHERE (it ->> 'variant_id')::bigint = oi.product_variant_id
                       AND it ->> 'visit_date' = oi.detail_snapshot ->> 'visit_date'
                     LIMIT 1)))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_order IS
    '下单侧不变量（54）：明细单价必须等于定价函数输出（改派过的行由改派留痕解释）';

-- -------------------------------------------------------------------------------------
-- ④ 不变量 109-112：改派侧
--
-- 109：改派留痕的最后一跳必须等于明细当前值。
--      明细不许在改派之后被人手改过（改了价、改了源，留痕不认）。
-- 110：改派留痕的链必须自洽，且第一跳从下单时的定价快照起。
--      链断了 = 有一次改派没留痕（那就是把历史洗掉了）。
-- 111：已收款的订单不许有改派过的明细。
--      已成交的金额不许因为换源而失去依据（改派只发生在未收款时）。
-- 112：单张形态的成分行必须与明细的采纳源一致。
--      两处说的不是同一个源 = 「按 A 源的价格卖、按 B 源出票」。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_reassign AS
WITH trail AS (
    SELECT oi.id AS order_item_id,
           o.id AS order_id,
           o.pricing_snapshot,
           oi.unit_price,
           oi.unit_cost,
           oi.total_price,
           oi.supplier_product_id,
           oi.supplier_id,
           COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb) AS steps
      FROM sales_order_item oi
      JOIN sales_order o ON o.id = oi.order_id
     WHERE jsonb_array_length(COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb)) > 0
),
last_step AS (
    SELECT t.*,
           (SELECT s.val FROM jsonb_array_elements(t.steps) WITH ORDINALITY AS s(val, ord)
             ORDER BY s.ord DESC LIMIT 1) AS last
      FROM trail t
),
raw (seq, check_name, actual) AS (
    -- 109：留痕的最后一跳 = 明细当前值
    SELECT 109, '改派留痕的最后一跳必须等于明细当前值',
           (SELECT count(*)
              FROM last_step l
             WHERE (l.last ->> 'to_supplier_product_id')::bigint IS DISTINCT FROM l.supplier_product_id
                OR (l.last ->> 'to_supplier_id')::bigint IS DISTINCT FROM l.supplier_id
                OR (l.last ->> 'to_unit_price')::numeric IS DISTINCT FROM l.unit_price
                OR (l.last ->> 'to_unit_cost')::numeric IS DISTINCT FROM l.unit_cost
                OR (l.last ->> 'to_total_price')::numeric IS DISTINCT FROM l.total_price)
    UNION ALL
    -- 110：链自洽 + 第一跳接得上定价快照
    SELECT 110, '改派留痕的链必须自洽且接得上下单时的定价快照',
           (SELECT count(*)
              FROM trail t
             WHERE EXISTS (
                     -- 每一跳的 from_* = 上一跳的 to_*
                     SELECT 1
                       FROM jsonb_array_elements(t.steps) WITH ORDINALITY AS s(val, ord)
                       JOIN jsonb_array_elements(t.steps) WITH ORDINALITY AS s2(val, ord2)
                         ON s2.ord2 = s.ord - 1
                      WHERE (s.val ->> 'from_supplier_product_id')::bigint
                            IS DISTINCT FROM (s2.val ->> 'to_supplier_product_id')::bigint
                         OR (s.val ->> 'from_unit_price')::numeric
                            IS DISTINCT FROM (s2.val ->> 'to_unit_price')::numeric
                         OR (s.val ->> 'from_unit_cost')::numeric
                            IS DISTINCT FROM (s2.val ->> 'to_unit_cost')::numeric
                         OR (s.val ->> 'from_total_price')::numeric
                            IS DISTINCT FROM (s2.val ->> 'to_total_price')::numeric)
             OR EXISTS (
                     -- 第一跳的 from_* = 下单时的定价快照
                     SELECT 1
                       FROM jsonb_array_elements(t.steps) WITH ORDINALITY AS s(val, ord)
                       JOIN jsonb_array_elements(COALESCE(t.pricing_snapshot -> 'items', '[]'::jsonb)) it
                         ON (it ->> 'variant_id')::bigint = (SELECT oi.product_variant_id
                                                             FROM sales_order_item oi
                                                            WHERE oi.id = t.order_item_id)
                      WHERE s.ord = 1
                        AND (it ->> 'visit_date') = (SELECT oi.detail_snapshot ->> 'visit_date'
                                                     FROM sales_order_item oi
                                                     WHERE oi.id = t.order_item_id)
                        AND (s.val ->> 'from_unit_price')::numeric
                            IS DISTINCT FROM (it ->> 'unit_price')::numeric))
    UNION ALL
    -- 111：已收款的订单不许有改派过的明细
    SELECT 111, '已收款的订单不许有改派过的明细',
           (SELECT count(*)
              FROM trail t
             WHERE EXISTS (SELECT 1 FROM sales_payment sp
                            WHERE sp.order_id = t.order_id AND sp.status = 'succeeded'))
    UNION ALL
    -- 112：单张形态的成分行必须与明细的采纳源一致
    --      履约按成分行建预订（不变量 58），记账按明细自己的字段。
    --      两处说的不是同一个源 = 「按 A 源的价格卖、按 B 源出票」——
    --      改派改了明细就必须连成分行一起改，这条门禁守着那个「一起」。
    --      配方与套装的成分行说的本来就是成分的源（不是明细的采纳源），所以排除。
    SELECT 112, '单张形态的成分行必须与明细的采纳源一致',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN product_variant pv ON pv.id = oi.product_variant_id
              JOIN sales_order_item_source s ON s.order_item_id = oi.id
             WHERE pv.variant_role <> 'combo'
               AND (s.supplier_product_id IS DISTINCT FROM oi.supplier_product_id
                    OR s.supplier_id IS DISTINCT FROM oi.supplier_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_reassign IS
    '改派侧不变量（109-112）：留痕与明细一致、留痕链自洽、已收款的订单不许改派、成分行与采纳源一致';

-- -------------------------------------------------------------------------------------
-- ⑤ 总表：加进 112
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v_invariant_checks_core_017.seq, v_invariant_checks_core_017.check_name, v_invariant_checks_core_017.expected, v_invariant_checks_core_017.actual, v_invariant_checks_core_017.passed, v_invariant_checks_core_017.result FROM v_invariant_checks_core_017
UNION ALL SELECT v_invariant_checks_tx.seq, v_invariant_checks_tx.check_name, v_invariant_checks_tx.expected, v_invariant_checks_tx.actual, v_invariant_checks_tx.passed, v_invariant_checks_tx.result FROM v_invariant_checks_tx
UNION ALL SELECT v_invariant_checks_order.seq, v_invariant_checks_order.check_name, v_invariant_checks_order.expected, v_invariant_checks_order.actual, v_invariant_checks_order.passed, v_invariant_checks_order.result FROM v_invariant_checks_order
UNION ALL SELECT v_invariant_checks_fulfill.seq, v_invariant_checks_fulfill.check_name, v_invariant_checks_fulfill.expected, v_invariant_checks_fulfill.actual, v_invariant_checks_fulfill.passed, v_invariant_checks_fulfill.result FROM v_invariant_checks_fulfill
UNION ALL SELECT v_invariant_checks_refund.seq, v_invariant_checks_refund.check_name, v_invariant_checks_refund.expected, v_invariant_checks_refund.actual, v_invariant_checks_refund.passed, v_invariant_checks_refund.result FROM v_invariant_checks_refund
UNION ALL SELECT v_invariant_checks_redemption.seq, v_invariant_checks_redemption.check_name, v_invariant_checks_redemption.expected, v_invariant_checks_redemption.actual, v_invariant_checks_redemption.passed, v_invariant_checks_redemption.result FROM v_invariant_checks_redemption
UNION ALL SELECT v_invariant_checks_inventory_017.seq, v_invariant_checks_inventory_017.check_name, v_invariant_checks_inventory_017.expected, v_invariant_checks_inventory_017.actual, v_invariant_checks_inventory_017.passed, v_invariant_checks_inventory_017.result FROM v_invariant_checks_inventory_017
UNION ALL SELECT v_invariant_checks_validity_017.seq, v_invariant_checks_validity_017.check_name, v_invariant_checks_validity_017.expected, v_invariant_checks_validity_017.actual, v_invariant_checks_validity_017.passed, v_invariant_checks_validity_017.result FROM v_invariant_checks_validity_017
UNION ALL SELECT v_invariant_checks_readmodel.seq, v_invariant_checks_readmodel.check_name, v_invariant_checks_readmodel.expected, v_invariant_checks_readmodel.actual, v_invariant_checks_readmodel.passed, v_invariant_checks_readmodel.result FROM v_invariant_checks_readmodel
UNION ALL SELECT v_invariant_checks_composition.seq, v_invariant_checks_composition.check_name, v_invariant_checks_composition.expected, v_invariant_checks_composition.actual, v_invariant_checks_composition.passed, v_invariant_checks_composition.result FROM v_invariant_checks_composition
UNION ALL SELECT v_invariant_checks_combo_017.seq, v_invariant_checks_combo_017.check_name, v_invariant_checks_combo_017.expected, v_invariant_checks_combo_017.actual, v_invariant_checks_combo_017.passed, v_invariant_checks_combo_017.result FROM v_invariant_checks_combo_017
UNION ALL SELECT v_invariant_checks_hardening.seq, v_invariant_checks_hardening.check_name, v_invariant_checks_hardening.expected, v_invariant_checks_hardening.actual, v_invariant_checks_hardening.passed, v_invariant_checks_hardening.result FROM v_invariant_checks_hardening
UNION ALL SELECT v_invariant_checks_bundle.seq, v_invariant_checks_bundle.check_name, v_invariant_checks_bundle.expected, v_invariant_checks_bundle.actual, v_invariant_checks_bundle.passed, v_invariant_checks_bundle.result FROM v_invariant_checks_bundle
UNION ALL SELECT v_invariant_checks_bundle_020.seq, v_invariant_checks_bundle_020.check_name, v_invariant_checks_bundle_020.expected, v_invariant_checks_bundle_020.actual, v_invariant_checks_bundle_020.passed, v_invariant_checks_bundle_020.result FROM v_invariant_checks_bundle_020
UNION ALL SELECT v_invariant_checks_supply_forms_021.seq, v_invariant_checks_supply_forms_021.check_name, v_invariant_checks_supply_forms_021.expected, v_invariant_checks_supply_forms_021.actual, v_invariant_checks_supply_forms_021.passed, v_invariant_checks_supply_forms_021.result FROM v_invariant_checks_supply_forms_021
UNION ALL SELECT v_invariant_checks_supply_form_shrink_022.seq, v_invariant_checks_supply_form_shrink_022.check_name, v_invariant_checks_supply_form_shrink_022.expected, v_invariant_checks_supply_form_shrink_022.actual, v_invariant_checks_supply_form_shrink_022.passed, v_invariant_checks_supply_form_shrink_022.result FROM v_invariant_checks_supply_form_shrink_022
UNION ALL SELECT v_invariant_checks_supply_source_count_023.seq, v_invariant_checks_supply_source_count_023.check_name, v_invariant_checks_supply_source_count_023.expected, v_invariant_checks_supply_source_count_023.actual, v_invariant_checks_supply_source_count_023.passed, v_invariant_checks_supply_source_count_023.result FROM v_invariant_checks_supply_source_count_023
UNION ALL SELECT v_invariant_checks_reassign.seq, v_invariant_checks_reassign.check_name, v_invariant_checks_reassign.expected, v_invariant_checks_reassign.actual, v_invariant_checks_reassign.passed, v_invariant_checks_reassign.result FROM v_invariant_checks_reassign;
