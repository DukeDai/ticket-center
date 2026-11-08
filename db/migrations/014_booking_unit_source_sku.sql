-- =====================================================================================
-- 014_booking_unit_source_sku.sql —— 预订单位 = 源 SKU（不是成分）
--
-- 013 让组合套餐能成交了，但预订的单位定错了：
-- **一个成分一条预订**。
--
-- 为什么这是错的：参数化源（自由行 / Zowoyoo 这种「一张通票，人群是购买时选的一档」）
-- 的一个源 SKU 会同时覆盖多个可售单元。家庭套餐「2 成人 + 1 儿童」在源侧是
-- **同一个源 SKU**（ZWO-1D-BASE，人群是参数），配方写的是：
--     成分 9（成人）×2  ← 源 SKU 21
--     成分 10（儿童）×1 ← 源 SKU 21
-- 按成分建预订 = **同一个源 SKU 在同一个源场次上被订了两次**：
--     源侧看到两张订单单（一次 2 张、一次 1 张）；
--     我们这边一条客户订单对两个源单号，对账时对不上；
--     退款要退两次，其中一次退不掉就是「钱退回来了但票还在」；
--     源侧只确认了其中一个成分时，整张套餐是半成品 —— 收了三个人的钱出了两张票。
--
-- 所以预订的单位必须是**源 SKU**：源卖的是 SKU，我们就按 SKU 订。
-- 成分的拆分留在预订的请求明细里（request_payload.components），
-- 出券时再按成分把票码和持票人分下去。
--
-- 代价说清楚：
--   - 成分可以来自不同的源商品（GlobalTix 的门票 + 快速通行证是两个源商品），
--     所以一条预订只覆盖**一个源 SKU**，一张套餐有几条预订 = 有几个源 SKU。
--   - 源侧把整套套餐当一个 SKU 卖的情况接不了（那是方向 A 的事，见 §20）。
--
-- 这一版还顺手修了一件事：
--   fn_available_qty 的池子归属（013 已改）之外，预订的幂等键从「成分行 id」
--   改成「明细 + 源 SKU」，所以重放建预订不会多建一条。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 预订覆盖的成分：一个函数的唯一读法
--
-- 一条预订 = 一个源 SKU 在一个源场次上的预留。
-- 它覆盖哪些成分，由 (明细, 源 SKU, 源场次) 推出来 —— 不另存一份，
-- 免得两份事实分叉（「一个事实只写一处」）。
--
-- 老明细（013 之前下的单）没有成分行，这时成分就是明细本身。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_booking_components(p_booking_id BIGINT)
RETURNS TABLE (
    component_variant_id BIGINT,
    ticket_type_id       BIGINT,
    quantity             NUMERIC,
    admission_quantity   NUMERIC,
    product_session_id   BIGINT,
    supplier_id          BIGINT,
    unit_cost            NUMERIC,
    currency             TEXT
)
LANGUAGE sql STABLE
AS $$
    WITH b AS (
        SELECT bo.order_item_id, bo.supplier_variant_id, bo.supplier_session_id
          FROM booking bo
         WHERE bo.id = p_booking_id
    )
    SELECT s.component_variant_id,
           s.ticket_type_id,
           s.quantity,
           s.admission_quantity,
           s.product_session_id,
           s.supplier_id,
           s.unit_cost,
           s.currency
      FROM b
      JOIN sales_order_item_source s
        ON s.order_item_id = b.order_item_id
       AND s.supplier_variant_id IS NOT DISTINCT FROM b.supplier_variant_id
       AND s.supplier_session_id IS NOT DISTINCT FROM b.supplier_session_id
    UNION ALL
    SELECT oi.product_variant_id,
           oi.ticket_type_id,
           oi.quantity::numeric,
           oi.quantity::numeric,
           oi.session_id,
           oi.supplier_id,
           oi.unit_cost,
           oi.currency
      FROM b
      JOIN sales_order_item oi ON oi.id = b.order_item_id
     WHERE NOT EXISTS (SELECT 1 FROM sales_order_item_source s2
                         WHERE s2.order_item_id = oi.id)
    ORDER BY 1;
$$;

COMMENT ON FUNCTION fn_booking_components(BIGINT) IS
    '一条预订覆盖的成分（履约单位）：按（明细, 源 SKU, 源场次）推出来；老明细没有成分行时成分就是明细本身';

