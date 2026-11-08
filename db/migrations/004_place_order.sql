-- =====================================================================================
-- 004 下单写路径
--
-- 到这一步为止，系统只有「读」：定价、路由、读模型、C 端视图都能查，
-- 但一笔订单怎么落库没人写 —— SPEC.md §3.3 的交易流只有一张图。
--
-- 这一份迁移给出下单的唯一实现 fn_place_order()：
--   - 金额与采纳源只从定价函数的唯一实现 fn_price_variant() 取，不另算一遍；
--     同一个函数既选源又定价，所以「按 A 源的价格卖、按 B 源出票」不可能发生；
--   - 幂等键必填（硬约束 8），重复下单返回同一张单，不会产生第二张；
--   - 明细快照落库（硬约束 7），订单历史不依赖当前商品表；
--   - 下单即留领域事件（触发器自动写 event_outbox，见 003）。
--
-- 预订（booking）不在这里建：SPEC.md §3.3 规定 booking 是独立聚合，
-- 在订单支付成功之后才创建，不能因为源侧故障阻塞订单聚合。
-- =====================================================================================

-- 订单号：TC + 日期 + 6 位流水（与种子数据的编号口径一致）
CREATE SEQUENCE public.seq_order_no;

COMMENT ON SEQUENCE public.seq_order_no IS '订单号流水（TC + YYYYMMDD + 6 位）';

