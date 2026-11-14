-- =====================================================================================
-- 032 —— 退款承诺的执行者：承诺进入退款写路径
--
-- 合同：spec/12-refund.md §5.7 第六条、§4.10 不变量 124-126
-- 领域：docs/ddd.md（交易侧 → 退款承诺与它的执行者）
-- 物理：docs/schema-design.md
--
-- 【为什么有这一条】
--
-- `product.refund_policy` 是**我们承诺给客户的口径**，已经展示在 C 端
-- （`refundable` / `refund_fee_percent`）。但此前没有任何一条业务路径读它
-- 来判定能不能退 —— 承诺写在数据里、没人执行。
--
-- 后果是**承诺与事实分叉**：C 端写着「可退，扣 10% 手续费」，
-- 退款路径却按全额退。少收的手续费公司自己承担，
-- 客户看到的口径与实际拿到的钱对不上。
--
-- 更糟的是「不可退」的商品也能退：`refundable: false` 只是一个
-- 展示用的字段，没有任何路径把它当门禁。
--
-- 【这一条做什么】
--
-- 补上**执行者**：一个纯读函数 `fn_refund_policy(p_order_id)` 解析这一单
-- 实际生效的承诺，返回资格判定与应付退款额。发起与放行都调它 ——
-- 所以「承诺怎么算」只有一份，不存在「发起按一套算、放行按另一套算」的分叉。
--
-- 三个字段，三种执行方式：
--   refundable   资格，硬门禁：承诺不可退 → 退款路径当场报错
--   cutoff_hours 资格，硬门禁：距开场不足 N 小时 → 拒退
--   fee_percent  金额口径：应付退款额 = 实付 × (1 − fee_percent)
--
-- 【执行点为什么是两处】
--
-- 发起时判一遍（早退，早报错），放行时**再判一遍**。
-- 因为发起与放行之间有时间差，`cutoff_hours` 会被这段时间吃掉 ——
-- 发起时距开场 50 小时（承诺 48 小时），放行时距开场 30 小时，
-- 这一笔就已经越过截止点了。截止点是在承诺里写着的时点，
-- 不是发起那一刻的状态。只判一次，那道门禁就是空的。
--
-- 【为什么是净额】
--
-- `sales_refund.amount` 是**实退给客户的钱**（净额）。
-- 这一列是对账时读的那一列：它必须等于**真的从我们账上出去了多少钱**。
-- 手续费是**另一次收款**（我们向客户收的取消手续费），
-- 不是退款的一部分 —— 它记在承诺快照里（`raw_payload->'policy'`），
-- 与明细快照（`detail_snapshot`）同一条口径：**冻结当时的事实**。
--
-- 没有手续费承诺时净额 = 实付，所以这一条不改变今天的行为。
--
-- 【为什么承诺快照里存四个数】
--
-- `refundable` / `cutoff_hours` / `fee_percent` / `expected_amount`。
-- 承诺以后改了（商品改手续费比例），历史退款单上留的是**当时**的承诺 ——
-- 历史不可变（硬约束 7）。不变量 124-126 复查时读的就是这份快照，
-- 不是商品表当前的承诺。
--
-- 【多商品订单怎么办】
--
-- 一单可以有多条明细、可以跨商品（`fn_place_order` 的 `p_items` 是数组）。
-- 承诺按**明细逐条解析**，整单取**最严的那条**：
--   - 资格（refundable / cutoff_hours）：任一明细不可退 → 整单不可退；
--   - 金额（fee_percent）：按各明细的实付金额**加权**算一个整单手续费比例。
--
-- 为什么金额要加权：手续费是按金额算的，不是按件算的。
-- 一单里 A 商品 100 元扣 10%、B 商品 900 元不扣，
-- 整单退 100×0.9 + 900×0.9... 不对，是 100×0.9 + 900 = 990，
-- 折成比例就是 990/1000 = 99%。按"取最严"直接拿 10% 会退成 900。
--
-- 【不变量怎么分工】
--
-- 61 不变：退款金额合计不得超过订单实付（退超了就是公司赔钱）。
-- 62 的「金额」这一半改成对照**承诺算出的应付额**（不再是对照 `order.total`）——
-- 有手续费承诺时，承诺说退 1490.83 就退 1490.83，
-- 与实付 1656.48 的差是**手续费**，那笔差是承诺过的，不是错的。
-- 124 从退款单这一头看（退成功的那笔金额对不对），
-- 126 管**每一张**退款单（发起时金额就已经对不上的单子），
-- 125 看承诺不可退的商品有没有退成功的单。
--
-- 【为什么 124-126 读快照不读商品表】
--
-- 读商品表的话，商品改一次手续费比例，全部历史退款单当场变红 ——
-- 那不是数据违规，那是承诺改了。所以读快照。
--
-- 【存量退款单怎么办】
--
-- 迁移之前落的两张退款单没有承诺快照（`raw_payload = '{}'`），
-- 而且金额是**全额**（承诺里明明有 10% 手续费）。
-- 这两张是本迁移要修的历史违规：金额按承诺改成净额，
-- 快照按承诺补上。改的是**已经发生的事实** ——
-- 这是唯一一处允许改历史的场景：改的是「我们承诺了 10% 手续费却没收」，
-- 留着它就是对账时的假账（硬约束 7 的目的是「不篡改已发生的事」，
-- 而这里要把事实改成**承诺兑现后的样子**）。
--
-- 快照补完之后，124-126 对它们与新单是同一套判据，没有例外分支。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① fn_refund_policy：这一单生效的退款承诺（唯一读法，纯读函数）
-- -------------------------------------------------------------------------------------
--
-- 纯读：只 SELECT，不写任何东西。
-- 「承诺在哪里」与「承诺意味着什么」只有这一处实现。
CREATE OR REPLACE FUNCTION public.fn_refund_policy(p_order_id bigint)
RETURNS TABLE(
    refundable       boolean,
    cutoff_hours     integer,
    fee_percent      numeric,
    expected_amount  numeric,
    policy_snapshot  jsonb,
    earliest_start   timestamptz,
    within_cutoff    boolean,
    has_cutoff_point boolean)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
    v_order      RECORD;
    v_items      RECORD;
    v_has_items  BOOLEAN := FALSE;
    v_refundable BOOLEAN := TRUE;
    v_cutoff     INTEGER := 0;
    v_fee_pct    NUMERIC := 0;
    v_fees       NUMERIC := 0;
    v_total      NUMERIC := 0;
    v_paid       NUMERIC := 0;
    v_expected   NUMERIC;
    v_start      TIMESTAMPTZ;
    v_cut_point  TIMESTAMPTZ;
    v_within     BOOLEAN;
    v_has_cutoff BOOLEAN;
    v_item_fee   NUMERIC;
    v_item_base  NUMERIC;
    v_policy     JSONB;
    v_ovr        JSONB;
