-- 020 套装库存池的两个口径
--
-- 017 把套装接到成交的时候，库存这块留了两个洞。都是「池子算错」，
-- 方向都是超卖 —— 卖出去的比源侧还剩的多，源侧一核就炸。
--
-- 洞一：指定源票种查库存时，落到了别的口径上。
--
-- fn_available_qty(p_supplier_session_id, p_ticket_type_id, p_source_ticket_type_id)
-- 拿到「源侧这个整套票种」时，如果源侧恰好没报这个票种的库存，
-- 它会一路兜底到票种级 / 场次级口径 —— 那两个口径算的是**别的池子**。
-- 套装的池子是以「套」计的，同一场次里成人票、儿童票的余量跟它不相干，
-- 把它们加进来就是拿别人的池子冒充这一个，数字越大越超卖。
--
-- 修法：指定了源票种就只认这个源票种自己的快照。没有就是「不知道」
-- （known = false），不拿别的池子的数字顶上。
--
-- 洞二：套装的需求没有按池子加总。
--
-- fn_place_order 里套装预占那一段去重键里带着 bundle_sets，
-- 于是「一单买两行同一个套装、每行一套」会被去重成一行，
-- 只按 1 套去比池子。池子还剩 1 套时，两行各自都看见「还剩 1」，
-- 两行都过 —— 超卖一套。
--
-- 修法：先按明细去重（一套只算一套），再按（源场次 + 源票种）加总，
-- 一个池子一份需求，比一次。
--
-- 关于「源侧没报库存时怎么办」：这里不改成「不卖」。
-- 项目的口径是「不知道就不拦，但要把当时的可售数写进明细快照」
-- （AGENTS.md 硬约束 22）—— 返回 0 意味着「卖完了」，
-- 让整个商品下架，比超卖更贵。所以这里只把「不知道」如实报出来，
-- 剩下的交给对账。
--
-- 门禁：新增不变量 100（池子不许跨源票种相加）与 101
-- （同一个池子上的需求不许超过落单时看到的可售数）。

