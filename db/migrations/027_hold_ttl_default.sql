-- 027 预占的存活秒数不许靠「省略参数」来给默认值
--
-- 009 的 fn_hold_inventory 里，p_ttl_seconds 的默认值是 900。
-- PostgreSQL 的 DEFAULT 只在**省略该实参**时生效；
-- 显式传 NULL 进去，拿到的是 NULL，不是 900。
--
-- 这个差别平时看不出来，一显式传 NULL 就炸：
--
--   v_hash := md5(... || p_ttl_seconds::text);   -- p_ttl_seconds 是 NULL
--   -- 整条 || 链变成 NULL → md5(NULL) 是 NULL
--   INSERT INTO idempotency_record (..., request_hash, ...)
--   VALUES (..., v_hash, 'in_progress');         -- request_hash NOT NULL → 报错
--
-- 表现是「预占刚开就被 NOT NULL 顶回来」，但根因跟幂等没关系：
-- 是默认值没生效。整个预占链路在预占这一步就断了，
-- 后面「明知不够当场报错」「不知道就不拦但留痕」那些口径根本没机会跑。
--
-- 为什么现在才暴露：Go 侧把「用户没指定 TTL」编码成 0，
-- 再把 0 翻译成 SQL 的 NULL 传进来（internal/inventory：
-- quoteOrNullInt —— 0 表示「用默认」）。所以
-- `tc-connect hold create` 不带 --ttl 一定失败，带 --ttl 900 才成功。
-- CLI 的 --help 里写着「0 表示用默认 900」，说的是「用默认」，
-- 实现给的是 NULL —— 两边说法不一致，文档就成了误导。
--
-- 修法：默认值在**函数里**兜住，不依赖调用方省略参数。
-- 函数体开头把 p_ttl_seconds 的 NULL 归一成 900，
-- 后面算哈希、写 expires_at 都用归一后的值。
--
-- 为什么不在 Go 侧改：Go 侧传 900 也只是「约定」，任何别的调用方
-- （脚本、报表、未来的写入路径）显式传 NULL 还是同一个坑。
-- 默认值是这条接口的合同，合同的默认值住在合同里 —— 库里。
--
-- 幂等键的口径不变：哈希里带的仍是归一后的 TTL，
-- 所以「同一个预占号 + 同一份内容」重放仍然命中同一张预占，
-- 「同一个预占号 + 不同的 TTL」仍然是另一笔请求，当场报错。
--
-- 门禁：新增不变量 119（落库的预占必须有确定的到期时间）。

-- -------------------------------------------------------------------------------------
-- ① 唯一实现：预占（009 建的，这里修默认值的落点）
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_hold_inventory(
    p_hold_no     TEXT,
    p_channel_id  BIGINT,
    p_variant_id  BIGINT,
    p_quantity    INTEGER,
    p_visit_date  DATE,
    p_cart_id     BIGINT DEFAULT NULL,
    p_ttl_seconds INTEGER DEFAULT 900
)
RETURNS TABLE (
    hold_id       BIGINT,
    hold_no       TEXT,
    known         BOOLEAN,
    available_qty INTEGER,
    committed_qty INTEGER,
    remaining_qty INTEGER,
    sold_qty      INTEGER,
    held_qty      INTEGER,
    source_status TEXT,
    created       BOOLEAN
)
LANGUAGE plpgsql AS $function$
DECLARE
    v_scope      TEXT;
    v_hash       TEXT;
    v_existing   RECORD;
    v_price      RECORD;
    v_price_row  RECORD;
    v_supplier_id BIGINT;
    v_sup_sess   BIGINT;
    v_avail      RECORD;
    v_hold_id    BIGINT;
    v_ttl        INTEGER;
