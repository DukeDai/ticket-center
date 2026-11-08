-- 007_refund.sql
--
-- 退款写路径：把「钱怎么退回来」收成唯一实现。
--
-- 到这一步为止系统能收款、能出票，但收进来的钱退不出去 —— 源侧预订失败、
-- 用户改主意、票过期了要退钱，这些场景库里没有写路径。`sales_refund` 表
-- 早就有了，但没人往里写，状态机里那条 refunding 边也永远走不到。
--
-- 口径（先说清楚，后面每段代码都按它写）：
--
--   1. 退款的作用域是**整单**。一行明细退一部分金额，金额怎么在行之间分摊，
--      跟优惠券、税的口径绑在一起 —— 那是业务决策不是工程决策。口径没定之前，
--      系统只做整单退款；遇到单行退款请求直接报错并说清卡在哪，
--      而不是替业务猜一个分摊规则。
--
--   2. 退款金额必须等于订单实付（order.total）。少退是客诉，多退是资损。
--      订单有没有真的收到钱，看的是 sales_payment 里有没有成功的支付记录，
--      不是看订单状态 —— 状态是结论，结论只有一个算法。
--
--   3. 幂等键必填。同一键重放返回同一张退款单；同一键配不同内容报错。
--      退款是钱的操作，重放一次就多退一次 —— 这里比下单更要紧。
--
--   4. 退款成功时事实一起改：明细（cancelled / refunded）、凭证（refunded）、
--      预订（cancelled）、支付（refunded）、订单（refunded + 履约 cancelled）。
--      事实与状态不许分叉：不变量 61-64 守这条。
--
--   5. 退款失败时订单照着退款前的状态退回去（票还有效的订单，不能因为
--      退款失败就变成 failed）。退不回去就留在 refunding 等人处理 ——
--      静默吞掉只会让钱和票对不上。
--
-- 为什么不写进 005：005 已经在库里应用过了，改它等于内容漂移。
-- 「DDL 只增不改」这条规矩自己也得守。

-- -------------------------------------------------------------------------------------
-- ① 序列与列
-- -------------------------------------------------------------------------------------

CREATE SEQUENCE public.seq_refund_no START WITH 1000;

COMMENT ON SEQUENCE public.seq_refund_no IS '退款单号流水：RF + YYYYMMDD + 6 位';

-- 发起退款时订单是什么状态 —— 退款失败要照着退回去。
ALTER TABLE sales_refund ADD COLUMN previous_order_status TEXT;

COMMENT ON COLUMN sales_refund.previous_order_status IS '发起退款时订单的状态；退款失败时订单照着退回去';

-- 退款单挂幂等键：同一个键只能有一张退款单。
ALTER TABLE sales_refund ADD COLUMN idempotency_key TEXT;

COMMENT ON COLUMN sales_refund.idempotency_key IS '幂等键：同一键重放返回同一张退款单';

-- 退不回来时要能说清为什么：源侧报的错误码与原因单独成列，不埋在 jsonb 里。
ALTER TABLE sales_refund ADD COLUMN error_code TEXT;

ALTER TABLE sales_refund ADD COLUMN error_message TEXT;

COMMENT ON COLUMN sales_refund.error_code IS '退款失败的错误码（源侧或网关）';

COMMENT ON COLUMN sales_refund.error_message IS '退款失败的错误描述';

CREATE UNIQUE INDEX ux_refund_idem ON sales_refund (idempotency_key) WHERE idempotency_key IS NOT NULL;

-- -------------------------------------------------------------------------------------
-- ② 状态机补边：退款失败时订单要能退回去
--
-- 合法流转的唯一来源是 state_transition（硬约束 17）。退款失败要把订单
-- 从 refunding 拉回退款前的状态 —— 没有这条边就拉不回去，订单会永远卡在
-- refunding 等人处理。
--
-- event_type = 'OrderRefundFailed'：下游要知道「这笔退款没成，订单还在原地」。
-- -------------------------------------------------------------------------------------

