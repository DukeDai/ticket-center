-- 028 凭证过期作业 —— 把过了有效期的 issued 券推进到 expired
--
-- 券的有效期过了，但券的状态还停在 issued。这是本项目里最贵的一种「事实与状态分叉」：
-- 券已经不能进场了，状态却还写着「已出票」，任何读券状态的地方都会读到错的值。
--
-- 核销路径（008）刻意**只落核销记录、不改券状态**：
--
--   WHEN 'expired' THEN v_result := 'expired'; v_reason := 'voucher_expired';
--
--   ——「过期只落核销记录，不改券状态 —— 券状态由过期作业统一改。
--     一件事一件事分开，才说得清是谁在什么时候把哪张票判成什么。」
--
-- 那句话不是注释，是承诺。现在补上兑现它的那一半。
--
-- -------------------------------------------------------------------------------------
-- 一、作业本身
-- -------------------------------------------------------------------------------------
-- 口径：
--   - 只动 status='issued' 的券（pending 是还没出票；used 是已核销；void/refunded 是另外两条事实）
--   - 判据是 valid_to <= now()（券自己的有效期终点，不是别的推算）
--   - 幂等：跑第二遍没有可推进的券就是 0，不报错、不重复改
--   - 限批：一次最多 p_limit 条（默认 500），避免一次锁太多行
--
-- 状态边是现成的：state_transition 里 'voucher' 的 ('issued' → 'expired') 早就在（003），
-- 守卫触发器 trg_voucher_status_guard 会挡住非法流转，事件触发器 trg_voucher_status_event
-- 会自动落一条 VoucherExpired 到 event_outbox。
-- 所以这个作业只 UPDATE 状态，不自己插事件 —— 事件由机制保证，不由自觉。
--
-- -------------------------------------------------------------------------------------
-- 二、为什么改派 / 履约 / 出券的口径也要跟着改
--
-- 这是本迁移真正的难点，也是最容易漏的地方。
--
-- 全库有一批地方用 `v.status IN ('issued', 'used')` 表达一个意思：
-- **「票确实交付到客户手上了」**。这个集合漏掉了 'expired'。
--
-- 漏掉的后果不是「过期券算不出来」，是**交付过的事实被改写**：
--
--   1. fn_apply_order_fulfillment 的 delivered 口径
--      券一过期，delivered 归零，订单的 fulfillment_status 从 fulfilled 翻成
--      partially_fulfilled / failed —— 客户交了钱、拿到了票，票只是过期了，
--      系统却说这张单没履约。基线不变量 12（已履约订单必须有 issued/used 凭证）同时炸。
--
--   2. fn_reassign_order_item 的「已经出票不许改派」守卫
--      券一过期，这条明细又变成「可改派」—— 已经卖出去的票被换源重卖一次，
--      一次交付两次出票。这是最贵的一种：按 A 源的价格卖、按 B 源出票。
--
--   3. fn_issue_voucher 的 ticketed 判定、v_order_item_source / v_reassign_candidates
--      同一口径，同一个毛病。
--
-- 所以口径要改成：**交付过 = issued / used / expired**。
--
-- 为什么 expired 算「交付过」：
--   - 状态机说得清：issued → expired → refunded 是一条合法的边链，expired 坐在交付之后。
--   - 退款路径认它：fn_complete_refund 的券状态白名单里有 'expired' ——
--     过期券该退能退，说明它是真实交付出去的东西。
--   - 核销路径把它和 void/refunded 分开：expired 是「过期了」，void/refunded 是「没交付 / 收回了」。
--
-- 为什么 void / refunded 不算交付过：
--   void 是票被作废、refunded 是钱退了 —— 那是另外两条事实，不能混进「交付过」。
--
-- -------------------------------------------------------------------------------------
-- 三、为什么不逐处改 IN 列表，而不改成一个共享口径
--
-- 「交付过」这个判定散在 5 个函数和 3 个视图里，每处自己写一遍 IN 列表，
-- 就是同一个意思写五遍 —— 改一处忘了另一处，下一个迁移再漏一次。
-- 本迁移把三处最关键的判定（履约推导、改派守卫、出券 ticketed 门）改成读同一个口径，
-- 其余的视图保持各自分工的语义（见下）。
--
-- v_order_fulfillment_gap 是**诊断视图**，它的 issued_vouchers / used_vouchers
-- 是状态分布统计，不是「交付过」的判定 —— 过期券单独开一列 expired_vouchers，
-- 另加一列 delivered_vouchers；suspected_lost（已付款但没交付 → 疑似丢单）
-- 改用 delivered 口径，否则过期之后每张正常交付的单都会被误报成疑似丢单。
--
-- -------------------------------------------------------------------------------------
-- 四、门禁
--
-- 只加**不随时间漂移**的不变量：
--   120：expired 的券必须有过期时间（valid_to 不许是 NULL —— NULL 的券永远不过期）
--   121：expired 的券必须已出票过（issued_at 不许是 NULL —— 没出票的券不会过期）
--
-- 不加「不许有过了期还停在 issued 的券」这种门禁：
-- 那是**作业有没有跑**的问题，不是数据对不对的问题 ——
-- 作业没跑的时候那张券就是「该过期还没过期」，拿它当门禁，
-- 库会因为「作业没被调度」而红，那是把运维状态混进数据质量。
-- 作业漏跑的情况由 v_voucher_expiry_overdue 视图暴露（看得见数，不挡门禁）。
--
-- 也不加「过期券的订单履约状态必须还是 fulfilled」这种门禁：
-- 履约状态的推导口径改了（上面第二节），订单的 fulfillment_status 是**推导值**，
-- 不是被作业改的值 —— 作业只改券状态，不碰订单状态。