-- -------------------------------------------------------------------------------------
-- ② 建预订：按源 SKU 建，不按成分建
--
-- 整体替换 fn_create_bookings（同签名，013 已替换过一次，这里是第二次）。
--
-- 与 013 的差别：
--   013：一个成分一条预订（同一个源 SKU 被订两次）。
--   014：一个源 SKU 一条预订（成分的拆分进请求明细）。
--
-- 幂等键从「成分行 id」改成「明细 + 源 SKU」：
-- 重放一次建预订不会多建一条，也不会把同一个源 SKU 订第二次。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_create_bookings(p_order_id BIGINT)
RETURNS TABLE (
    booking_id    BIGINT,
    booking_no    TEXT,
    order_item_id BIGINT,
    created       BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_order      RECORD;
    v_item       RECORD;
    v_grp        RECORD;
    v_booking    RECORD;
    v_booking_id BIGINT;
    v_booking_no TEXT;
    v_date       DATE;
    v_session    BIGINT;
    v_variant    BIGINT;
BEGIN
    SELECT o.id, o.order_no, o.status INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    IF v_order.status NOT IN ('paid', 'booking_pending') THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不能创建预订（只允许 paid / booking_pending）',
          v_order.order_no, v_order.status;
    END IF;

    FOR v_item IN
        SELECT oi.id, oi.product_id, oi.session_id, oi.ticket_type_id, oi.quantity,
               oi.product_variant_id, oi.supplier_product_id, oi.supplier_id,
               oi.detail_snapshot
          FROM sales_order_item oi
         WHERE oi.order_id = v_order.id
         ORDER BY oi.id
    LOOP
        -- 有成分行的明细：按源 SKU 分组建预订。
        --
        -- 分组键 = (源 SKU, 源商品, 源场次)：源卖的是 SKU，
        -- 同一个 SKU 在同一个源场次上只订一次（参数化源：成人与儿童是同一个 SKU）。
        FOR v_grp IN
            SELECT s.supplier_variant_id,
                   s.supplier_product_id,
                   s.supplier_id,
                   s.supplier_session_id,
                   s.product_session_id,
                   sum(s.admission_quantity)          AS total_admission,
                   jsonb_agg(jsonb_build_object(
                       'component_variant_id', s.component_variant_id,
                       'ticket_type_id',       s.ticket_type_id,
                       'quantity',            s.quantity,
                       'admission_quantity',  s.admission_quantity,
                       'unit_cost',           s.unit_cost,
                       'currency',            s.currency
                   ) ORDER BY s.component_variant_id, s.id) AS components
              FROM sales_order_item_source s
             WHERE s.order_item_id = v_item.id
             GROUP BY s.supplier_variant_id, s.supplier_product_id, s.supplier_id,
                      s.supplier_session_id, s.product_session_id
             ORDER BY min(s.id)
        LOOP
            -- 幂等：这张明细里同一个源 SKU 只有一条预订。
            SELECT b.id, b.booking_no INTO v_booking
              FROM booking b
             WHERE b.order_item_id = v_item.id
               AND b.supplier_variant_id IS NOT DISTINCT FROM v_grp.supplier_variant_id
               AND b.supplier_session_id IS NOT DISTINCT FROM v_grp.supplier_session_id
             ORDER BY b.id
             LIMIT 1;

            IF FOUND THEN
                -- 明细状态补齐：上一次建到一半崩了，这里把状态接上。
                UPDATE sales_order_item
                   SET status = 'booking'
                 WHERE id = v_item.id
                   AND status = 'pending';

                booking_id    := v_booking.id;
                booking_no    := v_booking.booking_no;
                order_item_id := v_item.id;
                created       := false;
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- 源场次没解析出来（老数据）：按绑定表再解析一次，取的还是绑定表那条。
            v_session := v_grp.supplier_session_id;
            IF v_session IS NULL THEN
                v_session := fn_bound_supplier_session(v_grp.product_session_id,
                                                       v_grp.supplier_product_id);
            END IF;

            IF v_session IS NULL THEN
                RAISE EXCEPTION '订单行 % 的源 SKU % 的规范场次 % 没有绑定源商品 % 的源场次，无法创建预订（product_session_source 缺一条绑定）',
                  v_item.id, v_grp.supplier_variant_id, v_grp.product_session_id, v_grp.supplier_product_id;
            END IF;

            v_booking_no := 'BK' || to_char(now(), 'YYYYMMDD')
                         || lpad(nextval('public.seq_booking_no')::text, 6, '0');

            v_date := NULLIF(v_item.detail_snapshot->>'visit_date', '')::date;

            INSERT INTO booking (booking_no, order_id, order_item_id,
                                 supplier_id, supplier_product_id, supplier_session_id,
                                 supplier_variant_id, status, idempotency_key, request_payload)
            VALUES (v_booking_no, v_order.id, v_item.id,
                    v_grp.supplier_id, v_grp.supplier_product_id, v_session,
                    v_grp.supplier_variant_id, 'pending',
                    'bk-' || v_order.order_no || '-' || v_item.id::text
                             || '-' || v_grp.supplier_variant_id::text,
                    jsonb_build_object('order_no', v_order.order_no,
                                       'order_item_id', v_item.id,
                                       'product_id', v_item.product_id,
                                       'supplier_variant_id', v_grp.supplier_variant_id,
                                       'quantity', v_grp.total_admission,
                                       'visit_date', v_date,
                                       'product_session_id', v_grp.product_session_id,
                                       'supplier_session_id', v_session,
                                       'components', v_grp.components,
                                       'snapshot', v_item.detail_snapshot))
            RETURNING id INTO v_booking_id;

            -- 明细状态推进：pending → booking（这一单已经在向源侧下单了）
            UPDATE sales_order_item
               SET status = 'booking'
             WHERE id = v_item.id
               AND status = 'pending';

            booking_id    := v_booking_id;
            booking_no    := v_booking_no;
            order_item_id := v_item.id;
            created       := true;
            RETURN NEXT;
        END LOOP;

        -- 老明细（013 之前下的单）没有成分行：一条明细一条预订（沿用 005 的口径）。
        IF NOT EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = v_item.id) THEN
            SELECT b.id, b.booking_no INTO v_booking
              FROM booking b
             WHERE b.order_id = v_order.id
               AND b.order_item_id = v_item.id
             ORDER BY b.id
             LIMIT 1;

            IF FOUND THEN
                UPDATE sales_order_item
                   SET status = 'booking'
                 WHERE id = v_item.id
                   AND status = 'pending';

                booking_id    := v_booking.id;
                booking_no    := v_booking.booking_no;
                order_item_id := v_item.id;
                created       := false;
                RETURN NEXT;
                CONTINUE;
            END IF;

            IF v_item.supplier_id IS NULL OR v_item.supplier_product_id IS NULL THEN
                RAISE EXCEPTION '订单行 % 没有采纳源，无法创建预订（下单时必须选中源）', v_item.id;
            END IF;

            IF v_item.session_id IS NULL THEN
                RAISE EXCEPTION '订单行 % 没有场次，无法创建预订', v_item.id;
            END IF;

            -- 源场次：走场次级绑定表，不按日期猜（硬约束 19）。
            v_session := fn_bound_supplier_session(v_item.session_id, v_item.supplier_product_id);

            IF v_session IS NULL THEN
                RAISE EXCEPTION '订单行 % 的规范场次 % 没有绑定源商品 % 的源场次，无法创建预订（product_session_source 缺一条绑定）',
                  v_item.id, v_item.session_id, v_item.supplier_product_id;
            END IF;

            -- 源变体：按覆盖映射找能履约这个变体的源变体（同一源商品内取置信度最高的）。
            SELECT svm.supplier_variant_id INTO v_variant
              FROM supplier_variant_mapping svm
              JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
             WHERE svm.product_variant_id = v_item.product_variant_id
               AND sv.supplier_product_id = v_item.supplier_product_id
             ORDER BY svm.confidence DESC, svm.id
             LIMIT 1;

            v_booking_no := 'BK' || to_char(now(), 'YYYYMMDD')
                         || lpad(nextval('public.seq_booking_no')::text, 6, '0');

            v_date := NULLIF(v_item.detail_snapshot->>'visit_date', '')::date;

            INSERT INTO booking (booking_no, order_id, order_item_id, supplier_id, supplier_product_id,
                                 supplier_session_id, supplier_variant_id, status, idempotency_key,
                                 request_payload)
            VALUES (v_booking_no, v_order.id, v_item.id, v_item.supplier_id, v_item.supplier_product_id,
                    v_session, v_variant, 'pending',
                    'bk-' || v_order.order_no || '-' || v_item.id::text,
                    jsonb_build_object('order_no', v_order.order_no,
                                       'order_item_id', v_item.id,
                                       'product_id', v_item.product_id,
                                       'quantity', v_item.quantity,
                                       'visit_date', v_date,
                                       'product_session_id', v_item.session_id,
                                       'supplier_session_id', v_session,
                                       'supplier_variant_id', v_variant,
                                       'snapshot', v_item.detail_snapshot))
            RETURNING id INTO v_booking_id;

            UPDATE sales_order_item
               SET status = 'booking'
             WHERE id = v_item.id
               AND status = 'pending';

            booking_id    := v_booking_id;
            booking_no    := v_booking_no;
            order_item_id := v_item.id;
            created       := true;
            RETURN NEXT;
        END IF;
    END LOOP;

    -- 全部明细都有预订了，订单推进到 booking_pending（触发器落 OrderBookingPending）
    UPDATE sales_order
       SET status = 'booking_pending'
     WHERE id = v_order.id
       AND status = 'paid'
       AND NOT EXISTS (
             SELECT 1 FROM sales_order_item oi
              WHERE oi.order_id = v_order.id
                AND NOT EXISTS (SELECT 1 FROM booking b
                                 WHERE b.order_id = v_order.id AND b.order_item_id = oi.id));

    RETURN;