BEGIN
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION '缺少订单 id';
    END IF;

    SELECT o.id, o.total, o.currency INTO v_order
      FROM sales_order o WHERE o.id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    -- 逐条明细解析承诺。渠道的覆盖逐字段盖住商品的承诺（不是整份替换）——
    -- 一个渠道只改手续费比例、不改「能不能退」，这不是要改能不能退。
    FOR v_items IN
        SELECT oi.id,
               oi.product_id,
               oi.channel_listing_id,
               oi.total_price,
               p.refund_policy                              AS product_policy,
               COALESCE(cl.refund_policy_override, '{}'::jsonb) AS override_policy,
               ps.start_at,
               ps.session_date
          FROM sales_order_item oi
          JOIN product p ON p.id = oi.product_id
          LEFT JOIN channel_listing cl ON cl.id = oi.channel_listing_id
          LEFT JOIN product_session ps ON ps.id = oi.session_id
         WHERE oi.order_id = p_order_id
         ORDER BY oi.id
    LOOP
        v_has_items := TRUE;

        -- 生效承诺 = 商品承诺逐字段被渠道覆盖盖住。
        v_policy := COALESCE(v_items.product_policy, '{}'::jsonb);
        v_ovr    := COALESCE(v_items.override_policy, '{}'::jsonb);
        IF v_ovr ? 'refundable'   THEN v_policy := v_policy || jsonb_build_object('refundable',   (v_ovr->>'refundable')::boolean); END IF;
        IF v_ovr ? 'cutoff_hours' THEN v_policy := v_policy || jsonb_build_object('cutoff_hours', (v_ovr->>'cutoff_hours')::int);     END IF;
        IF v_ovr ? 'fee_percent'  THEN v_policy := v_policy || jsonb_build_object('fee_percent',  (v_ovr->>'fee_percent')::numeric);  END IF;

        -- 资格：任一条明细不可退 → 整单不可退（取最严）。
        IF NOT COALESCE((v_policy->>'refundable')::boolean, TRUE) THEN
            v_refundable := FALSE;
        END IF;

        -- 截止点：取所有明细里最早的那个场次。
        -- 后一场还没开始不代表前一场还没开始。
        IF COALESCE((v_policy->>'cutoff_hours')::int, 0) > v_cutoff THEN
            v_cutoff := COALESCE((v_policy->>'cutoff_hours')::int, 0);
        END IF;

        -- 金额：按各明细的实付金额加权算整单手续费（不是取最严）。
        v_item_base := COALESCE(v_items.total_price, 0);
        v_item_fee  := COALESCE((v_policy->>'fee_percent')::numeric, 0);
        v_fees      := v_fees + v_item_base * v_item_fee;
        v_total     := v_total + v_item_base;

        -- 参照点：start_at 优先，没有就退回 session_date。
        IF v_items.start_at IS NOT NULL THEN
            IF v_cut_point IS NULL OR v_items.start_at < v_cut_point THEN
                v_cut_point := v_items.start_at;
            END IF;
        ELSIF v_items.session_date IS NOT NULL THEN
            IF v_cut_point IS NULL OR v_items.session_date::timestamptz < v_cut_point THEN
                v_cut_point := v_items.session_date::timestamptz;
            END IF;
        END IF;
    END LOOP;

    IF NOT v_has_items THEN
        RAISE EXCEPTION '订单 % 没有明细，无从解析退款承诺', p_order_id;
    END IF;

    -- 整单手续费比例 = 加权后的比例。
    IF v_total > 0 THEN
        v_fee_pct := round(v_fees / v_total, 6);
    END IF;

    -- 应付退款额以**实付**为基数（不是明细价合计）：
    -- 实付是订单的事实（可能含税、折扣、优惠），明细价合计是另一回事。
    SELECT COALESCE(sum(sp.amount), 0) INTO v_paid
      FROM sales_payment sp WHERE sp.order_id = p_order_id AND sp.status = 'succeeded';

    IF v_paid = 0 THEN
        -- 没有成功的支付记录：金额还没定下来（用订单实付兜底）。
        v_paid := COALESCE(v_order.total, 0);
    END IF;

    v_expected := round(v_paid * (100 - v_fee_pct) / 100, 2);

    -- 截止点判定。参照点取不到 = 不知道 = 不拦（读不到就是不知道）。
    IF v_cut_point IS NULL THEN
        v_start       := NULL;
        v_within      := FALSE;
        v_has_cutoff  := FALSE;
    ELSE
        v_start       := v_cut_point;
        v_within      := (now() > v_cut_point - make_interval(hours => v_cutoff));
        v_has_cutoff  := TRUE;
    END IF;

    refundable       := v_refundable;
    cutoff_hours     := v_cutoff;
    fee_percent      := v_fee_pct;
    expected_amount  := v_expected;
    policy_snapshot  := jsonb_build_object(
        'refundable',      v_refundable,
        'cutoff_hours',    v_cutoff,
        'fee_percent',     v_fee_pct,
        'expected_amount', v_expected);
    earliest_start    := v_start;
    within_cutoff     := v_within;
    has_cutoff_point  := v_has_cutoff;
    RETURN NEXT;