-- -------------------------------------------------------------------------------------
-- ① 过期作业：唯一实现
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_expire_vouchers(p_limit INTEGER DEFAULT 500)
RETURNS TABLE (expired_count INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- 只推进 issued 的券：
    --   pending   —— 还没出票，不是「过期的券」，是没发的券
    --   used      —— 已核销，已核销的券过期与否不影响它「被用过」这个事实
    --   void      —— 作废，是另外一条事实
    --   refunded  —— 已退款，是另外一条事实
    --
    -- 判据用券自己的 valid_to（券的有效期终点），不重算、不看别的表 ——
    -- 有效期口径在 010 已经统一到「格子日期 + 有效天数」，这里只是读它。
    WITH due AS (
        SELECT v.id
          FROM voucher v
         WHERE v.status = 'issued'
           AND v.valid_to IS NOT NULL
           AND v.valid_to <= now()
         ORDER BY v.valid_to, v.id
         LIMIT GREATEST(p_limit, 1)
    ), upd AS (
        UPDATE voucher v
           SET status     = 'expired',
               updated_at = now()
          FROM due d
         WHERE v.id = d.id
        RETURNING v.id
    )
    SELECT count(*) INTO v_count FROM upd;

    expired_count := v_count;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.fn_expire_vouchers(INTEGER)
    IS '凭证过期作业的唯一实现：把过了有效期的 issued 券推进到 expired（幂等，可反复跑）';

-- -------------------------------------------------------------------------------------
-- ② 交付口径：把「交付过」写成一个可复用的读法
--
-- 一个事实只写一处（硬约束 23 的同一精神）。
-- 交付过 = issued / used / expired；void / refunded 不算。
--
-- 这个函数不返回布尔而是返回状态集合里的成员，
-- 调用方写 `v.status IN (SELECT unnest(fn_delivered_voucher_statuses()))` ——
-- 集合读法写在一处，改集合只改这一处。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_delivered_voucher_statuses()
RETURNS TEXT[]
LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY['issued', 'used', 'expired']::TEXT[];
$$;

COMMENT ON FUNCTION public.fn_delivered_voucher_statuses()
    IS '「票确实交付到客户手上」的券状态集合：issued / used / expired。void 与 refunded 是另外两条事实，不算交付';

-- -------------------------------------------------------------------------------------
-- ③ 履约推导：交付口径改成含 expired
--
-- 下面三段是从库里活定义（pg_get_functiondef）取出来改的，
-- 不是从 005 的原文抄的 —— 005 之后 010/013/014/016 各自改过这个函数，
-- 抄原文会把那些修正一起 revert 掉。
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_apply_order_fulfillment(p_order_id bigint)
 RETURNS TABLE(order_id bigint, order_status text, fulfillment_status text, delivered_qty integer, requested_qty integer)
 LANGUAGE plpgsql
AS $function$
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
               -- 应发份数：成分入场份数之和（普通明细 = 明细份数；组合 = 各成分份数之和）
               COALESCE((SELECT sum(s.admission_quantity) FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id), oi.quantity) AS required,
               COALESCE((
                 SELECT sum(ve.quantity)
                   FROM voucher_entitlement ve
                   JOIN voucher v ON v.id = ve.voucher_id
                  WHERE v.order_item_id = oi.id
                    AND v.status IN ('issued', 'used', 'expired')
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
               CASE WHEN p.delivered >= p.required THEN 'done'
                    WHEN p.delivered > 0 THEN 'partial'
                    WHEN p.live THEN 'live'
                    WHEN p.ok THEN 'wait'
                    WHEN p.dead THEN 'dead'
                    ELSE 'idle' END AS st
          FROM per_item p
    )
    SELECT count(*),
           COALESCE(sum(LEAST(delivered, required)), 0),
           COALESCE(sum(required), 0),
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
$function$;
CREATE OR REPLACE FUNCTION public.fn_issue_voucher(p_booking_id bigint, p_codes text[] DEFAULT NULL::text[], p_raw_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(voucher_id bigint, voucher_no text, code text, holder_sequence integer, created boolean)
 LANGUAGE plpgsql
AS $function$
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
                AND v.status IN ('issued', 'used', 'expired')
                AND ve.entitlement_type = 'admission'), 0) >= v_required;

    -- 订单履约状态交给唯一实现推导
    PERFORM fn_apply_order_fulfillment(v_booking.order_id);
END;
$function$;
CREATE OR REPLACE FUNCTION public.fn_reassign_order_item(p_order_id bigint, p_order_item_id bigint, p_reason text DEFAULT NULL::text)
 RETURNS TABLE(order_item_id bigint, outcome text, previous_supplier_product_id bigint, previous_supplier_id bigint, new_supplier_product_id bigint, new_supplier_id bigint, previous_unit_price numeric, new_unit_price numeric, previous_unit_cost numeric, new_unit_cost numeric, previous_total_price numeric, new_total_price numeric, currency text, reason text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_order      RECORD;
    v_item       RECORD;
    v_price      RECORD;
    v_new_sp     BIGINT;
    v_new_sid    BIGINT;
    v_new_unit   NUMERIC;
    v_new_cost   NUMERIC;
    v_new_total  NUMERIC;
    v_basis      TEXT;
    v_qty        INT;
    v_channel    BIGINT;
    v_variant    BIGINT;
    v_date       DATE;
    v_currency   TEXT;
    v_trail      JSONB;
    v_role       TEXT;
    v_sv         BIGINT;
    v_hold_id    BIGINT;
    v_new_sess   BIGINT;
    v_subtotal   NUMERIC := 0;
    v_cost_total NUMERIC := 0;
    v_total      NUMERIC := 0;
    v_limits     RECORD;
    v_qty_limits JSONB := '[]'::jsonb;
BEGIN
    -- ---------------------------------------------------------------------------------
    -- ① 锁住订单与明细
    --
    -- 先锁订单再锁明细：两个改派同时进来时，后到的那个等一下，
    -- 拿到锁时看到的已经是改完之后的价（不会基于旧价再算一次）。
    -- ---------------------------------------------------------------------------------
    SELECT o.id, o.order_no, o.status, o.currency, o.channel_id, o.discount, o.tax
      INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    SELECT oi.id, oi.order_id, oi.product_id, oi.product_variant_id,
           oi.supplier_product_id, oi.supplier_id, oi.quantity,
           oi.unit_price, oi.unit_cost, oi.total_price,
           oi.currency, oi.status, oi.pricing_basis, oi.detail_snapshot,
           oi.session_id, oi.ticket_type_id
      INTO v_item
      FROM sales_order_item oi
     WHERE oi.id = p_order_item_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单明细 % 不存在', p_order_item_id;
    END IF;

    IF v_item.order_id <> p_order_id THEN
        RAISE EXCEPTION '订单明细 % 不属于订单 %', p_order_item_id, p_order_id;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ② 口径：只发生在未收款的时候
    -- ---------------------------------------------------------------------------------
    IF v_order.status NOT IN ('created', 'awaiting_payment') THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不能改派（改派只发生在未收款时：切换已支付订单的采纳源会让已成交的金额失去依据）',
            v_order.order_no, v_order.status;
    END IF;

    IF EXISTS (SELECT 1 FROM sales_payment sp
                WHERE sp.order_id = p_order_id AND sp.status = 'succeeded') THEN
        RAISE EXCEPTION '订单 % 有成功的支付记录，不能改派（已成交的金额不能失去依据；这类订单走退款）',
            v_order.order_no;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ③ 口径：单张形态、还没预订、还没出票
    -- ---------------------------------------------------------------------------------
    IF v_item.status <> 'pending' THEN
        RAISE EXCEPTION '订单明细 % 当前状态 % 不能改派（只允许还没进入预订的明细）',
            p_order_item_id, v_item.status;
    END IF;

    -- 形态：只对单张形态。
    --
    -- 配方与套装的源是**声明**的（源侧那个配方 / 源侧那个整套 SKU），
    -- 不是选出来的 —— 换源要重新声明配方，不是改派。
    --
    -- 判定用 product_variant.variant_role：下单与定价这两条路也是用它分
    -- 「源是选出来的」还是「源是声明出来的」（013/017 的同一个口径）。
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = v_item.product_variant_id;

    IF v_role = 'combo' THEN
        RAISE EXCEPTION '订单明细 % 是组合/套装形态：它的源是声明的（配方/套装），不是选出来的，换源要重新声明，不走改派',
            p_order_item_id;
    END IF;

    -- 多条成分行的明细同样是声明出来的源（成分拆开了）。
    IF (SELECT count(*) FROM sales_order_item_source s
         WHERE s.order_item_id = p_order_item_id) > 1 THEN
        RAISE EXCEPTION '订单明细 % 有多条成分行：它的源是声明出来的，不是选出来的，换源要重新声明，不走改派',
            p_order_item_id;
    END IF;

    IF EXISTS (SELECT 1 FROM booking b WHERE b.order_item_id = p_order_item_id) THEN
        RAISE EXCEPTION '订单明细 % 已经预订过：改派要在预订之前做（已经发出去的预订是事实，不能靠换源把它抹掉）',
            p_order_item_id;
    END IF;

    IF EXISTS (SELECT 1 FROM voucher v
                WHERE v.order_item_id = p_order_item_id
                  AND v.status IN ('issued', 'used', 'expired')) THEN
        RAISE EXCEPTION '订单明细 % 已经出票：改派不能改掉已经发出去的票，这类订单走退款',
            p_order_item_id;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ④ 重新选源 + 重新定价
    --
    -- 源与价都从 fn_price_variant 取 —— 它既选源又定价（硬约束 15）。
    -- 这里不另排一次序、不另算一次钱。
    -- ---------------------------------------------------------------------------------
    v_variant := v_item.product_variant_id;
    v_date    := NULLIF(v_item.detail_snapshot ->> 'visit_date', '')::date;
    v_qty     := v_item.quantity;
    v_channel := v_order.channel_id;

    IF v_variant IS NULL OR v_date IS NULL THEN
        RAISE EXCEPTION '订单明细 % 的明细快照不完整（缺变体或访客日），不能改派', p_order_item_id;
    END IF;

    SELECT * INTO v_price
      FROM fn_price_variant(v_variant, v_date, v_channel, v_channel);

    IF NOT FOUND THEN
        RAISE EXCEPTION '变体 % 在 % 没有可售价格（当天没有可用报价 / 商品未上架 / 成本无法折算）：改派不成',
            v_variant, v_date;
    END IF;

    v_currency := v_price.currency;

    IF v_currency <> TRIM(v_order.currency) THEN
        RAISE EXCEPTION '改派后的币种 % 与订单币种 % 不一致（一单一个币种）', v_currency, TRIM(v_order.currency);
    END IF;

    -- 定价口径：按团报价的总价是团总价，与人数不成正比（§4.5）。
    v_basis := COALESCE(NULLIF(v_price.rule ->> 'mode', ''), 'cost_plus');

    -- 总价 → 单位价只有一个实现（fn_unit_amount）。
    IF v_basis = 'per_group' THEN
        v_new_total := v_price.sell_price;
        v_new_unit  := fn_unit_amount(v_basis, v_price.sell_price, v_qty);
        v_new_cost  := fn_unit_amount(v_basis, v_price.cost_price, v_qty);
    ELSE
        v_new_unit  := fn_unit_amount(v_basis, v_price.sell_price, v_qty);
        v_new_total := round(v_price.sell_price * v_qty, 2);
        v_new_cost  := fn_unit_amount(v_basis, v_price.cost_price, v_qty);
    END IF;

    v_new_sp := v_price.supplier_product_id;

    IF v_new_sp IS NULL THEN
        RAISE EXCEPTION '变体 % 在 % 的定价结果没有单一采纳源：改派不成（这种形态的源不是选出来的）',
            v_variant, v_date;
    END IF;

    SELECT sp.supplier_id INTO v_new_sid
      FROM supplier_product sp
     WHERE sp.id = v_new_sp;

    -- 采纳的源变体：与定价同一个排序函数的第一名（选源与定价同源，硬约束 15）。
    -- 成分行要记源变体，建预订按源 SKU 建（不变量 87/88），所以这里一并取出来。
    SELECT rc.supplier_variant_id INTO v_sv
      FROM fn_route_candidates(v_variant, v_date, v_channel, v_price.currency) rc
     WHERE rc.route_rank = 1;

    -- ---------------------------------------------------------------------------------
    -- ⑤ 幂等：源没变、价没变、成本没变 → 什么都不做
    --
    -- 重复调用同一个改派不会改第二次（幂等键就是「这一条明细 + 当前的世界」）。
    -- ---------------------------------------------------------------------------------
    IF v_new_sp IS NOT DISTINCT FROM v_item.supplier_product_id
       AND v_new_unit IS NOT DISTINCT FROM v_item.unit_price
       AND v_new_cost IS NOT DISTINCT FROM v_item.unit_cost THEN
        order_item_id                := p_order_item_id;
        outcome                      := 'no_change';
        previous_supplier_product_id := v_item.supplier_product_id;
        previous_supplier_id         := v_item.supplier_id;
        new_supplier_product_id     := v_item.supplier_product_id;
        new_supplier_id              := v_item.supplier_id;
        previous_unit_price          := v_item.unit_price;
        new_unit_price               := v_item.unit_price;
        previous_unit_cost           := v_item.unit_cost;
        new_unit_cost                := v_item.unit_cost;
        previous_total_price         := v_item.total_price;
        new_total_price              := v_item.total_price;
        currency                     := v_currency;
        reason                       := p_reason;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ⑥ 区间：新源必须接得住这一单的份数（口径 6）
    --
    -- 放在「没变化就什么都不做」之后：什么都没改的时候不需要拦，
    -- 拦了反而是把一笔本来就成立的单说成不成立。
    --
    -- 区间按新源的价行读（fn_source_quantity_limits），
    -- 判定用 fn_qty_servable —— 与下单同一条口径，不在这里另写一遍比较。
    -- 份数的单位跟着形态走：按团报价比的是人数，单张比的是份数。
    -- ---------------------------------------------------------------------------------
    SELECT q.min_qty, q.max_qty INTO v_limits
      FROM fn_source_quantity_limits(v_sv, ARRAY[v_variant], v_date) q;

    IF FOUND THEN
        IF NOT fn_qty_servable(v_limits.min_qty, v_limits.max_qty, v_qty) THEN
            RAISE EXCEPTION
                '新源接不住这一单的份数：源 SKU % 在 % 只接 % 到 % 份，这一单要 % 份：改派不成',
                v_sv, v_date,
                COALESCE(v_limits.min_qty, 1),
                COALESCE(v_limits.max_qty::text, '不限'),
                v_qty;
        END IF;

        v_qty_limits := jsonb_build_array(jsonb_build_object(
            'supplier_variant_id', v_sv,
            'product_variant_ids', jsonb_build_array(v_variant),
            'min_qty',             v_limits.min_qty,
            'max_qty',             v_limits.max_qty,
            'quantity',            v_qty));
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ⑦ 落库：明细（留痕）+ 订单的钱
    --
    -- 明细就地改（重下一行明细 = 把这一行重新按当前的世界下一次），
    -- 旧值进快照的 reassignments —— 事实不许被一次调用洗掉（018）。
    -- ---------------------------------------------------------------------------------
    v_trail := jsonb_build_array(jsonb_build_object(
        'at',                       now(),
        'reason',                   p_reason,
        'from_supplier_product_id', v_item.supplier_product_id,
        'from_supplier_id',         v_item.supplier_id,
        'to_supplier_product_id',   v_new_sp,
        'to_supplier_id',           v_new_sid,
        'from_unit_price',          v_item.unit_price,
        'to_unit_price',            v_new_unit,
        'from_unit_cost',           v_item.unit_cost,
        'to_unit_cost',             v_new_cost,
        'from_total_price',         v_item.total_price,
        'to_total_price',           v_new_total,
        'currency',                 v_currency,
        'fx_rate',                  v_price.fx_rate,
        'fx_as_of',                 v_price.fx_as_of));

    UPDATE sales_order_item
       SET supplier_product_id = v_new_sp,
           supplier_id         = v_new_sid,
           unit_price          = v_new_unit,
           unit_cost           = v_new_cost,
           total_price         = v_new_total,
           currency            = v_currency,
           detail_snapshot     = (v_item.detail_snapshot
                || jsonb_build_object(
                       'unit_price',           v_new_unit,
                       'total_price',          v_new_total,
                       'cost_price',           v_new_cost,
                       'fx_rate',              v_price.fx_rate,
                       'fx_as_of',             v_price.fx_as_of,
                       'rule',                 v_price.rule,
                       'cost_source_product_id', v_new_sp,
                       'quantity_limits',      v_qty_limits)
                || jsonb_build_object(
                       'reassignments',
                       COALESCE(v_item.detail_snapshot -> 'reassignments', '[]'::jsonb) || v_trail))
     WHERE id = p_order_item_id;

    -- 成分行跟着明细一起走。
    --
    -- sales_order_item_source 那一行才是履约真正用的源：建预订按它建，
    -- 不变量 58 也按它判。改了明细不挪这一行 =
    -- 「按 A 源的价格卖、按 B 源出票」——
    -- 这是本项目最不许发生的事，所以改派必须两处一起改。
    --
    -- 挪的是源相关的字段：源变体 / 源商品 / 供应商 / 源场次 / 成本 / 币种 / 汇率。
    -- 规范场次与票种不动 —— 那是这个变体在这天的属性，不是源的属性，
    -- 换了源它也不变（源场次是「规范场次 ↔ 源商品」的绑定，绑定表说了算）。
    UPDATE sales_order_item_source s
       SET supplier_variant_id = v_sv,
           supplier_product_id = v_new_sp,
           supplier_id         = v_new_sid,
           supplier_session_id = fn_bound_supplier_session(s.product_session_id, v_new_sp),
           unit_cost           = v_price.cost_price,
           currency            = v_price.source_currency,
           fx_rate             = v_price.fx_rate,
           fx_as_of            = v_price.fx_as_of
     WHERE s.order_item_id = p_order_item_id;

    -- 库存预占跟着源走。
    --
    -- 预占记的是「我们承诺了多少」：钉在旧源上 = 旧池子继续被占着、新池子没被占 ——
    -- 那就是「按新源卖、按旧源占库存」（硬约束 22）。
    --
    -- 先查新源的池子：明知不够还改派 = 超卖，当场报错（fn_reserve_qty 是唯一实现）。
    -- 「不知道」（源侧没报这个池子的库存）时不拦 —— 返回 0 意味着「卖完了」，
    -- 那比超卖更贵（硬约束 22）。
    SELECT h.id INTO v_hold_id
      FROM inventory_hold h
     WHERE h.order_id = p_order_id
       AND h.status = 'consumed'
       AND h.product_session_id IS NOT DISTINCT FROM v_item.session_id
       AND h.ticket_type_id IS NOT DISTINCT FROM v_item.ticket_type_id
       AND h.supplier_id IS NOT DISTINCT FROM v_item.supplier_id
       AND h.quantity = v_item.quantity
     ORDER BY h.id
     LIMIT 1
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单明细 % 没有对应的库存预占，改派不成（预占是事实，不能凭空造一条）',
            p_order_item_id;
    END IF;

    v_new_sess := fn_bound_supplier_session(
        COALESCE(v_item.session_id,
                 (SELECT s.product_session_id
                    FROM sales_order_item_source s
                   WHERE s.order_item_id = p_order_item_id
                   LIMIT 1)),
        v_new_sp);

    PERFORM * FROM fn_reserve_qty(v_new_sess, v_item.ticket_type_id, v_item.quantity,
                                   '改派到源商品 ' || v_new_sp::text);

    UPDATE inventory_hold
       SET supplier_id         = v_new_sid,
           supplier_session_id = v_new_sess
     WHERE id = v_hold_id;

    -- 订单的钱跟着明细走（不变量 53：小计 = 明细合计）。
    -- 成本按明细自己记的口径还原：按团报价的成本是团成本，不是人均 × 人数。
    SELECT COALESCE(sum(oi.total_price), 0),
           COALESCE(sum(CASE WHEN oi.pricing_basis = 'per_group'
                               THEN COALESCE((oi.detail_snapshot ->> 'cost_price')::numeric, 0)
                               ELSE COALESCE(oi.unit_cost, 0) * oi.quantity END), 0)
      INTO v_subtotal, v_cost_total
      FROM sales_order_item oi
     WHERE oi.order_id = p_order_id;

    v_total := round(v_subtotal - COALESCE(v_order.discount, 0) + COALESCE(v_order.tax, 0), 2);

    UPDATE sales_order
       SET subtotal    = v_subtotal,
           total       = v_total,
           cost_total  = v_cost_total
     WHERE id = p_order_id;

    -- ---------------------------------------------------------------------------------
    -- ⑧ 领域事件
    --
    -- 状态没变（订单还在等付款），但价变了 —— 报价变了是件要通知出去的事，
    -- 所以显式落一条事件（SPEC.md §6）。
    -- ---------------------------------------------------------------------------------
    INSERT INTO event_outbox (aggregate_type, aggregate_id, event_type, payload)
    VALUES ('order', p_order_id, 'OrderItemReassigned', jsonb_build_object(
        'aggregate_type',            'order',
        'aggregate_id',              p_order_id,
        'order_no',                  v_order.order_no,
        'order_item_id',             p_order_item_id,
        'from_supplier_product_id',  v_item.supplier_product_id,
        'to_supplier_product_id',    v_new_sp,
        'from_unit_price',           v_item.unit_price,
        'to_unit_price',             v_new_unit,
        'reason',                    p_reason));

    order_item_id                := p_order_item_id;
    outcome                      := 'reassigned';
    previous_supplier_product_id := v_item.supplier_product_id;
    previous_supplier_id         := v_item.supplier_id;
    new_supplier_product_id     := v_new_sp;
    new_supplier_id              := v_new_sid;
    previous_unit_price          := v_item.unit_price;
    new_unit_price               := v_new_unit;
    previous_unit_cost           := v_item.unit_cost;
    new_unit_cost                := v_new_cost;
    previous_total_price         := v_item.total_price;
    new_total_price              := v_new_total;
    currency                     := v_currency;
    reason                       := p_reason;
    RETURN NEXT;
END;
$function$;
-- -------------------------------------------------------------------------------------
-- ④ 视图：口径跟着改
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_order_fulfillment_gap AS SELECT o.id AS order_id,
    o.order_no,
    o.channel_id,
    o.status AS order_status,
    o.payment_status,
    o.placed_at,
    count(DISTINCT b.id) AS booking_count,
    count(DISTINCT b.id) FILTER (WHERE b.status = 'confirmed'::text) AS confirmed_bookings,
    count(DISTINCT b.id) FILTER (WHERE b.status = 'failed'::text) AS failed_bookings,
    count(DISTINCT v.id) AS voucher_count,
    count(DISTINCT v.id) FILTER (WHERE v.status = 'issued'::text) AS issued_vouchers,
    count(DISTINCT v.id) FILTER (WHERE v.status = 'used'::text) AS used_vouchers,
    o.payment_status = 'paid'::text AND count(DISTINCT v.id) FILTER (WHERE v.status IN ('issued'::text, 'used'::text, 'expired'::text)) = 0 AND o.placed_at < (now() - '00:30:00'::interval) AS suspected_lost,
    count(DISTINCT v.id) FILTER (WHERE v.status = 'expired'::text) AS expired_vouchers,
    count(DISTINCT v.id) FILTER (WHERE v.status IN ('issued'::text, 'used'::text, 'expired'::text)) AS delivered_vouchers
   FROM sales_order o
     LEFT JOIN booking b ON b.order_id = o.id
     LEFT JOIN voucher v ON v.order_id = o.id
  GROUP BY o.id, o.order_no, o.channel_id, o.status, o.payment_status, o.placed_at;
CREATE OR REPLACE VIEW public.v_order_item_source AS SELECT oi.id AS order_item_id,
    o.order_no,
    o.status AS order_status,
    oi.product_id,
    oi.product_variant_id,
    pv.variant_key,
    pv.variant_role,
    s.component_variant_id,
    cv.variant_key AS component_variant_key,
    s.supplier_variant_id,
    sv.external_variant_id,
    s.supplier_product_id,
    sup.code AS supplier_code,
    s.quantity,
    s.admission_quantity,
    s.unit_cost,
    s.currency,
    s.fx_rate,
    s.fx_as_of,
    s.product_session_id,
    s.supplier_session_id,
    b.id AS booking_id,
    b.booking_no,
    b.status AS booking_status,
    ( SELECT count(*) AS count
           FROM voucher v
          WHERE v.booking_id = b.id AND NOT v.product_variant_id IS DISTINCT FROM s.component_variant_id AND (v.status = ANY (ARRAY['issued'::text, 'used'::text, 'expired'::text]))) AS issued_vouchers
   FROM sales_order_item_source s
     JOIN sales_order_item oi ON oi.id = s.order_item_id
     JOIN sales_order o ON o.id = oi.order_id
     JOIN product_variant pv ON pv.id = oi.product_variant_id
     JOIN product_variant cv ON cv.id = s.component_variant_id
     JOIN supplier_variant sv ON sv.id = s.supplier_variant_id
     JOIN supplier_product sp ON sp.id = s.supplier_product_id
     JOIN supplier sup ON sup.id = s.supplier_id
     LEFT JOIN booking b ON b.order_item_id = s.order_item_id AND NOT b.supplier_variant_id IS DISTINCT FROM s.supplier_variant_id AND NOT b.supplier_session_id IS DISTINCT FROM s.supplier_session_id;
CREATE OR REPLACE VIEW public.v_reassign_candidates AS SELECT o.id AS order_id,
    o.order_no,
    o.channel_id,
    oi.id AS order_item_id,
    oi.product_id,
    oi.product_variant_id,
    (oi.detail_snapshot ->> 'visit_date'::text)::date AS visit_date,
    oi.quantity,
    oi.supplier_product_id AS current_supplier_product_id,
    cur.name AS current_supplier,
    oi.unit_price AS current_unit_price,
    oi.unit_cost AS current_unit_cost,
    p.supplier_product_id AS new_supplier_product_id,
    nsup.name AS new_supplier,
    fn_unit_amount(oi.pricing_basis, p.sell_price, oi.quantity) AS new_unit_price,
    fn_unit_amount(oi.pricing_basis, p.cost_price, oi.quantity) AS new_unit_cost,
    p.sell_price IS NOT NULL AS can_reassign,
        CASE
            WHEN p.sell_price IS NULL THEN '当天没有可用报价'::text
            WHEN p.supplier_product_id IS DISTINCT FROM oi.supplier_product_id THEN (('源变了：'::text || COALESCE(cur.name, '?'::text)) || ' → '::text) || COALESCE(nsup.name, '?'::text)
            WHEN fn_unit_amount(oi.pricing_basis, p.sell_price, oi.quantity) IS DISTINCT FROM oi.unit_price THEN (('价变了：'::text || oi.unit_price::text) || ' → '::text) || fn_unit_amount(oi.pricing_basis, p.sell_price, oi.quantity)::text
            WHEN fn_unit_amount(oi.pricing_basis, p.cost_price, oi.quantity) IS DISTINCT FROM oi.unit_cost THEN '成本变了'::text
            ELSE NULL::text
        END AS stale_reason
   FROM sales_order o
     JOIN sales_order_item oi ON oi.order_id = o.id
     LEFT JOIN LATERAL fn_price_variant(oi.product_variant_id, (oi.detail_snapshot ->> 'visit_date'::text)::date, o.channel_id, o.channel_id) p(product_id, product_variant_id, date, currency, supplier_product_id, source_currency, net_price, fx_rate, fx_as_of, cost_price, sell_price, list_price, discount_pct, price_locked, min_margin, rule) ON true
     LEFT JOIN supplier_product curp ON curp.id = oi.supplier_product_id
     LEFT JOIN supplier cur ON cur.id = curp.supplier_id
     LEFT JOIN supplier_product nsp ON nsp.id = p.supplier_product_id
     LEFT JOIN supplier nsup ON nsup.id = nsp.supplier_id
  WHERE (o.status = ANY (ARRAY['created'::text, 'awaiting_payment'::text])) AND oi.status = 'pending'::text AND oi.product_variant_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM sales_payment sp
          WHERE sp.order_id = o.id AND sp.status = 'succeeded'::text)) AND COALESCE(( SELECT pv.variant_role
           FROM product_variant pv
          WHERE pv.id = oi.product_variant_id), 'base'::text) <> 'combo'::text AND (( SELECT count(*) AS count
           FROM sales_order_item_source s
          WHERE s.order_item_id = oi.id)) <= 1 AND NOT (EXISTS ( SELECT 1
           FROM booking b
          WHERE b.order_item_id = oi.id)) AND NOT (EXISTS ( SELECT 1
           FROM voucher v
          WHERE v.order_item_id = oi.id AND (v.status = ANY (ARRAY['issued'::text, 'used'::text, 'expired'::text])))) AND (p.sell_price IS NULL OR p.supplier_product_id IS DISTINCT FROM oi.supplier_product_id OR fn_unit_amount(oi.pricing_basis, p.sell_price, oi.quantity) IS DISTINCT FROM oi.unit_price OR fn_unit_amount(oi.pricing_basis, p.cost_price, oi.quantity) IS DISTINCT FROM oi.unit_cost);