BEGIN
    -- 默认值在函数里兜住：省略参数、显式传 NULL，都落到 900。
    -- （PostgreSQL 的 DEFAULT 只在省略实参时生效；显式传 NULL 拿到的是 NULL。）
    v_ttl := COALESCE(p_ttl_seconds, 900);

    IF p_hold_no IS NULL OR btrim(p_hold_no) = '' THEN
        RAISE EXCEPTION '缺少预占号：预占必须幂等';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION '预占数量不合法：%', p_quantity;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM channel c WHERE c.id = p_channel_id AND c.status = 'active') THEN
        RAISE EXCEPTION '渠道 % 不存在或不是 active', p_channel_id;
    END IF;

    -- 幂等：抢键
    v_scope := 'hold:' || p_channel_id::text;
    v_hash  := md5(p_variant_id::text || '|' || p_quantity::text || '|' || p_visit_date::text
                   || '|' || COALESCE(p_cart_id::text, '') || '|' || v_ttl::text);

    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_hold_no, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        SELECT ir.request_hash, ir.response INTO v_existing
          FROM idempotency_record ir
         WHERE ir.scope = v_scope AND ir.idempotency_key = p_hold_no;

        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔请求（预占 %）',
              p_hold_no, COALESCE(v_existing.response->>'hold_no', '?');
        END IF;

        SELECT h.id, h.hold_no INTO v_hold_id, p_hold_no
          FROM inventory_hold h
         WHERE h.hold_no = p_hold_no;

        IF v_hold_id IS NULL THEN
            RAISE EXCEPTION '预占 % 正在处理中，稍后重试', p_hold_no;
        END IF;

        SELECT * INTO v_avail
          FROM fn_available_qty(
                 (SELECT h.supplier_session_id FROM inventory_hold h WHERE h.id = v_hold_id),
                 (SELECT h.ticket_type_id FROM inventory_hold h WHERE h.id = v_hold_id));

        hold_id       := v_hold_id;
        hold_no       := p_hold_no;
        known         := v_avail.known;
        available_qty := v_avail.available_qty;
        committed_qty := v_avail.committed_qty;
        remaining_qty := v_avail.remaining_qty;
        sold_qty      := v_avail.sold_qty;
        held_qty      := v_avail.held_qty;
        source_status := v_avail.source_status;
        created       := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 选源：和下单走同一套（fn_price_variant 是选源 + 定价的唯一实现）
    SELECT * INTO v_price
      FROM fn_price_variant(p_variant_id, p_visit_date, p_channel_id, p_channel_id);

    IF NOT FOUND THEN
        RAISE EXCEPTION '变体 % 在 % 没有可售价格（商品未上架 / 当天无可用报价 / 成本无法折算）',
          p_variant_id, p_visit_date;
    END IF;

    -- 规范场次与票种（从价格日历借 id，不借金额）
    SELECT pc.session_id, pc.ticket_type_id INTO v_price_row
      FROM price_calendar pc
     WHERE pc.product_variant_id = p_variant_id
       AND pc.date = p_visit_date
       AND pc.status = 'active'
       AND (pc.channel_id = p_channel_id OR pc.channel_id IS NULL)
     ORDER BY (pc.channel_id IS NOT NULL) DESC, pc.id DESC
     LIMIT 1;

    -- 场次是 NOT NULL 的：没有场次就没法预占（库存挂在场次上）
    IF v_price_row.session_id IS NULL THEN
        RAISE EXCEPTION '变体 % 在 % 没有场次，无法预占', p_variant_id, p_visit_date;
    END IF;

    -- 源侧场次：库存数字挂在源场次上
    SELECT pss.supplier_session_id INTO v_sup_sess
      FROM product_session_source pss
     WHERE pss.product_session_id IS NOT DISTINCT FROM v_price_row.session_id
       AND pss.supplier_product_id = v_price.supplier_product_id
     LIMIT 1;

    SELECT sp.supplier_id INTO v_supplier_id
      FROM supplier_product sp
     WHERE sp.id = v_price.supplier_product_id;

    -- 预留：锁 → 算 → 明知不够就报错
    SELECT * INTO v_avail
      FROM fn_reserve_qty(v_sup_sess, v_price_row.ticket_type_id, p_quantity,
                           '变体 ' || p_variant_id::text || ' ' || p_visit_date::text);

    INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                supplier_id, product_variant_id, supplier_session_id,
                                quantity, consumed_quantity, status, cart_id, expires_at)
    VALUES (p_hold_no, p_channel_id, v_price_row.session_id, v_price_row.ticket_type_id,
            v_supplier_id, p_variant_id, v_sup_sess,
            p_quantity, 0, 'active', p_cart_id,
            now() + make_interval(secs => v_ttl))
    RETURNING id INTO v_hold_id;

    UPDATE idempotency_record
       SET status   = 'done',
           response = jsonb_build_object('hold_id', v_hold_id, 'hold_no', p_hold_no)
     WHERE scope = v_scope AND idempotency_key = p_hold_no;

    -- 预占已经落库，重新算一次：返回的是「这张预占占住之后」的数，
    -- 跟幂等重放时返回的口径一致。
    SELECT * INTO v_avail
      FROM fn_available_qty(v_sup_sess, v_price_row.ticket_type_id);

    hold_id       := v_hold_id;
    hold_no       := p_hold_no;
    known         := v_avail.known;
    available_qty := v_avail.available_qty;
    committed_qty := v_avail.committed_qty;
    remaining_qty := v_avail.remaining_qty;
    sold_qty      := v_avail.sold_qty;
    held_qty      := v_avail.held_qty;
    source_status := v_avail.source_status;
    created       := true;
    RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION fn_hold_inventory(TEXT, BIGINT, BIGINT, INTEGER, DATE, BIGINT, INTEGER)
    IS '购物车预占的唯一实现：预占号是幂等键，明知库存不够当场报错；存活秒数省略或传 NULL 都是 900';