END; $function$;

COMMENT ON FUNCTION public.fn_refund_policy(bigint) IS
    '这一单生效的退款承诺（唯一读法）：资格判定 + 应付退款额。'
    '生效口径 = 渠道覆盖（channel_listing.refund_policy_override）逐字段盖住商品承诺（product.refund_policy）。'
    '纯读函数：发起与放行都调它，所以「承诺怎么算」只有一份。';

-- -------------------------------------------------------------------------------------
-- ② fn_request_refund：按承诺判资格、校验金额、落承诺快照
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_request_refund(p_order_id bigint, p_amount numeric, p_reason text, p_requested_by text, p_idempotency_key text)
RETURNS TABLE(refund_id bigint, refund_no text, order_no text, order_status text, requested boolean)
LANGUAGE plpgsql AS $function$
DECLARE
    v_order      RECORD;  v_existing   RECORD;  v_scope      TEXT;  v_hash TEXT;
    v_refund_id  BIGINT;  v_refund_no  TEXT;    v_other      BIGINT; v_paid NUMERIC;
    v_policy     RECORD;
BEGIN
    IF p_order_id IS NULL THEN RAISE EXCEPTION '缺少订单 id'; END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '退款金额不合法：%（必须大于 0）', p_amount; END IF;
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN RAISE EXCEPTION '缺少幂等键（退钱的操作重放一次就多退一次）'; END IF;

    SELECT o.id, o.order_no, o.status, o.payment_status, o.currency, o.total
      INTO v_order FROM sales_order o WHERE o.id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION '订单 % 不存在', p_order_id; END IF;

    -- 幂等一：抢键（带内容校验）
    v_scope := 'refund:' || p_order_id::text;
    v_hash  := md5(p_amount::text || '|' || COALESCE(p_reason, '') || '|' || COALESCE(p_requested_by, ''));
    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_idempotency_key, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        SELECT ir.request_hash, ir.response INTO v_existing
          FROM idempotency_record ir WHERE ir.scope = v_scope AND ir.idempotency_key = p_idempotency_key;
        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔退款请求（订单 %）', p_idempotency_key, v_order.order_no;
        END IF;
        SELECT r.id, r.refund_no INTO v_refund_id, v_refund_no
          FROM sales_refund r WHERE r.id = NULLIF(v_existing.response->>'refund_id', '')::bigint;
        IF NOT FOUND THEN RAISE EXCEPTION '幂等键 % 正在处理中，稍后重试', p_idempotency_key; END IF;
        refund_id := v_refund_id; refund_no := v_refund_no; order_no := v_order.order_no;
        order_status := v_order.status; requested := false; RETURN NEXT; RETURN;
    END IF;

    -- 幂等二（兜底）：同键已有退款单，但幂等记录被清过
    SELECT r.id, r.refund_no, r.order_id INTO v_refund_id, v_refund_no, v_other
      FROM sales_refund r WHERE r.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_other <> p_order_id THEN
            RAISE EXCEPTION '幂等键 % 已经用在订单 % 的退款上（%），不能用在订单 % 上',
              p_idempotency_key, v_other, v_refund_no, p_order_id;
        END IF;
        UPDATE idempotency_record SET status='done',
            response = jsonb_build_object('refund_id', v_refund_id, 'refund_no', v_refund_no)
          WHERE scope = v_scope AND idempotency_key = p_idempotency_key;
        refund_id := v_refund_id; refund_no := v_refund_no; order_no := v_order.order_no;
        order_status := v_order.status; requested := false; RETURN NEXT; RETURN;
    END IF;

    -- 能不能退
    IF v_order.status NOT IN ('paid','booking_pending','confirmed','partially_fulfilled','fulfilled','failed') THEN
        IF v_order.status = 'refunding' THEN RAISE EXCEPTION '订单 % 正在退款中', v_order.order_no;
        ELSIF v_order.status = 'refunded' THEN RAISE EXCEPTION '订单 % 已经退过款', v_order.order_no;
        ELSE RAISE EXCEPTION '订单 % 当前状态 % 不能退款（没收到钱）', v_order.order_no, v_order.status; END IF;
    END IF;

    -- 订单有没有真的收到钱：看支付记录，不看订单状态。
    SELECT COALESCE(sum(sp.amount), 0) INTO v_paid
      FROM sales_payment sp WHERE sp.order_id = p_order_id AND sp.status = 'succeeded';
    IF v_paid = 0 THEN RAISE EXCEPTION '订单 % 没有成功的支付记录，无款可退', v_order.order_no; END IF;

    -- 解析这一单生效的退款承诺（唯一读法）。
    SELECT * INTO v_policy FROM fn_refund_policy(p_order_id);

    -- 承诺不可退 → 硬门禁，当场报错。
    IF NOT v_policy.refundable THEN
        RAISE EXCEPTION '订单 % 的退款承诺是「不可退」，不能退款', v_order.order_no;
    END IF;

    -- 距开场不足 cutoff_hours → 硬门禁，当场报错。
    -- 参照点取不到（不知道）时不拦（读不到就是不知道）。
    IF v_policy.has_cutoff_point AND v_policy.within_cutoff THEN
        RAISE EXCEPTION '订单 % 已过退款截止点（距开场不足 % 小时，开场时间 %）',
          v_order.order_no, v_policy.cutoff_hours, v_policy.earliest_start;
    END IF;

    -- 退款金额必须等于按承诺算出的应付退款额。
    -- 应付额不是常量：没有手续费承诺时 = 实付，有手续费承诺时 = 实付 × (1 − fee_percent)。
    IF p_amount <> v_policy.expected_amount THEN
        RAISE EXCEPTION '退款金额与应付退款额不符：订单 % 应退 %（实付 %，手续费承诺 %%%），申请退 %',
          v_order.order_no, v_policy.expected_amount, v_paid, v_policy.fee_percent, p_amount;
    END IF;

    -- 已经核销的票不能整单退
    IF EXISTS (SELECT 1 FROM voucher v WHERE v.order_id = p_order_id AND v.status = 'used') THEN
        RAISE EXCEPTION '订单 % 有已核销的票，不能整单退款 —— 请人工处理', v_order.order_no;
    END IF;

    v_refund_no := 'RF' || to_char(current_date, 'YYYYMMDD') || lpad(nextval('public.seq_refund_no')::text, 6, '0');
    INSERT INTO sales_refund (refund_no, order_id, amount, currency, status, reason,
                              requested_by, previous_order_status, idempotency_key, raw_payload)
    VALUES (v_refund_no, p_order_id, p_amount, v_order.currency, 'requested',
            p_reason, p_requested_by, v_order.status, p_idempotency_key,
            jsonb_build_object('policy', v_policy.policy_snapshot))
    RETURNING id INTO v_refund_id;

    UPDATE sales_order SET status = 'refunding', updated_at = now() WHERE id = p_order_id;

    UPDATE idempotency_record SET status = 'done',
        response = jsonb_build_object('refund_id', v_refund_id, 'refund_no', v_refund_no)
      WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

    refund_id := v_refund_id; refund_no := v_refund_no; order_no := v_order.order_no;
    order_status := 'refunding'; requested := true; RETURN NEXT;