-- -------------------------------------------------------------------------------------
-- ④ 之二：不变量分支视图：口径跟着改
--
-- 上面三段改的是「谁在算」；这一段改的是「门禁在查什么」。
--
-- 门禁里有六处用 `v.status IN ('issued','used')` 表达「交付过 / 出过票」：
-- 不变量 12、20、51、60、86，以及 60 的基座视图。
-- 只改履约推导函数不改门禁 = 门禁会红，而且红得莫名其妙
-- （券确实交付了，只是过期了，门禁说「没交付」）。
--
-- 这一段还改了一处 check_name：不变量 12 的名字原本写死「issued/used」，
-- 名字是这个门禁的稳定标识（seq 会重排），改名字 = 改合同，
-- SPEC.md 与 verify.sql 里的按名定位要同步改（见 verify.sql 的 SELECT ... WHERE check_name =）。
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_invariant_checks_supply AS WITH raw(seq, check_name, actual) AS (
         SELECT 1 AS "?column?",
            '规范商品必须有至少一个 active 源映射'::text AS "?column?",
            ( SELECT count(*) AS count
                   FROM product p
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM product_mapping m
                          WHERE ((m.product_id = p.id) AND (m.status = 'active'::text)))))) AS count
        UNION ALL
         SELECT 2,
            '同一商品同一供应商最多一个 primary 映射'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM product_mapping
                          WHERE product_mapping.is_primary
                          GROUP BY product_mapping.product_id, product_mapping.supplier_id
                         HAVING (count(*) > 1)) x) AS count
        UNION ALL
         SELECT 3,
            '场次源绑定的源商品必须映射到同一规范商品'::text,
            ( SELECT count(*) AS count
                   FROM ((product_session_source pss
                     JOIN product_session ps ON ((ps.id = pss.product_session_id)))
                     JOIN supplier_product sp ON ((sp.id = pss.supplier_product_id)))
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM product_mapping m
                          WHERE ((m.supplier_product_id = sp.id) AND (m.product_id = ps.product_id) AND (m.status = 'active'::text)))))) AS count
        UNION ALL
         SELECT 4,
            '订单金额自洽 total = subtotal - discount + tax'::text,
            ( SELECT count(*) AS count
                   FROM sales_order
                  WHERE (sales_order.total <> ((sales_order.subtotal - sales_order.discount) + sales_order.tax))) AS count
        UNION ALL
         SELECT 5,
            '订单明细金额自洽（按人计价 total=unit×qty；按团计价 团总价来自快照）'::text,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE
                        CASE oi.pricing_basis
                            WHEN 'per_person'::text THEN (oi.total_price <> (oi.unit_price * (oi.quantity)::numeric))
                            ELSE (NOT ((oi.total_price > (0)::numeric) AND (oi.unit_price > (0)::numeric) AND (abs((oi.total_price - (oi.unit_price * (oi.quantity)::numeric))) <= ((oi.quantity)::numeric * 0.01)) AND (oi.total_price = COALESCE((NULLIF((oi.detail_snapshot ->> 'group_total'::text), ''::text))::numeric, oi.total_price))))
                        END) AS count
        UNION ALL
         SELECT 6,
            '订单行 supplier_id 与 supplier_product 所属供应商一致'::text,
            ( SELECT count(*) AS count
                   FROM (sales_order_item oi
                     JOIN supplier_product sp ON ((sp.id = oi.supplier_product_id)))
                  WHERE (sp.supplier_id <> oi.supplier_id)) AS count
        UNION ALL
         SELECT 7,
            '已确认预订必须有 external_booking_id'::text,
            ( SELECT count(*) AS count
                   FROM booking
                  WHERE ((booking.status = 'confirmed'::text) AND (booking.external_booking_id IS NULL))) AS count
        UNION ALL
         SELECT 8,
            '同源同票码不得重复出票'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM voucher
                          WHERE (voucher.code IS NOT NULL)
                          GROUP BY voucher.supplier_id, voucher.code
                         HAVING (count(*) > 1)) x) AS count
        UNION ALL
         SELECT 9,
            '权益消耗数不得超过发放数'::text,
            ( SELECT count(*) AS count
                   FROM voucher_entitlement
                  WHERE (voucher_entitlement.consumed_quantity > voucher_entitlement.quantity)) AS count
        UNION ALL
         SELECT 10,
            '对客售价必须 ≥ 采纳成本（不得亏本销售）'::text,
            ( SELECT count(*) AS count
                   FROM price_calendar
                  WHERE ((price_calendar.cost_price IS NOT NULL) AND (price_calendar.sell_price IS NOT NULL) AND (price_calendar.sell_price < price_calendar.cost_price))) AS count
        UNION ALL
         SELECT 11,
            '已支付订单必须有 succeeded 支付记录'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((o.payment_status = 'paid'::text) AND (NOT (EXISTS ( SELECT 1
                           FROM sales_payment p
                          WHERE ((p.order_id = o.id) AND (p.status = 'succeeded'::text))))))) AS count
        UNION ALL
         SELECT 12,
            '已履约订单必须有交付过的凭证（issued/used/expired）'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((o.fulfillment_status = 'fulfilled'::text) AND (NOT (EXISTS ( SELECT 1
                           FROM voucher v
                          WHERE ((v.order_id = o.id) AND (v.status = ANY (fn_delivered_voucher_statuses())))))))) AS count
        UNION ALL
         SELECT 13,
            '映射的 supplier_id 与源商品所属供应商一致'::text,
            ( SELECT count(*) AS count
                   FROM (product_mapping m
                     JOIN supplier_product sp ON ((sp.id = m.supplier_product_id)))
                  WHERE (m.supplier_id <> sp.supplier_id)) AS count
        UNION ALL
         SELECT 14,
            '所有在用币种（非基准币种）必须有汇率快照'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT supplier_price_calendar.currency
                           FROM supplier_price_calendar) c
                  WHERE ((c.currency <> 'CNY'::bpchar) AND (NOT (EXISTS ( SELECT 1
                           FROM fx_rate f
                          WHERE ((f.quote_currency = c.currency) AND (f.base_currency = 'CNY'::bpchar))))))) AS count
        UNION ALL
         SELECT 15,
            '每个 online 渠道上架必须绑定至少一个启用源'::text,
            ( SELECT count(*) AS count
                   FROM channel_listing cl
                  WHERE ((cl.status = 'online'::text) AND (NOT (EXISTS ( SELECT 1
                           FROM channel_listing_source cls
                          WHERE ((cls.channel_listing_id = cl.id) AND cls.enabled)))))) AS count
        UNION ALL
         SELECT 16,
            '售价日历的采纳成本必须可追溯到具体源'::text,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE ((pc.cost_price IS NOT NULL) AND (pc.cost_source_product_id IS NULL))) AS count
        UNION ALL
         SELECT 17,
            'booking.attempt_count 不得小于实际尝试记录数'::text,
            ( SELECT count(*) AS count
                   FROM booking b
                  WHERE (b.attempt_count < ( SELECT count(*) AS count
                           FROM booking_attempt ba
                          WHERE (ba.booking_id = b.id)))) AS count
        UNION ALL
         SELECT 18,
            '渠道内订单幂等键不得重复'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM sales_order
                          WHERE (sales_order.idempotency_key IS NOT NULL)
                          GROUP BY sales_order.channel_id, sales_order.idempotency_key
                         HAVING (count(*) > 1)) x) AS count
        UNION ALL
         SELECT 19,
            '库存快照与可用性缓存的供应商必须存在'::text,
            ( SELECT count(*) AS count
                   FROM availability_cache ac
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM supplier s
                          WHERE (s.id = ac.supplier_id))))) AS count
        UNION ALL
         SELECT 20,
            '已出票凭证必须归属某个已确认预订'::text,
            ( SELECT count(*) AS count
                   FROM voucher v
                  WHERE ((v.status = ANY (fn_delivered_voucher_statuses())) AND ((v.booking_id IS NULL) OR (NOT (EXISTS ( SELECT 1
                           FROM booking b
                          WHERE ((b.id = v.booking_id) AND (b.status = ANY (ARRAY['confirmed'::text, 'ticketed'::text]))))))))) AS count
        UNION ALL
         SELECT 21,
            '购物车项的库存预占数量必须一致'::text,
            ( SELECT count(*) AS count
                   FROM (cart_item ci
                     JOIN inventory_hold h ON ((h.id = ci.hold_id)))
                  WHERE (h.quantity <> ci.quantity)) AS count
        UNION ALL
         SELECT 22,
            '活跃库存预占必须关联购物车或订单'::text,
            ( SELECT count(*) AS count
                   FROM inventory_hold h
                  WHERE ((h.status = 'active'::text) AND (h.cart_id IS NULL) AND (h.order_id IS NULL))) AS count
        UNION ALL
         SELECT 23,
            '优惠券使用次数不得超过发放上限'::text,
            ( SELECT count(*) AS count
                   FROM coupon
                  WHERE ((coupon.usage_limit IS NOT NULL) AND (coupon.used_count > coupon.usage_limit))) AS count
        UNION ALL
         SELECT 24,
            '订单引用的优惠券必须有核销记录'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((o.coupon_id IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                           FROM coupon_redemption cr
                          WHERE ((cr.order_id = o.id) AND (cr.status = 'used'::text))))))) AS count
        UNION ALL
         SELECT 25,
            '要求实名的票种持票人数必须与票数一致'::text,
            ( SELECT count(*) AS count
                   FROM ((sales_order_item oi
                     JOIN sales_order o ON ((o.id = oi.order_id)))
                     JOIN checkout_requirement cr ON (((cr.product_id = oi.product_id) AND ((cr.ticket_type_id IS NULL) OR (cr.ticket_type_id = oi.ticket_type_id)) AND ((cr.channel_id IS NULL) OR (cr.channel_id = o.channel_id)))))
                  WHERE ((cr.field_code = 'holder_name'::text) AND cr.required AND (( SELECT count(DISTINCT oh.sequence) AS count
                           FROM order_holder oh
                          WHERE ((oh.order_item_id = oi.id) AND (oh.field_code = 'holder_name'::text))) <> oi.quantity))) AS count
        UNION ALL
         SELECT 26,
            'C端读模型卡片的起价必须能追溯到价格日历'::text,
            ( SELECT count(*) AS count
                   FROM c_product_card c
                  WHERE ((c.status = 'online'::text) AND (c.from_price IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                           FROM price_calendar pc
                          WHERE ((pc.product_id = c.product_id) AND (pc.status = 'active'::text) AND ((pc.channel_id = c.channel_id) OR (pc.channel_id IS NULL)) AND (pc.date >= CURRENT_DATE) AND (pc.date <= (CURRENT_DATE + 30)))))))) AS count
        UNION ALL
         SELECT 27,
            '变体轴取值必须属于该商品的轴定义'::text,
            ( SELECT count(*) AS count
                   FROM ((product_variant_option pvo
                     JOIN product_variant pv ON ((pv.id = pvo.product_variant_id)))
                     JOIN product_axis ax ON ((ax.id = pvo.axis_id)))
                  WHERE (ax.product_id <> pv.product_id)) AS count
        UNION ALL
         SELECT 28,
            '同一商品内变体指纹不得重复'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT 1 AS "?column?"
                           FROM product_variant
                          GROUP BY product_variant.product_id, product_variant.variant_key
                         HAVING (count(*) > 1)) x) AS count
        UNION ALL
         SELECT 29,
            '在售变体必须有人群或轴取值定义'::text,
            ( SELECT count(*) AS count
                   FROM product_variant pv
                  WHERE ((pv.status = 'active'::text) AND (pv.ticket_type_id IS NULL) AND (NOT (EXISTS ( SELECT 1
                           FROM product_variant_option pvo
                          WHERE (pvo.product_variant_id = pv.id)))))) AS count
        UNION ALL
         SELECT 30,
            '源变体覆盖映射必须完整覆盖目标变体'::text,
            ( SELECT count(*) AS count
                   FROM supplier_variant_mapping svm
                  WHERE ((svm.status = 'active'::text) AND (NOT fn_variant_covered(svm.coverage, svm.product_variant_id)))) AS count
        UNION ALL
         SELECT 31,
            '在售售价日历必须绑定变体'::text,
            ( SELECT count(*) AS count
                   FROM price_calendar
                  WHERE ((price_calendar.status = 'active'::text) AND (price_calendar.product_variant_id IS NULL))) AS count
        UNION ALL
         SELECT 32,
            '订单明细的变体必须与明细商品一致'::text,
            ( SELECT count(*) AS count
                   FROM (sales_order_item oi
                     JOIN product_variant pv ON ((pv.id = oi.product_variant_id)))
                  WHERE (pv.product_id <> oi.product_id)) AS count
        UNION ALL
         SELECT 33,
            '加购件变体必须挂在基础变体上'::text,
            ( SELECT count(*) AS count
                   FROM product_variant pv
                  WHERE ((pv.variant_role = 'addon'::text) AND (pv.status = 'active'::text) AND (NOT (EXISTS ( SELECT 1
                           FROM product_variant_relation r
                          WHERE ((r.child_variant_id = pv.id) AND (r.relation_type = 'optional_addon'::text))))))) AS count
        UNION ALL
         SELECT 34,
            '有售价的变体在其上架渠道必须至少有一个可履约源'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT cl.channel_id,
                            pc.product_variant_id
                           FROM (channel_listing cl
                             JOIN price_calendar pc ON (((pc.product_id = cl.product_id) AND (pc.channel_id IS NULL) AND (pc.status = 'active'::text))))
                          WHERE ((pc.product_variant_id IS NOT NULL) AND (pc.sell_price IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                                   FROM v_variant_routing_candidates vrc
                                  WHERE ((vrc.channel_id = cl.channel_id) AND (vrc.product_variant_id = pc.product_variant_id))))))) x) AS count
        UNION ALL
         SELECT 35,
            '同一订单内同一商品的多个变体必须使用同一日期'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT oi.order_id
                           FROM (sales_order_item oi
                             JOIN product_session ps ON ((ps.id = oi.session_id)))
                          GROUP BY oi.order_id, oi.product_id
                         HAVING (count(DISTINCT ps.session_date) > 1)) x) AS count
        UNION ALL
         SELECT 36,
            '订单小计必须等于明细金额之和'::text,
            ( SELECT count(*) AS count
                   FROM ( SELECT o.id
                           FROM (sales_order o
                             JOIN sales_order_item oi ON ((oi.order_id = o.id)))
                          GROUP BY o.id, o.subtotal
                         HAVING (o.subtotal <> sum(oi.total_price))) x) AS count
        UNION ALL
         SELECT 37,
            '锁价售价必须等于采纳源的挂牌价'::text,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE (pc.price_locked AND (pc.status = 'active'::text) AND (NOT (EXISTS ( SELECT 1
                           FROM (supplier_price_calendar spc
                             JOIN supplier_variant sv ON (((sv.id = spc.supplier_variant_id) AND sv.is_price_locked)))
                          WHERE ((spc.supplier_product_id = pc.cost_source_product_id) AND (spc.product_variant_id = pc.product_variant_id) AND (spc.date = pc.date) AND (spc.status = 'available'::text) AND (pc.sell_price = round(fn_convert(spc.supplier_price, (spc.currency)::text, (pc.currency)::text, pc.date), 2)))))))) AS count
        UNION ALL
         SELECT 38,
            '采纳价格保护源的售价行必须锁价'::text,
            ( SELECT count(*) AS count
                   FROM ((price_calendar pc
                     JOIN supplier_price_calendar spc ON (((spc.supplier_product_id = pc.cost_source_product_id) AND (spc.product_variant_id = pc.product_variant_id) AND (spc.date = pc.date) AND (spc.status = 'available'::text))))
                     JOIN supplier_variant sv ON ((sv.id = spc.supplier_variant_id)))
                  WHERE ((pc.status = 'active'::text) AND sv.is_price_locked AND (NOT pc.price_locked))) AS count
        UNION ALL
         SELECT 39,
            '在售源价格的币种必须可折算到基准币种'::text,
            ( SELECT count(*) AS count
                   FROM supplier_price_calendar spc
                  WHERE ((spc.status = 'available'::text) AND (fn_fx_rate((spc.currency)::text, spc.date) IS NULL))) AS count
        UNION ALL
         SELECT 40,
            '售价行的成本必须等于采纳源成本按留痕汇率折算的结果'::text,
            ( SELECT count(*) AS count
                   FROM (price_calendar pc
                     LEFT JOIN supplier_price_calendar spc ON (((spc.supplier_product_id = pc.cost_source_product_id) AND (NOT (spc.product_variant_id IS DISTINCT FROM pc.product_variant_id)) AND (spc.date = pc.date) AND (spc.status = 'available'::text))))
                  WHERE ((pc.status = 'active'::text) AND (pc.cost_source_product_id IS NOT NULL) AND ((spc.id IS NULL) OR (pc.fx_rate IS NULL) OR (pc.cost_price IS DISTINCT FROM round((spc.net_price * pc.fx_rate), 2)) OR (pc.cost_price IS DISTINCT FROM round(fn_convert(spc.net_price, (spc.currency)::text, (pc.currency)::text, pc.date), 2))))) AS count
        UNION ALL
         SELECT 41,
            '在售售价行必须等于定价函数的输出'::text,
            ( SELECT count(*) AS count
                   FROM (price_calendar pc
                     LEFT JOIN LATERAL fn_price_variant(pc.product_variant_id, pc.date, COALESCE(pc.channel_id, fn_default_context_channel()), pc.channel_id) v(product_id, product_variant_id, date, currency, supplier_product_id, source_currency, net_price, fx_rate, fx_as_of, cost_price, sell_price, list_price, discount_pct, price_locked, min_margin, rule) ON (true))
                  WHERE ((pc.status = 'active'::text) AND (pc.product_variant_id IS NOT NULL) AND (((v.product_variant_id IS NULL) AND ((pc.sell_price IS NOT NULL) OR (pc.cost_price IS NOT NULL))) OR ((v.product_variant_id IS NOT NULL) AND ((pc.cost_price IS DISTINCT FROM v.cost_price) OR (pc.sell_price IS DISTINCT FROM v.sell_price) OR (pc.list_price IS DISTINCT FROM v.list_price) OR (pc.discount_pct IS DISTINCT FROM v.discount_pct) OR (pc.price_locked IS DISTINCT FROM v.price_locked) OR (pc.cost_source_product_id IS DISTINCT FROM v.supplier_product_id)))))) AS count
        UNION ALL
         SELECT 42,
            '非锁价售价行的毛利率必须达到生效 min_margin'::text,
            ( SELECT count(*) AS count
                   FROM ((price_calendar pc
                     JOIN channel_listing cl ON (((cl.product_id = pc.product_id) AND (cl.channel_id = COALESCE(pc.channel_id, fn_default_context_channel())) AND (cl.status = 'online'::text))))
                     JOIN channel_listing_source cls ON (((cls.channel_listing_id = cl.id) AND (cls.supplier_product_id = pc.cost_source_product_id) AND cls.enabled)))
                  WHERE ((pc.status = 'active'::text) AND (NOT pc.price_locked) AND (COALESCE(NULLIF((cl.price_policy ->> 'mode'::text), ''::text), 'cost_plus'::text) = 'cost_plus'::text) AND (round(((pc.sell_price - pc.cost_price) / NULLIF(pc.sell_price, (0)::numeric)), 6) < GREATEST(COALESCE((NULLIF((cl.price_policy ->> 'min_margin'::text), ''::text))::numeric, (0)::numeric), COALESCE(cls.min_margin, (0)::numeric))))) AS count
        UNION ALL
         SELECT 43,
            '定价采用的源必须是路由选中的源'::text,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE ((pc.status = 'active'::text) AND (pc.product_variant_id IS NOT NULL) AND (pc.cost_source_product_id IS DISTINCT FROM ( SELECT rc.supplier_product_id
                           FROM fn_route_candidates(pc.product_variant_id, pc.date, COALESCE(pc.channel_id, fn_default_context_channel()), fn_price_row_currency(pc.channel_id)) rc(supplier_product_id, supplier_variant_id, source_currency, net_price, supplier_price, is_price_locked, source_min_margin, cost_base, fx_rate_to_target, fx_as_of, priority, fallback_order, route_rank)
                          WHERE (rc.route_rank = 1))))) AS count
        UNION ALL
         SELECT 44,
            '售价行的币种必须等于该行的结算币种'::text,
            ( SELECT count(*) AS count
                   FROM price_calendar pc
                  WHERE ((pc.status = 'active'::text) AND (pc.product_variant_id IS NOT NULL) AND ((pc.currency)::text IS DISTINCT FROM fn_price_row_currency(pc.channel_id)))) AS count
        UNION ALL
         SELECT 45,
            '售价行留痕的汇率与快照必须自洽'::text,
            ( SELECT count(*) AS count
                   FROM (price_calendar pc
                     JOIN supplier_price_calendar spc ON (((spc.supplier_product_id = pc.cost_source_product_id) AND (NOT (spc.product_variant_id IS DISTINCT FROM pc.product_variant_id)) AND (spc.date = pc.date) AND (spc.status = 'available'::text))))
                  WHERE ((pc.status = 'active'::text) AND (pc.cost_source_product_id IS NOT NULL) AND (((spc.currency = pc.currency) AND ((pc.fx_as_of IS NOT NULL) OR (pc.fx_rate IS DISTINCT FROM (1)::numeric))) OR ((spc.currency <> pc.currency) AND ((pc.fx_as_of IS NULL) OR (pc.fx_rate IS DISTINCT FROM round(fn_fx_pair_rate((spc.currency)::text, (pc.currency)::text, pc.fx_as_of), 8))))))) AS count
        )
 SELECT seq,
    check_name,
    0 AS expected,
    actual,
    (actual = 0) AS passed,
        CASE
            WHEN (actual = 0) THEN 'PASS'::text
            ELSE 'FAIL'::text
        END AS result
   FROM raw;