-- -------------------------------------------------------------------------------------
-- ② 不变量 119：落库的预占必须有确定的到期时间
--
-- 「默认 900」这条约定只写在函数的 DEFAULT 上是不够的 ——
-- 显式传 NULL 会绕过 DEFAULT，然后把 NULL 顺着哈希链带进
-- idempotency_record.request_hash（NOT NULL），预占当场炸在第一步。
--
-- 这里守的是「expires_at 为 NULL 的预占永远不过期」：
-- 那是一个不会释放的库存占用 —— 库存池被慢慢吃光，
-- 源侧其实还有票，我们这边说不卖。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_hold_ttl AS
WITH raw(seq, check_name, actual) AS (
    -- 119：预占的到期时间不许是 NULL（NULL 的预占永远不过期）
    SELECT 119, '落库的预占必须有确定的到期时间',
           (SELECT count(*)
              FROM inventory_hold h
             WHERE h.expires_at IS NULL)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_hold_ttl IS
    '预占侧不变量（119）：落库的预占必须有确定的到期时间（NULL 的预占永远不过期）';

-- -------------------------------------------------------------------------------------
-- ③ 总表：加进 119
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks AS
    SELECT v_invariant_checks_core_017.seq,
           v_invariant_checks_core_017.check_name,
           v_invariant_checks_core_017.expected,
           v_invariant_checks_core_017.actual,
           v_invariant_checks_core_017.passed,
           v_invariant_checks_core_017.result
      FROM v_invariant_checks_core_017
    UNION ALL
    SELECT v_invariant_checks_tx.seq,
           v_invariant_checks_tx.check_name,
           v_invariant_checks_tx.expected,
           v_invariant_checks_tx.actual,
           v_invariant_checks_tx.passed,
           v_invariant_checks_tx.result
      FROM v_invariant_checks_tx
    UNION ALL
    SELECT v_invariant_checks_order.seq,
           v_invariant_checks_order.check_name,
           v_invariant_checks_order.expected,
           v_invariant_checks_order.actual,
           v_invariant_checks_order.passed,
           v_invariant_checks_order.result
      FROM v_invariant_checks_order
    UNION ALL
    SELECT v_invariant_checks_fulfill.seq,
           v_invariant_checks_fulfill.check_name,
           v_invariant_checks_fulfill.expected,
           v_invariant_checks_fulfill.actual,
           v_invariant_checks_fulfill.passed,
           v_invariant_checks_fulfill.result
      FROM v_invariant_checks_fulfill
    UNION ALL
    SELECT v_invariant_checks_refund.seq,
           v_invariant_checks_refund.check_name,
           v_invariant_checks_refund.expected,
           v_invariant_checks_refund.actual,
           v_invariant_checks_refund.passed,
           v_invariant_checks_refund.result
      FROM v_invariant_checks_refund
    UNION ALL
    SELECT v_invariant_checks_redemption.seq,
           v_invariant_checks_redemption.check_name,
           v_invariant_checks_redemption.expected,
           v_invariant_checks_redemption.actual,
           v_invariant_checks_redemption.passed,
           v_invariant_checks_redemption.result
      FROM v_invariant_checks_redemption
    UNION ALL
    SELECT v_invariant_checks_inventory_017.seq,
           v_invariant_checks_inventory_017.check_name,
           v_invariant_checks_inventory_017.expected,
           v_invariant_checks_inventory_017.actual,
           v_invariant_checks_inventory_017.passed,
           v_invariant_checks_inventory_017.result
      FROM v_invariant_checks_inventory_017
    UNION ALL
    SELECT v_invariant_checks_validity_017.seq,
           v_invariant_checks_validity_017.check_name,
           v_invariant_checks_validity_017.expected,
           v_invariant_checks_validity_017.actual,
           v_invariant_checks_validity_017.passed,
           v_invariant_checks_validity_017.result
      FROM v_invariant_checks_validity_017
    UNION ALL
    SELECT v_invariant_checks_readmodel.seq,
           v_invariant_checks_readmodel.check_name,
           v_invariant_checks_readmodel.expected,
           v_invariant_checks_readmodel.actual,
           v_invariant_checks_readmodel.passed,
           v_invariant_checks_readmodel.result
      FROM v_invariant_checks_readmodel
    UNION ALL
    SELECT v_invariant_checks_composition.seq,
           v_invariant_checks_composition.check_name,
           v_invariant_checks_composition.expected,
           v_invariant_checks_composition.actual,
           v_invariant_checks_composition.passed,
           v_invariant_checks_composition.result
      FROM v_invariant_checks_composition
    UNION ALL
    SELECT v_invariant_checks_combo_017.seq,
           v_invariant_checks_combo_017.check_name,
           v_invariant_checks_combo_017.expected,
           v_invariant_checks_combo_017.actual,
           v_invariant_checks_combo_017.passed,
           v_invariant_checks_combo_017.result
      FROM v_invariant_checks_combo_017
    UNION ALL
    SELECT v_invariant_checks_hardening.seq,
           v_invariant_checks_hardening.check_name,
           v_invariant_checks_hardening.expected,
           v_invariant_checks_hardening.actual,
           v_invariant_checks_hardening.passed,
           v_invariant_checks_hardening.result
      FROM v_invariant_checks_hardening
    UNION ALL
    SELECT v_invariant_checks_bundle.seq,
           v_invariant_checks_bundle.check_name,
           v_invariant_checks_bundle.expected,
           v_invariant_checks_bundle.actual,
           v_invariant_checks_bundle.passed,
           v_invariant_checks_bundle.result
      FROM v_invariant_checks_bundle
    UNION ALL
    SELECT v_invariant_checks_bundle_020.seq,
           v_invariant_checks_bundle_020.check_name,
           v_invariant_checks_bundle_020.expected,
           v_invariant_checks_bundle_020.actual,
           v_invariant_checks_bundle_020.passed,
           v_invariant_checks_bundle_020.result
      FROM v_invariant_checks_bundle_020
    UNION ALL
    SELECT v_invariant_checks_supply_forms_021.seq,
           v_invariant_checks_supply_forms_021.check_name,
           v_invariant_checks_supply_forms_021.expected,
           v_invariant_checks_supply_forms_021.actual,
           v_invariant_checks_supply_forms_021.passed,
           v_invariant_checks_supply_forms_021.result
      FROM v_invariant_checks_supply_forms_021
    UNION ALL
    SELECT v_invariant_checks_supply_form_shrink_022.seq,
           v_invariant_checks_supply_form_shrink_022.check_name,
           v_invariant_checks_supply_form_shrink_022.expected,
           v_invariant_checks_supply_form_shrink_022.actual,
           v_invariant_checks_supply_form_shrink_022.passed,
           v_invariant_checks_supply_form_shrink_022.result
      FROM v_invariant_checks_supply_form_shrink_022
    UNION ALL
    SELECT v_invariant_checks_supply_source_count_023.seq,
           v_invariant_checks_supply_source_count_023.check_name,
           v_invariant_checks_supply_source_count_023.expected,
           v_invariant_checks_supply_source_count_023.actual,
           v_invariant_checks_supply_source_count_023.passed,
           v_invariant_checks_supply_source_count_023.result
      FROM v_invariant_checks_supply_source_count_023
    UNION ALL
    SELECT v_invariant_checks_reassign.seq,
           v_invariant_checks_reassign.check_name,
           v_invariant_checks_reassign.expected,
           v_invariant_checks_reassign.actual,
           v_invariant_checks_reassign.passed,
           v_invariant_checks_reassign.result
      FROM v_invariant_checks_reassign
    UNION ALL
    SELECT v_invariant_checks_qty_limits.seq,
           v_invariant_checks_qty_limits.check_name,
           v_invariant_checks_qty_limits.expected,
           v_invariant_checks_qty_limits.actual,
           v_invariant_checks_qty_limits.passed,
           v_invariant_checks_qty_limits.result
      FROM v_invariant_checks_qty_limits
    UNION ALL
    SELECT v_invariant_checks_reassign_basis.seq,
           v_invariant_checks_reassign_basis.check_name,
           v_invariant_checks_reassign_basis.expected,
           v_invariant_checks_reassign_basis.actual,
           v_invariant_checks_reassign_basis.passed,
           v_invariant_checks_reassign_basis.result
      FROM v_invariant_checks_reassign_basis
    UNION ALL
    SELECT v_invariant_checks_hold_ttl.seq,
           v_invariant_checks_hold_ttl.check_name,
           v_invariant_checks_hold_ttl.expected,
           v_invariant_checks_hold_ttl.actual,
           v_invariant_checks_hold_ttl.passed,
           v_invariant_checks_hold_ttl.result
      FROM v_invariant_checks_hold_ttl;
