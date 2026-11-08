-- =====================================================================================
-- 005 履约写路径：支付 → 预订 → 出券
--
-- 004 把「下单」写通了：订单能落库、金额只认定价函数、幂等由抢键保证。
-- 但订单落库之后就断了 —— 付了钱没人记账，没人向源侧下预订，预订成了没人出券。
-- SPEC.md §3.3 的交易流到这里才是完整的。
--
-- 这一份迁移给出履约侧的唯一实现：
--   - fn_record_payment()        支付入账：金额必须等于订单应付，订单 awaiting_payment → paid；
--   - fn_create_bookings()       为每条明细建预订（幂等键稳定，重跑不会重复下单）；
--   - fn_request_booking()       发起预订请求：pending → requested，attempt_count 递增；
--   - fn_record_booking_attempt() 每次尝试的报文归档（硬约束 8：原始报文必须归档）；
--   - fn_complete_booking()      源侧结果落库：requested → confirmed / failed / cancelled；
--   - fn_issue_voucher()         出券：券 + 权益 + 持票人快照；
--   - fn_retry_booking()         失败重报：failed → pending 并设 next_retry_at；
--   - fn_apply_order_fulfillment() 订单履约状态的唯一推导（订单状态不靠调用方手写）。
--
-- 预订的源来自订单明细的采纳源（下单时快照的），不允许换源 ——
-- 否则会出现「按 A 源的价格卖、按 B 源出票」。
--
-- 三条口径写在前面，后面每条实现都对着它：
--
--   1. 订单的履约状态**不归调用方写**。调用方只报告事实（源确认了 / 出了几张票），
--      由 fn_apply_order_fulfillment 从明细的实际出票情况推导。
--      写订单状态的地方只此一处 —— 散落在各个函数里各写各的，订单迟早会自相矛盾。
--   2. 预订的源场次必须来自 product_session_source（规范场次 ↔ 源场次的绑定），
--      不能按日期去 supplier_session 里猜一条。猜中的概率不低，猜错的后果是
--      「买的是 A 天的票，出的是 B 天的票」。
--   3. 票码与持票人必须一一对应。码不够就报错，不能拿一张券顶两个人的票。
-- =====================================================================================

-- 预订号与券号：各一个序列（种子数据用的是显式 id，序列从 1000 起，避开种子里的号）
CREATE SEQUENCE public.seq_booking_no START WITH 1000;
CREATE SEQUENCE public.seq_voucher_no START WITH 1000;

COMMENT ON SEQUENCE public.seq_booking_no IS '预订号流水（BK + YYYYMMDD + 6 位）';
COMMENT ON SEQUENCE public.seq_voucher_no IS '凭证号流水（VC + YYYYMMDD + 6 位）';

-- -------------------------------------------------------------------------------------
-- 5.0 状态机补正
--
-- 这两条边的领域事件名写错了，都写成了 OrderConfirmed。
-- 事件名是订阅方（通知 / 结算 / 履约看板）唯一的抓手：
-- 「订单已履约」发成「订单已确认」，订阅方会把已履约的订单当成还在等票的。
--
-- 合法边本身没问题（booking_pending → fulfilled / partially_fulfilled 都合法），
-- 只改事件名。改状态机 = 改 state_transition 表 + 同步 SPEC.md §5 / §6。
-- -------------------------------------------------------------------------------------
UPDATE state_transition
   SET event_type = 'OrderFulfilled'
 WHERE aggregate_type = 'order'
   AND from_status = 'booking_pending'
   AND to_status = 'fulfilled';

UPDATE state_transition
   SET event_type = 'OrderPartiallyFulfilled'
 WHERE aggregate_type = 'order'
   AND from_status = 'booking_pending'
   AND to_status = 'partially_fulfilled';

