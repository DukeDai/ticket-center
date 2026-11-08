-- =====================================================================================
-- 008 核销写路径（voucher redemption）
--
-- 前面三段写路径（下单 / 履约 / 退款）都有唯一实现，核销这一段以前只有状态和表，
-- 没有写路径 —— 票发出去就没人能用了；退款里「有已核销的票不许整单退」那条分支
-- 也永远走不到（没有东西能把票变成 used）。
--
-- 这一段的口径写死在这里：
--
--   1. 一次核销 = 一次扫票。核销记录永远追加，不覆盖、不去重 ——
--      重复扫票本身就是事实（票务欺诈的入口），压掉就看不见了。
--   2. 状态效果幂等：一张券最多成功核销一次，靠唯一索引兜底，不靠调用方自觉。
--      第二次扫同一张券 → result='duplicate'，并带回第一次核销的记录，
--      调用方据此对账（网络重试和恶意重复扫码在这里是同一件事，不该分成两条路）。
--   3. 额度一次用尽：一人一券的券一次扫一张（消耗 1），整团一券的券一次扫全团
--      （消耗整份额度）。核销成功后券从 issued 变 used（触发器落 VoucherRedeemed）。
--      前提是凭证是一次性的入场凭证 —— 多次入场的通票还没进模型，
--      真要支持，这一条要重新设计（额度不该被一次扫票用尽）。
--   4. 过期 / 作废 / 未出票的券不许核销，但都要落一条记录并说清原因 ——
--      「为什么这张票进不去」是闸机和客服都要看到的事实。
--   5. 正在退款的订单不认核销：钱在退的时候把人放进去，退款就退不干净。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 表结构补齐
--
-- reason：核销没成功的原因（未出票 / 过期 / 额度用尽 / 订单在退款…）。result 只有五档，
--         细分原因放这里 —— 闸机要告诉人「券还没出」，客服要查「为什么进不去」。
-- consumed_quantity：这次核销实际消耗的额度（按人是 1，按团是整团人数）。
--         记在核销记录上，是为了跟券的额度账对得上（不变量 67）。
-- -------------------------------------------------------------------------------------
ALTER TABLE voucher_redemption ADD COLUMN reason TEXT;
ALTER TABLE voucher_redemption ADD COLUMN consumed_quantity INTEGER NOT NULL DEFAULT 0;

ALTER TABLE voucher_redemption
    ADD CONSTRAINT voucher_redemption_consumed_ck CHECK (consumed_quantity >= 0);

COMMENT ON COLUMN voucher_redemption.reason IS '核销未成功的原因（result<>success 时有意义）';
COMMENT ON COLUMN voucher_redemption.consumed_quantity IS '本次核销消耗的入场额度';

-- -------------------------------------------------------------------------------------
-- ② 一张券最多成功核销一次
--
-- 唯一索引是机制保证，不是约定。两个闸机同时扫同一张券时，
-- 索引挡住第二条 success —— 重复入场是票务欺诈的入口，不能靠「先查后改」防。
-- 扫描记录照旧两条都留（一次 success + 一次 duplicate），事实不丢。
-- -------------------------------------------------------------------------------------
CREATE UNIQUE INDEX ux_redemption_single_success
    ON voucher_redemption (voucher_id)
 WHERE result = 'success';

COMMENT ON INDEX ux_redemption_single_success IS '一张凭证最多成功核销一次（重复入场由机制挡住）';

-- -------------------------------------------------------------------------------------
-- ③ 核销的唯一实现
--
-- 返回值是一张「这次扫票的结果」，不是异常：
--   success   核销成功，券已用尽
--   duplicate 这张券之前已经成功核销过（带 original_redemption_id 供对账）
--   expired   过期了
--   revoked   作废 / 已退款
--   failed    没过（未出票 / 还没到有效期 / 额度用尽 / 订单在退款 / 闸机停用）
--
-- 查不到券（票码不存在、不唯一）是调用方的问题，不是扫票的结果 —— 那类情况报错，
-- 因为 voucher_redemption.voucher_id NOT NULL，没法为一张不存在的券记一条扫描。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_redeem_voucher(
    p_voucher_id       BIGINT DEFAULT NULL,
    p_code             TEXT   DEFAULT NULL,
    p_gate_id          BIGINT DEFAULT NULL,
    p_gate_operator_id BIGINT DEFAULT NULL,
    p_device_id        TEXT   DEFAULT NULL,
    p_operator_id      TEXT   DEFAULT NULL,
    p_payload          JSONB  DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    redemption_id          BIGINT,
    voucher_id             BIGINT,
    voucher_no             TEXT,
    result                 TEXT,
    reason                 TEXT,
    voucher_status         TEXT,
    consumed_quantity      INTEGER,
    remaining_quantity     INTEGER,
    original_redemption_id BIGINT,
    original_scanned_at    TIMESTAMPTZ
)
LANGUAGE plpgsql AS $$
DECLARE
    v_voucher      RECORD;
    v_order        RECORD;
    v_ent          RECORD;
    v_ids          BIGINT[];
    v_gate_loc     TEXT;
    v_gate_status  TEXT;
    v_gate_supplier BIGINT;
    v_gate_ok      BOOLEAN := TRUE;
    v_channel      TEXT;
    v_consume      INTEGER := 0;
    v_remaining    INTEGER := 0;
    v_qty          INTEGER := 0;
    v_result       TEXT;
    v_reason       TEXT;
    v_redemption   BIGINT;
    v_orig_id      BIGINT;
    v_orig_at      TIMESTAMPTZ;
    v_scan_at      TIMESTAMPTZ := now();