CREATE OR REPLACE VIEW public.v_invariant_checks_tx AS WITH RECURSIVE edges(aggregate_type, from_status, to_status) AS (
         SELECT state_transition.aggregate_type,
            state_transition.from_status,
            state_transition.to_status
           FROM state_transition
        ), reach(aggregate_type, status) AS (
         SELECT e.aggregate_type,
            e.to_status
           FROM edges e
          WHERE (e.from_status = ''::text)
        UNION
         SELECT e.aggregate_type,
            e.to_status
           FROM (reach r
             JOIN edges e ON (((e.aggregate_type = r.aggregate_type) AND (e.from_status = r.status))))
        ), raw(seq, check_name, actual) AS (
         SELECT 46 AS "?column?",
            '订单状态必须可从初始状态沿合法边到达'::text AS "?column?",
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM reach
                          WHERE ((reach.aggregate_type = 'order'::text) AND (reach.status = o.status)))))) AS count
        UNION ALL
         SELECT 47,
            '订单明细状态必须可从初始状态沿合法边到达'::text,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM reach
                          WHERE ((reach.aggregate_type = 'order_item'::text) AND (reach.status = oi.status)))))) AS count
        UNION ALL
         SELECT 48,
            '预订状态必须可从初始状态沿合法边到达'::text,
            ( SELECT count(*) AS count
                   FROM booking b
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM reach
                          WHERE ((reach.aggregate_type = 'booking'::text) AND (reach.status = b.status)))))) AS count
        UNION ALL
         SELECT 49,
            '凭证状态必须可从初始状态沿合法边到达'::text,
            ( SELECT count(*) AS count
                   FROM voucher v
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM reach
                          WHERE ((reach.aggregate_type = 'voucher'::text) AND (reach.status = v.status)))))) AS count
        UNION ALL
         SELECT 50,
            '已确认订单必须有 confirmed/ticketed 的预订'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((o.status = ANY (ARRAY['confirmed'::text, 'partially_fulfilled'::text, 'fulfilled'::text])) AND (NOT (EXISTS ( SELECT 1
                           FROM booking b
                          WHERE ((b.order_id = o.id) AND (b.status = ANY (ARRAY['confirmed'::text, 'ticketed'::text])))))))) AS count
        UNION ALL
         SELECT 51,
            '已出票凭证必须挂在 confirmed/ticketed 的预订上'::text,
            ( SELECT count(*) AS count
                   FROM voucher v
                  WHERE ((v.status = ANY (fn_delivered_voucher_statuses())) AND (NOT (EXISTS ( SELECT 1
                           FROM booking b
                          WHERE ((b.id = v.booking_id) AND (b.status = ANY (ARRAY['confirmed'::text, 'ticketed'::text])))))))) AS count
        UNION ALL
         SELECT 52,
            '订单状态与履约状态必须一致'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE (((o.status = 'fulfilled'::text) AND (o.fulfillment_status <> 'fulfilled'::text)) OR ((o.status = ANY (ARRAY['cancelled'::text, 'failed'::text, 'refunded'::text])) AND (o.fulfillment_status = 'fulfilled'::text)))) AS count
        UNION ALL
         SELECT 53,
            '订单小计必须等于明细合计'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((EXISTS ( SELECT 1
                           FROM sales_order_item oi
                          WHERE (oi.order_id = o.id))) AND (o.subtotal <> ( SELECT sum(oi.total_price) AS sum
                           FROM sales_order_item oi
                          WHERE (oi.order_id = o.id))))) AS count
        )
 SELECT seq,
    check_name,
    0 AS expected,
    actual,
    (actual = 0) AS passed,
        CASE
            WHEN (actual = 0) THEN 'PASS'::text
            ELSE 'FAIL'::text
        END AS result
   FROM raw;