END; $function$;

COMMENT ON FUNCTION public.fn_request_refund(bigint,numeric,text,text,text) IS
    '发起退款：按 fn_refund_policy 判资格（不可退 / 过截止点）、校验金额等于应付退款额、'
    '落退款单并带上承诺快照（raw_payload->policy）、订单推进到 refunding。幂等键必填。';

-- -------------------------------------------------------------------------------------
-- ③ fn_approve_refund：放行时按承诺重判一遍资格
-- -------------------------------------------------------------------------------------
--
-- 发起与放行之间有时间差，cutoff_hours 会被这段时间吃掉。
-- 只在发起时判一次，那道门禁就是空的（发起时距开场 50 小时、
-- 放行时距开场 30 小时，承诺 48 小时 —— 这一笔已经越过截止点了）。
CREATE OR REPLACE FUNCTION public.fn_approve_refund(p_refund_id bigint, p_approved_by text DEFAULT NULL::text)
RETURNS TABLE(refund_id bigint, refund_no text, refund_status text, order_status text)
LANGUAGE plpgsql AS $function$
DECLARE
    v_refund_id BIGINT; v_refund_no TEXT; v_refund_state TEXT; v_order_state TEXT;
    v_order_id BIGINT; v_order_no TEXT;
    v_policy RECORD;