END;
$$;

COMMENT ON FUNCTION fn_create_bookings(BIGINT) IS
    '预订的唯一实现：一个源 SKU 一条预订（成分的拆分进请求明细），幂等键按「明细 + 源 SKU」定，源场次来自成分行';

-- -------------------------------------------------------------------------------------
-- ③ 出券：一条预订可能覆盖好几个成分
--
-- 整体替换 fn_issue_voucher（同签名，013 已替换过一次，这里是第二次）。
--
-- 与 013 的差别：
--   013：一条预订 = 一个成分 → 应发张数取那一个成分的入场份数。
--   014：一条预订 = 一个源 SKU → 可能覆盖多个成分（参数化源：成人 + 儿童），
--        应发张数 = 各成分入场份数之和，票码与持票人按成分分下去。
--
-- 持票人按**成分变体**归位（不是票种）：
--   两个成分可能共用一个票种（成人门票 + 成人快速通行证都是成人票），
--   按票种分会分错人。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_issue_voucher(
    p_booking_id  BIGINT,
    p_codes       TEXT[] DEFAULT NULL,
    p_raw_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    voucher_id      BIGINT,
    voucher_no      TEXT,
    code            TEXT,
    holder_sequence INT,
    created         BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_booking    RECORD;
    v_item       RECORD;
    v_comp       RECORD;
    v_session    RECORD;
    v_existing   RECORD;
    v_expected   INT;
    v_have       INT;
    v_need       INT;
    v_voucher_no TEXT;
    v_code       TEXT;
    v_holders    JSONB;
    v_i          INT;
    v_days       INT;
    v_required   NUMERIC;
    v_comp_have  INT;
    v_comp_need  INT;
    v_code_pos   INT := 0;
BEGIN
    SELECT b.id, b.booking_no, b.order_id, b.order_item_id, b.status, b.supplier_variant_id
      INTO v_booking
      FROM booking b
     WHERE b.id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 不存在', p_booking_id;
    END IF;

    IF v_booking.status NOT IN ('confirmed', 'ticketed') THEN
        RAISE EXCEPTION '预订 % 当前状态 % 不能出券（只允许 confirmed / ticketed）',
          v_booking.booking_no, v_booking.status;
    END IF;

    SELECT oi.id, oi.product_id, oi.supplier_id, oi.ticket_type_id, oi.session_id, oi.quantity,
           oi.product_variant_id, COALESCE(oi.pricing_basis, 'per_person') AS pricing_basis
      INTO v_item
      FROM sales_order_item oi
     WHERE oi.id = v_booking.order_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 没有对应的订单明细', v_booking.booking_no;
    END IF;

    -- 应发张数：这条预订覆盖的成分的入场份数之和（按团一券，按人一人一份）。
    SELECT COALESCE(sum(CASE WHEN v_item.pricing_basis = 'per_group'
                              THEN 1 ELSE c.admission_quantity END), 0)::int
      INTO v_expected
      FROM fn_booking_components(p_booking_id) c;

    SELECT count(*) INTO v_have
      FROM voucher v
     WHERE v.booking_id = v_booking.id;

    -- 已经发够了就返回原来那些（幂等）。
    IF v_have >= v_expected THEN
        FOR v_existing IN
            SELECT v.id, v.voucher_no, v.code,
                   COALESCE((v.holder_snapshot->>'sequence')::int, 0) AS holder_sequence
              FROM voucher v
             WHERE v.booking_id = v_booking.id
             ORDER BY v.id
        LOOP
            voucher_id      := v_existing.id;
            voucher_no      := v_existing.voucher_no;
            code            := v_existing.code;
            holder_sequence := v_existing.holder_sequence;
            created         := false;
            RETURN NEXT;
        END LOOP;
        RETURN;
    END IF;

    v_need := v_expected - v_have;

    -- 票码必须与要发的张数一一对应。
    IF p_codes IS NOT NULL AND array_length(p_codes, 1) IS NOT NULL THEN
        IF array_length(p_codes, 1) <> v_need THEN
            RAISE EXCEPTION '预订 % 还要发 % 张券，收到 % 个票码（票码必须与持票人一一对应）',
              v_booking.booking_no, v_need, array_length(p_codes, 1);
        END IF;
    END IF;

    -- 有效期天数：这个可售单元有效几天（010 的口径，不写死 1）。
    --
    -- 一条预订可能覆盖几个成分，它们的有效天数可能不一样
    -- （门票两日、快速通行证一日）。哪个说了算取决于源侧怎么兑现 ——
    -- 这里按**成分**各自的天数算，各发各的。
    FOR v_comp IN SELECT * FROM fn_booking_components(p_booking_id) LOOP
        v_comp_need := CASE WHEN v_item.pricing_basis = 'per_group'
                            THEN 1 ELSE v_comp.admission_quantity::int END;

        -- 这个成分已经发了几张（幂等：重放不重发）。
        SELECT count(*) INTO v_comp_have
          FROM voucher v
         WHERE v.booking_id = v_booking.id
           AND v.product_variant_id IS NOT DISTINCT FROM v_comp.component_variant_id;

        IF v_comp_have >= v_comp_need THEN
            FOR v_existing IN
                SELECT v.id, v.voucher_no, v.code,
                       COALESCE((v.holder_snapshot->>'sequence')::int, 0) AS holder_sequence
                  FROM voucher v
                 WHERE v.booking_id = v_booking.id
                   AND v.product_variant_id IS NOT DISTINCT FROM v_comp.component_variant_id
                 ORDER BY v.id
            LOOP
                voucher_id      := v_existing.id;
                voucher_no      := v_existing.voucher_no;
                code            := v_existing.code;
                holder_sequence := v_existing.holder_sequence;
                created         := false;
                RETURN NEXT;
            END LOOP;
            CONTINUE;
        END IF;

        SELECT ps.session_date INTO v_session
          FROM product_session ps
         WHERE ps.id = v_comp.product_session_id;

        v_days := fn_variant_validity_days(v_comp.component_variant_id);

        FOR v_i IN v_comp_have + 1 .. v_comp_need
        LOOP
            -- 持票人快照：按**成分**取那一位持票人的字段。
            --
            -- 按成分归位而不是按票种：成人门票与成人快速通行证是同一个票种，
            -- 按票种分会把这个人的两份实名混在一起。
            SELECT COALESCE(jsonb_object_agg(h.field_code, h.value), '{}'::jsonb)
              INTO v_holders
              FROM order_holder h
             WHERE h.order_item_id = v_item.id
               AND h.sequence = v_i
               AND (h.component_variant_id = v_comp.component_variant_id
                    OR (h.component_variant_id IS NULL
                        AND h.ticket_type_id IS NOT DISTINCT FROM v_comp.ticket_type_id));

            v_holders := v_holders || jsonb_build_object('sequence', v_i);

            v_voucher_no := 'VC' || to_char(now(), 'YYYYMMDD')
                         || lpad(nextval('public.seq_voucher_no')::text, 6, '0');

            v_code_pos := v_code_pos + 1;
            v_code := COALESCE(p_codes[v_code_pos], v_voucher_no);

            INSERT INTO voucher (voucher_no, order_id, order_item_id, booking_id, product_id, supplier_id,
                                 ticket_type_id, session_id, product_variant_id, supplier_variant_id,
                                 code, qr_payload, status, holder_snapshot, raw_payload)
            VALUES (v_voucher_no, v_booking.order_id, v_item.id, v_booking.id, v_item.product_id,
                    v_comp.supplier_id, v_comp.ticket_type_id, v_comp.product_session_id,
                    v_comp.component_variant_id, v_booking.supplier_variant_id,
                    v_code, v_code, 'pending', v_holders, p_raw_payload)
            RETURNING id INTO v_existing;

            -- 权益：按团一券含全部份数，按人一人一份
            INSERT INTO voucher_entitlement (voucher_id, entitlement_type, quantity, meta)
            VALUES (v_existing.id, 'admission',
                    CASE WHEN v_item.pricing_basis = 'per_group' THEN v_comp.admission_quantity ELSE 1 END,
                    jsonb_build_object('order_item_id', v_item.id,
                                       'booking_id', v_booking.id,
                                       'quantity', v_comp.quantity,
                                       'admission_quantity', v_comp.admission_quantity,
                                       'pricing_basis', v_item.pricing_basis,
                                       'component_variant_id', v_comp.component_variant_id));

            -- pending → issued（触发器落 VoucherIssued 事件）
            UPDATE voucher
               SET status     = 'issued',
                   issued_at  = now(),
                   valid_from = COALESCE(v_session.session_date, now())::timestamptz,
                   valid_to   = COALESCE((v_session.session_date + v_days)::timestamptz,
                                         now() + make_interval(days => v_days))
             WHERE id = v_existing.id;

            voucher_id      := v_existing.id;
            voucher_no      := v_voucher_no;
            code            := v_code;
            holder_sequence := v_i;
            created         := true;
            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- 明细状态：份数发齐了就是 ticketed（pending / booking / confirmed → ticketed 都是合法边）
    --
    -- 应发份数 = 成分入场份数之和（组合 2+1=3；普通明细 = 明细份数）。
    SELECT COALESCE(sum(s.admission_quantity), v_item.quantity) INTO v_required
      FROM sales_order_item_source s
     WHERE s.order_item_id = v_item.id;

    UPDATE sales_order_item oi
       SET status = 'ticketed'
     WHERE oi.id = v_item.id
       AND oi.status IN ('pending', 'booking', 'confirmed')
       AND COALESCE((
             SELECT sum(ve.quantity)
               FROM voucher_entitlement ve
               JOIN voucher v ON v.id = ve.voucher_id
              WHERE v.order_item_id = oi.id
                AND v.status IN ('issued', 'used')
                AND ve.entitlement_type = 'admission'), 0) >= v_required;

    -- 订单履约状态交给唯一实现推导
    PERFORM fn_apply_order_fulfillment(v_booking.order_id);
END;
$$;

COMMENT ON FUNCTION fn_issue_voucher(BIGINT, TEXT[], JSONB) IS
    '出券的唯一实现：一条预订覆盖的成分逐个发（各发各的张数、各按各的持票人与有效期），票码与持票人一一对应';

-- -------------------------------------------------------------------------------------
-- ④ 视图：成分对账（预订改成按源 SKU 建之后的对账口径）
-- -------------------------------------------------------------------------------------
DROP VIEW v_order_item_source;

CREATE VIEW v_order_item_source AS
SELECT oi.id                AS order_item_id,
       o.order_no,
       o.status             AS order_status,
       oi.product_id,
       oi.product_variant_id,
       pv.variant_key,
       pv.variant_role,
       s.component_variant_id,
       cv.variant_key      AS component_variant_key,
       s.supplier_variant_id,
       sv.external_variant_id,
       s.supplier_product_id,
       sup.code            AS supplier_code,
       s.quantity,
       s.admission_quantity,
       s.unit_cost,
       s.currency,
       s.fx_rate,
       s.fx_as_of,
       s.product_session_id,
       s.supplier_session_id,
       b.id                AS booking_id,
       b.booking_no,
       b.status            AS booking_status,
       (SELECT count(*) FROM voucher v
         WHERE v.booking_id = b.id
           AND v.product_variant_id IS NOT DISTINCT FROM s.component_variant_id
           AND v.status IN ('issued', 'used')) AS issued_vouchers
  FROM sales_order_item_source s
  JOIN sales_order_item oi ON oi.id = s.order_item_id
  JOIN sales_order o       ON o.id = oi.order_id
  JOIN product_variant pv  ON pv.id = oi.product_variant_id
  JOIN product_variant cv  ON cv.id = s.component_variant_id
  JOIN supplier_variant sv ON sv.id = s.supplier_variant_id
  JOIN supplier_product sp ON sp.id = s.supplier_product_id
  JOIN supplier sup        ON sup.id = s.supplier_id
  LEFT JOIN booking b      ON b.order_item_id = s.order_item_id
                           AND b.supplier_variant_id IS NOT DISTINCT FROM s.supplier_variant_id
                           AND b.supplier_session_id IS NOT DISTINCT FROM s.supplier_session_id;

COMMENT ON VIEW v_order_item_source IS
    '订单成分对账：每一份成分用哪个源 SKU、要几份、订了没有、发了几张券（组合逐行可查；一条预订可覆盖多个成分）';

-- -------------------------------------------------------------------------------------
-- ⑤ 不变量：不变量 58（预订的源）、75（源覆盖得住）、新增 87 / 88
--
-- 与 012 / 013 同一个套路：不把整份不变量抄一遍改一条（抄一遍就分叉，
-- 分叉的门禁等于没有门禁），而是「改名 + 重建」：
--   旧视图改名保留 → 新视图 = 旧的（去掉被修订的那条）+ 修订后的那一条。
--
-- 先把总视图拆掉：它挂在下面那些视图上，拆之前改不动被引用的列。
-- -------------------------------------------------------------------------------------
DROP VIEW v_invariant_checks;

-- ---- ⑤之一 不变量 58 / 60（预订的源按成分行算）-------------------------------------
ALTER VIEW v_invariant_checks_fulfill RENAME TO v_invariant_checks_fulfill_013;

COMMENT ON VIEW v_invariant_checks_fulfill_013 IS
    '履约侧不变量自检（013 修订了第 58 / 60 条；014 按「预订 = 源 SKU」重写第 58 条）';

CREATE VIEW v_invariant_checks_fulfill AS
WITH item_state AS (
    -- 每条明细的「应发 / 已发」：应发按成分入场份数之和（组合 2+1，普通 = 明细份数）
    SELECT oi.order_id,
           oi.id AS item_id,
           COALESCE((SELECT sum(s.admission_quantity)
                       FROM sales_order_item_source s
                      WHERE s.order_item_id = oi.id), oi.quantity) AS quantity,
           COALESCE((SELECT sum(ve.quantity)
                       FROM voucher_entitlement ve
                       JOIN voucher v ON v.id = ve.voucher_id
                      WHERE v.order_item_id = oi.id
                        AND v.status IN ('issued', 'used')
                        AND ve.entitlement_type = 'admission'), 0) AS delivered
      FROM sales_order_item oi
),
raw (seq, check_name, expected, actual) AS (
    SELECT b.seq, b.check_name, b.expected, b.actual
      FROM v_invariant_checks_fulfill_base b
     WHERE b.seq NOT IN (58, 60)
    UNION ALL
    -- 58：预订的源 = 它覆盖的那些成分的源
    --
    -- 014 之后一条预订覆盖的是**同一个源 SKU** 的若干成分，
    -- 所以判定改成「预订的源字段与它覆盖的成分逐项对得上」。
    SELECT 58,
           '预订的源必须等于它覆盖的那些成分的源',
           0,
           (SELECT count(*)
              FROM booking b
              JOIN sales_order_item oi ON oi.id = b.order_item_id
             WHERE (EXISTS (SELECT 1 FROM sales_order_item_source s
                             WHERE s.order_item_id = oi.id)
                    AND EXISTS (SELECT 1 FROM sales_order_item_source s
                                 WHERE s.order_item_id = oi.id
                                   AND s.supplier_variant_id IS NOT DISTINCT FROM b.supplier_variant_id
                                   AND s.supplier_session_id IS NOT DISTINCT FROM b.supplier_session_id
                                   AND (s.supplier_id IS DISTINCT FROM b.supplier_id
                                        OR s.supplier_product_id IS DISTINCT FROM b.supplier_product_id)))
                OR (NOT EXISTS (SELECT 1 FROM sales_order_item_source s
                                 WHERE s.order_item_id = oi.id)
                    AND (b.supplier_id IS DISTINCT FROM oi.supplier_id
                         OR b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id)))
    UNION ALL
    -- 60：订单的履约状态必须与明细的出票情况一致（应发份数按成分算）
    SELECT 60,
           '订单的履约状态必须与明细的出票情况一致',
           0,
           (SELECT count(*)
              FROM sales_order o
             WHERE o.status = 'fulfilled'
               AND EXISTS (SELECT 1 FROM item_state s
                            WHERE s.order_id = o.id AND s.delivered < s.quantity)
                OR o.status = 'partially_fulfilled'
               AND COALESCE((SELECT sum(s.delivered) FROM item_state s
                              WHERE s.order_id = o.id), 0::numeric) = 0::numeric
                OR o.status IN ('booking_pending', 'confirmed', 'partially_fulfilled')
               AND EXISTS (SELECT 1 FROM item_state s WHERE s.order_id = o.id)
               AND NOT EXISTS (SELECT 1 FROM item_state s
                                WHERE s.order_id = o.id AND s.delivered < s.quantity))
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_fulfill IS
    '履约侧不变量自检（第 58 / 60 条按 014 修订：预订按源 SKU 建，源与它覆盖的成分对得上）';

-- ---- ⑤之二 不变量 75（源要覆盖得住它服务的那份成分）-------------------------------
ALTER VIEW v_invariant_checks_validity RENAME TO v_invariant_checks_validity_013;

COMMENT ON VIEW v_invariant_checks_validity_013 IS
    '有效期与覆盖侧不变量自检（013 修订了第 75 条；014 按「预订 = 源 SKU」重写）';

CREATE VIEW v_invariant_checks_validity AS
WITH raw (seq, check_name, expected, actual) AS (
    SELECT b.seq, b.check_name, b.expected, b.actual
      FROM v_invariant_checks_validity_base b
     WHERE b.seq <> 75
    UNION ALL
    -- 75：卖出去的订单必须是用能装配出该可售单元的源出的
    --     组合没有单一映射：预订的源要覆盖它服务的那一份成分。
    SELECT 75,
           '卖出去的订单必须是用能装配出该可售单元的源出的（组合按成分）',
           0,
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN booking b ON b.order_item_id = oi.id
             WHERE b.supplier_variant_id IS NOT NULL
               AND NOT (
                 EXISTS (SELECT 1 FROM supplier_variant_mapping svm
                          WHERE svm.supplier_variant_id = b.supplier_variant_id
                            AND svm.product_variant_id = oi.product_variant_id
                            AND svm.status = 'active'
                            AND fn_variant_covered(svm.coverage, oi.product_variant_id))
                 OR EXISTS (SELECT 1 FROM sales_order_item_source s
                             JOIN supplier_variant_mapping svm
                               ON svm.supplier_variant_id = b.supplier_variant_id
                              AND svm.product_variant_id = s.component_variant_id
                              AND svm.status = 'active'
                            WHERE s.order_item_id = oi.id
                              AND s.supplier_variant_id IS NOT DISTINCT FROM b.supplier_variant_id
                              AND s.supplier_session_id IS NOT DISTINCT FROM b.supplier_session_id
                              AND fn_variant_covered(svm.coverage, s.component_variant_id))
               ))
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_validity IS
    '有效期与覆盖侧不变量自检（第 75 条按 014 修订：预订按源 SKU 建，源要覆盖得住它服务的成分）';

-- ---- ⑤之三 不变量 87 / 88（预订与成分双向对齐）-------------------------------------
ALTER VIEW v_invariant_checks_combo RENAME TO v_invariant_checks_combo_base;

COMMENT ON VIEW v_invariant_checks_combo_base IS
    '组合交易侧不变量（82-86，013 的口径；014 在此基础上加了 87 / 88）';

CREATE VIEW v_invariant_checks_combo AS
WITH raw (seq, check_name, actual) AS (
    SELECT b.seq, b.check_name, b.actual
      FROM v_invariant_checks_combo_base b
     WHERE b.seq NOT IN (87, 88)
    UNION ALL
    -- 87：同一张明细里同一个源 SKU 只能有一条预订
    --
    -- 这是 014 的核心门禁：参数化源下成人票与儿童票是同一个源 SKU，
    -- 按成分建预订就会把同一个源 SKU 订两次 ——
    -- 源侧看到两张订单单，我们这边一条客户订单对两个源单号。
    SELECT 87, '同一订单明细里同一个源 SKU 只能有一条预订',
           (SELECT count(*)
              FROM (
                SELECT b.order_item_id, b.supplier_variant_id, b.supplier_session_id
                  FROM booking b
                 WHERE b.supplier_variant_id IS NOT NULL
                 GROUP BY 1, 2, 3
                HAVING count(*) > 1
               ) x)
    UNION ALL
    -- 88：预订与成分双向对齐
    --     每个成分都要有预订覆盖；每条预订都要覆盖它那张明细的成分。
    --     漏订 = 套餐少一份（收三个人的钱出两张票）；悬空预订 = 订了没人要的东西。
    --
    -- 第一半写成「存在一个没被预订覆盖的成分」，不是「不存在一个被覆盖的成分」。
    -- 这两句话差一个字，意思完全相反：后者说的是「一个成分都没被覆盖」，
    -- 那这张明细只要有一个成分被覆盖就放过 ——
    -- 家庭套餐订了成人没订儿童，照样绿灯。这就是这版要修的洞。
    SELECT 88, '订单进入预订阶段后，预订与成分必须双向对齐',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN sales_order o ON o.id = oi.order_id
             WHERE o.status IN ('booking_pending', 'confirmed', 'partially_fulfilled', 'fulfilled')
               AND EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND EXISTS (SELECT 1 FROM sales_order_item_source s
                            WHERE s.order_item_id = oi.id
                              AND NOT EXISTS (SELECT 1 FROM booking b
                                               WHERE b.order_item_id = oi.id
                                                 AND b.supplier_variant_id IS NOT DISTINCT FROM s.supplier_variant_id
                                                 AND b.supplier_session_id IS NOT DISTINCT FROM s.supplier_session_id)))
           + (SELECT count(*)
                FROM booking b
                JOIN sales_order_item oi ON oi.id = b.order_item_id
               WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
                 AND NOT EXISTS (SELECT 1 FROM sales_order_item_source s
                                  WHERE s.order_item_id = oi.id
                                    AND s.supplier_variant_id IS NOT DISTINCT FROM b.supplier_variant_id
                                    AND s.supplier_session_id IS NOT DISTINCT FROM b.supplier_session_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_combo IS
    '组合交易侧不变量（82-88）：成分不串商品、成本对得上、份数与配方对得上、同源、出票发够了、同一源 SKU 只订一次、预订与成分双向对齐';

-- 013 留下的两个「中间态」视图引用了要拆掉的那一列，
-- 拆列之前先扔掉它们（新视图已经从前一版基线重建，不依赖它们）。
DROP VIEW v_invariant_checks_fulfill_013;
DROP VIEW v_invariant_checks_validity_013;

-- -------------------------------------------------------------------------------------
-- ⑥ 拆掉 booking.order_item_source_id
--
-- 013 用这一列记「这条预订服务的是哪个成分」。014 之后一条预订可以覆盖好几个成分
-- （参数化源：成人 + 儿童是同一个源 SKU），这一列装不下 ——
-- 装得下就会误导（以为一条预订只服务一个成分）。
--
-- 改由 fn_booking_components 按（明细, 源 SKU, 源场次）推出来，
-- 推导是唯一的（一个成分只属于一个源 SKU 分组），不会分叉。
-- -------------------------------------------------------------------------------------
ALTER TABLE booking DROP COLUMN order_item_source_id;

COMMENT ON COLUMN booking.supplier_variant_id IS
    '这条预订订的是哪个源 SKU；一条预订 = 一个源 SKU 在一个源场次上的预留，它覆盖的成分由 fn_booking_components 推出来';

-- 机制保证：同一张明细里同一个源 SKU 不许有两条预订。
--
-- 先查一遍：存量库里如果有旧形状的数据（013 按成分建的预订），
-- 这里当场报错说清楚，而不是让索引创建失败报一句看不懂的话。
DO $$
DECLARE
    v_conflicts INT;
BEGIN
    SELECT count(*) INTO v_conflicts
      FROM (SELECT order_item_id, supplier_variant_id, supplier_session_id
              FROM booking
             WHERE supplier_variant_id IS NOT NULL
             GROUP BY 1, 2, 3
            HAVING count(*) > 1) x;

    IF v_conflicts > 0 THEN
        RAISE EXCEPTION
            '这个库里已有 % 组「同一订单明细的同一个源 SKU 被订了多次」的预订（013 按成分建预订留下的形状）。请重建库（make db），或先人工退掉重复预订', v_conflicts;
    END IF;
END $$;

CREATE UNIQUE INDEX ux_booking_one_per_source_sku
    ON booking (order_item_id, supplier_variant_id, COALESCE(supplier_session_id, 0))
    WHERE supplier_variant_id IS NOT NULL;

COMMENT ON INDEX ux_booking_one_per_source_sku IS
    '同一张订单明细里同一个源 SKU 只能有一条预订（参数化源不许把同一个源 SKU 订两次）';

-- -------------------------------------------------------------------------------------
-- ⑦ 总视图：并集
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks AS
    SELECT * FROM v_invariant_checks_core
    UNION ALL
    SELECT * FROM v_invariant_checks_tx
    UNION ALL
    SELECT * FROM v_invariant_checks_order
    UNION ALL
    SELECT * FROM v_invariant_checks_fulfill
    UNION ALL
    SELECT * FROM v_invariant_checks_refund
    UNION ALL
    SELECT * FROM v_invariant_checks_redemption
    UNION ALL
    SELECT * FROM v_invariant_checks_inventory
    UNION ALL
    SELECT * FROM v_invariant_checks_validity
    UNION ALL
    SELECT * FROM v_invariant_checks_readmodel
    UNION ALL
    SELECT * FROM v_invariant_checks_composition
    UNION ALL
    SELECT * FROM v_invariant_checks_combo;

COMMENT ON VIEW v_invariant_checks IS '全部 88 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
