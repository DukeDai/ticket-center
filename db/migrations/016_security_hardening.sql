-- =====================================================================================
-- 016 — 收紧三处「失败时放行」的口径
--
-- 安全复核指出三处 fail-open，都是真问题：
--
--   1. fn_complete_refund 不检查退款单有没有放行过。一笔 requested 的退款
--      可以被直接结掉，放行这一步形同虚设 —— 钱能退，审批绕得过去。
--   2. fn_issue_voucher 在源侧没给票码时，拿券号（VC + 日期 + 序列）当票码。
--      券号是连号的，猜得到；票码是闸机认的东西，不能猜。
--   3. fn_approve_refund 收了 p_approved_by 却没存 —— 谁放行的查不到，
--      出了事没法追。
--
-- 三处都在已发布的迁移里（007 / 014），改它们等于内容漂移，
-- 迁移引擎会拒绝 —— 所以在这里整体替换一次（与 010 / 013 / 014 同一个套路）。
--
-- 顺带说明一条「故意不修」的：fn_reserve_qty 在源侧库存未知时放行
-- （known = false 时不拦）。那是业务决策，不是漏洞：源侧挂了还硬拦，
-- 整个商品就下架了，比超卖更贵。真实的兜底是「不知道的时候把当时的
-- 可售数写进明细快照」，事后对账能追出来。见 AGENTS.md 硬约束 22。
-- =====================================================================================

-- ① 放行人要留下来
ALTER TABLE sales_refund ADD COLUMN approved_by TEXT;
COMMENT ON COLUMN sales_refund.approved_by IS '放行人（工号或邮箱）；放行是退款里的一步，这里留痕';