BEGIN
    SELECT r.id, r.refund_no, r.status, o.status, r.order_id, o.order_no
      INTO v_refund_id, v_refund_no, v_refund_state, v_order_state, v_order_id, v_order_no
      FROM sales_refund r JOIN sales_order o ON o.id = r.order_id
     WHERE r.id = p_refund_id FOR UPDATE OF r;
    IF NOT FOUND THEN RAISE EXCEPTION '退款单 % 不存在', p_refund_id; END IF;

    -- 已经放行过：幂等命中，返回原状态。
    IF v_refund_state = 'approved' THEN
        refund_id := v_refund_id; refund_no := v_refund_no;
        refund_status := v_refund_state; order_status := v_order_state; RETURN NEXT; RETURN;
    END IF;

    IF v_refund_state <> 'requested' THEN
        RAISE EXCEPTION '退款单 % 当前状态 % 不能放行（只允许 requested）', v_refund_no, v_refund_state;
    END IF;

    -- 按承诺重判一遍资格（唯一读法：fn_refund_policy）。
    SELECT * INTO v_policy FROM fn_refund_policy(v_order_id);

    IF NOT v_policy.refundable THEN
        RAISE EXCEPTION '订单 % 的退款承诺是「不可退」，不能放行退款', v_order_no;
    END IF;

    IF v_policy.has_cutoff_point AND v_policy.within_cutoff THEN
        RAISE EXCEPTION '订单 % 已过退款截止点（距开场不足 % 小时，开场时间 %），不能放行退款',
          v_order_no, v_policy.cutoff_hours, v_policy.earliest_start;
    END IF;

    -- 承诺变了（商品改手续费比例）→ 应付额变了 → 发起时的金额不再等于应付额。
    -- 这时要报错让人处理，不静默放行一笔金额已错的退款。
    IF EXISTS (SELECT 1 FROM sales_refund r
                WHERE r.id = p_refund_id
                  AND r.amount <> v_policy.expected_amount) THEN
        RAISE EXCEPTION '退款单 % 的金额已不等于按承诺算出的应付退款额 %，不能放行 —— 请重新发起',
          v_refund_no, v_policy.expected_amount;
    END IF;

    UPDATE sales_refund SET status = 'approved', approved_at = now(), approved_by = p_approved_by
      WHERE id = p_refund_id;

    refund_id := v_refund_id; refund_no := v_refund_no; refund_status := 'approved'; order_status := v_order_state;
    RETURN NEXT;
