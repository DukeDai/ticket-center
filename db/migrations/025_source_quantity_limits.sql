-- =====================================================================================
-- 025. 源侧的售卖份数区间（min_qty / max_qty）—— 以前没人读的一手事实
--
-- 是什么：
--   supplier_price_calendar 上有一对整数：min_qty / max_qty。
--   它说的是「这份报价能接的最小 / 最大份数」：
--     min_qty > 1 = 最少成团人数（携程 priceSettingType=4 的「最少 6 人成团」）；
--     max_qty     = 单笔上限。
--   种子里已经填了（按团报价那张票的源价行是 6 到 40 份），
--   但全库没有一处读它 —— 这条事实一直是死的。
--
-- 为什么非读不可：
--   按团报价的源价行是「整团 1200，最少 6 人」。
--   客户只买 1 张 → 系统按整团价收了 1200 → 源侧因为不足 6 人直接拒单。
--   钱收了、票出不来 —— 这是「收了钱出不了票」最典型的形态。
--
-- 七条口径：
--   1. 区间是源侧的一手事实，唯一读法是 fn_source_quantity_limits；
--      能不能接由 fn_qty_servable 判。两件事各一处，不在别处再写一遍比较。
--   2. 份数的单位 = 源侧的售卖单位，也就是我们发给源侧的那条预订里的份数：
--        单张·按人 = 份（票），单张·按团 = 人（团人数），套装 = 套，
--        配方 = 该源 SKU 的份数。
--      同一个源 SKU 顶多个成分时，源侧收到的是**一条预订里的总份数**
--      （2 份成人 + 1 份儿童 = 3 份），按成分各判各的会漏掉「合起来超上限」。
--   3. 落单时必须落在采纳源的区间内，否则当场报错说清差在哪
--      （源、日期、区间、这一单的份数）。不拦下来就是收了钱出不了票。
--   4. 按团报价的团总价只在人数达标时成立 —— 1 个人不能按团价成交。
--   5. 我们不按份数换源。换了源就是另一个价，而售价行没有份数维度；
--      要按份数换源，得给价格加阶梯（另一个增量）。这次只做「如实拦住 + 说清」。
--   6. 改派也要守这条：新源接不住这一单的份数 → 拒绝改派
--      （不许改成一个出不了票的源）。
--   7. 区间记进明细快照的 quantity_limits —— 事后对账的依据
--      （源侧改了他的成团人数，我们这边记的是当时那一版）。
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- ① 一手事实的唯一读法
--
-- 源价行上的那一对整数，按「源变体 × 规范变体 × 日期」这一行读出来 ——
-- 这把键与选源函数（fn_route_candidates）连源价行时用的是同一把，
-- 所以读到的一定是定价时看到的那一行，不是另一行。
--
-- 规范变体给的是**数组**：一个源 SKU 可能顶多个规范变体（配方里成人与儿童
-- 共用一个源 SKU），那些报价行上的区间都要容得下这一单在这个源 SKU 上的总份数。
-- 取最紧的那一版（最大的下限、最小的上限）—— 数据不一致时按紧的走，
-- 不往松了放（往松了放就是放过一次超卖）。
--
-- 读不到（源价行不存在 / 不在售）→ 没有区间这件事 → 返回空行，
-- 调用方按「没有约束」处理。不猜。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_source_quantity_limits(
    p_supplier_variant_id BIGINT,
    p_product_variant_ids BIGINT[],
    p_date                DATE
)
RETURNS TABLE (
    min_qty INT,
    max_qty INT
)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(MAX(spc.min_qty), 1), MIN(spc.max_qty)
      FROM supplier_price_calendar spc
     WHERE spc.supplier_variant_id = p_supplier_variant_id
       AND spc.product_variant_id = ANY(p_product_variant_ids)
       AND spc.date                = p_date
       AND spc.status              = 'available'
    HAVING count(*) > 0;
$$;

COMMENT ON FUNCTION fn_source_quantity_limits(BIGINT, BIGINT[], DATE) IS
    '源侧售卖份数区间的唯一读法：这个源变体在这些规范变体、这一天能接的最小 / 最大份数（min_qty 默认 1，max_qty 空 = 不限；多行取最紧的一版）';


-- -------------------------------------------------------------------------------------
-- ② 规则的唯一读法：这个源能不能接这个份数
--
-- min_qty / max_qty 是区间，quantity 是这一单要买的份数。
-- 判定的口径只有这一处：写路径、快照留痕、不变量都走它。
--
-- p_quantity 为空 = 不判（读侧不知道要买几份时用）。
-- min_qty 空 = 没有下限（默认 1 份）；max_qty 空 = 没有上限。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_qty_servable(
    p_min_qty  INT,
    p_max_qty  INT,
    p_quantity INT
)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_quantity IS NULL
        OR (COALESCE(p_min_qty, 1) <= p_quantity
            AND (p_max_qty IS NULL OR p_quantity <= p_max_qty));
$$;

COMMENT ON FUNCTION fn_qty_servable(INT, INT, INT) IS
    '份数区间的唯一判定：这个源能不能接这个份数（区间来自源价行的 min_qty / max_qty）';