CREATE OR REPLACE VIEW public.v_invariant_checks_fulfill AS WITH item_state AS (
         SELECT oi.order_id,
            oi.id AS item_id,
            COALESCE(( SELECT sum(s.admission_quantity) AS sum
                   FROM sales_order_item_source s
                  WHERE (s.order_item_id = oi.id)), (oi.quantity)::numeric) AS quantity,
            COALESCE(( SELECT sum(ve.quantity) AS sum
                   FROM (voucher_entitlement ve
                     JOIN voucher v ON ((v.id = ve.voucher_id)))
                  WHERE ((v.order_item_id = oi.id) AND (v.status = ANY (fn_delivered_voucher_statuses())) AND (ve.entitlement_type = 'admission'::text))), (0)::bigint) AS delivered
           FROM sales_order_item oi
        ), raw(seq, check_name, expected, actual) AS (
         SELECT b.seq,
            b.check_name,
            b.expected,
            b.actual
           FROM v_invariant_checks_fulfill_base b
          WHERE (b.seq <> ALL (ARRAY[58, 60]))
        UNION ALL
         SELECT 58,
            '预订的源必须等于它覆盖的那些成分的源'::text,
            0,
            ( SELECT count(*) AS count
                   FROM (booking b
                     JOIN sales_order_item oi ON ((oi.id = b.order_item_id)))
                  WHERE (((EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id))) AND (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE ((s.order_item_id = oi.id) AND (NOT (s.supplier_variant_id IS DISTINCT FROM b.supplier_variant_id)) AND (NOT (s.supplier_session_id IS DISTINCT FROM b.supplier_session_id)) AND ((s.supplier_id IS DISTINCT FROM b.supplier_id) OR (s.supplier_product_id IS DISTINCT FROM b.supplier_product_id)))))) OR ((NOT (EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id)))) AND ((b.supplier_id IS DISTINCT FROM oi.supplier_id) OR (b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id))))) AS count
        UNION ALL
         SELECT 60,
            '订单的履约状态必须与明细的出票情况一致'::text,
            0,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE (((o.status = 'fulfilled'::text) AND (EXISTS ( SELECT 1
                           FROM item_state s
                          WHERE ((s.order_id = o.id) AND ((s.delivered)::numeric < s.quantity))))) OR ((o.status = 'partially_fulfilled'::text) AND (COALESCE(( SELECT sum(s.delivered) AS sum
                           FROM item_state s
                          WHERE (s.order_id = o.id)), (0)::numeric) = (0)::numeric)) OR ((o.status = ANY (ARRAY['booking_pending'::text, 'confirmed'::text, 'partially_fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM item_state s
                          WHERE (s.order_id = o.id))) AND (NOT (EXISTS ( SELECT 1
                           FROM item_state s
                          WHERE ((s.order_id = o.id) AND ((s.delivered)::numeric < s.quantity)))))))) AS count
        )
 SELECT seq,
    check_name,
    expected,
    actual,
    (actual = 0) AS passed,
        CASE
            WHEN (actual = 0) THEN 'PASS'::text
            ELSE 'FAIL'::text
        END AS result
   FROM raw;