CREATE OR REPLACE FUNCTION public.fn_available_qty(p_supplier_session_id bigint, p_ticket_type_id bigint, p_source_ticket_type_id bigint)
 RETURNS TABLE(known boolean, available_qty integer, committed_qty integer, remaining_qty integer, sold_qty integer, held_qty integer, source_status text, snapshot_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_avail         INTEGER;
    v_sold          INTEGER;
    v_status        TEXT;
    v_at            TIMESTAMPTZ;
    v_cnt           INTEGER;
    v_found         BOOLEAN := FALSE;
    v_ticket_scoped BOOLEAN := FALSE;   -- 池子是票种级的（互不相干）还是场次级的（共享）
    v_our_sold      INTEGER := 0;
    v_our_held      INTEGER := 0;
    v_unref         INTEGER := 0;
BEGIN
    IF p_supplier_session_id IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::int, 0::int, 0::int, 0::int, 0::int,
                            NULL::text, NULL::timestamptz;
        RETURN;
    END IF;

    -- 精确优先：源票种级库存快照（017 新增）。
    --
    -- 套装的售卖单位是「套」：源侧报「还剩 3 套家庭套票」，
    -- 这个数不对应任何规范票种，只能直接按源票种找。
    -- 承诺也按源票种算：我们在这个源票种上欠了多少套。
    IF p_source_ticket_type_id IS NOT NULL THEN
        SELECT COALESCE(i.available_qty, 0), COALESCE(i.sold_qty, 0),
               i.status, i.captured_at
          INTO v_avail, v_sold, v_status, v_at
          FROM inventory_snapshot i
         WHERE i.supplier_session_id = p_supplier_session_id
           AND i.supplier_ticket_type_id = p_source_ticket_type_id
         ORDER BY i.captured_at DESC, i.id DESC
         LIMIT 1;

        IF FOUND THEN
            v_found := TRUE;
            v_ticket_scoped := TRUE;

            SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
                   COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
              INTO v_our_sold, v_our_held
              FROM inventory_hold h
             WHERE h.supplier_session_id = p_supplier_session_id
               AND h.source_ticket_type_id = p_source_ticket_type_id;
        END IF;
    END IF;

    -- 精确优先：票种级库存快照。
    --
    -- 上面这三道兜底（票种级 / 场次级 / 可用性缓存）在指定了源票种时一律不许走：
    -- 那些口径算的是**别的**池子。套装要的是「源侧这个整套票种还剩几套」，
    -- 把同一场次里成人票、儿童票的余量加进来，就是拿别的池子冒充这一个 ——
    -- 数字越大越超卖。源侧没报这个票种的库存，就是不知道（known=false），
    -- 不是「这个池子还有场次里所有的余量」。
    -- 一个源票种只取最新一条；一个规范票种可能对应好几个源票种（映射表），要加总。
    IF p_source_ticket_type_id IS NULL AND NOT v_found THEN
        WITH latest AS (
            SELECT DISTINCT ON (i.supplier_ticket_type_id)
                   i.supplier_ticket_type_id, i.available_qty, i.sold_qty, i.status, i.captured_at
              FROM inventory_snapshot i
             WHERE i.supplier_session_id = p_supplier_session_id
               AND i.supplier_ticket_type_id IS NOT NULL
             ORDER BY i.supplier_ticket_type_id, i.captured_at DESC, i.id DESC
        )
        SELECT count(*),
               COALESCE(sum(l.available_qty), 0),
               COALESCE(sum(l.sold_qty), 0),
               COALESCE((array_agg(l.status ORDER BY l.captured_at DESC))[1], ''),
               max(l.captured_at)
          INTO v_cnt, v_avail, v_sold, v_status, v_at
          FROM latest l
         WHERE p_ticket_type_id IS NULL
            OR EXISTS (SELECT 1
                         FROM ticket_type_mapping ttm
                        WHERE ttm.supplier_ticket_type_id = l.supplier_ticket_type_id
                          AND ttm.ticket_type_id = p_ticket_type_id);

        IF v_cnt > 0 THEN
            v_found := TRUE;
            v_ticket_scoped := TRUE;
        END IF;
    END IF;

    -- 兜底：场次级快照（票种为空的那些行 = 整个场次的合计）
    IF p_source_ticket_type_id IS NULL AND NOT v_found THEN
        SELECT COALESCE(i.available_qty, 0), COALESCE(i.sold_qty, 0),
               i.status, i.captured_at
          INTO v_avail, v_sold, v_status, v_at
          FROM inventory_snapshot i
         WHERE i.supplier_session_id = p_supplier_session_id
           AND i.supplier_ticket_type_id IS NULL
         ORDER BY i.captured_at DESC, i.id DESC
         LIMIT 1;

        IF FOUND THEN
            v_found := TRUE;
        END IF;
    END IF;

    -- 粗略兜底：场次级可用性缓存（过期的不算数）
    IF p_source_ticket_type_id IS NULL AND NOT v_found THEN
        SELECT COALESCE(ac.available_qty, 0), 0,
               COALESCE(ac.status, ''), ac.fetched_at
          INTO v_avail, v_sold, v_status, v_at
          FROM availability_cache ac
         WHERE ac.supplier_session_id = p_supplier_session_id
           AND ac.expires_at > now()
         ORDER BY ac.fetched_at DESC
         LIMIT 1;

        IF FOUND THEN
            v_found := TRUE;
        END IF;
    END IF;

    -- 我们在这个池子上的承诺：已兑现的（consumed）+ 还占着的（active）。
    -- voided / released / expired 都不再占库存 —— 承诺已经撤销了。
    --
    -- 算到哪个范围，看这个池子是怎么来的：
    --   源票种级池子（套装）：这个源票种上的池子，与别的票种互不相干 → 只算本票种的承诺；
    --   票种级池子（v_ticket_scoped）：每个源票种各有一个池子，互不相干 → 只算本票种的承诺；
    --   场次级池子（整个场次一份）    ：所有票种共用 → 整个场次的承诺都要算。
    --
    -- 少了后一句，就是「每个票种都能把整场次的可用量再花一遍」——
    -- 卖 2 张成人再卖 2 张儿童，池子里明明只有 2 张。
    IF p_source_ticket_type_id IS NOT NULL THEN
        IF v_found THEN
            NULL;   -- 上面已经算过了（本源票种的承诺）
        ELSE
            -- 源侧没报这个票种的库存：可用数是「不知道」，
            -- 但我们在这个池子上欠了多少是事实，照样算出来。
            SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
                   COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
              INTO v_our_sold, v_our_held
              FROM inventory_hold h
             WHERE h.supplier_session_id = p_supplier_session_id
               AND h.source_ticket_type_id = p_source_ticket_type_id;
        END IF;
    ELSIF p_ticket_type_id IS NULL OR v_ticket_scoped THEN
        SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
               COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
          INTO v_our_sold, v_our_held
          FROM inventory_hold h
         WHERE h.supplier_session_id = p_supplier_session_id
           AND (p_ticket_type_id IS NULL OR h.ticket_type_id = p_ticket_type_id);
    ELSE
        SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
               COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
          INTO v_our_sold, v_our_held
          FROM inventory_hold h
         WHERE h.supplier_session_id = p_supplier_session_id;
    END IF;

    -- 源侧还没算进去的已售：源侧报了已售量就减掉它对不上的那部分，
    -- 源侧没报（缓存口径）就全算成「还不知道」。
    IF v_found AND v_sold IS NOT NULL THEN
        v_unref := GREATEST(v_our_sold - v_sold, 0);
    ELSE
        v_unref := v_our_sold;
    END IF;

    known         := v_found;
    available_qty := CASE WHEN v_found THEN v_avail END;
    committed_qty := v_unref + v_our_held;
    remaining_qty := CASE WHEN v_found THEN GREATEST(v_avail - v_unref - v_our_held, 0) END;
    sold_qty      := v_our_sold;
    held_qty      := v_our_held;
    source_status := CASE WHEN v_found THEN v_status END;
    snapshot_at   := CASE WHEN v_found THEN v_at END;
    RETURN NEXT;
END;
$function$;

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
            END LOOP;

            IF jsonb_array_length(v_sources) = 0 THEN
                RAISE EXCEPTION '组合套餐 % 在 % 没有可售的成分配方（成分当天没报价 / 成分不同场次 / 跨源 / 按团报价口径未定）',
                  v_variant, v_date;
            END IF;

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
        END IF;

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
            'rule',                 v_price.rule)
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