-- -------------------------------------------------------------------------------------
-- ③ 下单：落单前把「这一单在源侧买得成吗」判掉
--
-- 下面这份 fn_place_order 是 020 的版本（套装库存池口径收紧后的那一份），
-- 改动只有一处：③b 的份数区间校验。
-- 其余一个字没动 —— 下单是唯一实现，改口径只能改它。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_place_order(p_channel_id bigint, p_idempotency_key text, p_items jsonb, p_customer_id bigint DEFAULT NULL::bigint, p_contact jsonb DEFAULT '{}'::jsonb, p_buyer_note text DEFAULT NULL::text, p_holders jsonb DEFAULT '[]'::jsonb)
 RETURNS TABLE(order_id bigint, order_no text, order_status text, order_currency text, order_subtotal numeric, order_total numeric, created boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_scope        TEXT;
    v_hash         TEXT;
    v_existing     RECORD;
    v_order        RECORD;
    v_item         JSONB;
    v_resolved     JSONB := '[]'::jsonb;   -- 解析好的明细，落库时再取
    v_items        JSONB := '[]'::jsonb;   -- 已落库的明细（带 order_item_id）
    v_pricing      JSONB := '[]'::jsonb;   -- 定价快照（订单级）
    v_line         JSONB;
    v_req          RECORD;
    v_holder       JSONB;
    v_item_id      BIGINT;
    v_holders      INT;
    v_variant      BIGINT;
    v_qty          INT;
    v_date         DATE;
    v_price        RECORD;
    v_price_row    RECORD;
    v_listing_id   BIGINT;
    v_supplier_id  BIGINT;
    v_basis        TEXT;
    v_unit_price   NUMERIC;
    v_unit_cost    NUMERIC;
    v_total_price  NUMERIC;
    v_snapshot     JSONB;
    v_currency     TEXT;
    v_subtotal     NUMERIC := 0;
    v_cost_total   NUMERIC := 0;
    v_order_id     BIGINT;
    v_order_no     TEXT;
    v_detail       JSONB;
    v_inserted     INT;
    -- 库存预占（009）：逐项的源侧场次与当时看到的可售数
    v_sessions     JSONB := '[]'::jsonb;
    v_new_sources  JSONB := '[]'::jsonb;
    v_line_rec     RECORD;
    v_avail        JSONB := '[]'::jsonb;
    v_avail_items  JSONB := '[]'::jsonb;   -- 每条明细一份可售数快照（013）
    v_session_ids  BIGINT[];
    v_sup_sess     BIGINT;
    v_demand       INT;
    v_ord          BIGINT;
    v_src_ord      BIGINT;
    v_avail_row    RECORD;
    v_hold_id      BIGINT;
    v_hold_no      TEXT;
    -- 组合（013）：明细的成分行
    v_role         TEXT;
    -- 套装（017）：源侧一个 SKU 整套卖
    v_is_bundle    BOOLEAN := FALSE;
    v_stt          BIGINT;   -- 套装的源票种（源侧那个「套」的票种）
    v_sets         INT;      -- 套数（售卖单位）
    v_comp         RECORD;
    v_sources      JSONB := '[]'::jsonb;
    v_src          JSONB;
    v_sv           BIGINT;
    v_session_id   BIGINT;
    v_ticket_type  BIGINT;
    v_need         INT;
    v_adm          INT;
    v_item_index   INT;
    -- 实名匹配：holder 里的 variant_id 指向成分变体；
    -- item_index 指向明细（同一个变体在一单里出现两次时靠它区分）。
    v_strict_item BOOLEAN;
    v_ambiguous   TEXT;
    -- 源侧售卖份数区间（025）：这一单在每个采纳源上买几份、那个源能接几份。
    v_qty_checks  JSONB := '[]'::jsonb;
    v_qty_limits  JSONB := '[]'::jsonb;
    v_chk         JSONB;
    v_limits      RECORD;
    -- 配方（013）：成分的份数按源 SKU 归拢 —— 源侧收到的是一条预订里的总份数。
    v_comp_units  JSONB := '[]'::jsonb;
    v_agg         RECORD;
    v_pvs         JSONB;
BEGIN
    -- ---------------------------------------------------------------------------------
    -- ① 参数与前置检查
    -- ---------------------------------------------------------------------------------
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
        RAISE EXCEPTION '缺少幂等键：下单必须幂等';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION '下单明细不能为空';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM channel c WHERE c.id = p_channel_id AND c.status = 'active') THEN
        RAISE EXCEPTION '渠道 % 不存在或不是 active', p_channel_id;
    END IF;

    IF p_customer_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM customer cu WHERE cu.id = p_customer_id) THEN
        RAISE EXCEPTION '客户 % 不存在', p_customer_id;
    END IF;

    v_scope := 'order:' || p_channel_id::text;
    v_hash  := md5(p_channel_id::text || '|' || p_items::text || '|'
                   || COALESCE(p_contact::text, '{}') || '|' || COALESCE(p_buyer_note, '')
                   || '|' || COALESCE(p_holders::text, '[]'));

    -- ---------------------------------------------------------------------------------
    -- ② 幂等：抢键
    --
    -- 抢键用 INSERT ... ON CONFLICT DO NOTHING，不用「先查后插」：
    -- 先查后插在并发下会双双通过检查，然后双双落单。
    -- ---------------------------------------------------------------------------------
    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_idempotency_key, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        SELECT ir.request_hash, ir.response, ir.status INTO v_existing
          FROM idempotency_record ir
         WHERE ir.scope = v_scope AND ir.idempotency_key = p_idempotency_key;

        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔请求（订单 %）',
              p_idempotency_key, COALESCE(v_existing.response->>'order_no', '?');
        END IF;

        SELECT o.id, o.order_no, o.status, o.currency, o.subtotal, o.total INTO v_order
          FROM sales_order o
         WHERE o.id = NULLIF(v_existing.response->>'order_id', '')::bigint;

        IF NOT FOUND THEN
            RAISE EXCEPTION '幂等键 % 正在处理中，稍后重试', p_idempotency_key;
        END IF;

        order_id       := v_order.id;
        order_no       := v_order.order_no;
        order_status   := v_order.status;
        order_currency := v_order.currency;
        order_subtotal := v_order.subtotal;
        order_total    := v_order.total;
        created        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 抢到键了，但库里可能已经有同键的订单（幂等记录被清过的情况）。
    SELECT o.id, o.order_no, o.status, o.currency, o.subtotal, o.total INTO v_order
      FROM sales_order o
     WHERE o.channel_id = p_channel_id
       AND o.idempotency_key = p_idempotency_key;

    IF FOUND THEN
        UPDATE idempotency_record
           SET status   = 'done',
               response = jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no)
         WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

        order_id       := v_order.id;
        order_no       := v_order.order_no;
        order_status   := v_order.status;
        order_currency := v_order.currency;
        order_subtotal := v_order.subtotal;
        order_total    := v_order.total;
        created        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 实名里带 item_index 的，按明细严格匹配；否则退回「按 variant_id 匹配」。
    v_strict_item := EXISTS (SELECT 1 FROM jsonb_array_elements(p_holders) h WHERE h ? 'item_index');

    -- ---------------------------------------------------------------------------------
    -- ③ 逐项解析：价格、采纳源、成分行、快照
    --
    -- 金额只从 fn_price_variant() 取（定价的唯一实现）。
    -- 采纳源也来自同一个函数 —— 定价选中的源就是路由选中的源（不变量 43）。
    -- ---------------------------------------------------------------------------------
    FOR v_item, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        -- 行号从 1 开始：调用方传过来的实名 item_index 用的是同一套口径。
        -- （0 起会让「第几行」和「第几名持票人」两套编号混在一起，
        --   差一位就把甲的实名绑到乙的票上。）
        v_item_index := v_ord::int;

        -- 区间检查与留痕都是**按明细**的：每一行明细自己一组，
        -- 不许把上一行的份数带到这一行（两行明细可以是不同的变体、不同的源）。
        v_qty_checks := '[]'::jsonb;
        v_qty_limits := '[]'::jsonb;

        v_variant := NULLIF(v_item->>'variant_id', '')::bigint;
        v_qty     := COALESCE(NULLIF(v_item->>'quantity', '')::int, 0);
        v_date    := NULLIF(v_item->>'visit_date', '')::date;

        IF v_variant IS NULL OR v_qty <= 0 OR v_date IS NULL THEN
            RAISE EXCEPTION '明细不完整（需要 variant_id / quantity / visit_date）：%', v_item::text;
        END IF;

        SELECT * INTO v_price
          FROM fn_price_variant(v_variant, v_date, p_channel_id, p_channel_id);

        IF NOT FOUND THEN
            RAISE EXCEPTION '变体 % 在 % 没有可售价格（商品未上架 / 当天无可用报价 / 成本无法折算 / 组合套餐当天配不齐）',
              v_variant, v_date;
        END IF;

        v_basis := COALESCE(NULLIF(v_price.rule->>'mode', ''), 'cost_plus');

        IF v_basis = 'per_group' THEN
            -- 按团报价：总价是团总价，与人数不成正比；人均只是分摊（硬约束 5）。
            v_total_price := v_price.sell_price;
            v_unit_price  := round(v_price.sell_price / v_qty, 2);
            v_unit_cost   := round(v_price.cost_price / v_qty, 2);
            v_cost_total  := v_cost_total + v_price.cost_price;
        ELSE
            v_unit_price  := v_price.sell_price;
            v_total_price := round(v_price.sell_price * v_qty, 2);
            v_unit_cost   := v_price.cost_price;
            v_cost_total  := v_cost_total + round(v_price.cost_price * v_qty, 2);
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_price.currency;
        ELSIF v_currency <> v_price.currency THEN
            RAISE EXCEPTION '一单只能一个币种：% 与 % 混在一单里', v_currency, v_price.currency;
        END IF;

        v_subtotal := v_subtotal + v_total_price;

        -- 场次与票种 id 从价格行借（只借 id，不借金额：金额只认定价函数）。
        SELECT pc.session_id, pc.ticket_type_id INTO v_price_row
          FROM price_calendar pc
         WHERE pc.product_variant_id = v_variant
           AND pc.date = v_date
           AND pc.status = 'active'
           AND (pc.channel_id = p_channel_id OR pc.channel_id IS NULL)
         ORDER BY (pc.channel_id IS NOT NULL) DESC, pc.id DESC
         LIMIT 1;

        SELECT cl.id INTO v_listing_id
          FROM channel_listing cl
         WHERE cl.channel_id = p_channel_id
           AND cl.product_id = v_price.product_id
           AND cl.status = 'online'
         ORDER BY cl.id
         LIMIT 1;

        -- ---------------------------------------------------------------------------------
        -- ③a 成分行：这个明细要用哪些源 SKU、各几份
        --
        -- 普通变体 = 一行（明细自己的变体 + 定价选中的源 SKU）；
        -- 组合变体 = 每个成分一行（配方说了算）。
        -- ---------------------------------------------------------------------------------
        SELECT pv.variant_role INTO v_role
          FROM product_variant pv
         WHERE pv.id = v_variant;

        v_sources := '[]'::jsonb;

        IF v_role = 'combo' THEN
            -- 套装优先（017）：源侧一个 SKU 整套卖。
            -- 配方与套装不许同时有（守卫），所以这里只需要问「有没有套装」。
            IF EXISTS (SELECT 1
                         FROM supplier_variant_bundle svb
                        WHERE svb.product_variant_id = v_variant
                          AND svb.status = 'active') THEN
                v_is_bundle := TRUE;

                FOR v_comp IN
                    SELECT * FROM fn_bundle_components(v_variant, v_date, p_channel_id, v_price.currency)
                LOOP
                    v_sources := v_sources || jsonb_build_array(jsonb_build_object(
                        'component_variant_id',  v_comp.component_variant_id,
                        'supplier_variant_id',   v_comp.supplier_variant_id,
                        'supplier_product_id',   v_comp.supplier_product_id,
                        'supplier_id',           v_comp.supplier_id,
                        'product_session_id',    v_comp.product_session_id,
                        'supplier_session_id',   v_comp.supplier_session_id,
                        'source_ticket_type_id', v_comp.source_ticket_type_id,
                        'ticket_type_id',        v_comp.component_ticket_type_id,
                        -- 售卖单位是「套」：源侧卖的是整套，不是逐张。
                        'quantity',              v_qty,
                        -- 入场份数是「人」：一套里几个名额。
                        'admission_quantity',    (v_comp.quantity * v_qty)::int,
                        -- 每套分摊到这个成分上的成本。
                        'unit_cost',             v_comp.unit_cost,
                        'currency',              v_comp.source_currency,
                        'fx_rate',               v_comp.fx_rate,
                        'fx_as_of',              v_comp.fx_as_of,
                        'is_bundle',             true,
                        'bundle_sets',           v_qty));
                END LOOP;

                IF jsonb_array_length(v_sources) = 0 THEN
                    RAISE EXCEPTION '套装 % 在 % 没有可售的套装价（源侧当天没有这个套装的报价）',
                      v_variant, v_date;
                END IF;

                -- 套装的场次 = 规范场次（一次入园一个场次）
                v_session_id   := (v_sources -> 0 ->> 'product_session_id')::bigint;
                v_ticket_type  := NULL;   -- 套装没有单一票种（它是一组人）
                v_supplier_id  := (v_sources -> 0 ->> 'supplier_id')::bigint;

                -- 套装的售卖单位是「套」：源侧那个整套 SKU 的价行按套数记区间。
                v_qty_checks := jsonb_build_array(jsonb_build_object(
                    'supplier_variant_id', (v_sources -> 0 ->> 'supplier_variant_id')::bigint,
                    'product_variant_ids', jsonb_build_array(v_variant),
                    'quantity',            v_qty,
                    'label',               '套装源 SKU ' || (v_sources -> 0 ->> 'supplier_variant_id')));
            ELSE
            FOR v_comp IN
                SELECT * FROM fn_combo_components(v_variant, v_date, p_channel_id, v_price.currency)
            LOOP
                v_sources := v_sources || jsonb_build_array(jsonb_build_object(
                    'component_variant_id', v_comp.component_variant_id,
                    'supplier_variant_id',  v_comp.supplier_variant_id,
                    'supplier_product_id',  v_comp.supplier_product_id,
                    'supplier_id',          v_comp.supplier_id,
                    'product_session_id',   v_comp.product_session_id,
                    'supplier_session_id',  v_comp.supplier_session_id,
                    'ticket_type_id',       v_comp.component_ticket_type_id,
                    'quantity',             (v_comp.quantity * v_qty)::int,
                    'admission_quantity',   (v_comp.quantity * v_qty)::int,
                    'unit_cost',            v_comp.unit_cost,
                    'currency',             v_comp.source_currency,
                    'fx_rate',              v_comp.fx_rate,
                    'fx_as_of',             v_comp.fx_as_of));

                -- 配方：成分的份数先记下来，归拢到源 SKU 上（见下面的归拢段）。
                v_comp_units := v_comp_units || jsonb_build_array(jsonb_build_object(
                    'supplier_variant_id', v_comp.supplier_variant_id,
                    'product_variant_id',  v_comp.component_variant_id,
                    'units',               (v_comp.quantity * v_qty)::int));
            END LOOP;

            IF jsonb_array_length(v_sources) = 0 THEN
                RAISE EXCEPTION '组合套餐 % 在 % 没有可售的成分配方（成分当天没报价 / 成分不同场次 / 跨源 / 按团报价口径未定）',
                  v_variant, v_date;
            END IF;

            -- 配方：区间按**源 SKU** 判，份数是这个 SKU 在这一单里的总份数。
            --
            -- 同一个源 SKU 顶多个成分时（参数化源：成人与儿童是同一个 SKU），
            -- 源侧收到的是一条预订里的总份数 —— 2 份成人 + 1 份儿童 = 3 份。
            -- 按成分各判各的会漏掉「合起来超上限」：每份单独看都合法，
            -- 合起来超过源侧的单笔上限，源侧照样拒单（钱收了票出不来）。
            FOR v_agg IN
                SELECT (e.value->>'supplier_variant_id')::bigint AS sv,
                       sum((e.value->>'units')::int)               AS units
                  FROM jsonb_array_elements(v_comp_units) e
                 GROUP BY 1
            LOOP
                -- 这个 SKU 顶的每个成分的报价行上的区间都要容得下总份数
                -- （哪一行卡住就点哪一行）。
                SELECT jsonb_agg(DISTINCT (e.value->>'product_variant_id')::bigint)
                  INTO v_pvs
                  FROM jsonb_array_elements(v_comp_units) e
                 WHERE (e.value->>'supplier_variant_id')::bigint = v_agg.sv;

                v_qty_checks := v_qty_checks || jsonb_build_array(jsonb_build_object(
                    'supplier_variant_id', v_agg.sv,
                    'product_variant_ids', v_pvs,
                    'quantity',            v_agg.units,
                    'label',               '成分源 SKU ' || v_agg.sv::text));
            END LOOP;

            -- 组合的场次 = 成分的场次（一次入园一个场次；定价函数已判定成分同场次）
            v_session_id   := (v_sources -> 0 ->> 'product_session_id')::bigint;
            v_ticket_type  := NULL;   -- 组合没有单一票种（成人 + 儿童）
            v_supplier_id  := (v_sources -> 0 ->> 'supplier_id')::bigint;
            END IF;
        ELSE
            SELECT sp.supplier_id INTO v_supplier_id
              FROM supplier_product sp
             WHERE sp.id = v_price.supplier_product_id;

            -- 定价选中的源 SKU：与 fn_price_variant 同一个排序函数的第一名。
            SELECT rc.supplier_variant_id INTO v_sv
              FROM fn_route_candidates(v_variant, v_date, p_channel_id, v_price.currency) rc
             WHERE rc.route_rank = 1;

            IF v_sv IS NULL THEN
                RAISE EXCEPTION '变体 % 在 % 没有选出可履约的源（定价与选源不一致）', v_variant, v_date;
            END IF;

            v_session_id  := v_price_row.session_id;
            v_ticket_type := v_price_row.ticket_type_id;

            -- 按团报价：向源侧买的是「一整团」，进几次场看团人数。
            v_need := CASE WHEN v_basis = 'per_group' THEN 1 ELSE v_qty END;
            v_adm  := v_qty;

            v_sources := jsonb_build_array(jsonb_build_object(
                'component_variant_id', v_variant,
                'supplier_variant_id',  v_sv,
                'supplier_product_id',  v_price.supplier_product_id,
                'supplier_id',          v_supplier_id,
                'product_session_id',   v_session_id,
                -- 源场次：走场次级绑定表，不按日期猜（硬约束 19）。
                -- 没有绑定就留空 —— 留空是「还不知道」，不是「没有」。
                -- 库存快照与预订建到那一步再报错，源头不猜。
                'supplier_session_id',  fn_bound_supplier_session(v_session_id, v_price.supplier_product_id),
                'ticket_type_id',       v_ticket_type,
                'quantity',             v_need,
                'admission_quantity',   v_adm,
                'unit_cost',            v_price.cost_price,
                'currency',             v_price.source_currency,
                'fx_rate',              v_price.fx_rate,
                'fx_as_of',             v_price.fx_as_of));

            -- 单张形态：区间按这一单的份数判。
            -- 按团报价时比的是人数（v_qty），不是「一整团」——
            -- 团总价只在人数达标时成立，1 个人不能按团价成交（口径 ④）。
            v_qty_checks := jsonb_build_array(jsonb_build_object(
                'supplier_variant_id', v_sv,
                'product_variant_ids', jsonb_build_array(v_variant),
                'quantity',            v_qty,
                'label',               '源 SKU ' || v_sv::text));
        END IF;

        -- ---------------------------------------------------------------------------------
        -- ③b 份数区间：采纳的源接不接得住这一单
        --
        -- 源侧可能只卖 6 人起的团、每人最多 10 份。这是一手事实，
        -- 落单时必须落在区间里，否则钱收了票出不来。
        --
        -- 唯一读法是 fn_source_quantity_limits（跟定价读的是同一行价行），
        -- 判定是 fn_qty_servable（口径只有一条，不许各处再判一遍）。
        -- ---------------------------------------------------------------------------------
        FOR v_chk IN
            SELECT e.value FROM jsonb_array_elements(v_qty_checks) e
        LOOP
            -- 检查项残了就是代码写错了。这种错不许静悄悄地把检查关掉 ——
            -- 关掉了就是收了钱出不了票还不报错（这里的坑：数组里放的是规范变体 id，
            -- 当成对象去取字段会取出一串 NULL，区间读不出来，检查就成了一句空话）。
            IF (v_chk -> 'product_variant_ids') IS NULL
               OR jsonb_array_length(v_chk -> 'product_variant_ids') = 0
               OR (SELECT count(*)
                     FROM jsonb_array_elements(v_chk -> 'product_variant_ids') x
                    WHERE jsonb_typeof(x) <> 'number') > 0 THEN
                RAISE EXCEPTION '份数检查项残了（源 SKU % 的规范变体不是一组 id）：%',
                  v_chk ->> 'supplier_variant_id', v_chk::text;
            END IF;

            SELECT q.min_qty, q.max_qty INTO v_limits
              FROM fn_source_quantity_limits(
                       (v_chk->>'supplier_variant_id')::bigint,
                       ARRAY(SELECT (x::text)::bigint
                               FROM jsonb_array_elements(v_chk -> 'product_variant_ids') x),
                       v_date) q;

            -- 源侧没有报这个源的区间 = 源侧没给约束 = 不拦（不猜）。
            IF NOT FOUND THEN
                CONTINUE;
            END IF;

            IF NOT fn_qty_servable(v_limits.min_qty, v_limits.max_qty,
                                   (v_chk->>'quantity')::int) THEN
                RAISE EXCEPTION
                    '源侧的售卖份数接不住这一单：% 在 % 只接 % 到 % 份，这一单要 % 份',
                    v_chk->>'label', v_date,
                    COALESCE(v_limits.min_qty, 1),
                    COALESCE(v_limits.max_qty::text, '不限'),
                    (v_chk->>'quantity')::int;
            END IF;

            -- 留痕：区间进明细快照，事后对账时能看出当时源侧接不接得住。
            v_qty_limits := v_qty_limits || jsonb_build_array(jsonb_build_object(
                'supplier_variant_id', (v_chk->>'supplier_variant_id')::bigint,
                'product_variant_ids', v_chk->'product_variant_ids',
                'min_qty',             v_limits.min_qty,
                'max_qty',             v_limits.max_qty,
                'quantity',            (v_chk->>'quantity')::int));
        END LOOP;

        -- 展示与对账用的成分快照（组合看得见自己由什么组成）
        v_snapshot := jsonb_build_object(
            'variant_id',           v_variant,
            'product_id',           v_price.product_id,
            'visit_date',           v_date,
            'quantity',             v_qty,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'unit_price',           v_unit_price,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'cost_price',           v_price.cost_price,
            'cost_source_product_id', v_price.supplier_product_id,
            'price_locked',         v_price.price_locked,
            'fx_rate',              v_price.fx_rate,
            'fx_as_of',             v_price.fx_as_of,
            'rule',                 v_price.rule,
            'quantity_limits',      v_qty_limits)
            || CASE WHEN v_basis = 'per_group'
                    THEN jsonb_build_object('group_total', v_price.sell_price)
                    ELSE '{}'::jsonb END
            || CASE WHEN v_role = 'combo'
                    THEN jsonb_build_object('components', v_sources)
                    ELSE '{}'::jsonb END;

        v_resolved := v_resolved || jsonb_build_array(jsonb_build_object(
            'item_index',           v_item_index,
            'product_id',           v_price.product_id,
            'product_variant_id',   v_variant,
            'session_id',           v_session_id,
            'ticket_type_id',       v_ticket_type,
            'channel_listing_id',   v_listing_id,
            'supplier_product_id',  CASE WHEN v_role = 'combo' AND NOT v_is_bundle THEN NULL ELSE v_price.supplier_product_id END,
            'supplier_id',          v_supplier_id,
            'quantity',             v_qty,
            'unit_price',           v_unit_price,
            'unit_cost',            v_unit_cost,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'snapshot',             v_snapshot,
            'sources',              v_sources));

        v_pricing := v_pricing || jsonb_build_array(v_snapshot);
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ③a 源场次解析：每一行成分都要落到一个源场次上
    --
    -- 库存数字挂在源场次上，预订也挂在源场次上 —— 所以这一行成分的源场次
    -- 必须在下单时就定下来，后面所有环节读同一个值。
    --
    -- 为什么强调「同一个值」：
    --   库存算一遍用 A 源场次、建预订再算一遍用 B 源场次，
    --   卖出去的是 A 场的票、出去的是 B 场的票，账面上完全看不出来。
    --   所以这里解析一次写回，后面不许再各算各的。
    --
    -- 解析口径：场次级绑定表（product_session_source），不按日期猜（硬约束 19）。
    -- 没有绑定就留空 —— 留空是「还不知道」，真到建预订那一步才报错。
    -- ---------------------------------------------------------------------------------
    v_sessions := '[]'::jsonb;

    FOR v_line_rec IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        v_new_sources := '[]'::jsonb;

        FOR v_src IN
            SELECT e.value FROM jsonb_array_elements(v_line_rec.value->'sources') e
        LOOP
            IF NULLIF(v_src->>'supplier_session_id', '') IS NULL THEN
                v_src := v_src || jsonb_build_object(
                    'supplier_session_id',
                    fn_bound_supplier_session(
                        NULLIF(v_src->>'product_session_id', '')::bigint,
                        NULLIF(v_src->>'supplier_product_id', '')::bigint));
            END IF;

            v_new_sources := v_new_sources || jsonb_build_array(v_src);
        END LOOP;

        v_resolved := jsonb_set(v_resolved,
                                ARRAY[(v_line_rec.ordinality - 1)::text, 'sources'],
                                v_new_sources);
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ③a 实名归属：分不清是哪一行的，不许猜
    --
    -- 组合套餐把这个歧义放大了：
    --   一张家庭套餐（成分 9 = 2 份成人票）+ 一张单买的成人票（也是成分 9），
    --   两行明细都要实名，但光看 variant_id 分不出「这份姓名属于哪一行」。
    --
    -- 猜错就是把甲的实名绑到乙的票上 —— 闸机前才发现，人已经进去了。
    -- 所以同一个成分变体出现在多行明细时，当场报错，让调用方带 item_index 指明行号。
    -- ---------------------------------------------------------------------------------
    IF NOT v_strict_item THEN
        SELECT string_agg(DISTINCT x.component_variant_id, ', ')
          INTO v_ambiguous
          FROM (
                SELECT s->>'component_variant_id' AS component_variant_id
                  FROM jsonb_array_elements(v_resolved) it
                  CROSS JOIN LATERAL jsonb_array_elements(it->'sources') s
                 GROUP BY s->>'component_variant_id'
                HAVING count(DISTINCT it->>'item_index') > 1
               ) x;

        IF v_ambiguous IS NOT NULL THEN
            RAISE EXCEPTION '成分变体 % 同时出现在多行明细里，持票人无法归属：请在实名里带 item_index 指明是哪一行（从 1 开始）',
              v_ambiguous;
        END IF;
    ELSE
        -- 带了 item_index 就得全带：漏一条的那条匹配不上任何行，
        -- 报出来的是「实名收不齐」这种让人摸不着头脑的话。
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_holders) h WHERE NOT (h ? 'item_index')) THEN
            RAISE EXCEPTION '实名里带了 item_index 的，每一条实名都必须带 item_index（要么全带，要么全不带）';
        END IF;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ③b 库存预占：锁源场次 → 算可售 → 明知不够当场报错
    --
    -- 防超卖靠两件事：
    --   1. 锁：按源场次 id 升序加锁（SELECT ... ORDER BY id FOR UPDATE）。
    --      两个并发订单不会各卖各的最后一张；升序是为了不让两个订单互相死锁
    --      （A 锁 1 再锁 2、B 锁 2 再锁 1）。
    --   2. 扣：可售数要减去我们在这个场次上已经承诺出去的量（inventory_hold）。
    --
    -- 不知道就不猜：没有库存快照也没有可用性缓存时放行，
    -- 但把「卖的时候不知道还剩多少」写进明细快照（硬约束 7）。
    --
    -- 组合：每个成分在自己的源场次上单独预占（成分之间是不同的票，甚至不同的源商品）。
    -- ---------------------------------------------------------------------------------
    FOR v_detail IN SELECT * FROM jsonb_array_elements(v_resolved)
    LOOP
        FOR v_src IN SELECT * FROM jsonb_array_elements(v_detail->'sources')
        LOOP
            -- 源场次在 ③a 已经解析过一次，这里直接读，不重算。
            v_sup_sess := NULLIF(v_src->>'supplier_session_id', '')::bigint;

            v_sessions := v_sessions || jsonb_build_array(v_sup_sess);
        END LOOP;
    END LOOP;

    SELECT array_agg(s ORDER BY s) INTO v_session_ids
      FROM (SELECT DISTINCT (e.value)::bigint AS s
              FROM jsonb_array_elements(v_sessions) e) t
     WHERE s IS NOT NULL;

    IF v_session_ids IS NOT NULL THEN
        PERFORM 1 FROM supplier_session ss
         WHERE ss.id = ANY(v_session_ids)
         ORDER BY ss.id
         FOR UPDATE;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ③b-1 场次总量校验：同一场次上的所有成分要一起算
    --
    -- 逐成分各查各的会漏掉超卖：
    --   成人成分查「这个源票种还剩 2 张」→ 2 ≤ 2 过；
    --   儿童成分也查「还剩 2 张」→ 1 ≤ 2 过；
    --   加起来要 3 张，可那个池子只有 2 张 —— 超卖一张。
    --
    -- 根子在参数化源：成人和儿童是**同一个源票种**（一个人群参数化的 SKU），
    -- 一个池子被查了两次，每次都以为还有 2 张。
    -- 池子被查两次这个事实，只有按场次加总才看得见。
    --
    -- 所以这里按源场次把这一单的需求加总，跟这个场次的**总可售数**比一次
    -- （票种级可售数是子集，比总池子严；总池子都不够，子集更不够）。
    -- 这一道挡住的是「一个池子被查两次」；下面逐成分那道挡住的是「某个票种本来就不够」。
    -- ---------------------------------------------------------------------------------
    FOR v_sup_sess, v_demand IN
        SELECT (src->>'supplier_session_id')::bigint AS sess,
               sum((src->>'admission_quantity')::int)::int AS demand
          FROM jsonb_array_elements(v_resolved) d
          CROSS JOIN LATERAL jsonb_array_elements(d->'sources') src
         WHERE NULLIF(src->>'supplier_session_id', '') IS NOT NULL
           AND NOT COALESCE((src->>'is_bundle')::boolean, false)
         GROUP BY 1
         ORDER BY 1
    LOOP
        PERFORM * FROM fn_reserve_qty(
            v_sup_sess,
            NULL,
            v_demand,
            '本单在这个源场次上的总需求（多个成分合起来）');
    END LOOP;

    -- 套装：按套数预占。
    --
    -- 源侧卖的是整套，池子里的单位也是套 ——
    -- 拿「入场份数」去比一个以套计的池子，就会把 3 个名额当成 3 套，
    -- 明明还剩 1 套也报「库存不足」。所以这里走源票种口径、按套数算。
    --
    -- 两件事必须同时做对：
    --   一、**一套只算一套**。一套的成分行都记着同一个套数，
    --       逐成分加总会把一套算成好几套。
    --   二、**同一个池子上的需求要加总**。一单里买两行同一个套装，
    --       两行抢的是同一个池子；各看各的（都看见「还剩 1 套」），
    --       加起来要 2 套就超卖了。
    -- 所以先按明细去重（每行一套），再按池子加总（每池一份需求）。
    FOR v_sup_sess, v_stt, v_sets IN
        SELECT b.sess, b.stt, sum(b.sets)::int
          FROM (
                SELECT (max(src->>'supplier_session_id')::bigint) AS sess,
                       (max(src->>'source_ticket_type_id')::bigint) AS stt,
                       max((src->>'bundle_sets')::int) AS sets
                  FROM jsonb_array_elements(v_resolved) WITH ORDINALITY d(value, ordinality)
                  CROSS JOIN LATERAL jsonb_array_elements(d.value->'sources') src
                 WHERE COALESCE((src->>'is_bundle')::boolean, false)
                   AND NULLIF(src->>'supplier_session_id', '') IS NOT NULL
                 GROUP BY d.ordinality
               ) b
         GROUP BY b.sess, b.stt
         ORDER BY b.sess
    LOOP
        PERFORM * FROM fn_reserve_qty(
            v_sup_sess,
            NULL,
            v_stt,
            v_sets,
            '本单在这个源场次上的套装需求（按套）');
    END LOOP;

    -- 逐成分算可售数，按明细聚合成一份快照（每条明细一份）
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        v_avail := '[]'::jsonb;

        FOR v_src, v_src_ord IN
            SELECT e.value, e.ordinality
              FROM jsonb_array_elements(v_detail->'sources') WITH ORDINALITY AS e(value, ordinality)
        LOOP
            v_sup_sess := (v_src->>'supplier_session_id')::bigint;

            IF COALESCE((v_src->>'is_bundle')::boolean, false) THEN
                -- 套装：池子落在源侧的「套」票种上，量是套数。
                SELECT * INTO v_avail_row
                  FROM fn_reserve_qty(v_sup_sess,
                                      NULL,
                                      NULLIF(v_src->>'source_ticket_type_id', '')::bigint,
                                      (v_src->>'bundle_sets')::int,
                                      '套装 ' || COALESCE(v_src->>'component_variant_id', '?')
                                        || ' ' || COALESCE(v_detail->'snapshot'->>'visit_date', '?'));
            ELSE
                SELECT * INTO v_avail_row
                  FROM fn_reserve_qty(v_sup_sess,
                                      NULLIF(v_src->>'ticket_type_id', '')::bigint,
                                      (v_src->>'admission_quantity')::int,
                                      '变体 ' || COALESCE(v_src->>'component_variant_id', '?')
                                        || ' ' || COALESCE(v_detail->'snapshot'->>'visit_date', '?'));
            END IF;

            v_avail := v_avail || jsonb_build_array(jsonb_build_object(
                'component_variant_id', (v_src->>'component_variant_id')::bigint,
                'supplier_variant_id',  (v_src->>'supplier_variant_id')::bigint,
                'source_quantity',      (CASE WHEN COALESCE((v_src->>'is_bundle')::boolean, false)
                                              THEN (v_src->>'bundle_sets')::int
                                              ELSE (v_src->>'admission_quantity')::int END),
                'known',         v_avail_row.known,
                'available_qty', v_avail_row.available_qty,
                'committed_qty', v_avail_row.committed_qty,
                'remaining_qty', v_avail_row.remaining_qty,
                'sold_qty',      v_avail_row.sold_qty,
                'held_qty',      v_avail_row.held_qty,
                'source_status', v_avail_row.source_status,
                'snapshot_at',   v_avail_row.snapshot_at));
        END LOOP;

        -- 聚合成一条明细的可售数快照：
        --   known      = 全都知道才算知道（有一个成分不知道，这条明细就不知道）
        --   remaining  = 取最小（最紧的那个成分才是约束）
        --   逐成分的明细放在 sources 里，对账要看得见「哪一份成分不紧」
        v_avail_items := v_avail_items || jsonb_build_array(jsonb_build_object(
            'known',         COALESCE((SELECT bool_and((e->>'known')::boolean) FROM jsonb_array_elements(v_avail) e), false),
            'available_qty', COALESCE((SELECT sum((e->>'available_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'committed_qty', COALESCE((SELECT sum((e->>'committed_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'remaining_qty', (SELECT min((e->>'remaining_qty')::int) FROM jsonb_array_elements(v_avail) e),
            'sold_qty',      COALESCE((SELECT sum((e->>'sold_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'held_qty',      COALESCE((SELECT sum((e->>'held_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'source_status', (SELECT e->>'source_status' FROM jsonb_array_elements(v_avail) e LIMIT 1),
            'snapshot_at',   (SELECT max((e->>'snapshot_at')::timestamptz) FROM jsonb_array_elements(v_avail) e),
            'sources',       v_avail));
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④ 落单
    -- ---------------------------------------------------------------------------------
    v_order_no := 'TC' || to_char(now(), 'YYYYMMDD') || lpad(nextval('public.seq_order_no')::text, 6, '0');

    INSERT INTO sales_order (order_no, channel_id, customer_id, status, currency,
                             subtotal, discount, tax, total, cost_total, commission_amount,
                             pricing_snapshot, contact_snapshot, idempotency_key, buyer_note, expires_at)
    VALUES (v_order_no, p_channel_id, p_customer_id, 'created', v_currency,
            v_subtotal, 0, 0, v_subtotal, v_cost_total, 0,
            jsonb_build_object('items', v_pricing, 'channel_id', p_channel_id, 'computed_at', now()),
            COALESCE(p_contact, '{}'::jsonb), p_idempotency_key, p_buyer_note,
            now() + interval '30 minutes')
    RETURNING id INTO v_order_id;

    -- 明细：展示内容走快照，订单历史不依赖当前商品表（硬约束 7）。
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        INSERT INTO sales_order_item (order_id, product_id, product_variant_id, channel_listing_id,
                                      supplier_product_id, supplier_id, session_id, ticket_type_id,
                                      quantity, unit_price, unit_cost, total_price, currency,
                                      pricing_basis, detail_snapshot, status)
        VALUES (v_order_id,
                (v_detail->>'product_id')::bigint,
                (v_detail->>'product_variant_id')::bigint,
                NULLIF(v_detail->>'channel_listing_id', '')::bigint,
                NULLIF(v_detail->>'supplier_product_id', '')::bigint,
                NULLIF(v_detail->>'supplier_id', '')::bigint,
                NULLIF(v_detail->>'session_id', '')::bigint,
                NULLIF(v_detail->>'ticket_type_id', '')::bigint,
                (v_detail->>'quantity')::int,
                (v_detail->>'unit_price')::numeric,
                (v_detail->>'unit_cost')::numeric,
                (v_detail->>'total_price')::numeric,
                (v_detail->>'currency'),
                (v_detail->>'pricing_basis'),
                (v_detail->'snapshot') || jsonb_build_object(
                    'title', COALESCE(
                        (SELECT p.title FROM product p WHERE p.id = (v_detail->>'product_id')::bigint),
                        ''),
                    'availability', COALESCE(v_avail_items -> ((v_ord - 1)::int), '{}'::jsonb)),
                'pending')
        RETURNING id INTO v_item_id;

        -- 成分行落库：履约的单位（预订 / 出券 / 预占都按它走）
        INSERT INTO sales_order_item_source (order_item_id, component_variant_id, supplier_variant_id,
                                             supplier_product_id, supplier_id, product_session_id,
                                             supplier_session_id, ticket_type_id, quantity,
                                             admission_quantity, unit_cost, currency, fx_rate, fx_as_of)
        SELECT v_item_id,
               (s->>'component_variant_id')::bigint,
               (s->>'supplier_variant_id')::bigint,
               (s->>'supplier_product_id')::bigint,
               (s->>'supplier_id')::bigint,
               (s->>'product_session_id')::bigint,
               (s->>'supplier_session_id')::bigint,
               (s->>'ticket_type_id')::bigint,
               (s->>'quantity')::numeric,
               (s->>'admission_quantity')::numeric,
               (s->>'unit_cost')::numeric,
               (s->>'currency'),
               (s->>'fx_rate')::numeric,
               (s->>'fx_as_of')::date
          FROM jsonb_array_elements(v_detail->'sources') s;

        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'order_item_id',  v_item_id,
            'item_index',     (v_detail->>'item_index')::int,
            'variant_id',     (v_detail->>'product_variant_id')::bigint,
            'product_id',     (v_detail->>'product_id')::bigint,
            'ticket_type_id', NULLIF(v_detail->>'ticket_type_id', '')::bigint,
            'quantity',       (v_detail->>'quantity')::int,
            'sources',        v_detail->'sources'));
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④c 库存预占落账
    --
    -- 每份成分都要有一条预占记录：「我们卖出去多少」是事实，必须查得到。
    --
    -- 有购物车预占就把它消费掉（同一张预占从 active 变 consumed，
    -- 承诺量不变，不会重复扣）；没有就新建一张 consumed 的。
    -- ---------------------------------------------------------------------------------
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        IF NULLIF(v_detail->>'session_id', '') IS NULL THEN
            RAISE EXCEPTION '订单明细（变体 %）没有场次，无法预占库存',
              COALESCE(v_detail->>'product_variant_id', '?');
        END IF;

        FOR v_src, v_src_ord IN
            SELECT e.value, e.ordinality
              FROM jsonb_array_elements(v_detail->'sources') WITH ORDINALITY AS e(value, ordinality)
        LOOP
            -- 套装不按成分各占一份（源侧卖的是整套），它在下面单独占一条。
            IF COALESCE((v_src->>'is_bundle')::boolean, false) THEN
                CONTINUE;
            END IF;

            v_sup_sess := (v_src->>'supplier_session_id')::bigint;
            v_qty       := (v_src->>'admission_quantity')::int;

            SELECT h.id INTO v_hold_id
              FROM inventory_hold h
             WHERE h.status = 'active'
               AND h.channel_id = p_channel_id
               AND h.product_variant_id = (v_src->>'component_variant_id')::bigint
               AND h.product_session_id IS NOT DISTINCT FROM (v_src->>'product_session_id')::bigint
               AND h.supplier_session_id IS NOT DISTINCT FROM v_sup_sess
               AND h.quantity = v_qty
             ORDER BY h.created_at, h.id
             LIMIT 1
             FOR UPDATE;

            IF v_hold_id IS NOT NULL THEN
                UPDATE inventory_hold
                   SET status            = 'consumed',
                       consumed_quantity = quantity,
                       order_id          = v_order_id,
                       released_at       = NULL
                 WHERE id = v_hold_id;
            ELSE
                v_hold_no := 'HOLD' || v_order_no || '-' || lpad(v_ord::text, 2, '0')
                          || '-' || lpad(v_src_ord::text, 2, '0');

                INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                            supplier_id, product_variant_id, supplier_session_id,
                                            quantity, consumed_quantity, status, order_id,
                                            expires_at, created_at)
                VALUES (v_hold_no, p_channel_id,
                        (v_src->>'product_session_id')::bigint,
                        (v_src->>'ticket_type_id')::bigint,
                        (v_src->>'supplier_id')::bigint,
                        (v_src->>'component_variant_id')::bigint,
                        v_sup_sess,
                        v_qty, v_qty, 'consumed', v_order_id,
                        now() + interval '30 minutes', now())
                RETURNING id INTO v_hold_id;
            END IF;
        END LOOP;

        -- 套装：一条预占记「套」，不记成分。
        --
        -- 记成分会把这个池子扣成「3 张」—— 源侧那个池子是以套计的，
        -- 扣成 3 套就把可售数扣没了。所以只记一套。
        FOR v_src IN
            SELECT DISTINCT ON (e.value->>'supplier_variant_id') e.value
              FROM jsonb_array_elements(v_detail->'sources') e
             WHERE COALESCE((e.value->>'is_bundle')::boolean, false)
             ORDER BY e.value->>'supplier_variant_id'
        LOOP
            v_sup_sess := (v_src->>'supplier_session_id')::bigint;
            v_qty       := (v_src->>'bundle_sets')::int;

            SELECT h.id INTO v_hold_id
              FROM inventory_hold h
             WHERE h.status = 'active'
               AND h.channel_id = p_channel_id
               AND h.product_variant_id = (v_detail->>'product_variant_id')::bigint
               AND h.product_session_id IS NOT DISTINCT FROM (v_src->>'product_session_id')::bigint
               AND h.supplier_session_id IS NOT DISTINCT FROM v_sup_sess
               AND h.quantity = v_qty
             ORDER BY h.created_at, h.id
             LIMIT 1
             FOR UPDATE;

            IF v_hold_id IS NOT NULL THEN
                UPDATE inventory_hold
                   SET status            = 'consumed',
                       consumed_quantity = quantity,
                       order_id          = v_order_id,
                       released_at       = NULL
                 WHERE id = v_hold_id;
            ELSE
                v_hold_no := 'HOLD' || v_order_no || '-' || lpad(v_ord::text, 2, '0')
                          || '-B' || (v_src->>'supplier_variant_id');

                INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                            supplier_id, product_variant_id, supplier_session_id,
                                            source_ticket_type_id,
                                            quantity, consumed_quantity, status, order_id,
                                            expires_at, created_at)
                VALUES (v_hold_no, p_channel_id,
                        (v_src->>'product_session_id')::bigint,
                        NULL,
                        (v_src->>'supplier_id')::bigint,
                        (v_detail->>'product_variant_id')::bigint,
                        v_sup_sess,
                        (v_src->>'source_ticket_type_id')::bigint,
                        v_qty, v_qty, 'consumed', v_order_id,
                        now() + interval '30 minutes', now())
                RETURNING id INTO v_hold_id;
            END IF;
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④b 实名：票种要求的持票人信息必须收齐
    --
    -- 结算页要哪些字段由 checkout_requirement 说（不变量 25 按同一口径把门）。
    -- 这里按**成分**逐项校验：组合的每个成分各有自己的份数与票种，
    -- 持票人按成分变体分组收（组合 = 2 份成人票 + 1 份儿童票 → 三份实名）。
    -- 校验口径与不变量 25 必须一致 —— 两处口径不一样，就会出现「函数放行、门禁拦下」。
    -- ---------------------------------------------------------------------------------
    FOR v_line IN SELECT * FROM jsonb_array_elements(v_items)
    LOOP
        FOR v_src IN SELECT * FROM jsonb_array_elements(v_line->'sources')
        LOOP
            FOR v_req IN
                SELECT cr.field_code, cr.label, cr.max_length, cr.pattern
                  FROM checkout_requirement cr
                 WHERE cr.required
                   AND cr.product_id = (v_line->>'product_id')::bigint
                   AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = (v_src->>'ticket_type_id')::bigint)
                   AND (cr.channel_id IS NULL OR cr.channel_id = p_channel_id)
            LOOP
                SELECT count(DISTINCT (h->>'sequence')::int) INTO v_holders
                  FROM jsonb_array_elements(p_holders) h
                 WHERE (h->>'variant_id')::bigint = (v_src->>'component_variant_id')::bigint
                   AND h->>'field_code' = v_req.field_code
                   AND (NOT v_strict_item
                        OR (h->>'item_index')::int = (v_line->>'item_index')::int);

                IF v_holders < (v_src->>'admission_quantity')::int THEN
                    RAISE EXCEPTION '订单行（成分变体 %）要求实名信息：% 需要 % 份，实收 % 份',
                      (v_src->>'component_variant_id')::bigint, v_req.label,
                      (v_src->>'admission_quantity')::int, v_holders;
                END IF;

                FOR v_holder IN
                    SELECT h FROM jsonb_array_elements(p_holders) h
                     WHERE (h->>'variant_id')::bigint = (v_src->>'component_variant_id')::bigint
                       AND h->>'field_code' = v_req.field_code
                       AND (NOT v_strict_item
                            OR (h->>'item_index')::int = (v_line->>'item_index')::int)
                LOOP
                    IF v_req.max_length IS NOT NULL
                       AND length(COALESCE(v_holder->>'value', '')) > v_req.max_length THEN
                        RAISE EXCEPTION '订单行（成分变体 %）的 % 超过长度上限 %',
                          (v_src->>'component_variant_id')::bigint, v_req.label, v_req.max_length;
                    END IF;

                    IF NULLIF(v_req.pattern, '') IS NOT NULL
                       AND (v_holder->>'value') !~ v_req.pattern THEN
                        RAISE EXCEPTION '订单行（成分变体 %）的 % 不符合格式要求',
                          (v_src->>'component_variant_id')::bigint, v_req.label;
                    END IF;
                END LOOP;
            END LOOP;
        END LOOP;
    END LOOP;

    -- 持票人落库（每个字段一行，与 checkout_requirement 的字段口径对齐）
    INSERT INTO order_holder (order_id, order_item_id, ticket_type_id, component_variant_id,
                              sequence, field_code, value, value_hash)
    SELECT v_order_id,
           (it->>'order_item_id')::bigint,
           (s->>'ticket_type_id')::bigint,
           (s->>'component_variant_id')::bigint,
           (h->>'sequence')::int,
           h->>'field_code',
           h->>'value',
           md5(COALESCE(h->>'value', ''))
      FROM jsonb_array_elements(v_items) it
      JOIN LATERAL jsonb_array_elements(it->'sources') s ON true
      JOIN LATERAL jsonb_array_elements(p_holders) h
        ON (h->>'variant_id')::bigint = (s->>'component_variant_id')::bigint
       AND (NOT v_strict_item
            OR (h->>'item_index')::int = (it->>'item_index')::int);

    -- created → awaiting_payment（触发器会落一条 OrderAwaitingPayment 事件）
    UPDATE sales_order SET status = 'awaiting_payment' WHERE id = v_order_id;

    -- ---------------------------------------------------------------------------------
    -- ⑤ 幂等记账
    -- ---------------------------------------------------------------------------------
    UPDATE idempotency_record
       SET status   = 'done',
           response = jsonb_build_object('order_id', v_order_id, 'order_no', v_order_no)
     WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

    order_id       := v_order_id;
    order_no       := v_order_no;
    order_status   := 'awaiting_payment';
    order_currency := v_currency;
    order_subtotal := v_subtotal;
    order_total    := v_subtotal;
    created        := true;
    RETURN NEXT;
END;
$function$;

-- -------------------------------------------------------------------------------------
-- ② 改派也要守区间（口径 6）
--
-- 改派 = 换源 + 重新定价。换来的新源必须接得住这一单的份数，
-- 否则就是「按新源卖、源侧接不住」—— 把一笔本来该拦的单改成拦不住的单。
--
-- 函数体从 024 整段复制过来，只改两处：
--   1. 多一段区间校验（新源接不住 → 拒绝改派）；
--   2. 明细快照里的 quantity_limits 跟着换源更新。
-- 别的口径一个字没动（幂等 / 三处同源 / 库存预占跟着走 / 留痕）。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_reassign_order_item(
    p_order_id      BIGINT,
    p_order_item_id BIGINT,
    p_reason        TEXT DEFAULT NULL
)
RETURNS TABLE (
    order_item_id                BIGINT,
    outcome                      TEXT,
    previous_supplier_product_id BIGINT,
    previous_supplier_id         BIGINT,
    new_supplier_product_id     BIGINT,
    new_supplier_id              BIGINT,
    previous_unit_price          NUMERIC,
    new_unit_price               NUMERIC,
    previous_unit_cost           NUMERIC,
    new_unit_cost                NUMERIC,
    previous_total_price         NUMERIC,
    new_total_price              NUMERIC,
    currency                     TEXT,
    reason                       TEXT
)
LANGUAGE plpgsql AS $$
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
                  AND v.status IN ('issued', 'used')) THEN
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

    IF v_basis = 'per_group' THEN
        v_new_total := v_price.sell_price;
        v_new_unit  := round(v_price.sell_price / v_qty, 2);
        v_new_cost  := round(v_price.cost_price / v_qty, 2);
    ELSE
        v_new_unit  := v_price.sell_price;
        v_new_total := round(v_price.sell_price * v_qty, 2);
        v_new_cost  := v_price.cost_price;
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
$$;

-- -------------------------------------------------------------------------------------
-- ③ 不变量 113-115：份数区间侧
--
-- 113：明细留痕的份数必须落在留痕的区间内。
--      留痕自己跟自己矛盾 = 记错了，事后对账会拿这份留痕说「当时源侧接得住」。
-- 114：区间留痕必须指向明细的采纳源。
--      留痕说的源不是这一单实际用的源 = 留痕指向了另一笔生意的事实。
-- 115：改派过的明细必须记着当前采纳源的区间。
--      改派换了源，区间没跟着换 = 留的是旧源的区间，
--      而这一单已经不在旧源上了 —— 对账时会拿旧源的区间判新源的单。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_qty_limits AS
WITH lim AS (
    SELECT oi.id AS order_item_id,
           e.value AS lim
      FROM sales_order_item oi
      CROSS JOIN LATERAL jsonb_array_elements(
               COALESCE(oi.detail_snapshot -> 'quantity_limits', '[]'::jsonb)) e
),
raw (seq, check_name, actual) AS (
    -- 113：留痕的份数必须落在留痕的区间内
    SELECT 113, '明细留痕的份数必须落在留痕的区间内',
           (SELECT count(*)
              FROM lim l
             WHERE NOT fn_qty_servable(
                       (l.lim ->> 'min_qty')::int,
                       (l.lim ->> 'max_qty')::int,
                       (l.lim ->> 'quantity')::int))
    UNION ALL
    -- 114：区间留痕必须指向明细的采纳源
    SELECT 114, '区间留痕必须指向明细的采纳源',
           (SELECT count(*)
              FROM lim l
             WHERE NOT EXISTS (
                     SELECT 1
                       FROM sales_order_item_source s
                      WHERE s.order_item_id = l.order_item_id
                        AND s.supplier_variant_id = (l.lim ->> 'supplier_variant_id')::bigint))
    UNION ALL
    -- 115：改派（发生在 025 之后的）必须记着当前采纳源的区间
    --
    --     为什么按时间卡：这条规则是 025 才有的，规则之前发生的改派
    --     本来就没有区间留痕 —— 那不是违规，是规则还没存在。
    --     规则的生效时刻取迁移账本里的 applied_at（唯一一份「规则从哪天起」的记录）。
    SELECT 115, '改派过的明细必须记着当前采纳源的区间',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE jsonb_array_length(COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb)) > 0
               AND (SELECT max((s.val ->> 'at')::timestamptz)
                      FROM jsonb_array_elements(
                               COALESCE(oi.detail_snapshot -> 'reassignments', '[]'::jsonb))
                           WITH ORDINALITY AS s(val, ord))
                   >= (SELECT applied_at FROM ops.schema_migration WHERE version = '025')
               AND NOT EXISTS (
                     SELECT 1
                       FROM sales_order_item_source s
                       JOIN jsonb_array_elements(
                                COALESCE(oi.detail_snapshot -> 'quantity_limits', '[]'::jsonb)) e
                         ON (e ->> 'supplier_variant_id')::bigint = s.supplier_variant_id
                      WHERE s.order_item_id = oi.id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_qty_limits IS
    '份数区间侧不变量（113-115）：留痕的份数在区间内、留痕指向采纳源、改派后区间跟着换源';

-- -------------------------------------------------------------------------------------
-- ④ 总表：加进 115
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v_invariant_checks_core_017.seq, v_invariant_checks_core_017.check_name, v_invariant_checks_core_017.expected, v_invariant_checks_core_017.actual, v_invariant_checks_core_017.passed, v_invariant_checks_core_017.result FROM v_invariant_checks_core_017
UNION ALL SELECT v_invariant_checks_tx.seq, v_invariant_checks_tx.check_name, v_invariant_checks_tx.expected, v_invariant_checks_tx.actual, v_invariant_checks_tx.passed, v_invariant_checks_tx.result FROM v_invariant_checks_tx
UNION ALL SELECT v_invariant_checks_order.seq, v_invariant_checks_order.check_name, v_invariant_checks_order.expected, v_invariant_checks_order.actual, v_invariant_checks_order.passed, v_invariant_checks_order.result FROM v_invariant_checks_order
UNION ALL SELECT v_invariant_checks_fulfill.seq, v_invariant_checks_fulfill.check_name, v_invariant_checks_fulfill.expected, v_invariant_checks_fulfill.actual, v_invariant_checks_fulfill.passed, v_invariant_checks_fulfill.result FROM v_invariant_checks_fulfill
UNION ALL SELECT v_invariant_checks_refund.seq, v_invariant_checks_refund.check_name, v_invariant_checks_refund.expected, v_invariant_checks_refund.actual, v_invariant_checks_refund.passed, v_invariant_checks_refund.result FROM v_invariant_checks_refund
UNION ALL SELECT v_invariant_checks_redemption.seq, v_invariant_checks_redemption.check_name, v_invariant_checks_redemption.expected, v_invariant_checks_redemption.actual, v_invariant_checks_redemption.passed, v_invariant_checks_redemption.result FROM v_invariant_checks_redemption
UNION ALL SELECT v_invariant_checks_inventory_017.seq, v_invariant_checks_inventory_017.check_name, v_invariant_checks_inventory_017.expected, v_invariant_checks_inventory_017.actual, v_invariant_checks_inventory_017.passed, v_invariant_checks_inventory_017.result FROM v_invariant_checks_inventory_017
UNION ALL SELECT v_invariant_checks_validity_017.seq, v_invariant_checks_validity_017.check_name, v_invariant_checks_validity_017.expected, v_invariant_checks_validity_017.actual, v_invariant_checks_validity_017.passed, v_invariant_checks_validity_017.result FROM v_invariant_checks_validity_017
UNION ALL SELECT v_invariant_checks_readmodel.seq, v_invariant_checks_readmodel.check_name, v_invariant_checks_readmodel.expected, v_invariant_checks_readmodel.actual, v_invariant_checks_readmodel.passed, v_invariant_checks_readmodel.result FROM v_invariant_checks_readmodel
UNION ALL SELECT v_invariant_checks_composition.seq, v_invariant_checks_composition.check_name, v_invariant_checks_composition.expected, v_invariant_checks_composition.actual, v_invariant_checks_composition.passed, v_invariant_checks_composition.result FROM v_invariant_checks_composition
UNION ALL SELECT v_invariant_checks_combo_017.seq, v_invariant_checks_combo_017.check_name, v_invariant_checks_combo_017.expected, v_invariant_checks_combo_017.actual, v_invariant_checks_combo_017.passed, v_invariant_checks_combo_017.result FROM v_invariant_checks_combo_017
UNION ALL SELECT v_invariant_checks_hardening.seq, v_invariant_checks_hardening.check_name, v_invariant_checks_hardening.expected, v_invariant_checks_hardening.actual, v_invariant_checks_hardening.passed, v_invariant_checks_hardening.result FROM v_invariant_checks_hardening
UNION ALL SELECT v_invariant_checks_bundle.seq, v_invariant_checks_bundle.check_name, v_invariant_checks_bundle.expected, v_invariant_checks_bundle.actual, v_invariant_checks_bundle.passed, v_invariant_checks_bundle.result FROM v_invariant_checks_bundle
UNION ALL SELECT v_invariant_checks_bundle_020.seq, v_invariant_checks_bundle_020.check_name, v_invariant_checks_bundle_020.expected, v_invariant_checks_bundle_020.actual, v_invariant_checks_bundle_020.passed, v_invariant_checks_bundle_020.result FROM v_invariant_checks_bundle_020
UNION ALL SELECT v_invariant_checks_supply_forms_021.seq, v_invariant_checks_supply_forms_021.check_name, v_invariant_checks_supply_forms_021.expected, v_invariant_checks_supply_forms_021.actual, v_invariant_checks_supply_forms_021.passed, v_invariant_checks_supply_forms_021.result FROM v_invariant_checks_supply_forms_021
UNION ALL SELECT v_invariant_checks_supply_form_shrink_022.seq, v_invariant_checks_supply_form_shrink_022.check_name, v_invariant_checks_supply_form_shrink_022.expected, v_invariant_checks_supply_form_shrink_022.actual, v_invariant_checks_supply_form_shrink_022.passed, v_invariant_checks_supply_form_shrink_022.result FROM v_invariant_checks_supply_form_shrink_022
UNION ALL SELECT v_invariant_checks_supply_source_count_023.seq, v_invariant_checks_supply_source_count_023.check_name, v_invariant_checks_supply_source_count_023.expected, v_invariant_checks_supply_source_count_023.actual, v_invariant_checks_supply_source_count_023.passed, v_invariant_checks_supply_source_count_023.result FROM v_invariant_checks_supply_source_count_023
UNION ALL SELECT v_invariant_checks_reassign.seq, v_invariant_checks_reassign.check_name, v_invariant_checks_reassign.expected, v_invariant_checks_reassign.actual, v_invariant_checks_reassign.passed, v_invariant_checks_reassign.result FROM v_invariant_checks_reassign
UNION ALL SELECT v_invariant_checks_qty_limits.seq, v_invariant_checks_qty_limits.check_name, v_invariant_checks_qty_limits.expected, v_invariant_checks_qty_limits.actual, v_invariant_checks_qty_limits.passed, v_invariant_checks_qty_limits.result FROM v_invariant_checks_qty_limits;