CREATE OR REPLACE VIEW public.v_invariant_checks_fulfill_base AS WITH item_state AS (
         SELECT oi.order_id,
            oi.id AS item_id,
            oi.quantity,
            COALESCE(( SELECT sum(ve.quantity) AS sum
                   FROM (voucher_entitlement ve
                     JOIN voucher v ON ((v.id = ve.voucher_id)))
                  WHERE ((v.order_item_id = oi.id) AND (v.status = ANY (fn_delivered_voucher_statuses())) AND (ve.entitlement_type = 'admission'::text))), (0)::bigint) AS delivered
           FROM sales_order_item oi
        ), raw(seq, check_name, actual) AS (
         SELECT 55 AS "?column?",
            '支付金额必须等于订单应付金额'::text AS "?column?",
            ( SELECT count(*) AS count
                   FROM (sales_payment sp
                     JOIN sales_order o ON ((o.id = sp.order_id)))
                  WHERE ((sp.status = 'succeeded'::text) AND (sp.amount <> o.total))) AS count
        UNION ALL
         SELECT 56,
            '已支付订单必须有成功的支付记录'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((o.payment_status = 'paid'::text) AND (NOT (EXISTS ( SELECT 1
                           FROM sales_payment sp
                          WHERE ((sp.order_id = o.id) AND (sp.status = 'succeeded'::text))))))) AS count
        UNION ALL
         SELECT 57,
            '已确认订单的每条明细都必须有 confirmed/ticketed 的预订'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE ((o.status = ANY (ARRAY['confirmed'::text, 'fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM sales_order_item oi
                          WHERE ((oi.order_id = o.id) AND (NOT (EXISTS ( SELECT 1
                                   FROM booking b
                                  WHERE ((b.order_item_id = oi.id) AND (b.status = ANY (ARRAY['confirmed'::text, 'ticketed'::text]))))))))))) AS count
        UNION ALL
         SELECT 58,
            '预订的源必须等于订单明细的采纳源'::text,
            ( SELECT count(*) AS count
                   FROM (booking b
                     JOIN sales_order_item oi ON ((oi.id = b.order_item_id)))
                  WHERE ((b.supplier_id IS DISTINCT FROM oi.supplier_id) OR (b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id))) AS count
        UNION ALL
         SELECT 59,
            '预订的源场次必须绑定在该明细的规范场次上'::text,
            ( SELECT count(*) AS count
                   FROM (booking b
                     JOIN sales_order_item oi ON ((oi.id = b.order_item_id)))
                  WHERE ((b.supplier_session_id IS NULL) OR (NOT (EXISTS ( SELECT 1
                           FROM product_session_source pss
                          WHERE ((pss.product_session_id = oi.session_id) AND (pss.supplier_product_id = b.supplier_product_id) AND (pss.supplier_id = b.supplier_id) AND (pss.supplier_session_id = b.supplier_session_id))))))) AS count
        UNION ALL
         SELECT 60,
            '订单的履约状态必须与明细的出票情况一致'::text,
            ( SELECT count(*) AS count
                   FROM sales_order o
                  WHERE (((o.status = 'fulfilled'::text) AND (EXISTS ( SELECT 1
                           FROM item_state s
                          WHERE ((s.order_id = o.id) AND (s.delivered < s.quantity))))) OR ((o.status = 'partially_fulfilled'::text) AND (COALESCE(( SELECT sum(s.delivered) AS sum
                           FROM item_state s
                          WHERE (s.order_id = o.id)), (0)::numeric) = (0)::numeric)) OR ((o.status = ANY (ARRAY['booking_pending'::text, 'confirmed'::text, 'partially_fulfilled'::text])) AND (EXISTS ( SELECT 1
                           FROM item_state s
                          WHERE (s.order_id = o.id))) AND (NOT (EXISTS ( SELECT 1
                           FROM item_state s
                          WHERE ((s.order_id = o.id) AND (s.delivered < s.quantity)))))))) AS count
        )
 SELECT seq,
    check_name,
    0 AS expected,
    actual,
    (actual = 0) AS passed,
        CASE
            WHEN (actual = 0) THEN 'PASS'::text
            ELSE 'FAIL'::text
        END AS result
   FROM raw;