-- -----------------------------------------------------------------------------
-- 读模型：一个订单在套装池子上的需求（对账用）
--
-- 「这一单在这个池子上要了多少套」和「落单时这个池子还剩多少」摆在一起，
-- 超卖一眼就看得出来。逐明细看是看不出来的：每条明细都记着自己那一份。
-- -----------------------------------------------------------------------------
CREATE VIEW v_bundle_pool_demand AS
WITH bi AS (
    -- 套装明细：套装变体的订单明细。
    SELECT oi.id AS item_id, oi.order_id, oi.quantity, oi.session_id,
           oi.product_variant_id, oi.detail_snapshot
      FROM sales_order_item oi
     WHERE EXISTS (SELECT 1
                     FROM supplier_variant_bundle svb
                    WHERE svb.product_variant_id = oi.product_variant_id
                      AND svb.status = 'active')
),
bp AS (
    -- 明细落在哪个池子上：套装预占记着池子（源场次 + 源票种）。
    SELECT DISTINCT bi.order_id, bi.item_id, bi.quantity, bi.detail_snapshot,
                    h.supplier_session_id, h.source_ticket_type_id
      FROM bi
      JOIN inventory_hold h
        ON h.order_id = bi.order_id
       AND h.product_variant_id = bi.product_variant_id
       AND NOT h.product_session_id IS DISTINCT FROM bi.session_id
     WHERE h.source_ticket_type_id IS NOT NULL
)
SELECT bp.order_id,
       bp.supplier_session_id,
       bp.source_ticket_type_id,
       sum(bp.quantity) AS demand_sets,
       min(a.remaining) AS remaining_at_order,
       bool_and(a.known) AS known_at_order
  FROM bp
  CROSS JOIN LATERAL (
        -- 这一条明细落单时看到的池子余量。
        -- 套装明细的可售数条目都属于同一个池子（源侧卖的是整套），
        -- 所以取最小值就是池子的余量。
        SELECT min(COALESCE((e.value->>'remaining_qty')::integer, 0)) AS remaining,
               bool_and(COALESCE((e.value->>'known')::boolean, false)) AS known
          FROM jsonb_array_elements(
                 COALESCE((bp.detail_snapshot->'availability')->'sources', '[]'::jsonb)) e(value)
       ) a
 GROUP BY bp.order_id, bp.supplier_session_id, bp.source_ticket_type_id;