BEGIN
    IF p_voucher_id IS NULL AND (p_code IS NULL OR btrim(p_code) = '') THEN
        RAISE EXCEPTION '核销需要凭证 id 或票码';
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 闸机
    --
    -- 闸机先查：票码撞车时要用闸机所属的源来收窄候选集。
    -- ---------------------------------------------------------------------------------
    IF p_gate_id IS NOT NULL THEN
        SELECT g.location_name, g.status, g.supplier_id
          INTO v_gate_loc, v_gate_status, v_gate_supplier
          FROM gate g
         WHERE g.id = p_gate_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION '闸机 % 不存在', p_gate_id;
        END IF;
        -- 停用的闸机不认票：闸机撤了、临时封了，票不该从这儿进。
        IF v_gate_status <> 'active' THEN
            v_gate_ok := FALSE;
        END IF;
    END IF;

    IF p_gate_operator_id IS NOT NULL THEN
        PERFORM 1 FROM gate_operator go WHERE go.id = p_gate_operator_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION '闸机操作员 % 不存在', p_gate_operator_id;
        END IF;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 找券
    --
    -- 票码在不同源之间可能撞车（两个源各自发了一串同样的数字），
    -- 所以票码不唯一时按闸机所属的源收窄；还收窄不出来就报错，
    -- 不能猜一张 —— 猜错就是「拿 A 源的票进了 B 源的场」。
    -- ---------------------------------------------------------------------------------
    IF p_voucher_id IS NOT NULL THEN
        SELECT v.id, v.voucher_no, v.status, v.supplier_id, v.order_id,
               v.order_item_id, v.valid_from, v.valid_to
          INTO v_voucher
          FROM voucher v
         WHERE v.id = p_voucher_id
         FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION '凭证 % 不存在', p_voucher_id;
        END IF;
    ELSE
        SELECT array_agg(v.id)
          INTO v_ids
          FROM voucher v
         WHERE v.code      = btrim(p_code)
            OR v.barcode   = btrim(p_code)
            OR v.qr_payload = btrim(p_code);

        IF array_length(v_ids, 1) IS NULL THEN
            RAISE EXCEPTION '票码 % 不存在', p_code;
        END IF;

        IF array_length(v_ids, 1) > 1 AND v_gate_supplier IS NOT NULL THEN
            SELECT array_agg(v.id)
              INTO v_ids
              FROM voucher v
             WHERE v.id = ANY(v_ids)
               AND (v.supplier_id = v_gate_supplier OR v.supplier_id IS NULL);
        END IF;

        IF array_length(v_ids, 1) IS NULL THEN
            RAISE EXCEPTION '票码 % 命中多张凭证，且与闸机所属的源都不匹配', p_code;
        END IF;
        IF array_length(v_ids, 1) > 1 THEN
            RAISE EXCEPTION '票码 % 不唯一（命中 % 张凭证），无法确定是哪一张',
              p_code, array_length(v_ids, 1);
        END IF;

        SELECT v.id, v.voucher_no, v.status, v.supplier_id, v.order_id,
               v.order_item_id, v.valid_from, v.valid_to
          INTO v_voucher
          FROM voucher v
         WHERE v.id = v_ids[1]
         FOR UPDATE;
    END IF;

    v_result := NULL;
    v_reason := NULL;

    -- ---------------------------------------------------------------------------------
    -- 这张券现在是什么状态
    -- ---------------------------------------------------------------------------------
    IF v_gate_ok = FALSE THEN
        v_result := 'failed';
        v_reason := 'gate_inactive';
    ELSE
        CASE v_voucher.status
            WHEN 'used'     THEN v_result := 'duplicate'; v_reason := 'already_redeemed';
            WHEN 'void'     THEN v_result := 'revoked';  v_reason := 'voucher_void';
            WHEN 'refunded' THEN v_result := 'revoked';  v_reason := 'voucher_refunded';
            WHEN 'expired'  THEN v_result := 'expired';  v_reason := 'voucher_expired';
            WHEN 'pending'  THEN v_result := 'failed';   v_reason := 'voucher_not_issued';
            WHEN 'issued'   THEN NULL;
            ELSE v_result := 'failed';                   v_reason := 'voucher_status_' || v_voucher.status;
        END CASE;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 有效期
    --
    -- 过期只落核销记录，不改券状态 —— 券状态由过期作业统一改。
    -- 一件事一件事分开，才说得清是谁在什么时候把哪张票判成什么。
    -- ---------------------------------------------------------------------------------
    IF v_result IS NULL THEN
        IF v_voucher.valid_from IS NOT NULL AND v_scan_at < v_voucher.valid_from THEN
            v_result := 'failed';
            v_reason := 'not_yet_valid';
        ELSIF v_voucher.valid_to IS NOT NULL AND v_scan_at >= v_voucher.valid_to THEN
            v_result := 'expired';
            v_reason := 'past_valid_to';
        END IF;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 订单在退款中 → 不认核销
    --
    -- 这里刻意不锁订单行：退款路径的加锁顺序是「订单 → 凭证」，
    -- 这边再锁订单就是反序，并发时死锁。读一次快照判断即可 ——
    -- 万一退款在核销之后发起，退款路径会撞上「有已核销的票」并要求人工处理，
    -- 两边不可能同时放行。
    -- ---------------------------------------------------------------------------------
    IF v_result IS NULL THEN
        SELECT o.id, o.order_no, o.status, o.channel_id
          INTO v_order
          FROM sales_order o
         WHERE o.id = v_voucher.order_id;

        IF FOUND THEN
            IF v_order.status = 'refunding' THEN
                v_result := 'failed';
                v_reason := 'order_refunding';
            END IF;
            SELECT c.code INTO v_channel FROM channel c WHERE c.id = v_order.channel_id;
        END IF;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 消耗额度
    --
    -- 一次核销用尽这张券的全部入场额度：一人一券的券一次扫一张（额度 1），
    -- 整团一券的券一次扫全团（额度 = 团人数）。
    -- 额度行锁住，避免两个闸机同时扫同一张券各扣一次。
    -- ---------------------------------------------------------------------------------
    IF v_result IS NULL THEN
        FOR v_ent IN
            SELECT e.id, e.entitlement_type, e.quantity, e.consumed_quantity
              FROM voucher_entitlement e
             WHERE e.voucher_id = v_voucher.id
             ORDER BY e.id
             FOR UPDATE
        LOOP
            v_qty := v_qty + v_ent.quantity;
            IF v_ent.consumed_quantity < v_ent.quantity THEN
                v_consume := v_consume + (v_ent.quantity - v_ent.consumed_quantity);
            END IF;
        END LOOP;

        IF v_qty = 0 THEN
            v_result := 'failed';
            v_reason := 'no_entitlement';
        ELSIF v_consume = 0 THEN
            v_result := 'failed';
            v_reason := 'entitlement_exhausted';
        ELSE
            UPDATE voucher_entitlement e
               SET consumed_quantity = e.quantity
             WHERE e.voucher_id = v_voucher.id;

            v_consume   := v_qty;
            v_result    := 'success';
        END IF;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 券改成已核销
    --
    -- 触发器 fn_guard_state_transition 挡住非法流转，
    -- fn_emit_state_event 保证状态一变就落一条 VoucherRedeemed 领域事件。
    --
    -- used_channel 记的是这张券所属订单的销售渠道（channel.code）——
    -- 核销口径要能按渠道对账；闸机 / 操作员 / 设备另记在 voucher_redemption 上。
    -- ---------------------------------------------------------------------------------
    IF v_result = 'success' THEN
        UPDATE voucher v
           SET status       = 'used',
               used_at      = v_scan_at,
               used_channel = v_channel
         WHERE v.id = v_voucher.id;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- 落核销记录（每一次扫票都落，成功失败都落）
    -- ---------------------------------------------------------------------------------
    INSERT INTO voucher_redemption (voucher_id, supplier_id, result, scanned_at,
                                   gate_location, device_id, operator_id, payload,
                                   gate_id, gate_operator_id, reason, consumed_quantity)
    VALUES (v_voucher.id, v_voucher.supplier_id, v_result, v_scan_at,
            v_gate_loc, p_device_id, p_operator_id,
            COALESCE(p_payload, '{}'::jsonb), p_gate_id, p_gate_operator_id,
            v_reason, CASE WHEN v_result = 'success' THEN v_consume ELSE 0 END)
    RETURNING id INTO v_redemption;

    -- 重复扫票：把第一次成功核销的记录带回去，调用方据此对账
    -- （网络重试丢了响应，和恶意重复扫码，在这里是同一件事）。
    IF v_result = 'duplicate' THEN
        SELECT r.id, r.scanned_at
          INTO v_orig_id, v_orig_at
          FROM voucher_redemption r
         WHERE r.voucher_id = v_voucher.id
           AND r.result = 'success'
         ORDER BY r.scanned_at, r.id
         LIMIT 1;
    END IF;

    -- 这张券现在还剩多少额度（成功核销后是 0；没过的核销不消耗额度）。
    SELECT COALESCE(sum(e.quantity - e.consumed_quantity), 0)
      INTO v_remaining
      FROM voucher_entitlement e
     WHERE e.voucher_id = v_voucher.id;

    redemption_id          := v_redemption;
    voucher_id             := v_voucher.id;
    voucher_no             := v_voucher.voucher_no;
    result                 := v_result;
    reason                 := v_reason;
    voucher_status         := (SELECT v2.status FROM voucher v2 WHERE v2.id = v_voucher.id);
    consumed_quantity      := CASE WHEN v_result = 'success' THEN v_consume ELSE 0 END;
    remaining_quantity     := v_remaining;
    original_redemption_id := v_orig_id;
    original_scanned_at    := v_orig_at;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_redeem_voucher IS
    '核销的唯一实现：一次扫票一条记录，成功则券从 issued 变 used 并用尽入场额度；重复扫码记 duplicate 不覆盖事实';