CREATE OR REPLACE VIEW public.v_invariant_checks_combo_base AS WITH raw(seq, check_name, actual) AS (
         SELECT 82 AS "?column?",
            '订单明细的成分变体必须属于该明细的商品'::text AS "?column?",
            ( SELECT count(*) AS count
                   FROM ((sales_order_item_source s
                     JOIN sales_order_item oi ON ((oi.id = s.order_item_id)))
                     JOIN product_variant cv ON ((cv.id = s.component_variant_id)))
                  WHERE (cv.product_id <> oi.product_id)) AS count
        UNION ALL
         SELECT 83,
            '订单明细的成分成本合计必须等于明细的采纳成本'::text,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE ((EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id))) AND (round(COALESCE(( SELECT sum((s.unit_cost * s.quantity)) AS sum
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id)), (0)::numeric), 2) IS DISTINCT FROM round((COALESCE((NULLIF((oi.detail_snapshot ->> 'cost_price'::text), ''::text))::numeric, (0)::numeric) * (
                        CASE
                            WHEN (oi.pricing_basis = 'per_group'::text) THEN 1
                            ELSE oi.quantity
                        END)::numeric), 2)))) AS count
        UNION ALL
         SELECT 84,
            '订单明细的成分入场份数必须与配方声明对得上'::text,
            ( SELECT count(*) AS count
                   FROM (sales_order_item oi
                     JOIN product_variant pv ON ((pv.id = oi.product_variant_id)))
                  WHERE ((EXISTS ( SELECT 1
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id))) AND (COALESCE(( SELECT sum(s.admission_quantity) AS sum
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id)), (0)::numeric) IS DISTINCT FROM
                        CASE
                            WHEN (pv.variant_role = 'combo'::text) THEN (( SELECT COALESCE(sum(r.quantity), (0)::numeric) AS "coalesce"
                               FROM product_variant_relation r
                              WHERE ((r.parent_variant_id = oi.product_variant_id) AND (r.relation_type = 'included'::text))) * (oi.quantity)::numeric)
                            ELSE (oi.quantity)::numeric
                        END))) AS count
        UNION ALL
         SELECT 85,
            '订单明细的成分必须来自同一个源且与明细的供应商一致'::text,
            (( SELECT count(*) AS count
                   FROM ( SELECT s.order_item_id
                           FROM sales_order_item_source s
                          GROUP BY s.order_item_id
                         HAVING (count(DISTINCT s.supplier_id) > 1)) x) + ( SELECT count(*) AS count
                   FROM (sales_order_item oi
                     JOIN sales_order_item_source s ON ((s.order_item_id = oi.id)))
                  WHERE (oi.supplier_id IS DISTINCT FROM s.supplier_id)))
        UNION ALL
         SELECT 86,
            '已出票的订单明细必须按成分把份数发够了'::text,
            ( SELECT count(*) AS count
                   FROM sales_order_item oi
                  WHERE ((oi.status = 'ticketed'::text) AND ((COALESCE(( SELECT sum(ve.quantity) AS sum
                           FROM (voucher_entitlement ve
                             JOIN voucher v ON ((v.id = ve.voucher_id)))
                          WHERE ((v.order_item_id = oi.id) AND (v.status = ANY (fn_delivered_voucher_statuses())) AND (ve.entitlement_type = 'admission'::text))), (0)::bigint))::numeric < COALESCE(( SELECT sum(s.admission_quantity) AS sum
                           FROM sales_order_item_source s
                          WHERE (s.order_item_id = oi.id)), (oi.quantity)::numeric)))) AS count
        )
 SELECT seq,
    check_name,
    0 AS expected,
    actual,
    (actual = 0) AS passed,
        CASE
            WHEN (actual = 0) THEN 'PASS'::text
            ELSE 'FAIL'::text
        END AS result
   FROM raw;