-- ('order','refunding','failed') 003 里已经有了，这里不重复插。
-- booking_pending 也要能退：收了钱、票还没出、源侧预订失败 —— 这是最常见的退款场景。
INSERT INTO state_transition (aggregate_type, from_status, to_status, event_type) VALUES
('order','booking_pending','refunding',     'RefundRequested'),
('order','refunding','paid',                'OrderRefundFailed'),
('order','refunding','confirmed',           'OrderRefundFailed'),
('order','refunding','partially_fulfilled', 'OrderRefundFailed'),
('order','refunding','fulfilled',           'OrderRefundFailed'),
('order','refunding','booking_pending',     'OrderRefundFailed');

-- -------------------------------------------------------------------------------------
-- ③ fn_request_refund：发起整单退款
--
-- 这一步落「要退钱」这个意图，并把订单推进到 refunding
-- （触发器落一条 RefundRequested 领域事件）。钱还没回来，
-- 但订单从这一刻起不再接受履约推进 —— 免得一边退一边出票。
--
-- 幂等：抢键用 INSERT ... ON CONFLICT DO NOTHING，不用「先查后插」
-- （并发下会双双通过检查，然后双双退钱）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_request_refund(
    p_order_id        BIGINT,
    p_amount          NUMERIC,
    p_reason          TEXT,
    p_requested_by    TEXT,
    p_idempotency_key TEXT
)
RETURNS TABLE (
    refund_id    BIGINT,
    refund_no    TEXT,
    order_no     TEXT,
    order_status TEXT,
    requested    BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_order      RECORD;
    v_existing   RECORD;
    v_scope      TEXT;
    v_hash       TEXT;
    v_refund_id  BIGINT;
    v_refund_no  TEXT;
    v_other      BIGINT;
    v_paid       NUMERIC;
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION '缺少订单 id';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION '退款金额不合法：%（必须大于 0）', p_amount;
    END IF;
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
        RAISE EXCEPTION '缺少幂等键（退钱的操作重放一次就多退一次）';
    END IF;

    SELECT o.id, o.order_no, o.status, o.payment_status, o.currency, o.total
      INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 幂等一：抢键（带内容校验）
    --
    -- 先抢键再比内容，顺序不能反：内容校验在抢键的冲突分支里，
    -- 先查退款单会把「同键异内容」变成静默返回 —— 那等于把两次不同的退款
    -- 当成同一次，钱少退一次还没人知道。
    -- ---------------------------------------------------------------------------------
    v_scope := 'refund:' || p_order_id::text;
    v_hash  := md5(p_amount::text || '|' || COALESCE(p_reason, '') || '|' || COALESCE(p_requested_by, ''));

    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_idempotency_key, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        -- 键已被占用：要么是同一笔请求（返回原单），要么是另一笔请求（拒绝）。
        SELECT ir.request_hash, ir.response INTO v_existing
          FROM idempotency_record ir
         WHERE ir.scope = v_scope AND ir.idempotency_key = p_idempotency_key;

        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔退款请求（订单 %）',
              p_idempotency_key, v_order.order_no;
        END IF;

        SELECT r.id, r.refund_no INTO v_refund_id, v_refund_no
          FROM sales_refund r
         WHERE r.id = NULLIF(v_existing.response->>'refund_id', '')::bigint;

        IF NOT FOUND THEN
            RAISE EXCEPTION '幂等键 % 正在处理中，稍后重试', p_idempotency_key;
        END IF;

        refund_id    := v_refund_id;
        refund_no    := v_refund_no;
        order_no     := v_order.order_no;
        order_status := v_order.status;
        requested    := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 幂等二（兜底）：同键已有退款单，但幂等记录被清过
    --
    -- 没有内容可比（内容校验只存在幂等记录里），但同键不能再退一次。
    -- ---------------------------------------------------------------------------------
    SELECT r.id, r.refund_no, r.order_id INTO v_refund_id, v_refund_no, v_other
      FROM sales_refund r
     WHERE r.idempotency_key = p_idempotency_key;

    IF FOUND THEN
        IF v_other <> p_order_id THEN
            RAISE EXCEPTION '幂等键 % 已经用在订单 % 的退款上（%），不能用在订单 % 上',
              p_idempotency_key, v_other, v_refund_no, p_order_id;
        END IF;

        UPDATE idempotency_record
           SET status   = 'done',
               response = jsonb_build_object('refund_id', v_refund_id, 'refund_no', v_refund_no)
         WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

        refund_id    := v_refund_id;
        refund_no    := v_refund_no;
        order_no     := v_order.order_no;
        order_status := v_order.status;
        requested    := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 能不能退
    -- ---------------------------------------------------------------------------------
    IF v_order.status NOT IN ('paid', 'booking_pending', 'confirmed', 'partially_fulfilled', 'fulfilled', 'failed') THEN
        IF v_order.status = 'refunding' THEN
            RAISE EXCEPTION '订单 % 正在退款中', v_order.order_no;
        ELSIF v_order.status = 'refunded' THEN
            RAISE EXCEPTION '订单 % 已经退过款', v_order.order_no;
        ELSE
            RAISE EXCEPTION '订单 % 当前状态 % 不能退款（没收到钱）',
              v_order.order_no, v_order.status;
        END IF;
    END IF;

    -- 订单有没有真的收到钱：看支付记录，不看订单状态。
    SELECT COALESCE(sum(sp.amount), 0) INTO v_paid
      FROM sales_payment sp
     WHERE sp.order_id = p_order_id
       AND sp.status = 'succeeded';

    IF v_paid = 0 THEN
        RAISE EXCEPTION '订单 % 没有成功的支付记录，无款可退', v_order.order_no;
    END IF;

    -- 退款金额必须等于订单实付。
    IF p_amount <> v_order.total THEN
        RAISE EXCEPTION '退款金额与订单实付不符：订单 % 实付 %，申请退 %',
          v_order.order_no, v_order.total, p_amount;
    END IF;

    -- 已经核销的票不能整单退：票已经用掉了，钱不该全退。
    IF EXISTS (SELECT 1 FROM voucher v
                WHERE v.order_id = p_order_id AND v.status = 'used') THEN
        RAISE EXCEPTION '订单 % 有已核销的票，不能整单退款 —— 请人工处理', v_order.order_no;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 落退款单
    -- ---------------------------------------------------------------------------------
    v_refund_no := 'RF' || to_char(current_date, 'YYYYMMDD')
                   || lpad(nextval('public.seq_refund_no')::text, 6, '0');

    INSERT INTO sales_refund (refund_no, order_id, amount, currency, status, reason,
                               requested_by, previous_order_status, idempotency_key)
    VALUES (v_refund_no, p_order_id, p_amount, v_order.currency, 'requested',
            p_reason, p_requested_by, v_order.status, p_idempotency_key)
    RETURNING id INTO v_refund_id;

    -- 订单推进到退款中：触发器落一条 RefundRequested 事件。
    UPDATE sales_order
       SET status      = 'refunding',
           updated_at   = now()
     WHERE id = p_order_id;

    UPDATE idempotency_record
       SET status   = 'done',
           response = jsonb_build_object('refund_id', v_refund_id, 'refund_no', v_refund_no)
     WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

    refund_id    := v_refund_id;
    refund_no    := v_refund_no;
    order_no     := v_order.order_no;
    order_status := 'refunding';
    requested    := true;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_request_refund IS '发起整单退款：金额必须等于订单实付，幂等键必填，订单推进到 refunding（钱还没回来）';

-- -------------------------------------------------------------------------------------
-- ④ fn_approve_refund：人工放行
--
-- 有些退款要先过一道人工（金额大、客服代客操作）。这一笔只是把退款单
-- 从 requested 挪到 approved，订单状态不动 —— 钱还没回来。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_approve_refund(
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
           approved_at = now()
     WHERE id = p_refund_id;

    refund_id     := v_refund_id;
    refund_no     := v_refund_no;
    refund_status := 'approved';
    order_status  := v_order_state;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_approve_refund IS '放行一笔退款（requested → approved）；订单状态不动，钱还没回来';

-- -------------------------------------------------------------------------------------
-- ⑤ fn_complete_refund：退款到了（或没到）
--
-- 成功时一次改完所有事实，不留半截状态：
--
--   明细：已确认/已出票的 → refunded；还没确认的 → cancelled
--   凭证：issued / pending → refunded（票作废）
--   预订：还在飞的、已确认的、已出票的 → cancelled（源侧也退了）
--   支付：succeeded → refunded
--   订单：refunding → refunded，支付状态 refunded，履约状态 cancelled
--
-- 失败时订单照着退款前的状态退回去。退不回去就留在 refunding ——
-- 静默吞掉只会让钱和票对不上。
--
-- 失败的退款单是终态：要重试得发起一笔新的退款请求（新的幂等键），
-- 因为订单已经退回了原来的状态，再走一遍「refunding → refunded」会缺边。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_complete_refund(
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

COMMENT ON FUNCTION fn_complete_refund IS '完成一笔退款：成功时一次改完明细/凭证/预订/支付/订单；失败时订单照着退款前的状态退回去';

-- -------------------------------------------------------------------------------------
-- ⑥ 退款侧不变量（61-64）
--
-- 守的是「事实与状态不许分叉」：
--   61 退款不能多退（资损）
--   62 订单说退了，就得真有成功的退款记录，金额还得对得上
--   63 订单说退了，每条明细都得是已取消或已退款（不能还留着 confirmed/ticketed）
--   64 订单说退了，不能还留着「成功」的支付记录（钱还没退回来的说法）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_refund AS
WITH raw (seq, check_name, actual) AS (
    -- 61：退款金额合计不得超过订单实付金额。
    SELECT 61, '退款金额合计不得超过订单实付金额',
           (SELECT count(*)
              FROM (SELECT r.order_id, sum(r.amount) AS refunded
                      FROM sales_refund r
                     WHERE r.status = 'succeeded'
                     GROUP BY r.order_id
                    HAVING sum(r.amount) > (SELECT o.total FROM sales_order o WHERE o.id = r.order_id)) x)
    UNION ALL
    -- 62：订单标着已退款，必须有成功的退款记录，且金额等于实付。
    SELECT 62, '已退款订单必须有成功的退款记录且金额等于实付',
           (SELECT count(*)
              FROM sales_order o
             WHERE o.payment_status = 'refunded'
               AND (NOT EXISTS (SELECT 1 FROM sales_refund r
                                 WHERE r.order_id = o.id AND r.status = 'succeeded')
                 OR (SELECT COALESCE(sum(r.amount), 0) FROM sales_refund r
                      WHERE r.order_id = o.id AND r.status = 'succeeded') <> o.total))
    UNION ALL
    -- 63：已退款的订单，每条明细都必须是已取消或已退款。
    SELECT 63, '已退款订单的每条明细必须已取消或已退款',
           (SELECT count(*)
              FROM sales_order o
             WHERE o.status = 'refunded'
               AND EXISTS (SELECT 1 FROM sales_order_item oi
                            WHERE oi.order_id = o.id
                              AND oi.status NOT IN ('cancelled', 'refunded')))
    UNION ALL
    -- 64：已退款的订单不能还留着「成功」的支付记录。
    SELECT 64, '已退款订单不能留着成功的支付记录',
           (SELECT count(*)
              FROM sales_order o
             WHERE o.status = 'refunded'
               AND EXISTS (SELECT 1 FROM sales_payment sp
                            WHERE sp.order_id = o.id AND sp.status = 'succeeded'))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_refund IS '退款侧不变量（61-64）：退款金额、退款记录、明细与支付状态的一致性';

-- -------------------------------------------------------------------------------------
-- ⑦ 总视图：并集
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
    SELECT * FROM v_invariant_checks_refund;

COMMENT ON VIEW v_invariant_checks IS '全部 64 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