-- -------------------------------------------------------------------------------------
-- ④ 核销侧不变量（65-68）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_redemption AS
WITH raw (seq, check_name, actual) AS (
    -- 65：标着已核销的券必须有一条成功的核销记录 —— 状态与事实不许分叉。
    SELECT 65, '已核销的凭证必须有一条成功的核销记录',
           (SELECT count(*)
              FROM voucher v
             WHERE v.status = 'used'
               AND NOT EXISTS (SELECT 1 FROM voucher_redemption r
                                WHERE r.voucher_id = v.id AND r.result = 'success'))
    UNION ALL
    -- 66：一张券最多成功核销一次 —— 重复入场是票务欺诈的入口。
    SELECT 66, '一张凭证最多只能成功核销一次',
           (SELECT count(*)
              FROM (SELECT r.voucher_id
                      FROM voucher_redemption r
                     WHERE r.result = 'success'
                     GROUP BY r.voucher_id
                    HAVING count(*) > 1) x)
    UNION ALL
    -- 67：一次核销把整张券的入场额度用尽，而且额度账要跟核销记录对得上。
    SELECT 67, '成功核销必须用尽该凭证的入场额度且额度账对得上',
           (SELECT count(*)
              FROM voucher_redemption r
             WHERE r.result = 'success'
               AND (r.consumed_quantity <> (SELECT COALESCE(sum(e.quantity), 0)
                                              FROM voucher_entitlement e
                                             WHERE e.voucher_id = r.voucher_id)
                 OR (SELECT COALESCE(sum(e.consumed_quantity), 0)
                       FROM voucher_entitlement e
                      WHERE e.voucher_id = r.voucher_id)
                    <> (SELECT COALESCE(sum(e.quantity), 0)
                          FROM voucher_entitlement e
                         WHERE e.voucher_id = r.voucher_id)))
    UNION ALL
    -- 68：成功核销必须落在券的有效期内 —— 券没到日子就进不了场。
    SELECT 68, '成功核销必须发生在凭证的有效期内',
           (SELECT count(*)
              FROM voucher_redemption r
              JOIN voucher v ON v.id = r.voucher_id
             WHERE r.result = 'success'
               AND ((v.valid_from IS NOT NULL AND r.scanned_at < v.valid_from)
                 OR (v.valid_to   IS NOT NULL AND r.scanned_at >= v.valid_to)))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_redemption IS '核销侧不变量（65-68）：核销记录与凭证状态、额度、有效期的一致性';

-- -------------------------------------------------------------------------------------
-- ⑤ 总视图：并集
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
    SELECT * FROM v_invariant_checks_redemption;

COMMENT ON VIEW v_invariant_checks IS '全部 68 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