-- -------------------------------------------------------------------------------------
-- ⑤ 看得见：过期作业漏跑时，这里能数出来
--
-- 刻意不是门禁（见上面第四节）：漏跑是运维状态，不是数据违规。
-- 运营侧看到 overdue_count > 0 就知道该跑作业了。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_voucher_expiry_overdue AS
SELECT count(*)::INTEGER                                    AS overdue_count,
       min(v.valid_to)                                      AS oldest_valid_to,
       max(v.valid_to)                                      AS newest_valid_to,
       count(DISTINCT v.order_id)::INTEGER                  AS affected_orders
  FROM voucher v
 WHERE v.status = 'issued'
   AND v.valid_to IS NOT NULL
   AND v.valid_to <= now();

COMMENT ON VIEW public.v_voucher_expiry_overdue
    IS '过期作业漏跑时看得见的数：还有多少 issued 券已经过了有效期（不是门禁，是运维信号）';

-- -------------------------------------------------------------------------------------
-- ⑥ 不变量：只加不随时间漂移的
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_voucher_expiry AS
WITH raw(seq, check_name, actual) AS (
    -- 120：过期的券必须有有效期终点（NULL 的券永远不过期 —— 作业认不出来，那个坑一直在）
    SELECT 120, '过期的凭证必须有有效期终点',
           (SELECT count(*)
              FROM voucher v
             WHERE v.status = 'expired'
               AND v.valid_to IS NULL)
    UNION ALL
    -- 121：过期的券必须出票过（没出票的券不会过期 —— 这条挡的是「凭空过期」）
    SELECT 121, '过期的凭证必须已出票',
           (SELECT count(*)
              FROM voucher v
             WHERE v.status = 'expired'
               AND v.issued_at IS NULL)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_voucher_expiry
    IS '凭证过期侧不变量（120/121）：过期的券必须有有效期终点、必须已出票过';

-- 把新分支接进 v_invariant_checks（唯一来源：这里 UNION ALL 一次）。
--
-- 这里的分支清单**不在模板里手抄** —— 21 个分支的 UNION ALL 手抄一遍，
-- 下一个人加第 22 个分支时漏改一处，v_invariant_checks 就少一条门禁，
-- 而少的那条永远不会有人发现（它从来没红过）。
--
-- 所以取活定义（pg_get_viewdef）再接上新分支：分支清单的唯一来源是库里。
CREATE OR REPLACE VIEW v_invariant_checks AS SELECT v_invariant_checks_core_017.seq,
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
   FROM v_invariant_checks_hold_ttl
UNION ALL
 SELECT v_invariant_checks_voucher_expiry.seq,
    v_invariant_checks_voucher_expiry.check_name,
    v_invariant_checks_voucher_expiry.expected,
    v_invariant_checks_voucher_expiry.actual,
    v_invariant_checks_voucher_expiry.passed,
    v_invariant_checks_voucher_expiry.result
   FROM v_invariant_checks_voucher_expiry;