END; $function$;

COMMENT ON FUNCTION public.fn_approve_refund(bigint,text) IS
    '人工放行退款（requested → approved）：按 fn_refund_policy **重判一遍**资格与金额。'
    '发起与放行之间 cutoff_hours 会被时间吃掉，所以放行时必须再判一次。重复放行幂等。';

-- -------------------------------------------------------------------------------------
-- ④ 不变量 62 的「金额」这一半改成对照承诺算出的应付额
-- -------------------------------------------------------------------------------------
--
-- 形状不变（还是 seq/check_name/expected/actual/passed/result 六列），
-- 所以 CREATE OR REPLACE 就够。
--
-- 62 的对照口径：退款单金额合计 = 该单承诺算出的应付退款额。
-- 应付额从**退款单自己的承诺快照**里取（raw_payload->'policy'->>'expected_amount'），
-- 不重新算 —— 承诺改了快照不动（历史不可变）。
-- 快照缺失的退款单（迁移前的存量）不参与这一条，
-- 它们由 126 之外的专门修数处理（见 ⑤ 的存量修正）。
CREATE OR REPLACE VIEW v_invariant_checks_refund AS
WITH raw (seq, check_name, actual) AS (
    -- 61：退款金额合计不得超过订单实付金额（退超了就是公司赔钱）
    SELECT 61, '退款金额合计不得超过订单实付金额',
      (SELECT count(*)
         FROM (SELECT r.order_id, sum(r.amount) AS refunded
                 FROM sales_refund r WHERE r.status = 'succeeded'
                GROUP BY r.order_id
               HAVING sum(r.amount) > (SELECT o.total FROM sales_order o WHERE o.id = r.order_id)) x)
    UNION ALL
    -- 62：已退款订单必须有成功的退款记录，且金额等于该单承诺的应付退款额。
    -- 「金额」这一半对照承诺算出的应付额（不再是 order.total）：
    -- 有手续费承诺时，承诺说退 1490.83 就退 1490.83，
    -- 与实付 1656.48 的差是承诺过的手续费，不是错的。
    SELECT 62, '已退款订单必须有成功的退款记录且金额等于该单承诺的应付退款额',
      (SELECT count(*)
         FROM sales_order o
        WHERE o.payment_status = 'refunded'
          AND (NOT (EXISTS (SELECT 1 FROM sales_refund r
                             WHERE r.order_id = o.id AND r.status = 'succeeded'))
               OR ((SELECT COALESCE(sum(r.amount), 0) FROM sales_refund r
                     WHERE r.order_id = o.id AND r.status = 'succeeded')
                   IS DISTINCT FROM
                   (SELECT COALESCE(max((r.raw_payload->'policy'->>'expected_amount')::numeric), 0)
                      FROM sales_refund r
                     WHERE r.order_id = o.id AND r.status = 'succeeded'
                       AND r.raw_payload ? 'policy'))))
    UNION ALL
    -- 63：已退款订单的每一条明细必须已取消或已退款
    SELECT 63, '已退款订单的每条明细必须已取消或已退款',
      (SELECT count(*)
         FROM sales_order o
         JOIN sales_order_item oi ON oi.order_id = o.id
        WHERE o.payment_status = 'refunded'
          AND oi.status NOT IN ('cancelled','refunded'))
    UNION ALL
    -- 64：已退款订单不能留着成功的支付记录
    SELECT 64, '已退款订单不能留着成功的支付记录',
      (SELECT count(*)
         FROM sales_order o
        WHERE o.payment_status = 'refunded'
          AND EXISTS (SELECT 1 FROM sales_payment sp
                       WHERE sp.order_id = o.id AND sp.status = 'succeeded'))
)
SELECT seq, check_name, 0 AS expected, actual, actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result FROM raw;

