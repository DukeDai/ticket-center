-- 006_duplicate_payment_guard.sql
--
-- 重复收款守卫。
--
-- 问题：fn_record_payment 的「已付过就不再付一次」那一支，只看订单的 payment_status，
-- 不看这次进来的是不是**同一笔**渠道流水。于是：
--
--   1. 订单 A 已付（流水 T1）
--   2. 用户又付了一次（流水 T2），渠道回调把 T2 送进来
--   3. 函数返回「幂等命中，本次未新记」
--   4. 库里只有 T1 这一笔支付记录
--
-- 钱收了两次，库里记了一次 —— 这笔钱在对账时凭空消失，而系统一声不吭。
-- 「幂等」只该覆盖**重放同一笔**，不该覆盖**真收了两笔**。
--
-- 口径：
--   - 同一笔流水重放（provider + provider_txn_id 相同）→ 幂等命中，照旧返回原记录；
--   - 另一笔流水打进来（provider_txn_id 不同）→ 报错，让人走退款流程；
--   - 没给流水号 → 无法判断，照旧按幂等命中处理（不猜）。
--
-- 为什么不写进 005：005 已经在库里应用过了，改它等于内容漂移。
-- 「DDL 只增不改」这条规矩自己也得守。

-- -------------------------------------------------------------------------------------
-- fn_record_payment 的新实现（只有幂等二那一支变了，其余与 005 一致）
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_record_payment(
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
        SELECT sp.id, sp.provider_txn_id INTO v_existing
          FROM sales_payment sp
         WHERE sp.order_id = v_order.id AND sp.status = 'succeeded'
         LIMIT 1;

        IF NOT FOUND THEN
            RAISE EXCEPTION '订单 % 标记为已支付，但没有成功的支付记录（数据不自洽）',
              v_order.order_no;
        END IF;

        -- 同一笔流水重放 → 幂等命中（上面那一支已经处理掉了，这里到不了）。
        -- **另一笔**流水又打进来 = 重复收款：钱收了两次，库里只记一笔，
        -- 对账时这笔钱会凭空消失。宁可当场报错让人走退款，也别悄悄吞掉。
        IF p_provider_txn_id IS NOT NULL
           AND v_existing.provider_txn_id IS DISTINCT FROM p_provider_txn_id THEN
            RAISE EXCEPTION '订单 % 已支付（流水 %），又收到一笔新流水 %：重复收款，需要走退款流程',
              v_order.order_no, v_existing.provider_txn_id, p_provider_txn_id;
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

COMMENT ON FUNCTION fn_record_payment IS '支付入账的唯一实现：金额必须等于订单应付，幂等按渠道流水；重复收款报错；订单状态与支付状态一起推进';
