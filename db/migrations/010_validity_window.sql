-- =====================================================================================
-- 010 有效期口径（validity window）
--
-- 到这一步为止，异构产品的差异在**轴**这一层已经表达清楚了：
-- 一个源 SKU 覆盖哪些轴取值、对应哪个可售单元，coverage + fn_variant_covered 说了算。
--
-- 但差异在**下游**被抹平了。
--
-- 举个真例子：USJ 有单日票（pass_type=1d）和两日票（pass_type=2d）。
-- 源侧 zowoyoo 的 ZWO-2D-BASE 确实是个两日票，源侧场次也只在 2026-11-19 一天。
-- 我们的规范场次是「(商品, 日期, 时段)」一行 —— 单日票和两日票共用同一个场次。
--
-- 而出券写死的是「场次当天 + 1 天」：
--
--     valid_to = session_date + 1
--
-- 结果：卖了两日票，发出来的券只管 2026-11-19 一天。
-- 客户第二天拿着付过钱的票到门口，闸机判 expired ——
-- 钱收了、票买了、门不认。这是本项目里最贵的一种 bug（客诉 + 赔付 + 平台罚款）。
--
-- 这一段的口径写死在这里：
--
--   1. **有效期长度是数据，不是代码**：轴选项上带 valid_days（1d → 1，2d → 2）。
--      轴选项本来就是「产品的差异维度」，有效期是差异维度之一 ——
--      让它进轴，而不是塞进某个函数里的常量。
--   2. **口径只有一处**：fn_variant_validity_days 读轴选项；出券只调它。
--      不在出券里写死 +1，也不在 Go 侧算。
--   3. **不许有歧义**：一个变体不能同时挂两个取值不同的 valid_days（不变量 73）。
--      有歧义就当场报出来，不猜。
--   4. **券不得短于产品承诺**：已发出的券必须覆盖该变体的有效期天数（不变量 74）。
--      这是防止「哪天又有人写回 +1」的门禁。
--   5. **源侧能不能兑现是选源时定的**：源变体能不能装配出这个可售单元，
--      由 fn_variant_covered 判断（coverage 里必须含对应的取值）。
--      卖了之后这条不许变 —— 不变量 75 复查「实际用的那个源」是不是还覆盖得住。
--
-- 为什么不写进 005：005 已经在库里应用过了，改它等于内容漂移，
-- 迁移引擎会直接拒绝继续跑。「DDL 只增不改」这条规矩自己也得守 ——
-- 所以 fn_issue_voucher 在这里整体替换一次（与 006 / 009 同一个套路）。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 表结构补齐
--
-- valid_days 挂在轴选项上：有效期是产品的差异维度之一，
-- 而「差异维度」的载体在本仓库里就是轴（product_axis / product_axis_option）。
-- 挂在别处（商品上、变体上）都会和轴打架 —— 同一个事实两处写，迟早分叉。
--
-- 为什么不是继续放在 option_attrs 里：option_attrs 是自由袋子，
-- valid_days 是要被计算、要被门禁断言的事实 —— 它得有自己的类型和约束
-- （大于 0、不许两个值打架）。种子里原本把它塞在 option_attrs 里，
-- 没有任何函数读它 —— 事实存在但没人用，等于没有。
-- 现在它搬到列上，option_attrs 里的同名键一并去掉（一个事实只写一处）。
--
-- NULL = 这条轴不描述有效期（比如 park_scope）。一个变体可以一条都不带，
-- 这时按 1 天算（单日票的默认口径）。
-- -------------------------------------------------------------------------------------
ALTER TABLE product_axis_option ADD COLUMN valid_days INTEGER;
ALTER TABLE product_axis_option ADD CONSTRAINT product_axis_option_valid_days_ck
    CHECK (valid_days IS NULL OR valid_days > 0);

COMMENT ON COLUMN product_axis_option.valid_days IS
    '这条取值覆盖连续几天（如 1d → 1，2d → 2）。NULL = 这条轴不描述有效期';

-- 变体矩阵要继续带上有效期 —— 前端拿它渲染「有效几天」，不能因为搬了家就丢了。
CREATE OR REPLACE VIEW v_product_variant_matrix AS
SELECT
    pv.product_id,
    p.product_code,
    p.title AS product_title,
    pv.id AS product_variant_id,
    pv.variant_code,
    pv.variant_key,
    pv.title AS variant_title,
    pv.variant_role,
    tt.code AS ticket_type_code,
    tt.name AS ticket_type_name,
    (SELECT jsonb_agg(jsonb_build_object('axis', ax.axis_code, 'axis_name', ax.axis_name,
                                         'option', opt.option_code, 'option_name', opt.option_name,
                                         'attrs', opt.option_attrs,
                                         'valid_days', opt.valid_days)
                       ORDER BY ax.sort_order, opt.sort_order)
       FROM product_variant_option pvo
       JOIN product_axis ax ON ax.id = pvo.axis_id
       JOIN product_axis_option opt ON opt.id = pvo.axis_option_id
      WHERE pvo.product_variant_id = pv.id) AS axes,
    (SELECT count(*) FROM product_variant_relation r
      WHERE r.child_variant_id = pv.id AND r.relation_type = 'optional_addon') AS addon_count,
    pv.sort_order,
    pv.status