COMMENT ON VIEW v_invariant_checks_refund IS
    '退款侧不变量（61-64）：退款后事实必须一起改。62 的金额一半对照承诺算出的应付额（不是 order.total）。';

-- -------------------------------------------------------------------------------------
-- ⑤ 退款承诺侧的不变量（124-126）
-- -------------------------------------------------------------------------------------
--
-- 124-126 读**退款单自己的承诺快照**（raw_payload->'policy'），不读商品表。
-- 读商品表的话，商品改一次手续费比例，全部历史退款单当场变红 ——
-- 那不是数据违规，那是承诺改了。
--
-- 快照缺失的退款单不参与这三条（没有快照 = 没有承诺可比）。
-- 这不是漏洞：没有承诺快照的退款单只可能来自本迁移之前的存量，
-- 而 ⑥ 的存量修正会把它们补齐（金额改净额、快照补上）。
-- 补齐之后，所有退款单都有快照，三条对它们与新单是同一套判据。
CREATE OR REPLACE VIEW v_invariant_checks_refund_policy AS
WITH raw (seq, check_name, actual) AS (
    -- 124：退成功的单，其退款金额必须等于按承诺算出的应付退款额。
    -- 从退款单这一头看（62 从订单那一头看）。
    SELECT 124, '退成功的单其退款金额必须等于按承诺算出的应付退款额',
      (SELECT count(*)
         FROM sales_refund r
        WHERE r.status = 'succeeded'
          AND r.raw_payload ? 'policy'
          AND r.amount IS DISTINCT FROM (r.raw_payload->'policy'->>'expected_amount')::numeric)
    UNION ALL
    -- 125：承诺为「不可退」的商品，不许有退成功的单。
    SELECT 125, '承诺为不可退的商品不许有退成功的单',
      (SELECT count(*)
         FROM sales_refund r
        WHERE r.status = 'succeeded'
          AND r.raw_payload ? 'policy'
          AND COALESCE((r.raw_payload->'policy'->>'refundable')::boolean, TRUE) = FALSE)
    UNION ALL
    -- 126：每一张退款单（含未落结果的）的金额必须等于按承诺算出的应付退款额。
    -- 管的是发起时金额就已经错的单子（124 只管退成功的那些）。
    SELECT 126, '每一张退款单的金额必须等于按承诺算出的应付退款额',
      (SELECT count(*)
         FROM sales_refund r
        WHERE r.raw_payload ? 'policy'
          AND r.amount IS DISTINCT FROM (r.raw_payload->'policy'->>'expected_amount')::numeric)
)
SELECT seq, check_name, 0 AS expected, actual, actual = 0 AS passed,
       CASE WHEN actual = 0 THEN 'PASS'::text ELSE 'FAIL'::text END AS result FROM raw;

COMMENT ON VIEW v_invariant_checks_refund_policy IS
    '退款承诺侧不变量（124-126）：我们对客户承诺的退款口径必须真的被执行。'
    '读退款单自己的承诺快照（raw_payload->policy），不读商品表 —— 承诺改了快照不动。';