-- ② 放行：把放行人存下来
CREATE OR REPLACE FUNCTION fn_approve_refund(
    p_refund_id    BIGINT,
    p_approved_by  TEXT DEFAULT NULL
)
RETURNS TABLE (
    refund_id     BIGINT,
    refund_no     TEXT,
    refund_status TEXT,
    order_status  TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_refund_id    BIGINT;
    v_refund_no    TEXT;
    v_refund_state TEXT;
    v_order_state  TEXT;
BEGIN
    SELECT r.id, r.refund_no, r.status, o.status
      INTO v_refund_id, v_refund_no, v_refund_state, v_order_state
      FROM sales_refund r
      JOIN sales_order o ON o.id = r.order_id
     WHERE r.id = p_refund_id
     FOR UPDATE OF r;

    IF NOT FOUND THEN
        RAISE EXCEPTION '退款单 % 不存在', p_refund_id;
    END IF;

    -- 已经放行过：幂等命中，返回原状态。
    IF v_refund_state = 'approved' THEN
        refund_id     := v_refund_id;
        refund_no     := v_refund_no;
        refund_status := v_refund_state;
        order_status  := v_order_state;
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_refund_state <> 'requested' THEN
        RAISE EXCEPTION '退款单 % 当前状态 % 不能放行（只允许 requested）',
          v_refund_no, v_refund_state;
    END IF;

    UPDATE sales_refund
       SET status      = 'approved',
           approved_at = now(),
           approved_by = p_approved_by
     WHERE id = p_refund_id;

    refund_id     := v_refund_id;
    refund_no     := v_refund_no;
    refund_status := 'approved';
    order_status  := v_order_state;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_approve_refund IS
    '放行一笔退款（requested → approved）；放行人留痕；订单状态不动，钱还没回来';

-- ③ 完成：没放行不许完成
CREATE OR REPLACE FUNCTION fn_complete_refund(
    p_refund_id          BIGINT,
    p_success            BOOLEAN,
    p_supplier_refund_id TEXT DEFAULT NULL,
    p_error_code         TEXT DEFAULT NULL,
    p_error_message      TEXT DEFAULT NULL,
    p_raw_payload        JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    refund_id                BIGINT,
    refund_no                TEXT,
    refund_status            TEXT,
    order_no                 TEXT,
    order_status             TEXT,
    order_payment_status     TEXT,
    order_fulfillment_status TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_refund     RECORD;
    v_order      RECORD;
    v_restored   BOOLEAN := false;
BEGIN
    SELECT r.id, r.refund_no, r.status, r.order_id, r.amount, r.currency,
           r.previous_order_status
      INTO v_refund
      FROM sales_refund r
     WHERE r.id = p_refund_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '退款单 % 不存在', p_refund_id;
    END IF;

    -- 已经退成功了：幂等命中，返回原状态，不重复退一次。
    IF v_refund.status = 'succeeded' THEN
        SELECT o.order_no, o.status, o.payment_status, o.fulfillment_status
          INTO v_order FROM sales_order o WHERE o.id = v_refund.order_id;

        refund_id                := v_refund.id;
        refund_no                := v_refund.refund_no;
        refund_status            := v_refund.status;
        order_no                 := v_order.order_no;
        order_status             := v_order.status;
        order_payment_status     := v_order.payment_status;
        order_fulfillment_status := v_order.fulfillment_status;
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_refund.status = 'failed' THEN
        RAISE EXCEPTION '退款单 % 已经失败（%），要重试请发起一笔新的退款请求',
          v_refund.refund_no, v_refund.error_message;
    END IF;

    IF v_refund.status = 'rejected' THEN
        RAISE EXCEPTION '退款单 % 已被拒绝，不能再完成', v_refund.refund_no;
    END IF;

    -- 没放行不许完成。放行是退款里的一步（requested → approved → completed），
    -- 少了这一步，谁都能直接把一笔退款结掉 —— 审批形同虚设。
    IF v_refund.status <> 'approved' THEN
        RAISE EXCEPTION '退款单 % 当前状态 % 不能完成（只允许已放行的退款单）',
          v_refund.refund_no, v_refund.status;
    END IF;

    SELECT o.id, o.order_no, o.status, o.payment_status, o.fulfillment_status, o.currency
      INTO v_order
      FROM sales_order o
     WHERE o.id = v_refund.order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '退款单 % 对应的订单不存在', v_refund.refund_no;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 失败：订单照着退款前的状态退回去
    -- ---------------------------------------------------------------------------------
    IF NOT p_success THEN
        UPDATE sales_refund
           SET status        = 'failed',
               error_code    = p_error_code,
               error_message = p_error_message,
               raw_payload   = COALESCE(p_raw_payload, raw_payload)
         WHERE id = p_refund_id;

        IF v_order.status = 'refunding'
           AND v_refund.previous_order_status IS NOT NULL
           AND v_refund.previous_order_status <> 'refunding'
           AND EXISTS (SELECT 1 FROM state_transition st
                        WHERE st.aggregate_type = 'order'
                          AND st.from_status = 'refunding'
                          AND st.to_status = v_refund.previous_order_status) THEN

            UPDATE sales_order
               SET status      = v_refund.previous_order_status,
                   updated_at  = now()
             WHERE id = v_order.id;

            v_restored := true;
        END IF;

        SELECT o.order_no, o.status, o.payment_status, o.fulfillment_status
          INTO v_order FROM sales_order o WHERE o.id = v_refund.order_id;

        IF NOT v_restored AND v_refund.previous_order_status IS NOT NULL THEN
            RAISE NOTICE '退款 % 失败，订单 % 没能退回状态 %（保持在 %），请人工处理',
              v_refund.refund_no, v_order.order_no,
              v_refund.previous_order_status, v_order.status;
        END IF;

        refund_id                := v_refund.id;
        refund_no                := v_refund.refund_no;
        refund_status            := 'failed';
        order_no                 := v_order.order_no;
        order_status             := v_order.status;
        order_payment_status     := v_order.payment_status;
        order_fulfillment_status := v_order.fulfillment_status;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 成功：一次改完所有事实
    -- ---------------------------------------------------------------------------------
    IF v_order.status <> 'refunding' THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不是退款中，不能完成退款（订单 %）',
          v_order.order_no, v_order.status, v_refund.refund_no;
    END IF;

    -- 已经核销的票不能整单退（请求时挡过一次，这里再挡一次：状态可能在这中间变了）。
    IF EXISTS (SELECT 1 FROM voucher v
                WHERE v.order_id = v_refund.order_id AND v.status = 'used') THEN
        RAISE EXCEPTION '订单 % 有已核销的票，不能整单退款 —— 请人工处理', v_order.order_no;
    END IF;

    -- 明细：交付过的记 refunded，没交付的记 cancelled。
    UPDATE sales_order_item
       SET status      = CASE WHEN status IN ('confirmed', 'ticketed') THEN 'refunded' ELSE 'cancelled' END,
           updated_at   = now()
     WHERE order_id = v_refund.order_id
       AND status IN ('pending', 'booking', 'confirmed', 'ticketed', 'failed');

    -- 凭证：票作废。已核销的不动（上面已经挡掉了）。
    UPDATE voucher
       SET status      = 'refunded',
           updated_at   = now()
     WHERE order_id = v_refund.order_id
       AND status IN ('pending', 'issued', 'expired', 'void');

    -- 预订：源侧也退了。失败/过期的预订留着不动 —— 它们本来就没成。
    UPDATE booking
       SET status       = 'cancelled',
           cancelled_at  = now(),
           updated_at    = now()
     WHERE order_id = v_refund.order_id
       AND status IN ('pending', 'requested', 'confirmed', 'ticketed');

    -- 支付：这笔钱退回去了。
    UPDATE sales_payment
       SET status = 'refunded'
     WHERE order_id = v_refund.order_id
       AND status = 'succeeded';

    -- 订单：退款完成。
    UPDATE sales_order
       SET status             = 'refunded',
           payment_status     = 'refunded',
           fulfillment_status = 'cancelled',
           completed_at       = now(),
           updated_at          = now()
     WHERE id = v_refund.order_id;

    UPDATE sales_refund
       SET status            = 'succeeded',
           supplier_refund_id = p_supplier_refund_id,
           completed_at       = now(),
           raw_payload        = COALESCE(p_raw_payload, raw_payload)
     WHERE id = p_refund_id;

    SELECT o.order_no, o.status, o.payment_status, o.fulfillment_status
      INTO v_order FROM sales_order o WHERE o.id = v_refund.order_id;

    refund_id                := v_refund.id;
    refund_no                := v_refund.refund_no;
    refund_status            := 'succeeded';
    order_no                 := v_order.order_no;
    order_status             := v_order.status;
    order_payment_status     := v_order.payment_status;
    order_fulfillment_status := v_order.fulfillment_status;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_complete_refund IS
    '完成一笔退款：成功时一次改完明细/凭证/预订/支付/订单；失败时订单照着退款前的状态退回去；未放行的退款单不许完成';

-- ④ 出券：源侧没给票码时用随机码
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
            -- 源侧给了票码就用源侧的；没给就自己生成一个随机的。
            -- 券号（VC + 日期 + 序列）是连号的，猜得到 —— 票码是闸机认的东西，
            -- 不能猜。券号留作内部标识，不当票码用。
            v_code := COALESCE(p_codes[v_code_pos],
                               'VC-' || replace(gen_random_uuid()::text, '-', ''));

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
    '出券的唯一实现：一条预订覆盖的成分逐个发（各发各的张数、各按各的持票人与有效期），票码与持票人一一对应；源侧没给票码时用随机码，券号不当票码用';

-- =====================================================================================
-- ⑤ 不变量（93-94）
--
--   93 走到终态的退款单必须经过放行（有人放行、有放行时间）
--   94 票码不许是券号派生的（券号连号，票码不能猜）
-- =====================================================================================
CREATE VIEW v_invariant_checks_hardening AS
WITH raw (seq, check_name, actual) AS (
    SELECT 93, '走到终态的退款单必须经过放行（放行时间与放行人都要在）',
           (SELECT count(*) FROM sales_refund r
             WHERE r.status IN ('succeeded','failed')
               AND (r.approved_at IS NULL OR r.approved_by IS NULL))
    UNION ALL
    SELECT 94, '票码不许是券号派生的（券号连号，票码必须不可猜）',
           (SELECT count(*) FROM voucher WHERE code = voucher_no)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_hardening IS
    '收紧口径的两条不变量：退款必须先放行；票码不许是连号派生的';

-- -------------------------------------------------------------------------------------
-- ⑥ 总视图：并集（加一条 harden 分支）
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks AS
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
    SELECT * FROM v_invariant_checks_combo
    UNION ALL
    SELECT * FROM v_invariant_checks_hardening;

COMMENT ON VIEW v_invariant_checks IS
    '全部 94 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