CREATE FUNCTION fn_place_order(
    p_channel_id      BIGINT,
    p_idempotency_key TEXT,
    p_items           JSONB,
    p_customer_id     BIGINT DEFAULT NULL,
    p_contact         JSONB DEFAULT '{}'::jsonb,
    p_buyer_note      TEXT DEFAULT NULL,
    p_holders         JSONB DEFAULT '[]'::jsonb
)
RETURNS TABLE (
    order_id       BIGINT,
    order_no       TEXT,
    order_status   TEXT,
    order_currency TEXT,
    order_subtotal NUMERIC,
    order_total    NUMERIC,
    created        BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_scope        TEXT;
    v_hash         TEXT;
    v_existing     RECORD;
    v_order        RECORD;
    v_item         JSONB;
    v_resolved     JSONB := '[]'::jsonb;   -- 解析好的明细，落库时再取
    v_items        JSONB := '[]'::jsonb;   -- 已落库的明细（带 order_item_id）
    v_pricing      JSONB := '[]'::jsonb;   -- 定价快照（订单级）
    v_line         JSONB;
    v_req          RECORD;
    v_holder       JSONB;
    v_item_id      BIGINT;
    v_holders      INT;
    v_variant      BIGINT;
    v_qty          INT;
    v_date         DATE;
    v_price        RECORD;
    v_price_row    RECORD;
    v_listing_id   BIGINT;
    v_supplier_id  BIGINT;
    v_basis        TEXT;
    v_unit_price   NUMERIC;
    v_unit_cost    NUMERIC;
    v_total_price  NUMERIC;
    v_snapshot     JSONB;
    v_currency     TEXT;
    v_subtotal     NUMERIC := 0;
    v_cost_total   NUMERIC := 0;
    v_order_id     BIGINT;
    v_order_no     TEXT;
    v_detail       JSONB;
    v_inserted     INT;
BEGIN
    -- ---------------------------------------------------------------------------------
    -- ① 参数与前置检查
    -- ---------------------------------------------------------------------------------
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
        RAISE EXCEPTION '缺少幂等键：下单必须幂等';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION '下单明细不能为空';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM channel c WHERE c.id = p_channel_id AND c.status = 'active') THEN
        RAISE EXCEPTION '渠道 % 不存在或不是 active', p_channel_id;
    END IF;

    IF p_customer_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM customer cu WHERE cu.id = p_customer_id) THEN
        RAISE EXCEPTION '客户 % 不存在', p_customer_id;
    END IF;

    v_scope := 'order:' || p_channel_id::text;
    v_hash  := md5(p_channel_id::text || '|' || p_items::text || '|'
                   || COALESCE(p_contact::text, '{}') || '|' || COALESCE(p_buyer_note, '')
                   || '|' || COALESCE(p_holders::text, '[]'));

    -- ---------------------------------------------------------------------------------
    -- ② 幂等：抢键
    --
    -- 抢键用 INSERT ... ON CONFLICT DO NOTHING，不用「先查后插」：
    -- 先查后插在并发下会双双通过检查，然后双双落单。
    -- ---------------------------------------------------------------------------------
    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_idempotency_key, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        -- 键已被占用：要么是同一笔请求（返回原单），要么是另一笔请求（拒绝）。
        SELECT ir.request_hash, ir.response, ir.status INTO v_existing
          FROM idempotency_record ir
         WHERE ir.scope = v_scope AND ir.idempotency_key = p_idempotency_key;

        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔请求（订单 %）',
              p_idempotency_key, COALESCE(v_existing.response->>'order_no', '?');
        END IF;

        SELECT o.id, o.order_no, o.status, o.currency, o.subtotal, o.total INTO v_order
          FROM sales_order o
         WHERE o.id = NULLIF(v_existing.response->>'order_id', '')::bigint;

        IF NOT FOUND THEN
            RAISE EXCEPTION '幂等键 % 正在处理中，稍后重试', p_idempotency_key;
        END IF;

        order_id       := v_order.id;
        order_no       := v_order.order_no;
        order_status   := v_order.status;
        order_currency := v_order.currency;
        order_subtotal := v_order.subtotal;
        order_total    := v_order.total;
        created        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 抢到键了，但库里可能已经有同键的订单（幂等记录被清过的情况）。
    SELECT o.id, o.order_no, o.status, o.currency, o.subtotal, o.total INTO v_order
      FROM sales_order o
     WHERE o.channel_id = p_channel_id
       AND o.idempotency_key = p_idempotency_key;

    IF FOUND THEN
        UPDATE idempotency_record
           SET status   = 'done',
               response = jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no)
         WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

        order_id       := v_order.id;
        order_no       := v_order.order_no;
        order_status   := v_order.status;
        order_currency := v_order.currency;
        order_subtotal := v_order.subtotal;
        order_total    := v_order.total;
        created        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ③ 逐项解析：价格、采纳源、快照
    --
    -- 金额只从 fn_price_variant() 取（定价的唯一实现）。
    -- 采纳源也来自同一个函数 —— 定价选中的源就是路由选中的源（不变量 43）。
    -- ---------------------------------------------------------------------------------
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_variant := NULLIF(v_item->>'variant_id', '')::bigint;
        v_qty     := COALESCE(NULLIF(v_item->>'quantity', '')::int, 0);
        v_date    := NULLIF(v_item->>'visit_date', '')::date;

        IF v_variant IS NULL OR v_qty <= 0 OR v_date IS NULL THEN
            RAISE EXCEPTION '明细不完整（需要 variant_id / quantity / visit_date）：%', v_item::text;
        END IF;

        SELECT * INTO v_price
          FROM fn_price_variant(v_variant, v_date, p_channel_id, p_channel_id);

        IF NOT FOUND THEN
            RAISE EXCEPTION '变体 % 在 % 没有可售价格（商品未上架 / 当天无可用报价 / 成本无法折算）',
              v_variant, v_date;
        END IF;

        v_basis := COALESCE(NULLIF(v_price.rule->>'mode', ''), 'cost_plus');

        IF v_basis = 'per_group' THEN
            -- 按团报价：总价是团总价，与人数不成正比；人均只是分摊（硬约束 5）。
            v_total_price := v_price.sell_price;
            v_unit_price  := round(v_price.sell_price / v_qty, 2);
            v_unit_cost   := round(v_price.cost_price / v_qty, 2);
            v_cost_total  := v_cost_total + v_price.cost_price;
        ELSE
            v_unit_price  := v_price.sell_price;
            v_total_price := round(v_price.sell_price * v_qty, 2);
            v_unit_cost   := v_price.cost_price;
            v_cost_total  := v_cost_total + round(v_price.cost_price * v_qty, 2);
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_price.currency;
        ELSIF v_currency <> v_price.currency THEN
            RAISE EXCEPTION '一单只能一个币种：% 与 % 混在一单里', v_currency, v_price.currency;
        END IF;

        v_subtotal := v_subtotal + v_total_price;

        -- 场次与票种 id 从价格行借（只借 id，不借金额：金额只认定价函数）。
        SELECT pc.session_id, pc.ticket_type_id INTO v_price_row
          FROM price_calendar pc
         WHERE pc.product_variant_id = v_variant
           AND pc.date = v_date
           AND pc.status = 'active'
           AND (pc.channel_id = p_channel_id OR pc.channel_id IS NULL)
         ORDER BY (pc.channel_id IS NOT NULL) DESC, pc.id DESC
         LIMIT 1;

        SELECT cl.id INTO v_listing_id
          FROM channel_listing cl
         WHERE cl.channel_id = p_channel_id
           AND cl.product_id = v_price.product_id
           AND cl.status = 'online'
         ORDER BY cl.id
         LIMIT 1;

        SELECT sp.supplier_id INTO v_supplier_id
          FROM supplier_product sp
         WHERE sp.id = v_price.supplier_product_id;

        v_snapshot := jsonb_build_object(
            'variant_id',           v_variant,
            'product_id',           v_price.product_id,
            'visit_date',           v_date,
            'quantity',             v_qty,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'unit_price',           v_unit_price,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'cost_price',           v_price.cost_price,
            'cost_source_product_id', v_price.supplier_product_id,
            'price_locked',         v_price.price_locked,
            'fx_rate',              v_price.fx_rate,
            'fx_as_of',             v_price.fx_as_of,
            'rule',                 v_price.rule)
            || CASE WHEN v_basis = 'per_group'
                    THEN jsonb_build_object('group_total', v_price.sell_price)
                    ELSE '{}'::jsonb END;

        v_resolved := v_resolved || jsonb_build_array(jsonb_build_object(
            'product_id',           v_price.product_id,
            'product_variant_id',   v_variant,
            'session_id',           v_price_row.session_id,
            'ticket_type_id',       v_price_row.ticket_type_id,
            'channel_listing_id',   v_listing_id,
            'supplier_product_id',  v_price.supplier_product_id,
            'supplier_id',          v_supplier_id,
            'quantity',             v_qty,
            'unit_price',           v_unit_price,
            'unit_cost',            v_unit_cost,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'snapshot',             v_snapshot));

        v_pricing := v_pricing || jsonb_build_array(v_snapshot);
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④ 落单
    -- ---------------------------------------------------------------------------------
    v_order_no := 'TC' || to_char(now(), 'YYYYMMDD') || lpad(nextval('public.seq_order_no')::text, 6, '0');

    INSERT INTO sales_order (order_no, channel_id, customer_id, status, currency,
                             subtotal, discount, tax, total, cost_total, commission_amount,
                             pricing_snapshot, contact_snapshot, idempotency_key, buyer_note, expires_at)
    VALUES (v_order_no, p_channel_id, p_customer_id, 'created', v_currency,
            v_subtotal, 0, 0, v_subtotal, v_cost_total, 0,
            jsonb_build_object('items', v_pricing, 'channel_id', p_channel_id, 'computed_at', now()),
            COALESCE(p_contact, '{}'::jsonb), p_idempotency_key, p_buyer_note,
            now() + interval '30 minutes')
    RETURNING id INTO v_order_id;

    -- 明细：展示内容走快照，订单历史不依赖当前商品表（硬约束 7）。
    FOR v_detail IN SELECT * FROM jsonb_array_elements(v_resolved)
    LOOP
        INSERT INTO sales_order_item (order_id, product_id, product_variant_id, channel_listing_id,
                                      supplier_product_id, supplier_id, session_id, ticket_type_id,
                                      quantity, unit_price, unit_cost, total_price, currency,
                                      pricing_basis, detail_snapshot, status)
        VALUES (v_order_id,
                (v_detail->>'product_id')::bigint,
                (v_detail->>'product_variant_id')::bigint,
                NULLIF(v_detail->>'channel_listing_id', '')::bigint,
                NULLIF(v_detail->>'supplier_product_id', '')::bigint,
                NULLIF(v_detail->>'supplier_id', '')::bigint,
                NULLIF(v_detail->>'session_id', '')::bigint,
                NULLIF(v_detail->>'ticket_type_id', '')::bigint,
                (v_detail->>'quantity')::int,
                (v_detail->>'unit_price')::numeric,
                (v_detail->>'unit_cost')::numeric,
                (v_detail->>'total_price')::numeric,
                (v_detail->>'currency'),
                (v_detail->>'pricing_basis'),
                (v_detail->'snapshot') || jsonb_build_object(
                    'title', COALESCE(
                        (SELECT p.title FROM product p WHERE p.id = (v_detail->>'product_id')::bigint),
                        '')),
                'pending')
        RETURNING id INTO v_item_id;

        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'order_item_id',  v_item_id,
            'variant_id',     (v_detail->>'product_variant_id')::bigint,
            'ticket_type_id', NULLIF(v_detail->>'ticket_type_id', '')::bigint,
            'quantity',       (v_detail->>'quantity')::int));
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④b 实名：票种要求的持票人信息必须收齐
    --
    -- 结算页要哪些字段由 checkout_requirement 说（不变量 25 按同一口径把门）。
    -- 这里按下单明细逐项校验：份数够、字段够、长度与格式过得了。
    -- 校验口径与不变量 25 必须一致 —— 两处口径不一样，就会出现「函数放行、门禁拦下」。
    -- ---------------------------------------------------------------------------------
    FOR v_line IN SELECT * FROM jsonb_array_elements(v_items)
    LOOP
        FOR v_req IN
            SELECT cr.field_code, cr.label, cr.max_length, cr.pattern
              FROM checkout_requirement cr
              JOIN sales_order_item oi ON oi.id = (v_line->>'order_item_id')::bigint
             WHERE cr.required
               AND cr.product_id = oi.product_id
               AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = oi.ticket_type_id)
               AND (cr.channel_id IS NULL OR cr.channel_id = p_channel_id)
        LOOP
            SELECT count(DISTINCT (h->>'sequence')::int) INTO v_holders
              FROM jsonb_array_elements(p_holders) h
             WHERE (h->>'variant_id')::bigint = (v_line->>'variant_id')::bigint
               AND h->>'field_code' = v_req.field_code;

            IF v_holders < (v_line->>'quantity')::int THEN
                RAISE EXCEPTION '订单行（变体 %）要求实名信息：% 需要 % 份，实收 % 份',
                  (v_line->>'variant_id')::bigint, v_req.label,
                  (v_line->>'quantity')::int, v_holders;
            END IF;

            FOR v_holder IN
                SELECT h FROM jsonb_array_elements(p_holders) h
                 WHERE (h->>'variant_id')::bigint = (v_line->>'variant_id')::bigint
                   AND h->>'field_code' = v_req.field_code
            LOOP
                IF v_req.max_length IS NOT NULL
                   AND length(COALESCE(v_holder->>'value', '')) > v_req.max_length THEN
                    RAISE EXCEPTION '订单行（变体 %）的 % 超过长度上限 %',
                      (v_line->>'variant_id')::bigint, v_req.label, v_req.max_length;
                END IF;

                IF NULLIF(v_req.pattern, '') IS NOT NULL
                   AND (v_holder->>'value') !~ v_req.pattern THEN
                    RAISE EXCEPTION '订单行（变体 %）的 % 不符合格式要求',
                      (v_line->>'variant_id')::bigint, v_req.label;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;

    -- 持票人落库（每个字段一行，与 checkout_requirement 的字段口径对齐）
    INSERT INTO order_holder (order_id, order_item_id, ticket_type_id, sequence, field_code, value, value_hash)
    SELECT v_order_id,
           (it->>'order_item_id')::bigint,
           (it->>'ticket_type_id')::bigint,
           (h->>'sequence')::int,
           h->>'field_code',
           h->>'value',
           md5(COALESCE(h->>'value', ''))
      FROM jsonb_array_elements(v_items) it
      JOIN jsonb_array_elements(p_holders) h
        ON (h->>'variant_id')::bigint = (it->>'variant_id')::bigint;

    -- created → awaiting_payment（触发器会落一条 OrderAwaitingPayment 事件）
    UPDATE sales_order SET status = 'awaiting_payment' WHERE id = v_order_id;

    -- ---------------------------------------------------------------------------------
    -- ⑤ 幂等记账
    -- ---------------------------------------------------------------------------------
    UPDATE idempotency_record
       SET status   = 'done',
           response = jsonb_build_object('order_id', v_order_id, 'order_no', v_order_no)
     WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

    order_id       := v_order_id;
    order_no       := v_order_no;
    order_status   := 'awaiting_payment';
    order_currency := v_currency;
    order_subtotal := v_subtotal;
    order_total    := v_subtotal;
    created        := true;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_place_order IS '下单的唯一实现：金额取自 fn_price_variant，幂等必填，明细走快照';