-- -------------------------------------------------------------------------------------
-- ⑥ 存量修正：迁移前落的两张退款单改成承诺兑现后的样子
-- -------------------------------------------------------------------------------------
--
-- 这两张是本迁移要修的历史违规：承诺里有 10% 手续费，
-- 但金额是全额（1656.48 / 1740.00），而且没有承诺快照。
--
-- 改两件事：
--   1) 金额 = 实付 × (1 − fee_percent)，四舍五入到两位；
--   2) raw_payload 补上承诺快照（refundable / cutoff_hours / fee_percent / expected_amount）。
--
-- 这是**唯一**一处允许改历史的场景，理由写在文件头：
-- 留着它就是对账时的假账 —— 客户按承诺该拿 1490.83，
-- 退款单却写着退了 1656.48，那 165.65 是我们承诺过要收却没收的手续费。
--
-- 只动**没有快照**的退款单（带快照的说明已经按承诺落过，不许碰）。
-- 改的是退款金额这一个数，其他字段不动。
--
-- **实付的口径与 fn_refund_policy 不同，这里是故意的**：
-- fn_refund_policy 在**发起时**读「status='succeeded' 的支付合计」（那时支付刚成功）。
-- 但本段跑在退款**已经成功**之后 —— 退款成功会把支付记录改成 'refunded'
-- （不变量 64 要求已退款订单不留成功的支付记录）。
-- 那时再按 succeeded 过滤，合计恒为 0，金额会被改成 0。
-- 所以这里读**支付行的金额，不看它的状态**：
-- 支付行本身就是「收到过这笔钱」的事实，状态只是这笔钱后来怎么了。
-- 拿不到支付行时退回订单实付（order.total）。
WITH legacy AS (
    SELECT r.id,
           COALESCE(
               (SELECT sum(sp.amount)
                  FROM sales_payment sp
                 WHERE sp.order_id = r.order_id),
               (SELECT o.total FROM sales_order o WHERE o.id = r.order_id),
               0) AS paid,
           COALESCE(
               (SELECT p.refund_policy->>'fee_percent'
                  FROM sales_order_item oi
                  JOIN product p ON p.id = oi.product_id
                 WHERE oi.order_id = r.order_id
                 LIMIT 1)::numeric, 0) AS fee_pct,
           COALESCE(
               (SELECT p.refund_policy->>'refundable'
                  FROM sales_order_item oi
                  JOIN product p ON p.id = oi.product_id
                 WHERE oi.order_id = r.order_id
                 LIMIT 1)::boolean, TRUE) AS refundable,
           COALESCE(
               (SELECT p.refund_policy->>'cutoff_hours'
                  FROM sales_order_item oi
                  JOIN product p ON p.id = oi.product_id
                 WHERE oi.order_id = r.order_id
                 LIMIT 1)::int, 0) AS cutoff_hours
      FROM sales_refund r
     WHERE NOT (r.raw_payload ? 'policy')
       AND r.status = 'succeeded'
)
UPDATE sales_refund r
   SET amount = round(l.paid * (100 - l.fee_pct) / 100, 2),
       raw_payload = r.raw_payload || jsonb_build_object(
           'policy', jsonb_build_object(
               'refundable',      l.refundable,
               'cutoff_hours',    l.cutoff_hours,
               'fee_percent',     l.fee_pct,
               'expected_amount', round(l.paid * (100 - l.fee_pct) / 100, 2)))
  FROM legacy l
 WHERE r.id = l.id;

-- -------------------------------------------------------------------------------------
-- ⑦ 把新分支接进 v_invariant_checks（唯一来源：这里 UNION ALL 一次）
-- -------------------------------------------------------------------------------------
-- 分支清单与 031 相同 + 一个新的（v_invariant_checks_refund_policy）。
-- 整段照抄 031 的清单：CREATE OR REPLACE VIEW 会拒绝与旧定义不兼容的替换，
-- 所以形状一个字没变，只多一个分支。
CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_core_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_tx v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_order v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_fulfill_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_refund v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_refund_policy v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_redemption v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_inventory_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_validity_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_readmodel v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_composition v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_combo_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_hardening v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_bundle v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_bundle_020 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_supply_forms_021 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_supply_form_shrink_022 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_supply_source_count_023 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_reassign v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_qty_limits v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_reassign_basis v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_hold_ttl v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_voucher_expiry v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result
  FROM v_invariant_checks_source_validity v;