FROM product_variant pv
JOIN product p ON p.id = pv.product_id
LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id;

COMMENT ON VIEW v_product_variant_matrix IS '变体矩阵：一个商品下有哪些可售组合、每个组合的轴取值与可叠加加购件';

-- -------------------------------------------------------------------------------------
-- ② 有效期的唯一实现
--
-- 一个可售单元有效几天：它挂的轴选项上 valid_days 的最大值（没有就 1 天）。
--
-- 为什么取最大值而不是求和：有效期是「窗口有多长」，不是「各条轴各占几天」。
-- 要真出现两条轴都声明天数且取值不同的情况，那是不变量 73 要报出来的歧义，
-- 不是这里该猜的东西。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_variant_validity_days(p_variant_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(MAX(ao.valid_days), 1)
      FROM product_variant_option pvo
      JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
     WHERE pvo.product_variant_id = p_variant_id;
$$;

COMMENT ON FUNCTION fn_variant_validity_days(BIGINT) IS
    '可售单元的有效期天数（连续几天，从场次当天算起）：轴选项 valid_days 的唯一读法';

-- -------------------------------------------------------------------------------------
-- ③ 出券：券的有效期按可售单元的有效天数
--
-- 整体替换 fn_issue_voucher（005 已应用，改它等于内容漂移 —— 见文首）。
-- 改动只有一处：valid_to 从「场次当天 + 1 天」变成「场次当天 + 有效天数」。
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
    v_session    RECORD;
    v_existing   RECORD;
    v_expected   INT;
    v_have       INT;
    v_need       INT;
    v_voucher_no TEXT;
    v_code       TEXT;
    v_holders    JSONB;
    v_i          INT;
    -- 有效期天数（010）：可售单元有效几天，从场次当天算起。
    v_days       INT;
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

    -- 有效期天数：这个可售单元有效几天。
    --
    -- 为什么不是「1」：单日票有效 1 天，两日票有效 2 天 —— 这是产品的本质区别，
    -- 不是展示细节。写成 +1 的话，两日票会被发成只管一天的券，
    -- 客户第二天进不了场（钱收了、票买了、门不认）。
    --
    -- 天数从「轴选项」上读（valid_days），不写死成 1，也不从源报文猜 ——
    -- 口径只有一处，源侧能不能兑现由 fn_variant_covered 在选源时把关。
    v_days := fn_variant_validity_days(v_item.product_variant_id);

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

COMMENT ON FUNCTION fn_issue_voucher IS
    '出券的唯一实现：按人一人一券、按团整团一券；已发的券不重复发；票码必须与持票人一一对应；券的有效期按可售单元的有效天数（010）';

-- -------------------------------------------------------------------------------------
-- ④ 有效期窗口视图
--
-- C 端日历要用的是「这一天能玩到什么时候」：
-- 单日票 = 当天；两日票 = 当天到后天。
-- 这个视图是「日期 → 有效期窗口」的唯一读法，别在应用侧自己加减一天。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_variant_validity AS
SELECT DISTINCT pc.product_variant_id,
       pv.variant_code,
       pv.title AS variant_title,
       pc.date AS session_date,
       pc.date AS valid_from,
       (pc.date + fn_variant_validity_days(pc.product_variant_id))::date AS valid_to,
       fn_variant_validity_days(pc.product_variant_id) AS valid_days,
       COALESCE(ps.status, '') AS session_status
  FROM price_calendar pc
  JOIN product_variant pv ON pv.id = pc.product_variant_id
  LEFT JOIN product_session ps ON ps.id = pc.session_id
 WHERE pc.status = 'active';

COMMENT ON VIEW v_variant_validity IS
    '可售单元的有效期窗口：场次当天起算，连续 valid_days 天（异构产品之间最容易被抹平的一条差异）';

-- -------------------------------------------------------------------------------------
-- ⑤ 差异对照视图
--
-- 两个可售单元差在哪，要能一眼看出来 —— 这才是「异构产品融合」真正要交付的东西：
-- 同样一张票，A 源是单日、B 源是两日，或者 A 源不可退、B 源可退，
-- 这些差异必须落成结构化事实，而不是靠人对着源报文看。
--
-- 一行一个可售单元：身份、人群、轴取值、有效期、退款口径、关键属性、
-- 以及「有几个源能装配出它」（fulfilable_source_count < source_count
-- 就说明这个可售单元有些源根本卖不了 —— 这是差异，也是风险）。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_variant_comparison AS
SELECT pv.id AS product_variant_id,
       pv.variant_code,
       pv.title AS variant_title,
       pv.variant_role,
       pv.status AS variant_status,
       p.product_code,
       p.title AS product_title,
       COALESCE(p.country_code, '') AS country_code,
       COALESCE(tt.code, '') AS audience,
       (SELECT jsonb_object_agg(ax.axis_code, ao.option_code)
          FROM product_variant_option pvo
          JOIN product_axis ax ON ax.id = pvo.axis_id
          JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
         WHERE pvo.product_variant_id = pv.id) AS axes,
       fn_variant_validity_days(pv.id) AS valid_days,
       COALESCE(p.validity_rule->>'single_use', '') AS single_use,
       COALESCE(p.validity_rule->>'timezone', '') AS timezone,
       COALESCE((p.refund_policy->>'refundable')::boolean, FALSE) AS refundable,
       COALESCE((p.refund_policy->>'fee_percent')::numeric, 0) AS refund_fee_percent,
       COALESCE((p.refund_policy->>'cutoff_hours')::int, 0) AS refund_cutoff_hours,
       COALESCE((p.attributes->>'duration_minutes')::int, 0) AS duration_minutes,
       COALESCE((p.attributes->'age_limit'->>'min')::int, 0) AS age_limit_min,
       (SELECT count(*)
          FROM supplier_variant_mapping svm
         WHERE svm.product_variant_id = pv.id AND svm.status = 'active') AS source_count,
       (SELECT count(*)
          FROM supplier_variant_mapping svm
         WHERE svm.product_variant_id = pv.id AND svm.status = 'active'
           AND fn_variant_covered(svm.coverage, pv.id)) AS fulfilable_source_count,
       (SELECT array_agg(DISTINCT sup.code ORDER BY sup.code)
          FROM supplier_variant_mapping svm
          JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
          JOIN supplier_product sp ON sp.id = sv.supplier_product_id
          JOIN supplier sup ON sup.id = sp.supplier_id
         WHERE svm.product_variant_id = pv.id AND svm.status = 'active'
           AND fn_variant_covered(svm.coverage, pv.id)) AS suppliers
  FROM product_variant pv
  JOIN product p ON p.id = pv.product_id
  LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id;

COMMENT ON VIEW v_variant_comparison IS
    '可售单元的差异对照表：人群、轴取值、有效期、退款口径、可用源 —— 两个变体差在哪，一行看清';

-- -------------------------------------------------------------------------------------
-- ⑥ 不变量（73-75）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_validity AS
WITH raw (seq, check_name, actual) AS (
    -- 73：有效期口径不许有歧义 ——
    --     一个变体不能同时挂两个取值不同的 valid_days（比如 1d 和 3d）。
    --     有歧义说明数据错了，当场报出来，不猜哪个对。
    SELECT 73, '一个可售单元的有效期口径不许有歧义',
           (SELECT count(*)
              FROM (SELECT pvo.product_variant_id
                      FROM product_variant_option pvo
                      JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
                     WHERE ao.valid_days IS NOT NULL
                     GROUP BY pvo.product_variant_id
                    HAVING count(DISTINCT ao.valid_days) > 1) t)
    UNION ALL
    -- 74：券不得短于产品承诺 ——
    --     发出去的券必须覆盖这个可售单元的有效期天数。
    --     这条是「哪天又有人把 +1 写回去」的门禁：两日票发成一天，这里就红。
    SELECT 74, '已发出的券不得短于该可售单元承诺的有效期',
           (SELECT count(*)
              FROM voucher v
             WHERE v.product_variant_id IS NOT NULL
               AND v.valid_from IS NOT NULL
               AND v.valid_to IS NOT NULL
               AND EXTRACT(day FROM (v.valid_to - v.valid_from))::int
                   < fn_variant_validity_days(v.product_variant_id))
    UNION ALL
    -- 75：卖出去的订单必须是用「能装配出这个可售单元」的源出的 ——
    --     源侧能不能兑现是选源时定的（fn_route_candidates 里有 fn_variant_covered）。
    --     卖了之后这条不许变：改了 coverage 或撤了映射，历史订单不该跟着变 ——
    --     真变了（源侧下架了这个组合），走的是退款，不是把历史订单改成「当时就不该卖」。
    SELECT 75, '卖出去的订单必须是用能装配出该可售单元的源出的',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN booking b ON b.order_item_id = oi.id
             WHERE b.supplier_variant_id IS NOT NULL
               AND NOT EXISTS (
                     SELECT 1
                       FROM supplier_variant_mapping svm
                      WHERE svm.supplier_variant_id = b.supplier_variant_id
                        AND svm.product_variant_id = oi.product_variant_id
                        AND svm.status = 'active'
                        AND fn_variant_covered(svm.coverage, oi.product_variant_id)))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_validity IS
    '有效期侧不变量（73-75）：口径不歧义、券不短于承诺、卖出去的源覆盖得住';

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
    SELECT * FROM v_invariant_checks_refund
    UNION ALL
    SELECT * FROM v_invariant_checks_redemption
    UNION ALL
    SELECT * FROM v_invariant_checks_inventory
    UNION ALL
    SELECT * FROM v_invariant_checks_validity;

COMMENT ON VIEW v_invariant_checks IS '全部 75 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