-- -------------------------------------------------------------------------------------
-- 5.1 支付入账
--
-- 金额口径只有一个：订单的 total。支付金额不等于应付，直接报错 ——
-- 「差一分钱」的订单在结算和对账阶段才会爆，那时已经晚了。
--
-- 订单的 status 与 payment_status 在**同一条 UPDATE** 里改。
-- 只改 payment_status 会留下一张「钱记上了、状态还挂在 awaiting_payment」的订单：
-- 下一棒（建预订）按状态推进就会卡住，而且卡在一个看不出原因的地方。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_record_payment(
    p_order_id        BIGINT,
    p_payment_method  TEXT,
    p_amount          NUMERIC,
    p_currency        TEXT,
    p_provider        TEXT DEFAULT NULL,
    p_provider_txn_id TEXT DEFAULT NULL,
    p_raw_payload     JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    payment_id  BIGINT,
    order_id    BIGINT,
    order_status TEXT,
    paid        BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_order    RECORD;
    v_existing RECORD;
    v_payment  BIGINT;
    v_status   TEXT;
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION '缺少订单 id';
    END IF;
    IF p_amount IS NULL OR p_amount < 0 THEN
        RAISE EXCEPTION '支付金额不合法：%', p_amount;
    END IF;

    SELECT o.id, o.order_no, o.status, o.currency, o.total, o.payment_status
      INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    -- 幂等一：同一笔渠道流水只入账一次（ux_payment_provider_txn 唯一索引兜底）。
    IF p_provider_txn_id IS NOT NULL THEN
        SELECT sp.id, sp.order_id, sp.status INTO v_existing
          FROM sales_payment sp
         WHERE sp.provider = p_provider
           AND sp.provider_txn_id = p_provider_txn_id;

        IF FOUND THEN
            -- 同一笔流水记到另一张单上 = 对账时两笔对不上，必须当场报错。
            IF v_existing.order_id <> v_order.id THEN
                RAISE EXCEPTION '渠道流水 % 已记在订单 % 上，不能记到订单 %',
                  p_provider_txn_id, v_existing.order_id, v_order.id;
            END IF;
            payment_id  := v_existing.id;
            order_id    := v_order.id;
            order_status := v_order.status;
            -- paid 的口径是「本次调用是否新记了一笔支付」，不是「订单现在是不是已支付」。
            -- 订单现在什么状态，看 order_status。
            paid        := false;
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    -- 幂等二：已付过就不再付一次。
    IF v_order.payment_status = 'paid' THEN
        SELECT sp.id INTO v_existing
          FROM sales_payment sp
         WHERE sp.order_id = v_order.id AND sp.status = 'succeeded'
         LIMIT 1;

        IF NOT FOUND THEN
            RAISE EXCEPTION '订单 % 标记为已支付，但没有成功的支付记录（数据不自洽）',
              v_order.order_no;
        END IF;

        payment_id  := v_existing.id;
        order_id    := v_order.id;
        order_status := v_order.status;
        paid        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_currency IS NOT NULL AND btrim(p_currency) <> v_order.currency THEN
        RAISE EXCEPTION '支付币种与订单不符：订单 % 币种 %，支付 %',
          v_order.order_no, v_order.currency, p_currency;
    END IF;

    IF p_amount <> v_order.total THEN
        RAISE EXCEPTION '支付金额与订单应付不符：订单 % 应付 %，实付 %',
          v_order.order_no, v_order.total, p_amount;
    END IF;

    IF v_order.status <> 'awaiting_payment' THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不能记账支付（只允许 awaiting_payment）',
          v_order.order_no, v_order.status;
    END IF;

    INSERT INTO sales_payment (order_id, channel_id, payment_method, amount, currency,
                               status, provider, provider_txn_id, paid_at, raw_payload)
    SELECT v_order.id, o.channel_id, p_payment_method, p_amount, v_order.currency,
           'succeeded', p_provider, p_provider_txn_id, now(), p_raw_payload
      FROM sales_order o
     WHERE o.id = v_order.id
    RETURNING id INTO v_payment;

    -- 状态机：awaiting_payment → paid（触发器落一条 OrderPaid 事件）
    UPDATE sales_order
       SET status         = 'paid',
           payment_status = 'paid'
     WHERE id = v_order.id
       AND status = 'awaiting_payment'
    RETURNING status INTO v_status;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不能记账支付（只允许 awaiting_payment）',
          v_order.order_no, v_order.status;
    END IF;

    payment_id  := v_payment;
    order_id    := v_order.id;
    order_status := v_status;
    paid        := true;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_record_payment IS '支付入账的唯一实现：金额必须等于订单应付，幂等按渠道流水；订单状态与支付状态一起推进';

-- -------------------------------------------------------------------------------------
-- 5.2 建预订
--
-- 一条订单明细一条预订（不是一条订单一条）：明细各自有各自的源与场次。
-- 幂等键 = 订单号 + 明细 id —— 稳定的，重跑不会向源侧下第二次单。
--
-- 源场次的唯一出处是 product_session_source（规范场次 ↔ 源场次的绑定）。
-- 按日期去 supplier_session 里找一条「同商品同日期」的记录是猜：
-- 同一商品同一天可以有好几个场次（上午场 / 下午场 / 夜间场），猜错就是发错场的票。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_create_bookings(p_order_id BIGINT)
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
    v_booking    RECORD;
    v_booking_id BIGINT;
    v_booking_no TEXT;
    v_session    BIGINT;
    v_variant    BIGINT;
    v_date       DATE;
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
        SELECT oi.id, oi.product_id, oi.supplier_id, oi.supplier_product_id,
               oi.session_id, oi.ticket_type_id, oi.quantity, oi.product_variant_id,
               oi.detail_snapshot
          FROM sales_order_item oi
         WHERE oi.order_id = v_order.id
         ORDER BY oi.id
    LOOP
        -- 已经建过就返回原来那条（幂等）。
        SELECT b.id, b.booking_no INTO v_booking
          FROM booking b
         WHERE b.order_id = v_order.id
           AND b.order_item_id = v_item.id
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

        IF v_item.supplier_id IS NULL OR v_item.supplier_product_id IS NULL THEN
            RAISE EXCEPTION '订单行 % 没有采纳源，无法创建预订（下单时必须选中源）', v_item.id;
        END IF;

        IF v_item.session_id IS NULL THEN
            RAISE EXCEPTION '订单行 % 没有场次，无法创建预订', v_item.id;
        END IF;

        -- 源场次：走场次级绑定表，不按日期猜。
        SELECT pss.supplier_session_id INTO v_session
          FROM product_session_source pss
         WHERE pss.product_session_id = v_item.session_id
           AND pss.supplier_product_id = v_item.supplier_product_id
         ORDER BY pss.id
         LIMIT 1;

        IF v_session IS NULL THEN
            RAISE EXCEPTION '订单行 % 的规范场次 % 没有绑定源商品 % 的源场次，无法创建预订（product_session_source 缺一条绑定）',
              v_item.id, v_item.session_id, v_item.supplier_product_id;
        END IF;

        -- 源变体：按覆盖映射找能履约这个变体的源变体（同一源商品内取置信度最高的）。
        -- 明细没有变体 id 的老订单（变体层之前下的）留空，不硬凑一个。
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

COMMENT ON FUNCTION fn_create_bookings IS '为订单的每条明细建预订：幂等键 = 订单号 + 明细 id；源场次走 product_session_source 绑定';

-- -------------------------------------------------------------------------------------
-- 5.3 发起预订请求
--
-- pending → requested。这一步只是「准备发出去了」，不代表源侧已经受理。
-- attempt_count 在这里递增：重试一次算一次尝试。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_request_booking(p_booking_id BIGINT, p_request JSONB DEFAULT '{}'::jsonb)
RETURNS TABLE (
    booking_id  BIGINT,
    booking_no  TEXT,
    attempt_no  INT,
    status      TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_booking RECORD;
BEGIN
    SELECT b.id, b.booking_no, b.status, b.attempt_count INTO v_booking
      FROM booking b
     WHERE b.id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 不存在', p_booking_id;
    END IF;

    IF v_booking.status NOT IN ('pending', 'requested') THEN
        RAISE EXCEPTION '预订 % 当前状态 % 不能发起请求（只允许 pending / requested）',
          v_booking.booking_no, v_booking.status;
    END IF;

    IF v_booking.status = 'pending' THEN
        UPDATE booking
           SET status          = 'requested',
               attempt_count   = attempt_count + 1,
               request_payload = COALESCE(p_request, request_payload),
               next_retry_at   = NULL
         WHERE id = v_booking.id;
    ELSE
        -- 重试：状态不动，尝试次数加一。
        UPDATE booking
           SET attempt_count   = attempt_count + 1,
               request_payload = COALESCE(p_request, request_payload),
               next_retry_at   = NULL
         WHERE id = v_booking.id;
    END IF;

    booking_id := v_booking.id;
    booking_no := v_booking.booking_no;
    attempt_no := v_booking.attempt_count + 1;
    status     := 'requested';
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_request_booking IS '发起预订请求：pending → requested，attempt_count 递增（重试也走这里）';

-- -------------------------------------------------------------------------------------
-- 5.4 每次尝试的报文归档
--
-- 硬约束 8：原始报文必须归档。接入层拿到源侧响应后调这个函数，
-- 尝试次数、HTTP 状态、耗时、错误分类全部留痕。
--
-- 同一次尝试重复归档走 upsert：崩溃重跑会再调一次，
-- 撞唯一索引 (booking_id, attempt_no) 报错等于把重试堵死。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_record_booking_attempt(
    p_booking_id    BIGINT,
    p_request       JSONB DEFAULT NULL,
    p_response      JSONB DEFAULT NULL,
    p_http_status   INT DEFAULT NULL,
    p_latency_ms    INT DEFAULT NULL,
    p_error_type    TEXT DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
)
RETURNS TABLE (
    attempt_id BIGINT,
    attempt_no INT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_attempt_no INT;
    v_attempt_id BIGINT;
BEGIN
    SELECT b.attempt_count INTO v_attempt_no
      FROM booking b
     WHERE b.id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 不存在', p_booking_id;
    END IF;

    IF v_attempt_no < 1 THEN
        RAISE EXCEPTION '预订 % 还没发起过请求（先调 fn_request_booking）', p_booking_id;
    END IF;

    INSERT INTO booking_attempt (booking_id, attempt_no, request, response, http_status,
                                 latency_ms, error_type, error_message)
    VALUES (p_booking_id, v_attempt_no, p_request, p_response, p_http_status,
            p_latency_ms, p_error_type, p_error_message)
    ON CONFLICT ON CONSTRAINT booking_attempt_uk DO UPDATE
       SET request       = COALESCE(EXCLUDED.request, booking_attempt.request),
           response      = COALESCE(EXCLUDED.response, booking_attempt.response),
           http_status   = COALESCE(EXCLUDED.http_status, booking_attempt.http_status),
           latency_ms    = COALESCE(EXCLUDED.latency_ms, booking_attempt.latency_ms),
           error_type    = COALESCE(EXCLUDED.error_type, booking_attempt.error_type),
           error_message = COALESCE(EXCLUDED.error_message, booking_attempt.error_message)
    RETURNING id INTO v_attempt_id;

    IF p_error_type IS NOT NULL OR p_error_message IS NOT NULL THEN
        UPDATE booking
           SET error_code    = p_error_type,
               error_message = p_error_message
         WHERE id = p_booking_id;
    END IF;

    attempt_id := v_attempt_id;
    attempt_no := v_attempt_no;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_record_booking_attempt IS '归档一次预订尝试：报文、HTTP 状态、耗时、错误分类（同一次尝试可重复归档）';

-- -------------------------------------------------------------------------------------
-- 5.5 订单履约状态的唯一推导
--
-- 订单的履约状态**不归调用方写**。调用方只报告事实：
--   - 源确认了预订（fn_complete_booking）
--   - 出了几张票（fn_issue_voucher）
-- 这里从明细的实际出票情况推出订单该是什么状态。
--
-- 为什么不让调用方直接写订单状态：订单状态是「这单到哪一步了」的**结论**，
-- 结论只有一个算法。写在各个函数里各写各的，订单迟早自相矛盾
-- （已履约却还挂着 booking_pending、已确认却早就发完票）。
--
-- 明细的五种态：
--
--   done    份数发齐（权益份数之和 ≥ 明细数量）
--   partial 发出了一部分，不足数
--   live    预订还在飞（pending / requested）
--   wait    源已确认，票还没出
--   dead    预订失败且不打算重报（失败、没有待重报时间）
--   idle    还没有预订
--
-- 订单的态：
--   全部 done              → fulfilled
--   发出去一些且没有在飞的  → partially_fulfilled（剩下的不会再来了）
--   每条明细的预订都确认了  → confirmed（票还没出齐）
--   每条明细都 dead 且没发出 → failed
--   其余                    → 保持原状（booking_pending）
--
-- 只走 state_transition 里的合法边。没有那条边就保持原状 —— 不硬改。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_apply_order_fulfillment(p_order_id BIGINT)
RETURNS TABLE (
    order_id          BIGINT,
    order_status      TEXT,
    fulfillment_status TEXT,
    delivered_qty     INT,
    requested_qty     INT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_order        RECORD;
    v_target       TEXT;
    v_fulfillment  TEXT;
    v_items        INT := 0;
    v_delivered    INT := 0;
    v_requested    INT := 0;
    v_inflight     INT := 0;
    v_confirmed    INT := 0;
    v_dead         INT := 0;
BEGIN
    SELECT o.id, o.order_no, o.status, o.fulfillment_status INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    WITH per_item AS (
        SELECT oi.id,
               oi.quantity,
               COALESCE((
                 SELECT sum(ve.quantity)
                   FROM voucher_entitlement ve
                   JOIN voucher v ON v.id = ve.voucher_id
                  WHERE v.order_item_id = oi.id
                    AND v.status IN ('issued', 'used')
                    AND ve.entitlement_type = 'admission'), 0) AS delivered,
               EXISTS (SELECT 1 FROM booking b
                        WHERE b.order_item_id = oi.id
                          AND b.status IN ('confirmed', 'ticketed')) AS ok,
               EXISTS (SELECT 1 FROM booking b
                        WHERE b.order_item_id = oi.id
                          AND b.status IN ('pending', 'requested')) AS live,
               EXISTS (SELECT 1 FROM booking b
                        WHERE b.order_item_id = oi.id
                          AND b.status IN ('failed', 'cancelled', 'expired')
                          AND b.next_retry_at IS NULL) AS dead
          FROM sales_order_item oi
         WHERE oi.order_id = p_order_id
    ), labeled AS (
        SELECT p.*,
               CASE WHEN p.delivered >= p.quantity THEN 'done'
                    WHEN p.delivered > 0 THEN 'partial'
                    WHEN p.live THEN 'live'
                    WHEN p.ok THEN 'wait'
                    WHEN p.dead THEN 'dead'
                    ELSE 'idle' END AS st
          FROM per_item p
    )
    SELECT count(*),
           COALESCE(sum(LEAST(delivered, quantity)), 0),
           COALESCE(sum(quantity), 0),
           count(*) FILTER (WHERE st IN ('live', 'wait', 'idle')),
           count(*) FILTER (WHERE ok),
           count(*) FILTER (WHERE st = 'dead')
      INTO v_items, v_delivered, v_requested, v_inflight, v_confirmed, v_dead
      FROM labeled;

    IF v_items = 0 THEN
        order_id           := v_order.id;
        order_status       := v_order.status;
        fulfillment_status := v_order.fulfillment_status;
        delivered_qty      := 0;
        requested_qty      := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_delivered >= v_requested THEN
        v_target := 'fulfilled';
    ELSIF v_delivered > 0 AND v_inflight = 0 THEN
        v_target := 'partially_fulfilled';
    ELSIF v_confirmed = v_items THEN
        v_target := 'confirmed';
    ELSIF v_dead = v_items THEN
        v_target := 'failed';
    ELSE
        v_target := NULL;
    END IF;

    -- 只有履约阶段的状态归这里改（paid 之前、refunding 之后都不动）。
    -- 状态不在范围内时**照样算、照样报**已出/应出份数 ——
    -- 调用方要的是「现在出到第几份」，不是「我有没有资格改状态」。
    IF v_order.status IN ('booking_pending', 'confirmed', 'partially_fulfilled')
       AND v_target IS NOT NULL AND v_target <> v_order.status THEN
        -- 只走合法边（state_transition 是唯一来源）；没有这条边就保持原状，不硬改。
        IF EXISTS (SELECT 1 FROM state_transition st
                    WHERE st.aggregate_type = 'order'
                      AND st.from_status = v_order.status
                      AND st.to_status = v_target) THEN
            v_fulfillment := CASE v_target
                               WHEN 'fulfilled' THEN 'fulfilled'
                               WHEN 'partially_fulfilled' THEN 'partial'
                               WHEN 'failed' THEN 'failed'
                               ELSE 'unfulfilled'
                             END;

            UPDATE sales_order
               SET status             = v_target,
                   fulfillment_status = v_fulfillment,
                   confirmed_at       = CASE WHEN v_target IN ('confirmed', 'fulfilled', 'partially_fulfilled')
                                            THEN COALESCE(confirmed_at, now())
                                            ELSE confirmed_at END,
                   completed_at       = CASE WHEN v_target = 'fulfilled'
                                            THEN COALESCE(completed_at, now())
                                            ELSE completed_at END
             WHERE id = v_order.id;

            v_order.status             := v_target;
            v_order.fulfillment_status := v_fulfillment;
        END IF;
    END IF;

    order_id           := v_order.id;
    order_status       := v_order.status;
    fulfillment_status := v_order.fulfillment_status;
    delivered_qty      := v_delivered;
    requested_qty      := v_requested;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_apply_order_fulfillment IS '订单履约状态的唯一推导：从明细的实际出票情况推出订单状态，只走 state_transition 的合法边';

-- -------------------------------------------------------------------------------------
-- 5.6 出券
--
-- 券挂预订，权益数量与明细数量对得上，持票人快照来自下单时收的实名信息。
--
-- 发几张券取决于计价口径（与种子数据的模型一致）：
--   - per_person（按人计价）：一人一券。2 张成人票 = 2 张券，各带各的持票人快照 ——
--     核销扫的是票，不是「一张含两份权益的券」。
--   - per_group（按团报价）：整团一券，权益数量 = 明细份数。
--
-- 幂等：已发的券不会再发一遍（按预订数出来的张数比对）。
--
-- p_codes 的口径：**本次要发的那些券的票码**，按持票人序号升序。
-- 第 k 个码对应序号「已发张数 + k」。码数必须等于还要发的张数 ——
-- 少一个就报错，不拿一张券顶两个人的票（那等于把甲的票发给了乙）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_issue_voucher(
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
    v_session    RECORD;
    v_existing   RECORD;
    v_expected   INT;
    v_have       INT;
    v_need       INT;
    v_voucher_no TEXT;
    v_code       TEXT;
    v_holders    JSONB;
    v_i          INT;
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

    v_expected := CASE WHEN v_item.pricing_basis = 'per_group'
                       THEN 1 ELSE v_item.quantity END;

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

    SELECT ps.session_date INTO v_session
      FROM product_session ps
     WHERE ps.id = v_item.session_id;

    FOR v_i IN v_have + 1 .. v_expected
    LOOP
        -- 持票人快照：按序号取那一位持票人的字段
        SELECT COALESCE(jsonb_object_agg(h.field_code, h.value), '{}'::jsonb)
          INTO v_holders
          FROM order_holder h
         WHERE h.order_item_id = v_item.id
           AND h.sequence = v_i;

        v_holders := v_holders || jsonb_build_object('sequence', v_i);

        v_voucher_no := 'VC' || to_char(now(), 'YYYYMMDD')
                     || lpad(nextval('public.seq_voucher_no')::text, 6, '0');

        v_code := COALESCE(p_codes[v_i - v_have], v_voucher_no);

        INSERT INTO voucher (voucher_no, order_id, order_item_id, booking_id, product_id, supplier_id,
                             ticket_type_id, session_id, product_variant_id, supplier_variant_id,
                             code, qr_payload, status, holder_snapshot, raw_payload)
        VALUES (v_voucher_no, v_booking.order_id, v_item.id, v_booking.id, v_item.product_id,
                v_item.supplier_id, v_item.ticket_type_id, v_item.session_id,
                v_item.product_variant_id, v_booking.supplier_variant_id,
                v_code, v_code, 'pending', v_holders, p_raw_payload)
        RETURNING id INTO v_existing;

        -- 权益：按团一券含全部份数，按人一人一份
        INSERT INTO voucher_entitlement (voucher_id, entitlement_type, quantity, meta)
        VALUES (v_existing.id, 'admission',
                CASE WHEN v_item.pricing_basis = 'per_group' THEN v_item.quantity ELSE 1 END,
                jsonb_build_object('order_item_id', v_item.id,
                                   'booking_id', v_booking.id,
                                   'quantity', v_item.quantity,
                                   'pricing_basis', v_item.pricing_basis));

        -- pending → issued（触发器落 VoucherIssued 事件）
        UPDATE voucher
           SET status     = 'issued',
               issued_at  = now(),
               valid_from = COALESCE(v_session.session_date, now())::timestamptz,
               valid_to   = COALESCE((v_session.session_date + 1)::timestamptz, now() + interval '1 day')
         WHERE id = v_existing.id;

        voucher_id      := v_existing.id;
        voucher_no      := v_voucher_no;
        code            := v_code;
        holder_sequence := v_i;
        created         := true;
        RETURN NEXT;
    END LOOP;

    -- 明细状态：份数发齐了就是 ticketed（pending / booking / confirmed → ticketed 都是合法边）
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
                AND ve.entitlement_type = 'admission'), 0) >= oi.quantity;

    -- 订单履约状态交给唯一实现推导
    PERFORM fn_apply_order_fulfillment(v_booking.order_id);
END;
$$;

COMMENT ON FUNCTION fn_issue_voucher IS '出券的唯一实现：按人一人一券、按团整团一券；已发的券不重复发；票码必须与持票人一一对应';

-- -------------------------------------------------------------------------------------
-- 5.7 源侧结果落库
--
-- requested → confirmed / failed / cancelled。
--
-- confirmed 之后可以出券（票码由调用方给出），并把订单状态交给唯一实现推导。
-- p_issue_voucher = false 用于「源先确认、票后到」的场景：
-- 先把订单推进到 confirmed，等票到了再调 fn_issue_voucher。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_complete_booking(
    p_booking_id        BIGINT,
    p_status            TEXT,
    p_external_booking_id TEXT DEFAULT NULL,
    p_response          JSONB DEFAULT '{}'::jsonb,
    p_error_code        TEXT DEFAULT NULL,
    p_error_message     TEXT DEFAULT NULL,
    p_codes             TEXT[] DEFAULT NULL,
    p_issue_voucher     BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    booking_id   BIGINT,
    booking_no   TEXT,
    status       TEXT,
    voucher_id   BIGINT,
    voucher_no   TEXT,
    voucher_count INT,
    order_status TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_booking    RECORD;
    v_order      RECORD;
    v_voucher_id BIGINT;
    v_voucher_no TEXT;
    v_voucher_count INT;
    v_order_status TEXT;
BEGIN
    IF p_status NOT IN ('confirmed', 'failed', 'cancelled') THEN
        RAISE EXCEPTION '预订结果只能是 confirmed / failed / cancelled，收到 %', p_status;
    END IF;

    SELECT b.id, b.booking_no, b.order_id, b.order_item_id, b.status, b.external_booking_id
      INTO v_booking
      FROM booking b
     WHERE b.id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 不存在', p_booking_id;
    END IF;

    IF v_booking.status <> 'requested' THEN
        RAISE EXCEPTION '预订 % 当前状态 % 不能落结果（只允许 requested）',
          v_booking.booking_no, v_booking.status;
    END IF;

    -- 确认的预订必须带源侧预订号（不变量 7）。
    -- 没有它就无法回头找源对账：出问题时连「找哪一笔」都做不到。
    -- 在写路径上挡，比等不变量事后报警强。
    IF p_status = 'confirmed'
       AND COALESCE(p_external_booking_id, v_booking.external_booking_id) IS NULL THEN
        RAISE EXCEPTION '预订 % 确认时必须给源侧预订号（external_booking_id），否则无法与源对账',
          v_booking.booking_no;
    END IF;

    UPDATE booking
       SET status             = p_status,
           external_booking_id = COALESCE(p_external_booking_id, external_booking_id),
           response_payload    = COALESCE(p_response, response_payload),
           error_code          = COALESCE(p_error_code, error_code),
           error_message       = COALESCE(p_error_message, error_message),
           confirmed_at        = CASE WHEN p_status = 'confirmed' THEN now() ELSE confirmed_at END,
           cancelled_at        = CASE WHEN p_status = 'cancelled' THEN now() ELSE cancelled_at END
     WHERE id = v_booking.id;

    -- 明细状态：源确认了就是 confirmed（票出了才是 ticketed）
    IF p_status = 'confirmed' THEN
        UPDATE sales_order_item oi
           SET status = 'confirmed'
         WHERE oi.id = v_booking.order_item_id
           AND oi.status IN ('pending', 'booking');
    END IF;

    -- confirmed 就出券（票码由调用方给出；不给就用我们自己的券号）
    v_voucher_count := 0;
    IF p_status = 'confirmed' AND p_issue_voucher THEN
        SELECT count(*), min(f.voucher_id), min(f.voucher_no)
          INTO v_voucher_count, v_voucher_id, v_voucher_no
          FROM fn_issue_voucher(v_booking.id, p_codes) AS f;
    END IF;

    -- 订单状态由唯一实现推导
    SELECT f.order_status INTO v_order_status
      FROM fn_apply_order_fulfillment(v_booking.order_id) f;

    booking_id   := v_booking.id;
    booking_no   := v_booking.booking_no;
    status       := p_status;
    voucher_id   := v_voucher_id;
    voucher_no   := v_voucher_no;
    voucher_count := v_voucher_count;
    order_status := v_order_status;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_complete_booking IS '源侧结果落库：requested → confirmed/failed/cancelled；confirmed 可出券；订单状态交给唯一实现推导';

-- -------------------------------------------------------------------------------------
-- 5.8 失败重报
--
-- failed → pending，并设 next_retry_at。触发器落 BookingRetryScheduled。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_retry_booking(p_booking_id BIGINT, p_next_retry_at TIMESTAMPTZ DEFAULT NULL)
RETURNS TABLE (
    booking_id BIGINT,
    booking_no TEXT,
    status     TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_booking RECORD;
BEGIN
    SELECT b.id, b.booking_no, b.status INTO v_booking
      FROM booking b
     WHERE b.id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 不存在', p_booking_id;
    END IF;

    IF v_booking.status <> 'failed' THEN
        RAISE EXCEPTION '预订 % 当前状态 % 不能重报（只允许 failed）',
          v_booking.booking_no, v_booking.status;
    END IF;

    UPDATE booking
       SET status        = 'pending',
           next_retry_at = COALESCE(p_next_retry_at, now() + interval '5 minutes'),
           error_code    = NULL,
           error_message = NULL
     WHERE id = v_booking.id;

    booking_id := v_booking.id;
    booking_no := v_booking.booking_no;
    status     := 'pending';
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_retry_booking IS '失败重报：failed → pending 并设 next_retry_at';

-- -------------------------------------------------------------------------------------
-- 5.9 履约侧不变量（55-60）
--
-- 单独一个视图，总视图做并集 —— 抄一遍旧的不变量就会分叉，分叉的门禁等于没有门禁。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_fulfill AS
WITH item_state AS (
    SELECT oi.order_id,
           oi.id AS item_id,
           oi.quantity,
           COALESCE((
             SELECT sum(ve.quantity)
               FROM voucher_entitlement ve
               JOIN voucher v ON v.id = ve.voucher_id
              WHERE v.order_item_id = oi.id
                AND v.status IN ('issued', 'used')
                AND ve.entitlement_type = 'admission'), 0) AS delivered
      FROM sales_order_item oi
), raw (seq, check_name, actual) AS (
    -- 55：支付金额必须等于订单应付。
    SELECT 55, '支付金额必须等于订单应付金额',
           (SELECT count(*)
              FROM sales_payment sp
              JOIN sales_order o ON o.id = sp.order_id
             WHERE sp.status = 'succeeded'
               AND sp.amount <> o.total)
    UNION ALL
    -- 56：订单说已支付，就必须有一笔成功的支付记录（状态与事实一致）。
    SELECT 56, '已支付订单必须有成功的支付记录',
           (SELECT count(*)
              FROM sales_order o
             WHERE o.payment_status = 'paid'
               AND NOT EXISTS (SELECT 1 FROM sales_payment sp
                                WHERE sp.order_id = o.id AND sp.status = 'succeeded'))
    UNION ALL
    -- 57：已确认 / 已履约订单的**每一条明细**都要有 confirmed/ticketed 的预订
    --     （不变量 50 只看订单级有没有，这里看逐行）。
    SELECT 57, '已确认订单的每条明细都必须有 confirmed/ticketed 的预订',
           (SELECT count(*)
              FROM sales_order o
             WHERE o.status IN ('confirmed', 'fulfilled')
               AND EXISTS (
                     SELECT 1 FROM sales_order_item oi
                      WHERE oi.order_id = o.id
                        AND NOT EXISTS (SELECT 1 FROM booking b
                                         WHERE b.order_item_id = oi.id
                                           AND b.status IN ('confirmed', 'ticketed'))))
    UNION ALL
    -- 58：预订的源必须等于明细的采纳源（不能换源出票）。
    --     改派备源不是「换源出票」，而是重下一行明细并重新定价。
    SELECT 58, '预订的源必须等于订单明细的采纳源',
           (SELECT count(*)
              FROM booking b
              JOIN sales_order_item oi ON oi.id = b.order_item_id
             WHERE b.supplier_id IS DISTINCT FROM oi.supplier_id
                OR b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id)
    UNION ALL
    -- 59：预订的源场次必须来自场次级绑定（规范场次 ↔ 源场次 ↔ 源商品）。
    --     按日期猜出来的源场次能对上日期，对不上场次。
    SELECT 59, '预订的源场次必须绑定在该明细的规范场次上',
           (SELECT count(*)
              FROM booking b
              JOIN sales_order_item oi ON oi.id = b.order_item_id
             WHERE b.supplier_session_id IS NULL
                OR NOT EXISTS (
                     SELECT 1 FROM product_session_source pss
                      WHERE pss.product_session_id = oi.session_id
                        AND pss.supplier_product_id = b.supplier_product_id
                        AND pss.supplier_id = b.supplier_id
                        AND pss.supplier_session_id = b.supplier_session_id))
    UNION ALL
    -- 60：订单的履约状态必须与明细的出票情况一致（状态是结论，结论只有一个算法）。
    SELECT 60, '订单的履约状态必须与明细的出票情况一致',
           (SELECT count(*)
              FROM sales_order o
             WHERE (
                     -- 已履约：每条明细的份数都要发齐
                     (o.status = 'fulfilled'
                      AND EXISTS (SELECT 1 FROM item_state s
                                   WHERE s.order_id = o.id AND s.delivered < s.quantity))
                     -- 部分履约：至少要发出一点
                  OR (o.status = 'partially_fulfilled'
                      AND COALESCE((SELECT sum(s.delivered) FROM item_state s
                                     WHERE s.order_id = o.id), 0) = 0)
                     -- 还在履约中却已经发齐了：状态没跟上
                  OR (o.status IN ('booking_pending', 'confirmed', 'partially_fulfilled')
                      AND EXISTS (SELECT 1 FROM item_state s WHERE s.order_id = o.id)
                      AND NOT EXISTS (SELECT 1 FROM item_state s
                                       WHERE s.order_id = o.id AND s.delivered < s.quantity))))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_fulfill IS '履约侧不变量（55-60）：支付、预订、出券与订单履约状态的一致性';

-- 总视图：并集（每个方向一个视图，加新方向不用抄旧的不变量）
CREATE OR REPLACE VIEW v_invariant_checks AS
    SELECT * FROM v_invariant_checks_core
    UNION ALL
    SELECT * FROM v_invariant_checks_tx
    UNION ALL
    SELECT * FROM v_invariant_checks_order
    UNION ALL
    SELECT * FROM v_invariant_checks_fulfill;

COMMENT ON VIEW v_invariant_checks IS '全部 60 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
