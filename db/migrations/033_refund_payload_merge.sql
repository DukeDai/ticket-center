-- =============================================================================
-- 033 —— 退款报文合并而不是覆盖
--
-- 背景（硬约束 29 的同类：事实不许被一次调用洗掉）
--
-- fn_complete_refund 原来两处写 sales_refund.raw_payload 是**覆盖**：
--
--     raw_payload = COALESCE(p_raw_payload, raw_payload)
--
-- 两层问题：
--
--   1. **COALESCE 从来不兜底。** p_raw_payload 的默认值是 '{}'::jsonb，
--      不是 NULL。所以「调用方没传报文」这一种最常见的情况，
--      COALESCE 取到的就是 '{}'，整列被洗成一个空对象。
--   2. **覆盖不是合并。** 即使调用方真传了报文（渠道回调原文），
--      它也是**整列替换**，不是往里加键。
--
-- 后果：发起退款时写进 raw_payload->'policy' 的**承诺快照**
-- （refundable / cutoff_hours / fee_percent / expected_amount）
-- 被完成退款的那一次调用洗掉了。
--
-- 为什么这是数据违规而不是「少了个字段」：
-- 不变量 62 / 124 / 126 复查的是**退款单金额与承诺快照的对照**。
-- 快照被洗掉 → 对照的右边变成 0 → 已退款的订单全部报违规。
-- 也就是说：**一次不带回调报文的退款完成调用，就把退款的事实洗没了。**
--
-- 修法：按 018 的先例（fn_create_bookings 的 request_payload 合并而不是覆盖），
-- 改成合并：
--
--     raw_payload = raw_payload || COALESCE(p_raw_payload, '{}'::jsonb)
--
-- 合并的键序：右边的键盖住左边的同名键（jsonb || 的语义）。
-- 调用方传的报文**不能**盖掉 'policy' —— 那是我们写下的承诺事实，
-- 不是渠道回给我们的东西。渠道回执的键要是撞上 'policy'，
-- 那是渠道报文串了字段，不是我们要让的事实被改写。
-- 所以这里先摘掉右边的 'policy' 再合并。
--
-- 已应用的迁移文件不许改（硬约束 3），所以这里新增一个迁移，
-- 用 CREATE OR REPLACE 重写函数体 —— 与 018 同一手法。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_complete_refund(
    p_refund_id          bigint,
    p_success            boolean,
    p_supplier_refund_id text    DEFAULT NULL::text,
    p_error_code         text    DEFAULT NULL::text,
    p_error_message      text    DEFAULT NULL::text,
    p_raw_payload        jsonb   DEFAULT '{}'::jsonb)
RETURNS TABLE(refund_id bigint,
              refund_no text,
              refund_status text,
              order_no text,
              order_status text,
              order_payment_status text,
              order_fulfillment_status text)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_refund     RECORD;
    v_order      RECORD;
    v_restored   BOOLEAN := false;
    -- 回调报文里不许有 'policy'：那是我们写下的承诺事实。
    -- 渠道报文撞上这个键，是渠道串了字段，不是我们要让的事实被改写。
    v_callback   JSONB;
BEGIN
    v_callback := COALESCE(p_raw_payload, '{}'::jsonb) - 'policy';

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
        -- 合并而不是覆盖：承诺快照（policy）留着，回调报文加在上面。
        UPDATE sales_refund
           SET status        = 'failed',
               error_code    = p_error_code,
               error_message = p_error_message,
               raw_payload   = raw_payload || v_callback
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

    -- 合并而不是覆盖：承诺快照（policy）留着，回调报文加在上面。
    UPDATE sales_refund
       SET status            = 'succeeded',
           supplier_refund_id = p_supplier_refund_id,
           completed_at       = now(),
           raw_payload        = raw_payload || v_callback
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
$function$;

COMMENT ON FUNCTION public.fn_complete_refund(bigint, boolean, text, text, text, jsonb) IS
'落退款结果。成功时一次改完明细 / 凭证 / 预订 / 支付 / 订单。raw_payload 是合并而不是覆盖：承诺快照（policy）留着，回调报文加在上面，且回调报文不许带 policy 键盖掉我们的承诺事实（硬约束 29 / 迁移 018 的先例）。';