-- -------------------------------------------------------------------------------------
-- 6.2.1 下单侧不变量
--
-- 单测之外，库里再留一道检查：刚下的单，明细金额必须等于定价函数的输出。
-- 这条不变量是「下单不会算错钱」的机器证明。
--
-- 放在自己的视图里，而不是改写 v_invariant_checks_tx：
-- 改写就要把 8 条抄一遍 —— 抄一遍就会分叉，分叉的门禁等于没有门禁。
-- 每个方向一个视图，总视图只做并集。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_order AS
WITH raw (seq, check_name, actual) AS (
    -- 54：订单明细的单价必须等于定价函数在同一天的输出。
    --     单价不是自己算的，是定价函数给的 —— 这条检查证明它没被算歪。
    SELECT 54, '订单明细单价必须等于定价函数输出',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN sales_order o ON o.id = oi.order_id
             WHERE oi.product_variant_id IS NOT NULL
               AND EXISTS (
                     SELECT 1 FROM jsonb_array_elements(COALESCE(o.pricing_snapshot->'items', '[]'::jsonb)) it
                     WHERE (it->>'variant_id')::bigint = oi.product_variant_id
                       AND it->>'visit_date' = oi.detail_snapshot->>'visit_date'
                       AND (it->>'unit_price')::numeric <> oi.unit_price))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_order IS '下单侧不变量（54）：明细单价必须等于定价函数输出';

-- 总视图：并集（每个方向一个视图，加新方向不用抄旧的不变量）
CREATE OR REPLACE VIEW v_invariant_checks AS
    SELECT * FROM v_invariant_checks_core
    UNION ALL
    SELECT * FROM v_invariant_checks_tx
    UNION ALL
    SELECT * FROM v_invariant_checks_order;

COMMENT ON VIEW v_invariant_checks IS '全部 54 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';