COMMENT ON VIEW v_bundle_pool_demand IS
    '套装池子上的需求对账：一个订单在某个池子上要了多少套，落单时那个池子还剩多少';

-- -----------------------------------------------------------------------------
-- 不变量 100：按源票种查库存，不许跨源票种相加
--
-- 指定源票种时，可用数只能来自这个源票种自己的快照。
-- 源侧没报这个票种的库存 → 不知道（known = false、可用数为空），
-- 不许拿同一场次里别的票种的余量顶上。
-- -----------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_bundle_020 AS
WITH raw(seq, check_name, actual) AS (
    SELECT 100,
           '按源票种查库存不许跨源票种相加（源侧没报就说不知道）',
           (SELECT count(*)
              FROM supplier_session ss
              JOIN supplier_ticket_type stt
                ON stt.supplier_product_id = ss.supplier_product_id
              CROSS JOIN LATERAL fn_available_qty(ss.id, NULL, stt.id) a
             WHERE (EXISTS (SELECT 1
                              FROM inventory_snapshot s
                             WHERE s.supplier_session_id = ss.id
                               AND s.supplier_ticket_type_id = stt.id)
                    AND (NOT a.known
                         OR a.available_qty IS DISTINCT FROM
                            (SELECT s.available_qty
                               FROM inventory_snapshot s
                              WHERE s.supplier_session_id = ss.id
                                AND s.supplier_ticket_type_id = stt.id
                              ORDER BY s.captured_at DESC, s.id DESC
                              LIMIT 1)))
                OR (NOT EXISTS (SELECT 1
                                 FROM inventory_snapshot s
                                WHERE s.supplier_session_id = ss.id
                                  AND s.supplier_ticket_type_id = stt.id)
                    AND (a.known OR a.available_qty IS NOT NULL)))
    UNION ALL
    -- 101：同一个池子上的需求不许超过落单时看到的可售数。
    --
    -- 逐明细比是看不出来的：两条明细各自记着「还剩 1 套」，
    -- 各要 1 套，各自都过 —— 加起来 2 套就超卖了。
    -- 按池子加总才看得见。
    SELECT 101,
           '套装在同一个池子上的需求不许超过落单时看到的可售数',
           (SELECT count(*)
              FROM v_bundle_pool_demand d
             WHERE d.known_at_order
               AND d.remaining_at_order < d.demand_sets)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_bundle_020 IS
    '套装库存侧不变量（100-101）：池子不跨源票种、需求按池子加总不许超卖';

-- -----------------------------------------------------------------------------
-- 总表：加进 100 / 101
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v_invariant_checks_core_017.seq, v_invariant_checks_core_017.check_name,
       v_invariant_checks_core_017.expected, v_invariant_checks_core_017.actual,
       v_invariant_checks_core_017.passed, v_invariant_checks_core_017.result
  FROM v_invariant_checks_core_017
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
UNION ALL SELECT v_invariant_checks_bundle_020.seq, v_invariant_checks_bundle_020.check_name, v_invariant_checks_bundle_020.expected, v_invariant_checks_bundle_020.actual, v_invariant_checks_bundle_020.passed, v_invariant_checks_bundle_020.result FROM v_invariant_checks_bundle_020;
