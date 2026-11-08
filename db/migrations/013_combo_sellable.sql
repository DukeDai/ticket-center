-- =====================================================================================
-- 013 组合套餐真的能卖（异构融合方向 B 的交易侧）
-- =====================================================================================
-- 012 把「一个可售单元由多个源 SKU 按数量组成」这件事**表达**出来了：
--   规范侧声明组件与数量（product_variant_relation.quantity），
--   源侧给配方（supplier_variant_composition），
--   两侧逐项对得上由不变量 79/80 把门。
--
-- 但那时候组合还**卖不了**，而且是刻意的：
--   定价与预订还没接组合 → 守卫触发器 fn_guard_combo_mapping 挡住组合直接挂源映射，
--   不变量 81 再复查一遍。理由写得很直白：
--   组合的成本 = Σ 组件成本 × 数量，一次预订要带整组源 SKU；
--   在这两样落地之前挂上源映射，定价函数会用**一个**源 SKU 的成本给整张套餐定价 ——
--   收三个人的钱，出一张票。
--
-- 这一段把这句话兑现：定价、预订、出券三条写路径都接组合。
-- 组合套餐从此是一个**能下单、能履约、能核销**的可售单元，而不是一张对不上的配方表。
--
-- 一、这一段引入的关键形状：订单明细的「成分行」
--   组合套餐在订单里是**一行**（客户买的是一份套餐），
--   但它要向源侧下**多份**单（2 份成人票 + 1 份儿童票 = 3 个成分）。
--   原来「一行明细 = 一个源 SKU」的形状装不下这件事：
--   sales_order_item 只有一个 supplier_product_id、一个票种、一个份数。
--
--   所以引入 sales_order_item_source（订单明细 ↔ 成分行）：
--     一行 = 「这个明细要用哪个源 SKU、顶的是哪个可售单元、要几份、能进几次场、成本多少」。
--   普通变体 = 一行（明细自己的变体 + 定价选中的源 SKU）；
--   组合变体 = 每个成分一行（配方说了算）。
--
--   从这一段起，**履约的单位是成分行，不是订单明细**：
--     预订：一份成分 = 一条预订；
--     出券：一份成分 = 该成分应发张数张券（票码与持票人一一对应，规矩不变）；
--     库存预占：一份成分 = 一张预占单（在成分自己的源场次上）。
--   订单明细仍然是「客户买了什么、价格多少」的单位。
--
--   成分行上有两个数，别混：
--     quantity          = 向源侧买了几份（按团报价时 = 1 团；按人 = 票数）
--     admission_quantity= 这些份数能进几次场（按团报价时 = 团人数）
--   两者相等时（绝大多数情况）看不出差别；按团报价时团总价摊到人头，差一个倍数。
--   成本按 quantity 算（unit_cost × quantity），实名 / 库存 / 出券 / 履约按 admission_quantity 算 ——
--   一笔账只有一个算法。
--
-- 二、为什么定价函数要分两路
--   定价只有一个实现（fn_price_variant，硬约束 15/18）。它内部按变体角色分两路：
--     普通变体：走 fn_route_candidates 取第一名（方向 A：一个源 SKU 覆盖这个可售单元）；
--     组合变体：走 fn_combo_components 取配方（方向 B：多个源 SKU 组成这个可售单元）。
--   两路共用同一套加价口径（percent / min_margin / floor / list_markup），
--   所以组合的售价与普通变体的售价是同一个合同算出来的，不是第二份定价规则。
--
--   组合的成本 = Σ 成分单价 × 成分数量；
--   组合没有单一的采纳源商品（成分可能来自多个源商品），
--   所以 supplier_product_id / net_price / fx_rate 这些「单一来源」的列在组合上是 NULL ——
--   留一个假的单一来源比留空更危险（对账会去查一个不存在的采纳源）。
--
--   成分的采纳源由**源侧配方**（supplier_variant_composition）指定，不在这里重新选源：
--   配方是「这个源 SKU 顶的是哪个可售单元」的显式记录，改它要走配方，不是定价函数偷偷换源。
--   「选源与定价必须同源」这条规矩对成分一样成立 ——
--   配方里某个成分用的是 Zowoyoo，定价就必须按 Zowoyoo 的成本算，
--   不能按 Trip 的成本卖 Zowoyoo 的票（那就是「按 A 源的价格卖、按 B 源出票」）。
--
-- 三、拿不准的地方一律不卖
--   - 有一个成分当天没报价 / 成本折算不出来 → 整个组合不可售（不卖半个套餐）；
--   - 成分不在同一个场次上 → 包不起来（一次入园不是一个场次）→ 不可售；
--   - 组合的成分来自多个源 → 一次预订给不了两个源 → 不可售；
--   - 组合走「按团报价」口径 → 团总价与成分份数不是一回事，口径还没定 → 不可售。
--   这四种都表现为「定价函数算不出这一行」，也就是「当天不可售」，
--   而不是拍一个价格出来。缺口查 v_combo_price_gap。
--
-- 四、实名（持票人）在组合上按成分收
--   家庭套餐 = 2 份成人票 + 1 份儿童票 → 要收 2 个成人的姓名证件 + 1 个儿童的姓名生日。
--   持票人挂在订单明细上，但按成分变体分组（order_holder.component_variant_id）。
--   因此不变量 25（「持票人数必须与票数一致」）要按成分改口径：
--   组合的「票数」= 各成分的入场份数之和，不是明细份数（明细份数是套餐份数）。
--
-- 五、这一段不改变的东西
--   - 金额一律 NUMERIC，汇率用快照（成分行留痕 fx_rate / fx_as_of）；
--   - 幂等键必填（同键异内容报错）；
--   - 状态机只走 state_transition 的合法边；
--   - 历史不可变：订单快照带成分明细，出券带持票人快照；
--   - 源不可信：预订失败、重复收款、退款、核销的口径一字未动。
--
-- 六、对 012 的一处修正
--   012 的文首第 6 条写的是「定价与预订还没接组合，组合不参与选源与定价」。
--   本段把那句话兑现了：组合现在参与定价与预订，但**仍然不许直接挂源映射**
--   （fn_guard_combo_mapping 与不变量 81 不变 —— 组合的供给只走配方）。
--   012 的守卫触发器与不变量一个字没动，动的只是「组合能不能卖」这件事。
--
-- 七、这一段暂时没做的
--   C 端读模型（c_variant_calendar / c_product_card）仍然只认 price_calendar，
--   而组合没有自己的 price_calendar 行 —— 组合今天只能从 B 端分销链路下单，
--   还上不了 C 端日历。原因是组合的「有效期终点」和「人群标签」还没有定：
--   2 份一日成人票 + 1 份一日儿童票的组合，有效期是 1 天还是 2 天？
--   人群标签是「家庭」还是「成人+儿童」？这两件事定了再进读模型，
--   否则前端会自己加一天、自己猜人群 —— 那是 010/011 刚根治掉的 bug。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 组合成分的成本：唯一实现
--
-- 一行 = 一个成分：顶的是哪个可售单元、用哪个源 SKU、要几份、那天多少钱、折算到目标币种多少。
--
-- 为什么要有这个函数，而不是在定价函数里现写一段 JOIN：
--   定价（fn_price_variant）要用它算成本，
--   下单（fn_place_order）要用它落成分行，
--   排查（v_combo_price_gap）要用它找缺口 ——
--   三处算三遍，就是三处可能算出三个答案。同一份成分，只有一处实现。
--
-- 口径说明：
--   - 成分用哪个源 SKU 由**源侧配方**（supplier_variant_composition）说，不在这里重新选源。
--     配方是「这个源 SKU 顶的是哪个可售单元」的显式记录（012 的原话：「配对关系记下来，不靠猜」）。
--     如果这里改成「按最便宜的源重新选」，就会出现配方记着 A 源、实际卖的是 B 源 ——
--     对账时逐行比配方全对不上，而且正是「按 A 源的价格卖、按 B 源出票」那种错。
--     配方过期了要改配方（运营的事），不是定价函数偷偷换源。
--   - 规范侧声明与源侧配方必须逐项对得上（r.quantity = c.quantity）；
--     对不上就不是一个包（不变量 79/80 把门，这里再挡一道）。
--   - 成分当天没有报价、或成本折算不出来 → 成本列留空（NULL），
--     由定价函数判「不可售」，不替它猜一个价。
--   - 场次：先看成分自己的售价行；没有就落到本商品当天的场次。
--     组合是一次入园，成分必须落在同一个场次上 —— 这个由定价函数判定（不可售则不卖）。
--   - 成本列是**每份**成本（单价），不是这一行总共多少钱。
--     总成本 = 单价 × 数量，由定价函数算 —— 两处各算一次就会差一个倍数。
--   - 一个源 SKU 可以同时顶多个成分（参数化源：一个人群参数化的 SKU 覆盖成人/儿童/老年）。
--     这时配方里有两行，同一个源 SKU，不同成分、不同份数 —— 013 放宽了 012 的唯一键就是为了这个。
-- -------------------------------------------------------------------------------------
-- -------------------------------------------------------------------------------------
-- ①a 场次级绑定：规范场次 ↔ 源场次
--
-- 预订与库存都挂在**源场次**上，而源场次只能从绑定表 product_session_source 来
-- （硬约束 19：「预订的源场次来自绑定，不按日期猜」）。
--
-- 为什么单独拎成一个函数：
--   组合成分要查、普通变体也要查、预订时还要再查一次（补历史单）——
--   三处各写一遍 WHERE，三处可能选出三个源场次。
--   选错的后果是「买的是 A 场的票，出的是 B 场的票」，
--   而且账面上完全看不出来（都是这个商品的场次）。
--
-- 排序：先按绑定优先级，再按 id —— 同等条件下取最早登记的那条，行为稳定。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_bound_supplier_session(
    p_product_session_id BIGINT,
    p_supplier_product_id BIGINT
)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT pss.supplier_session_id
      FROM product_session_source pss
     WHERE pss.product_session_id = p_product_session_id
       AND pss.supplier_product_id = p_supplier_product_id
     ORDER BY pss.priority, pss.id
     LIMIT 1;
$$;

COMMENT ON FUNCTION fn_bound_supplier_session(BIGINT, BIGINT) IS
    '场次级绑定查询的唯一实现：规范场次 + 源商品 → 源场次；没有绑定就返回 NULL（不猜）';

CREATE OR REPLACE FUNCTION fn_combo_components(
    p_variant_id      BIGINT,
    p_date             DATE,
    p_channel_id       BIGINT,
    p_target_currency  TEXT
)
RETURNS TABLE (
    component_variant_id     BIGINT,
    component_key            TEXT,
    component_ticket_type_id BIGINT,
    quantity                 NUMERIC,
    supplier_variant_id      BIGINT,
    supplier_product_id      BIGINT,
    supplier_id              BIGINT,
    net_price                NUMERIC,
    source_currency          TEXT,
    fx_rate                  NUMERIC,
    fx_as_of                 DATE,
    unit_cost                NUMERIC,
    product_session_id       BIGINT,
    supplier_session_id      BIGINT,
    source_min_margin        NUMERIC,
    is_price_locked          BOOLEAN
)
LANGUAGE sql STABLE
AS $$
    WITH combo AS (
        SELECT pv.id AS combo_variant_id, pv.product_id
          FROM product_variant pv
         WHERE pv.id = p_variant_id
           AND pv.variant_role = 'combo'
    ),
    listing AS (
        SELECT cl.id AS listing_id
          FROM channel_listing cl
         WHERE cl.channel_id = p_channel_id
           AND cl.status = 'online'
           AND cl.product_id = (SELECT product_id FROM combo)
    ),
    recipe AS (
        -- 源侧配方：一行 = 「这个成分由这个源 SKU 顶，要几份」
        SELECT c.component_variant_id,
               c.supplier_variant_id,
               c.quantity,
               cv.variant_key    AS component_key,
               cv.ticket_type_id AS component_ticket_type_id
          FROM combo
          JOIN supplier_variant_composition c
            ON c.product_variant_id = combo.combo_variant_id
           AND c.status = 'active'
          JOIN product_variant cv
            ON cv.id = c.component_variant_id
    ),
    parts AS (
        SELECT r.component_variant_id,
               r.component_key,
               r.component_ticket_type_id,
               r.quantity,
               r.supplier_variant_id,
               sv.supplier_product_id,
               sp.supplier_id,
               sv.is_price_locked,
               COALESCE(cls.min_margin, 0) AS source_min_margin,
               spc.net_price,
               spc.currency AS source_currency,
               CASE WHEN spc.net_price IS NULL THEN NULL
                    ELSE round(fn_fx_pair_rate(spc.currency, p_target_currency, p_date), 8) END AS fx_rate,
               CASE WHEN spc.net_price IS NULL THEN NULL
                    ELSE fn_fx_pair_snapshot_date(spc.currency, p_target_currency, p_date) END AS fx_as_of,
               CASE WHEN spc.net_price IS NULL THEN NULL
                    ELSE round(fn_convert(spc.net_price, spc.currency, p_target_currency, p_date), 2) END AS unit_cost,
               pc.session_id AS price_session_id
          FROM recipe r
          JOIN supplier_variant sv ON sv.id = r.supplier_variant_id AND sv.status = 'active'
          JOIN supplier_product sp ON sp.id = sv.supplier_product_id
          -- 成分当天在这个源上的报价：源侧 SKU × 规范成分 × 日期
          LEFT JOIN LATERAL (
                SELECT s.net_price, s.currency
                  FROM supplier_price_calendar s
                 WHERE s.supplier_variant_id = r.supplier_variant_id
                   AND s.product_variant_id  = r.component_variant_id
                   AND s.date = p_date
                   AND s.status = 'available'
                 ORDER BY s.id
                 LIMIT 1) spc ON true
          -- 成分的毛利下限：跟上架源绑定走（不是源侧的属性，是这个渠道的约定）
          LEFT JOIN LATERAL (
                SELECT c2.min_margin
                  FROM channel_listing_source c2
                  JOIN listing l ON l.listing_id = c2.channel_listing_id
                 WHERE c2.supplier_product_id = sv.supplier_product_id
                   AND c2.enabled
                 ORDER BY c2.priority, c2.id
                 LIMIT 1) cls ON true
          LEFT JOIN LATERAL (
                SELECT p2.session_id
                  FROM price_calendar p2
                 WHERE p2.product_variant_id = r.component_variant_id
                   AND p2.date = p_date
                   AND p2.status = 'active'
                 ORDER BY (p2.channel_id IS NOT NULL) DESC, p2.id DESC
                 LIMIT 1) pc ON true
    ),
    located AS (
        SELECT p.*,
               COALESCE(p.price_session_id,
                        (SELECT ps.id
                           FROM product_session ps
                          WHERE ps.product_id = (SELECT product_id FROM combo)
                            AND ps.session_date = p_date
                            AND ps.status = 'active'
                          ORDER BY ps.id
                          LIMIT 1)) AS product_session_id
          FROM parts p
    )
    SELECT l.component_variant_id,
           l.component_key,
           l.component_ticket_type_id,
           l.quantity,
           l.supplier_variant_id,
           l.supplier_product_id,
           l.supplier_id,
           l.net_price,
           l.source_currency,
           l.fx_rate,
           l.fx_as_of,
           l.unit_cost,
           l.product_session_id,
           fn_bound_supplier_session(l.product_session_id, l.supplier_product_id) AS supplier_session_id,
           l.source_min_margin,
           l.is_price_locked
      FROM located l
     ORDER BY l.component_variant_id;
$$;

COMMENT ON FUNCTION fn_combo_components(BIGINT, DATE, BIGINT, TEXT) IS
    '组合成分的唯一实现：一行一个成分（配方指定用哪个源 SKU、要几份、当天单价、折算到目标币种、落在哪个场次）；成分当天没报价时成本列留空，由定价函数判不可售';

-- -------------------------------------------------------------------------------------
-- ② 定价：组合分支
--
-- 整体替换 fn_price_variant（同签名，CREATE OR REPLACE）。
-- 001 已应用，改它等于内容漂移 —— 与 005/006/009/010/012 同一个套路。
--
-- 组合分支与普通分支的差别只在「成本从哪来」：
--   普通：采纳源 SKU 的净价（fn_route_candidates 第一名）；
--   组合：Σ 成分单价 × 成分数量（fn_combo_components）。
-- 加价口径（percent / min_margin / floor / list_markup / 划线价 / 折扣）两者共用同一段代码，
-- 所以组合的售价不是「另一份定价规则」算出来的。
--
-- 组合不参与锁价（price_locked）：锁价是「源方定价，平台无权加价」，
-- 而组合的售价是一整张套餐的价格，没有对应的单一源方挂牌价。
-- 成分各自是不是锁价，记在成分明细里（rule->'combo'）。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_price_variant(
    p_variant_id         BIGINT,
    p_date                DATE,
    p_context_channel_id BIGINT,
    p_price_channel_id   BIGINT DEFAULT NULL
)
RETURNS TABLE (
    product_id           BIGINT,
    product_variant_id   BIGINT,
    date                 DATE,
    currency             TEXT,
    supplier_product_id  BIGINT,
    source_currency      TEXT,
    net_price            NUMERIC,
    fx_rate              NUMERIC,
    fx_as_of             DATE,
    cost_price           NUMERIC,
    sell_price           NUMERIC,
    list_price           NUMERIC,
    discount_pct         NUMERIC,
    price_locked         BOOLEAN,
    min_margin           NUMERIC,
    rule                 JSONB
)
LANGUAGE sql STABLE
AS $$
WITH ctx AS (
    SELECT cl.id AS listing_id,
           cl.product_id,
           cl.price_policy,
           COALESCE(NULLIF(cl.price_policy->>'mode', ''), 'cost_plus')                  AS mode,
           COALESCE(NULLIF(cl.price_policy->>'percent', '')::numeric, 0)                AS percent,
           NULLIF(cl.price_policy->>'floor', '')::numeric                               AS floor_price,
           COALESCE(NULLIF(cl.price_policy->>'list_markup_percent', '')::numeric, 0)    AS list_markup,
           COALESCE(NULLIF(cl.price_policy->>'min_margin', '')::numeric, 0)            AS listing_min_margin,
           fn_price_row_currency(p_price_channel_id)                                   AS target_currency
      FROM channel_listing cl
     WHERE cl.channel_id = p_context_channel_id
       AND cl.status = 'online'
       AND cl.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = p_variant_id)
),
cand AS (
    -- 候选与排序来自选源的唯一实现（fn_route_candidates）：
    -- 路由视图与定价函数必须选出同一个源，否则会「按 A 源的价格卖、按 B 源出票」。
    SELECT ctx.product_id,
           ctx.price_policy,
           ctx.target_currency,
           ctx.mode,
           ctx.percent,
           ctx.floor_price,
           ctx.list_markup,
           ctx.listing_min_margin,
           rc.supplier_product_id,
           rc.source_currency,
           rc.net_price,
           rc.supplier_price,
           rc.is_price_locked,
           rc.source_min_margin,
           rc.fx_rate_to_target   AS rate_to_target,
           rc.fx_as_of            AS snap_date,
           fn_convert(rc.net_price, rc.source_currency, ctx.target_currency, p_date) AS cost_in_target
      FROM ctx
      JOIN LATERAL fn_route_candidates(p_variant_id, p_date, p_context_channel_id,
                                       ctx.target_currency) rc
        ON rc.route_rank = 1
),
combo_parts AS (
    SELECT cc.*
      FROM ctx
      JOIN LATERAL fn_combo_components(p_variant_id, p_date, p_context_channel_id,
                                       ctx.target_currency) cc
        ON true
),
combo AS (
    -- 组合：一份套餐的成本 = Σ 成分单价 × 成分数量。
    SELECT ctx.product_id,
           ctx.price_policy,
           ctx.target_currency,
           ctx.mode,
           ctx.percent,
           ctx.floor_price,
           ctx.list_markup,
           ctx.listing_min_margin,
           sum(cc.unit_cost * cc.quantity)                AS cost_in_target,
           count(*)                                      AS n_parts,
           count(cc.unit_cost)                           AS n_priced,
           count(DISTINCT cc.product_session_id)         AS n_sessions,
           count(DISTINCT cc.supplier_id)                AS n_suppliers,
           count(*) FILTER (WHERE cc.is_price_locked)    AS n_locked,
           max(cc.source_min_margin)                     AS source_min_margin,
           jsonb_agg(jsonb_build_object(
               'component_variant_id', cc.component_variant_id,
               'component_key',        cc.component_key,
               'quantity',             cc.quantity,
               'supplier_variant_id',  cc.supplier_variant_id,
               'supplier_product_id',  cc.supplier_product_id,
               'net_price',            cc.net_price,
               'currency',             cc.source_currency,
               'fx_rate',              cc.fx_rate,
               'fx_as_of',             cc.fx_as_of,
               'unit_cost',            cc.unit_cost,
               'cost',                 round(cc.unit_cost * cc.quantity, 2),
               'price_locked',         cc.is_price_locked
           ) ORDER BY cc.component_variant_id) AS breakdown
      FROM ctx
      JOIN combo_parts cc ON true
     GROUP BY ctx.product_id, ctx.price_policy, ctx.target_currency, ctx.mode, ctx.percent,
              ctx.floor_price, ctx.list_markup, ctx.listing_min_margin
),
one AS (
    -- 普通变体：一个源 SKU 顶住这个可售单元（方向 A）。
    SELECT c.product_id,
           c.target_currency,
           c.supplier_product_id,
           c.source_currency,
           c.net_price,
           c.rate_to_target,
           c.snap_date,
           c.cost_in_target,
           c.supplier_price,
           c.is_price_locked,
           c.source_min_margin,
           c.mode,
           c.percent,
           c.floor_price,
           c.list_markup,
           c.listing_min_margin,
           c.price_policy,
           NULL::jsonb  AS breakdown
      FROM cand c
    UNION ALL
    -- 组合变体：多个源 SKU 组成这个可售单元（方向 B）。
    -- 拿不准一律不卖：成分缺价、成分不同场次、跨源、成分锁价、按团报价 → 这一行不存在。
    --
    -- 成分锁价为什么也不卖：锁价是「源方定价，平台无权加价」。
    -- 组合是一整张套餐的价格，给它加价等于给那个被锁价的成分变相加价 ——
    -- 源方的锁价承诺是在成分上兑现的，挪到套餐上就没法兑现了。
    -- 宁可少卖，不可卖错。
    SELECT cb.product_id,
           cb.target_currency,
           NULL::bigint,   -- 没有单一采纳源商品（成分可能来自多个源商品）
           NULL::text,     -- 成分可能不同币种 → 没有单一源币种
           NULL::numeric,  -- 同理，没有单一源净价
           NULL::numeric,  -- 没有单一汇率（每个成分各自留痕）
           NULL::date,
           cb.cost_in_target,
           NULL::numeric,
           false,          -- 组合不锁价（锁价是单一源方挂牌价的概念）
           cb.source_min_margin,
           cb.mode,
           cb.percent,
           cb.floor_price,
           cb.list_markup,
           cb.listing_min_margin,
           cb.price_policy,
           cb.breakdown
      FROM combo cb
     WHERE cb.n_parts > 0
       AND cb.n_priced = cb.n_parts
       AND cb.n_sessions = 1
       AND cb.n_suppliers = 1
       AND cb.n_locked = 0
       AND cb.mode <> 'per_group'
),
calc AS (
    SELECT o.*,
           GREATEST(o.listing_min_margin, COALESCE(o.source_min_margin, 0)) AS effective_min_margin,
           (o.is_price_locked AND fn_bool_setting('price_locked_uses_source_list_price', true)) AS locked
      FROM one o
),
priced AS (
    SELECT c.*,
           CASE
             WHEN c.locked
               THEN round(fn_convert(c.supplier_price, c.source_currency, c.target_currency, p_date), 2)
             WHEN c.mode = 'per_group'
               THEN round(fn_convert(c.supplier_price, c.source_currency, c.target_currency, p_date), 2)
             ELSE round(GREATEST(
                    c.cost_in_target * (1 + c.percent / 100),
                    CASE WHEN c.effective_min_margin > 0 AND c.effective_min_margin < 1
                         THEN c.cost_in_target / (1 - c.effective_min_margin)
                         ELSE c.cost_in_target END,
                    COALESCE(c.floor_price, c.cost_in_target)
             ), 2)
           END AS sell_price
      FROM calc c
)
SELECT c.product_id,
       p_variant_id,
       p_date,
       c.target_currency,
       c.supplier_product_id,
       c.source_currency,
       c.net_price,
       c.rate_to_target,
       c.snap_date,
       round(c.cost_in_target, 2) AS cost_price,
       c.sell_price,
       -- 源方定价（锁价 / 按团报价）不虚构划线价；其余行按 list_markup_percent 上浮。
       CASE WHEN c.locked OR c.mode = 'per_group'
            THEN c.sell_price
            ELSE round(c.sell_price * (1 + c.list_markup / 100), 2)
       END AS list_price,
       CASE WHEN c.locked OR c.mode = 'per_group' OR c.sell_price = 0
            THEN 0::numeric
            ELSE round(((round(c.sell_price * (1 + c.list_markup / 100), 2) - c.sell_price)
                        / round(c.sell_price * (1 + c.list_markup / 100), 2)) * 100, 2)
       END AS discount_pct,
       c.locked AS price_locked,
       c.effective_min_margin AS min_margin,
       CASE WHEN c.breakdown IS NULL
            THEN c.price_policy
            ELSE c.price_policy || jsonb_build_object('combo', c.breakdown)
       END AS rule
  FROM priced c;
$$;

COMMENT ON FUNCTION fn_price_variant(BIGINT, DATE, BIGINT, BIGINT) IS
    '定价的唯一实现：普通变体走选源第一名，组合变体走配方（Σ 成分单价 × 数量），两者共用同一套加价口径';

-- -------------------------------------------------------------------------------------
-- ③之零 可售数的池子归属：场次级池子不能被每个票种各花一遍
--
-- 009 的 fn_available_qty 有个看不见的坑：
--   池子来自**场次级快照**（supplier_ticket_type_id 为空的那行 = 整个场次的合计）时，
--   可售数是整个场次一份，但算「我们的承诺」时只算了**本票种**的预占。
--   于是每个票种都能把整场次的可用量再花一遍：
--     场次还剩 2 张 → 卖 2 张成人（过）+ 卖 2 张儿童（也过）= 从 2 张的池子里花掉 4 张。
--
-- 组合套餐把这个坑放大了：一个源场次上有两个成分（成人 2 份 + 儿童 1 份），
-- 两个成分查的是同一个池子，各查各的必然超卖。
--
-- 票种级快照没有这个问题：每个源票种一个池子，池子之间互不相干。
-- 所以修法是按**池子是怎么来的**决定承诺算到哪：
--   票种级池子 → 只算本票种的承诺；
--   场次级池子 → 整个场次的承诺都算（池子是共享的）。
--
-- 这一段整体替换 009 的同名函数（签名与返回列一个字没动）。
-- 009 已经应用过了，改它等于内容漂移 —— 与 005/006/007/008/010/011/012 同一个套路。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_available_qty(
    p_supplier_session_id BIGINT,
    p_ticket_type_id      BIGINT DEFAULT NULL
)
RETURNS TABLE (
    known         BOOLEAN,
    available_qty INTEGER,
    committed_qty INTEGER,
    remaining_qty INTEGER,
    sold_qty      INTEGER,
    held_qty      INTEGER,
    source_status TEXT,
    snapshot_at   TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE AS $$
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

    -- 精确优先：票种级库存快照。
    -- 一个源票种只取最新一条；一个规范票种可能对应好几个源票种（映射表），要加总。
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

    -- 兜底：场次级快照（票种为空的那些行 = 整个场次的合计）
    IF NOT v_found THEN
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
    IF NOT v_found THEN
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

    -- 我们在这个源场次上的承诺：已兑现的（consumed）+ 还占着的（active）。
    -- voided / released / expired 都不再占库存 —— 承诺已经撤销了。
    --
    -- 算到哪个范围，看这个池子是怎么来的：
    --   票种级池子（v_ticket_scoped）：每个源票种各有一个池子，互不相干 → 只算本票种的承诺；
    --   场次级池子（整个场次一份）    ：所有票种共用 → 整个场次的承诺都要算。
    --
    -- 少了后一句，就是「每个票种都能把整场次的可用量再花一遍」——
    -- 卖 2 张成人再卖 2 张儿童，池子里明明只有 2 张。
    IF p_ticket_type_id IS NULL OR v_ticket_scoped THEN
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
$$;

COMMENT ON FUNCTION fn_available_qty(BIGINT, BIGINT) IS
    '可售数的唯一实现：源侧可售（票种级快照 → 场次级快照 → 场次级缓存 → 不知道）减去源侧还没算进去的已售与还占着的预占；票种级池子只算本票种的承诺，场次级池子算全场次的承诺';

-- -------------------------------------------------------------------------------------
-- ③之一 放宽配方表的唯一键：一个源 SKU 可以同时顶多个成分
--
-- 012 建表时用的唯一键是 (组合, 源 SKU)，意思是「一个组合里，一个源 SKU 只出现一次」。
-- 但 012 自己的文首就写着：
--   「两个组件数量一样、又被同一个源 SKU 覆盖得住的时候，猜就是瞎猜 ——
--     所以 component_variant_id 显式记『这个源 SKU 顶的是哪个组件』」
-- 这句话的前提就是**同一个源 SKU 可以覆盖多个组件**。
--
-- 现实里最常见的参数化源就是这样：
--   源侧一个 SKU「一日票 · 园区通票」，人群是一个下单参数（成人/儿童/老年）；
--   我们的「家庭套票 = 2 份成人 + 1 份儿童」要表达成配方，就得写两行：
--     (成人成分 ← 同一个源 SKU, 2 份)
--     (儿童成分 ← 同一个源 SKU, 1 份)
-- 老的唯一键直接把这个写法拒了 —— 而这不是一个能绕过的边角情况，
-- 是「异构融合」最常见的一种形状。
--
-- 放宽成 (组合, 成分, 源 SKU) 之后：
--   - 同一个成分配两个不同的源 SKU，仍然被「一个成分只配一个源」的规则挡住
--     （不变量 80：每个声明的组件必须**有且只有一个**对应的成分，数量一致）；
--   - 同一个源 SKU 配多个成分，允许 —— 这正是参数化源的形状；
--   - 同一行重复声明，仍然被唯一键挡住。
--
-- 约束是前向演进的：012 建的旧键被 013 替换掉（约束改名不等于失效，必须显式 DROP）。
-- 「迁移只增不改」说的是**已发布的迁移文件**不许回头改，不是说约束不许演进 ——
-- 约束要改，就写一个新的迁移文件说清楚为什么。
-- -------------------------------------------------------------------------------------
ALTER TABLE supplier_variant_composition
    DROP CONSTRAINT ssvc_uk;

ALTER TABLE supplier_variant_composition
    ADD CONSTRAINT ssvc_uk UNIQUE (product_variant_id, component_variant_id, supplier_variant_id);

COMMENT ON CONSTRAINT ssvc_uk ON supplier_variant_composition IS
    '一个成分在一个组合里只配一个源 SKU（不变量 80 把门）；同一个源 SKU 可以配多个成分（参数化源）';

-- 「一个成分只配一个源 SKU」这句话，靠不变量 80 查出来是事后 ——
-- 写成部分唯一索引，错配根本进不了库（不变量 80 退成第二道门）。
--
-- 只在 active 上生效：退成 retired 的历史配方可以保留（卖过的事实不许被改写），
-- 不影响新配方的唯一性。
CREATE UNIQUE INDEX ux_ssvc_combo_component_active
    ON supplier_variant_composition (product_variant_id, component_variant_id)
    WHERE status = 'active';

COMMENT ON INDEX ux_ssvc_combo_component_active IS
    '在用配方里一个成分只配一个源 SKU（不变量 80 的机制保证版）';

-- -------------------------------------------------------------------------------------
-- ③ 订单明细的成分行
--
-- 一行 = 「这个明细要用哪个源 SKU、顶的是哪个可售单元、要几份、能进几次场、成本多少、落在哪个场次」。
--
-- 为什么要有这张表：
--   组合套餐在订单里是一行，但要向源侧下多份单、发多种券。
--   sales_order_item 只有一个 supplier_product_id / ticket_type_id / quantity，装不下。
--   与其在明细里塞 jsonb 然后各处解析（解析口径会分叉），
--   不如把成分**行化**：谁要哪一份，看表就知道，对账逐行比。
--
-- 普通变体也写一行（明细自己的变体 + 定价选中的源 SKU）：
--   履约路径（预订 / 出券 / 预占）从此只有一套口径 ——
--   「履约的单位是成分行」，不因明细是不是组合而分两套。
-- -------------------------------------------------------------------------------------
CREATE TABLE sales_order_item_source (
    id                   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_item_id        BIGINT      NOT NULL REFERENCES sales_order_item(id) ON DELETE CASCADE,
    -- 这一行顶的是哪个可售单元（组合 = 组件变体；普通明细 = 明细自己的变体）
    component_variant_id BIGINT      NOT NULL REFERENCES product_variant(id),
    supplier_variant_id  BIGINT      NOT NULL REFERENCES supplier_variant(id),
    supplier_product_id  BIGINT      NOT NULL REFERENCES supplier_product(id),
    supplier_id          BIGINT      NOT NULL REFERENCES supplier(id),
    product_session_id   BIGINT      REFERENCES product_session(id),
    supplier_session_id  BIGINT      REFERENCES supplier_session(id),
    ticket_type_id       BIGINT      REFERENCES ticket_type(id),
    -- 向源侧买了几份（按团报价 = 1 团；按人 = 票数；组合 = 成分份数 × 套餐份数）
    quantity             NUMERIC(8,2) NOT NULL CHECK (quantity > 0),
    -- 这些份数能进几次场（按团报价 = 团人数；其余 = 票数）
    admission_quantity   NUMERIC(8,2) NOT NULL CHECK (admission_quantity > 0),
    -- 这一份的成本（已折算到明细币种）：按团报价时是团总价，其余是单价
    unit_cost            NUMERIC(12,2) NOT NULL,
    currency             TEXT        NOT NULL,
    -- 留痕汇率：1 单位源币种 = fx_rate 单位本行币种；fx_as_of 是这次折算依赖的快照日期
    fx_rate              NUMERIC(18,8),
    fx_as_of             DATE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sois_uk UNIQUE (order_item_id, component_variant_id, supplier_variant_id)
);

CREATE INDEX ix_sois_item      ON sales_order_item_source (order_item_id);
CREATE INDEX ix_sois_component ON sales_order_item_source (component_variant_id);
CREATE INDEX ix_sois_supplier  ON sales_order_item_source (supplier_variant_id);

COMMENT ON TABLE sales_order_item_source IS
    '订单明细的成分行：履约的单位（一份成分 = 一条预订 = 该成分应发张数张券 = 一张库存预占单）；普通明细也有一行';

COMMENT ON COLUMN sales_order_item_source.component_variant_id IS
    '这一行顶的是哪个可售单元：组合 = 组件变体；普通明细 = 明细自己的变体';

COMMENT ON COLUMN sales_order_item_source.quantity IS
    '向源侧买了几份：组合 = 成分份数 × 套餐份数；普通明细 = 明细份数；按团报价 = 1 团';

COMMENT ON COLUMN sales_order_item_source.admission_quantity IS
    '这些份数能进几次场（实名、库存、出券、履约都按这个数算）：按团报价 = 团人数，其余 = 票数';

COMMENT ON COLUMN sales_order_item_source.unit_cost IS
    '每一份的成本（已折算到明细币种）：按团报价时是团总价，其余是单价；本行总成本 = unit_cost × quantity';

-- 预订指回它服务的那一份成分（幂等与对账都按这份成分走）
ALTER TABLE booking
    ADD COLUMN order_item_source_id BIGINT REFERENCES sales_order_item_source(id) ON DELETE SET NULL;

CREATE INDEX ix_booking_source ON booking (order_item_source_id) WHERE order_item_source_id IS NOT NULL;

COMMENT ON COLUMN booking.order_item_source_id IS
    '这条预订服务的是哪一份成分：组合的一张明细会有多条预订（每个成分一条）';

-- 持票人挂在成分上（同一个票种的两个成分也要分得清）
ALTER TABLE order_holder
    ADD COLUMN component_variant_id BIGINT REFERENCES product_variant(id);

CREATE INDEX ix_holder_component ON order_holder (component_variant_id) WHERE component_variant_id IS NOT NULL;

COMMENT ON COLUMN order_holder.component_variant_id IS
    '这位持票人属于哪一份成分：组合里同一个票种可能有多个成分（成人园区票 + 成人单园区票）';

-- -------------------------------------------------------------------------------------
-- ④ 下单：组合也是一行明细，但落成分行
--
-- 整体替换 fn_place_order（同签名，CREATE OR REPLACE）。
--
-- 与 009 的差别只在「明细 → 成分行」这一步：
--   普通变体：一条成分行（明细自己的变体 + 定价选中的源 SKU）；
--   组合变体：每个成分一行（配方说了算，份数 = 成分份数 × 套餐份数）。
--
-- 定价选中的源 SKU（普通变体）：
--   走的是 fn_route_candidates 的第一名 —— 与 fn_price_variant 用的是同一个排序函数，
--   同一批参数，所以「定价选中的源」与「要下单的源」是同一个源 SKU。
--   （原来这一步在 fn_create_bookings 里按置信度找源变体，与定价的选法不是同一条规则；
--     013 把它挪到下单时按定价的选法定下来，记在成分行里，预订只读不改。）
--
-- 库存预占、实名、持票人落库都改成按成分行走：
--   组合的每个成分在**自己的**源场次上预占、收自己的实名、发自己的券。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_place_order(
    p_channel_id      BIGINT,
    p_idempotency_key TEXT,
    p_items           JSONB,
    p_customer_id     BIGINT DEFAULT NULL,
    p_contact         JSONB DEFAULT '{}'::jsonb,
    p_buyer_note      TEXT DEFAULT NULL,
    p_holders         JSONB DEFAULT '[]'::jsonb
)
RETURNS TABLE (
    order_id       BIGINT,
    order_no       TEXT,
    order_status   TEXT,
    order_currency TEXT,
    order_subtotal NUMERIC,
    order_total    NUMERIC,
    created        BOOLEAN
)
LANGUAGE plpgsql AS $$
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
            'supplier_product_id',  CASE WHEN v_role = 'combo' THEN NULL ELSE v_price.supplier_product_id END,
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
         GROUP BY 1
         ORDER BY 1
    LOOP
        PERFORM * FROM fn_reserve_qty(
            v_sup_sess,
            NULL,
            v_demand,
            '本单在这个源场次上的总需求（多个成分合起来）');
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

            SELECT * INTO v_avail_row
              FROM fn_reserve_qty(v_sup_sess,
                                  NULLIF(v_src->>'ticket_type_id', '')::bigint,
                                  (v_src->>'admission_quantity')::int,
                                  '变体 ' || COALESCE(v_src->>'component_variant_id', '?')
                                    || ' ' || COALESCE(v_detail->'snapshot'->>'visit_date', '?'));

            v_avail := v_avail || jsonb_build_array(jsonb_build_object(
                'component_variant_id', (v_src->>'component_variant_id')::bigint,
                'supplier_variant_id',  (v_src->>'supplier_variant_id')::bigint,
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
$$;

COMMENT ON FUNCTION fn_place_order(BIGINT, TEXT, JSONB, BIGINT, JSONB, TEXT, JSONB) IS
    '下单的唯一实现：金额取自 fn_price_variant，幂等必填，明细走快照；组合明细按成分落成分行';

-- -------------------------------------------------------------------------------------
-- ⑤ 预订：一份成分一条预订
--
-- 整体替换 fn_create_bookings（同签名）。
--
-- 与 005/009 的差别：预订的单位从「订单明细」变成「成分行」。
-- 普通明细只有一行成分 → 行为与从前一致（一条明细一条预订）。
-- 组合明细有多行成分 → 每个成分一条预订（家庭套餐 = 2 条预订）。
--
-- 幂等键按成分行定（'bk-<订单号>-<成分行 id>'）：
--   重跑一次不会多建一条预订；同一成分也不会建两条。
--
-- 源场次来自成分行（下单时按场次级绑定表解析好的），不按日期猜。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_create_bookings(p_order_id BIGINT)
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
    v_src        RECORD;
    v_booking    RECORD;
    v_booking_id BIGINT;
    v_booking_no TEXT;
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
        SELECT oi.id, oi.product_id, oi.session_id, oi.ticket_type_id, oi.quantity,
               oi.product_variant_id, oi.detail_snapshot
          FROM sales_order_item oi
         WHERE oi.order_id = v_order.id
         ORDER BY oi.id
    LOOP
        FOR v_src IN
            SELECT s.* FROM sales_order_item_source s
             WHERE s.order_item_id = v_item.id
             ORDER BY s.id
        LOOP
            -- 已经建过就返回原来那条（幂等）：幂等键是这份成分。
            SELECT b.id, b.booking_no INTO v_booking
              FROM booking b
             WHERE b.order_item_source_id = v_src.id
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

            IF v_src.supplier_session_id IS NULL THEN
                -- 013 之前下的单没有成分行，源场次当时就存在预订的解析里；
                -- 这里按同一口径（场次级绑定表）再解析一次，取的还是绑定表那条。
                v_src.supplier_session_id := fn_bound_supplier_session(
                    v_src.product_session_id, v_src.supplier_product_id);
            END IF;

            IF v_src.supplier_session_id IS NULL THEN
                RAISE EXCEPTION '订单行 % 的成分 % 的规范场次 % 没有绑定源商品 % 的源场次，无法创建预订（product_session_source 缺一条绑定）',
                  v_item.id, v_src.component_variant_id, v_src.product_session_id, v_src.supplier_product_id;
            END IF;

            v_booking_no := 'BK' || to_char(now(), 'YYYYMMDD')
                         || lpad(nextval('public.seq_booking_no')::text, 6, '0');

            v_date := NULLIF(v_item.detail_snapshot->>'visit_date', '')::date;

            INSERT INTO booking (booking_no, order_id, order_item_id, order_item_source_id,
                                 supplier_id, supplier_product_id, supplier_session_id,
                                 supplier_variant_id, status, idempotency_key, request_payload)
            VALUES (v_booking_no, v_order.id, v_item.id, v_src.id,
                    v_src.supplier_id, v_src.supplier_product_id, v_src.supplier_session_id,
                    v_src.supplier_variant_id, 'pending',
                    'bk-' || v_order.order_no || '-' || v_src.id::text,
                    jsonb_build_object('order_no', v_order.order_no,
                                       'order_item_id', v_item.id,
                                       'product_id', v_item.product_id,
                                       'component_variant_id', v_src.component_variant_id,
                                       'quantity', v_src.quantity,
                                       'admission_quantity', v_src.admission_quantity,
                                       'visit_date', v_date,
                                       'product_session_id', v_src.product_session_id,
                                       'supplier_session_id', v_src.supplier_session_id,
                                       'supplier_variant_id', v_src.supplier_variant_id,
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

        -- 老明细（013 之前下的单）没有成分行：沿用原来的「一条明细一条预订」口径。
        IF NOT EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = v_item.id) THEN
            SELECT b.id, b.booking_no INTO v_booking
              FROM booking b
             WHERE b.order_id = v_order.id
               AND b.order_item_id = v_item.id
             ORDER BY b.id
             LIMIT 1;

            IF FOUND THEN
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

            RAISE EXCEPTION '订单行 % 没有采纳源，无法创建预订（下单时必须选中源）', v_item.id;
        END IF;
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

COMMENT ON FUNCTION fn_create_bookings(BIGINT) IS
    '预订的唯一实现：一份成分一条预订（组合 = 2 条），幂等键按成分行定，源场次来自成分行';

-- -------------------------------------------------------------------------------------
-- ⑥ 出券：一份成分发该成分应发张数张券
--
-- 整体替换 fn_issue_voucher（同签名，010 已替换过一次，这里是第二次）。
--
-- 与 010 的差别：应发张数不再取订单明细的份数，而是取**成分行**的入场份数。
--   普通明细：成分行份数 = 明细份数 → 与从前一致。
--   组合明细：成人成分 2 份 → 2 张券；儿童成分 1 份 → 1 张券。
--
-- 券带的是**成分的**可售单元与票种（不是明细的）：
--   家庭套餐的儿童票，券上写的是儿童票 —— 核销时按儿童票的规则判（有效期、权益）。
--   但券仍挂在组合那一行明细上（order_item_id），退款与订单状态按整单管。
--
-- 票码与持票人一一对应的规矩不变：收到几个码就发几张，对不上当场报错。
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
    v_src        RECORD;
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
    -- 应发份数（013）：这份成分能进几次场
    v_required   NUMERIC;
BEGIN
    SELECT b.id, b.booking_no, b.order_id, b.order_item_id, b.status, b.supplier_variant_id,
           b.order_item_source_id
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

    -- 这份预订服务的是哪一份成分（013）。老预订没有成分行时退回明细本身。
    SELECT s.* INTO v_src
      FROM sales_order_item_source s
     WHERE s.id = v_booking.order_item_source_id;

    IF NOT FOUND THEN
        SELECT oi.quantity::numeric AS quantity,
               oi.quantity::numeric AS admission_quantity,
               oi.product_variant_id   AS component_variant_id,
               oi.ticket_type_id       AS ticket_type_id,
               oi.session_id           AS product_session_id,
               oi.supplier_id          AS supplier_id
          INTO v_src
          FROM sales_order_item oi
         WHERE oi.id = v_booking.order_item_id;
    END IF;

    -- 应发张数：按团一券，按人一人一份（组合：成分要几份就发几张）。
    v_expected := CASE WHEN v_item.pricing_basis = 'per_group'
                       THEN 1 ELSE v_src.admission_quantity::int END;

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
     WHERE ps.id = v_src.product_session_id;

    -- 有效期天数：这个可售单元有效几天。
    --
    -- 为什么不是「1」：单日票有效 1 天，两日票有效 2 天 —— 这是产品的本质区别，
    -- 不是展示细节。写成 +1 的话，两日票会被发成只管一天的券，
    -- 客户第二天进不了场（钱收了、票买了、门不认）。
    --
    -- 天数从「轴选项」上读（valid_days），不写死成 1，也不从源报文猜 ——
    -- 口径只有一处，源侧能不能兑现由 fn_variant_covered 在选源时把关。
    -- 组合：按**成分**的可售单元读（家庭套餐里的两日票成分，券就是两天的）。
    v_days := fn_variant_validity_days(v_src.component_variant_id);

    FOR v_i IN v_have + 1 .. v_expected
    LOOP
        -- 持票人快照：按序号取那一位持票人的字段（组合：按成分票种分组取）
        SELECT COALESCE(jsonb_object_agg(h.field_code, h.value), '{}'::jsonb)
          INTO v_holders
          FROM order_holder h
         WHERE h.order_item_id = v_item.id
           AND h.ticket_type_id IS NOT DISTINCT FROM v_src.ticket_type_id
           AND h.sequence = v_i;

        v_holders := v_holders || jsonb_build_object('sequence', v_i);

        v_voucher_no := 'VC' || to_char(now(), 'YYYYMMDD')
                     || lpad(nextval('public.seq_voucher_no')::text, 6, '0');

        v_code := COALESCE(p_codes[v_i - v_have], v_voucher_no);

        INSERT INTO voucher (voucher_no, order_id, order_item_id, booking_id, product_id, supplier_id,
                             ticket_type_id, session_id, product_variant_id, supplier_variant_id,
                             code, qr_payload, status, holder_snapshot, raw_payload)
        VALUES (v_voucher_no, v_booking.order_id, v_item.id, v_booking.id, v_item.product_id,
                v_src.supplier_id, v_src.ticket_type_id, v_src.product_session_id,
                v_src.component_variant_id, v_booking.supplier_variant_id,
                v_code, v_code, 'pending', v_holders, p_raw_payload)
        RETURNING id INTO v_existing;

        -- 权益：按团一券含全部份数，按人一人一份
        INSERT INTO voucher_entitlement (voucher_id, entitlement_type, quantity, meta)
        VALUES (v_existing.id, 'admission',
                CASE WHEN v_item.pricing_basis = 'per_group' THEN v_src.admission_quantity ELSE 1 END,
                jsonb_build_object('order_item_id', v_item.id,
                                   'booking_id', v_booking.id,
                                   'quantity', v_item.quantity,
                                   'admission_quantity', v_src.admission_quantity,
                                   'pricing_basis', v_item.pricing_basis,
                                   'component_variant_id', v_src.component_variant_id));

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
                AND v.status IN ('issued', 'used')
                AND ve.entitlement_type = 'admission'), 0) >= v_required;

    -- 订单履约状态交给唯一实现推导
    PERFORM fn_apply_order_fulfillment(v_booking.order_id);
END;
$$;

COMMENT ON FUNCTION fn_issue_voucher(BIGINT, TEXT[], JSONB) IS
    '出券的唯一实现：应发张数取成分行的入场份数（组合：成人成分 2 张、儿童成分 1 张），票码与持票人一一对应';

-- -------------------------------------------------------------------------------------
-- ⑦ 订单履约状态：按成分入场份数算「应发多少」
--
-- 整体替换 fn_apply_order_fulfillment（同签名，005 定义）。
--
-- 与 005 的差别：明细的「应发份数」从订单明细的 quantity 改成**成分入场份数之和**。
--   普通明细：成分行份数 = 明细份数 → 与从前一致。
--   组合明细：明细份数是「套餐份数」，真实应发的是 2 张成人券 + 1 张儿童券 = 3。
--   用明细份数算，组合发了一半也会被判成「已履约」—— 那是最坏的一种假绿。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_apply_order_fulfillment(p_order_id BIGINT)
RETURNS TABLE (
    order_id           BIGINT,
    order_status       TEXT,
    fulfillment_status TEXT,
    delivered_qty      INT,
    requested_qty      INT
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
               -- 应发份数：成分入场份数之和（普通明细 = 明细份数；组合 = 各成分份数之和）
               COALESCE((SELECT sum(s.admission_quantity) FROM sales_order_item_source s
                          WHERE s.order_item_id = oi.id), oi.quantity) AS required,
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
$$;

COMMENT ON FUNCTION fn_apply_order_fulfillment(BIGINT) IS
    '订单履约状态的唯一实现：应发份数按成分入场份数之和算（组合发一半不算已履约）';

-- -------------------------------------------------------------------------------------
-- ⑧ 视图：成分对账 + 定价缺口诊断
-- -------------------------------------------------------------------------------------
CREATE VIEW v_order_item_source AS
SELECT oi.id                AS order_item_id,
       o.order_no,
       o.status             AS order_status,
       oi.product_id,
       oi.product_variant_id,
       pv.variant_key,
       pv.variant_role,
       s.component_variant_id,
       cv.variant_key      AS component_variant_key,
       s.supplier_variant_id,
       sv.external_variant_id,
       s.supplier_product_id,
       sup.code            AS supplier_code,
       s.quantity,
       s.admission_quantity,
       s.unit_cost,
       s.currency,
       s.fx_rate,
       s.fx_as_of,
       s.product_session_id,
       s.supplier_session_id,
       b.id                AS booking_id,
       b.booking_no,
       b.status            AS booking_status,
       (SELECT count(*) FROM voucher v
         WHERE v.booking_id = b.id AND v.status IN ('issued', 'used')) AS issued_vouchers
  FROM sales_order_item_source s
  JOIN sales_order_item oi ON oi.id = s.order_item_id
  JOIN sales_order o       ON o.id = oi.order_id
  JOIN product_variant pv  ON pv.id = oi.product_variant_id
  JOIN product_variant cv  ON cv.id = s.component_variant_id
  JOIN supplier_variant sv ON sv.id = s.supplier_variant_id
  JOIN supplier_product sp ON sp.id = s.supplier_product_id
  JOIN supplier sup        ON sup.id = s.supplier_id
  LEFT JOIN booking b      ON b.order_item_source_id = s.id;

COMMENT ON VIEW v_order_item_source IS
    '订单成分对账：每一份成分用哪个源 SKU、要几份、订了没有、发了几张券（组合逐行可查）';

CREATE VIEW v_combo_price_gap AS
SELECT pv.id                AS combo_variant_id,
       pv.variant_key      AS combo_variant_key,
       pv.product_id,
       cl.id               AS channel_listing_id,
       cl.channel_id,
       pc.date,
       '成分当天没有报价'::text AS gap,
       cv.variant_key      AS component_variant_key,
       c.quantity
  FROM product_variant pv
  JOIN product_variant_relation r
    ON r.parent_variant_id = pv.id AND r.relation_type = 'included'
  JOIN product_variant cv ON cv.id = r.child_variant_id
  JOIN supplier_variant_composition c
    ON c.product_variant_id = pv.id
   AND c.component_variant_id = cv.id
   AND c.status = 'active'
  JOIN channel_listing cl ON cl.product_id = pv.id AND cl.status = 'online'
  JOIN price_calendar pc  ON pc.product_variant_id = cv.id AND pc.status = 'active'
 WHERE NOT EXISTS (
         SELECT 1 FROM supplier_price_calendar spc
          WHERE spc.supplier_variant_id = c.supplier_variant_id
            AND spc.product_variant_id  = c.component_variant_id
            AND spc.date = pc.date
            AND spc.status = 'available')
UNION ALL
SELECT pv.id, pv.variant_key, pv.product_id, cl.id, cl.channel_id, pc.date,
       '成分成本折算不到目标币种',
       cv.variant_key, c.quantity
  FROM product_variant pv
  JOIN product_variant_relation r
    ON r.parent_variant_id = pv.id AND r.relation_type = 'included'
  JOIN product_variant cv ON cv.id = r.child_variant_id
  JOIN supplier_variant_composition c
    ON c.product_variant_id = pv.id
   AND c.component_variant_id = cv.id
   AND c.status = 'active'
  JOIN channel_listing cl ON cl.product_id = pv.id AND cl.status = 'online'
  JOIN price_calendar pc  ON pc.product_variant_id = cv.id AND pc.status = 'active'
  JOIN supplier_price_calendar spc
    ON spc.supplier_variant_id = c.supplier_variant_id
   AND spc.product_variant_id  = c.component_variant_id
   AND spc.date = pc.date
   AND spc.status = 'available'
 WHERE fn_fx_pair_rate(spc.currency, fn_price_row_currency(cl.channel_id), pc.date) IS NULL;

COMMENT ON VIEW v_combo_price_gap IS
    '组合定价缺口诊断：哪个成分当天没报价 / 折算不出来（运营排查「为什么套餐卖不了」）';

-- -------------------------------------------------------------------------------------
-- ⑨ 不变量 82-86
--
-- 82 订单明细的成分变体必须属于该明细的商品（串商品 = 履约串了）
-- 83 订单明细的成分成本合计必须等于明细的采纳成本
-- 84 订单明细的入场份数之和必须等于配方声明的份数（组合）或明细份数（普通）
-- 85 订单明细的成分必须来自同一个源，且与明细的供应商一致
-- 86 已出票的订单明细必须按成分把份数发够了（发一半不算出票）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_combo AS
WITH raw (seq, check_name, actual) AS (
    -- 82：成分变体必须属于明细的商品
    SELECT 82, '订单明细的成分变体必须属于该明细的商品',
           (SELECT count(*)
              FROM sales_order_item_source s
              JOIN sales_order_item oi ON oi.id = s.order_item_id
              JOIN product_variant cv ON cv.id = s.component_variant_id
             WHERE cv.product_id <> oi.product_id)
    UNION ALL
    -- 83：成分成本合计 = 明细的采纳成本
    --     按人：明细成本 × 明细份数；按团：团总价（成分按「1 团」记）
    SELECT 83, '订单明细的成分成本合计必须等于明细的采纳成本',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND round(COALESCE((SELECT sum(s.unit_cost * s.quantity)
                                    FROM sales_order_item_source s
                                   WHERE s.order_item_id = oi.id), 0), 2)
                   IS DISTINCT FROM
                   round(COALESCE(NULLIF(oi.detail_snapshot->>'cost_price', '')::numeric, 0)
                         * (CASE WHEN oi.pricing_basis = 'per_group' THEN 1 ELSE oi.quantity END), 2))
    UNION ALL
    -- 84：入场份数之和 = 配方声明的份数之和 × 套餐份数（组合）/ 明细份数（普通）
    SELECT 84, '订单明细的成分入场份数必须与配方声明对得上',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN product_variant pv ON pv.id = oi.product_variant_id
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND COALESCE((SELECT sum(s.admission_quantity)
                               FROM sales_order_item_source s
                              WHERE s.order_item_id = oi.id), 0)
                   IS DISTINCT FROM
                   CASE WHEN pv.variant_role = 'combo'
                        THEN (SELECT COALESCE(sum(r.quantity), 0)
                                FROM product_variant_relation r
                               WHERE r.parent_variant_id = oi.product_variant_id
                                 AND r.relation_type = 'included') * oi.quantity
                        ELSE oi.quantity::numeric
                   END)
    UNION ALL
    -- 85：成分必须来自同一个源，且与明细的供应商一致
    SELECT 85, '订单明细的成分必须来自同一个源且与明细的供应商一致',
           (SELECT count(*)
              FROM (SELECT s.order_item_id
                      FROM sales_order_item_source s
                     GROUP BY s.order_item_id
                    HAVING count(DISTINCT s.supplier_id) > 1) x)
           + (SELECT count(*)
                FROM sales_order_item oi
                JOIN sales_order_item_source s ON s.order_item_id = oi.id
               WHERE oi.supplier_id IS DISTINCT FROM s.supplier_id)
    UNION ALL
    -- 86：出票的明细必须按成分把份数发够了
    SELECT 86, '已出票的订单明细必须按成分把份数发够了',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE oi.status = 'ticketed'
               AND COALESCE((SELECT sum(ve.quantity)
                               FROM voucher_entitlement ve
                               JOIN voucher v ON v.id = ve.voucher_id
                              WHERE v.order_item_id = oi.id
                                AND v.status IN ('issued', 'used')
                                AND ve.entitlement_type = 'admission'), 0)
                   < COALESCE((SELECT sum(s.admission_quantity)
                                 FROM sales_order_item_source s
                                WHERE s.order_item_id = oi.id), oi.quantity))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_combo IS
    '组合交易侧不变量（82-86）：成分不串商品、成本对得上、份数与配方对得上、同源、出票发够了';

-- -------------------------------------------------------------------------------------
-- ⑩ 不变量 25 / 58 / 60 / 69 / 72 / 75 的口径修订：组合打破了「一行 = 一种票」
--
-- 这六条不变量写于「一行明细 = 一种票、一份明细 = 一张票的人数」那个时代。
-- 组合套餐打破了这个假设：一条明细里有 2 份成人票 + 1 份儿童票，
-- 明细份数是「套餐份数」（1），而实名要收 3 份、履约要发 3 张券、库存要占 3 份。
--
-- 口径改成「按成分算」：
--   25 持票人数  = 该成分的入场份数（不是明细份数）
--   58 预订的源  = 该成分行的源（组合没有单一采纳源）
--   60 应发份数  = 各成分入场份数之和（发一半不算已履约）
--   69 库存预占  = 每个成分一条预占（组合要占两份库存）
--   72 可售数    = 每个成分各比各的（不能用明细份数去比成分的可售数）
--   75 采纳源    = 预订的源要覆盖它服务的那份成分（组合没有单一映射）
--
-- 与 012 同一个套路：不把整份不变量抄一遍改一条（抄一遍就分叉，
-- 分叉的门禁等于没有门禁），而是「改名 + 重建」：
--   旧视图改名保留 → 新视图 = 旧的（去掉被修订的那条）+ 修订后的那一条。
-- -------------------------------------------------------------------------------------

-- ---- ⑩之一 不变量 25（实名份数按成分算）-------------------------------------------
ALTER VIEW v_invariant_checks_core RENAME TO v_invariant_checks_variant;

COMMENT ON VIEW v_invariant_checks_variant IS
    '变体侧 45 条业务不变量自检（012 修订了第 29 条：组合变体豁免）';

CREATE VIEW v_invariant_checks_core AS
WITH amended (seq, check_name, expected, actual) AS (
    SELECT 25,
           '要求实名的票种持票人数必须与票数一致（组合按成分算）',
           0,
           (SELECT count(*)
              FROM (
                -- 有成分行的明细：按成分算（每个成分要收它自己那份实名）
                SELECT s.order_item_id AS item_id,
                       s.ticket_type_id,
                       s.admission_quantity AS required,
                       oi.product_id,
                       o.channel_id,
                       s.component_variant_id
                  FROM sales_order_item_source s
                  JOIN sales_order_item oi ON oi.id = s.order_item_id
                  JOIN sales_order o        ON o.id = oi.order_id
                UNION ALL
                -- 没有成分行的明细（历史数据）：按明细份数算
                SELECT oi.id,
                       oi.ticket_type_id,
                       oi.quantity::numeric,
                       oi.product_id,
                       o.channel_id,
                       NULL::bigint
                  FROM sales_order_item oi
                  JOIN sales_order o ON o.id = oi.order_id
                 WHERE NOT EXISTS (SELECT 1 FROM sales_order_item_source s
                                    WHERE s.order_item_id = oi.id)
              ) x
             WHERE EXISTS (SELECT 1 FROM checkout_requirement cr
                            WHERE cr.product_id = x.product_id
                              AND cr.field_code = 'holder_name'
                              AND cr.required
                              AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = x.ticket_type_id)
                              AND (cr.channel_id IS NULL OR cr.channel_id = x.channel_id))
               AND (SELECT count(DISTINCT oh.sequence)
                      FROM order_holder oh
                     WHERE oh.order_item_id = x.item_id
                       AND oh.field_code = 'holder_name'
                       AND (x.component_variant_id IS NULL
                            OR oh.component_variant_id = x.component_variant_id))
                   <> x.required)
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM v_invariant_checks_variant
 WHERE seq <> 25
UNION ALL
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM amended;

COMMENT ON VIEW v_invariant_checks_core IS
    '供给/定价/展示侧 45 条业务不变量自检（第 29 条按 012 修订：组合变体豁免；第 25 条按 013 修订：组合按成分算持票人数）';

-- ---- ⑩之二 不变量 58 / 60（预订的源、履约份数按成分算）---------------------------
ALTER VIEW v_invariant_checks_fulfill RENAME TO v_invariant_checks_fulfill_base;

COMMENT ON VIEW v_invariant_checks_fulfill_base IS
    '履约侧不变量自检（013 修订了第 58 / 60 条：组合按成分行算）';

CREATE VIEW v_invariant_checks_fulfill AS
WITH item_state AS (
    -- 每条明细的「应发 / 已发」：应发按成分入场份数之和（组合 2+1，普通 = 明细份数）
    SELECT oi.order_id,
           oi.id AS item_id,
           COALESCE((SELECT sum(s.admission_quantity)
                       FROM sales_order_item_source s
                      WHERE s.order_item_id = oi.id), oi.quantity) AS quantity,
           COALESCE((SELECT sum(ve.quantity)
                       FROM voucher_entitlement ve
                       JOIN voucher v ON v.id = ve.voucher_id
                      WHERE v.order_item_id = oi.id
                        AND v.status IN ('issued', 'used')
                        AND ve.entitlement_type = 'admission'), 0) AS delivered
      FROM sales_order_item oi
),
raw (seq, check_name, expected, actual) AS (
    SELECT b.seq, b.check_name, b.expected, b.actual
      FROM v_invariant_checks_fulfill_base b
     WHERE b.seq NOT IN (58, 60)
    UNION ALL
    -- 58：预订的源 = 它服务的那一份成分的源（组合没有单一采纳源）
    SELECT 58,
           '预订的源必须等于订单明细的采纳源（组合按成分行）',
           0,
           (SELECT count(*)
              FROM booking b
              JOIN sales_order_item oi ON oi.id = b.order_item_id
             WHERE (b.order_item_source_id IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM sales_order_item_source s
                                     WHERE s.id = b.order_item_source_id
                                       AND s.order_item_id = oi.id
                                       AND s.supplier_id = b.supplier_id
                                       AND s.supplier_product_id = b.supplier_product_id))
                OR (b.order_item_source_id IS NULL
                    AND NOT EXISTS (SELECT 1 FROM sales_order_item_source s
                                     WHERE s.order_item_id = oi.id)
                    AND (b.supplier_id IS DISTINCT FROM oi.supplier_id
                         OR b.supplier_product_id IS DISTINCT FROM oi.supplier_product_id)))
    UNION ALL
    -- 60：订单的履约状态必须与明细的出票情况一致（应发份数按成分算）
    SELECT 60,
           '订单的履约状态必须与明细的出票情况一致',
           0,
           (SELECT count(*)
              FROM sales_order o
             WHERE o.status = 'fulfilled'
               AND EXISTS (SELECT 1 FROM item_state s
                            WHERE s.order_id = o.id AND s.delivered < s.quantity)
                OR o.status = 'partially_fulfilled'
               AND COALESCE((SELECT sum(s.delivered) FROM item_state s
                              WHERE s.order_id = o.id), 0::numeric) = 0::numeric
                OR o.status IN ('booking_pending', 'confirmed', 'partially_fulfilled')
               AND EXISTS (SELECT 1 FROM item_state s WHERE s.order_id = o.id)
               AND NOT EXISTS (SELECT 1 FROM item_state s
                                WHERE s.order_id = o.id AND s.delivered < s.quantity))
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_fulfill IS
    '履约侧不变量自检（第 58 / 60 条按 013 修订：组合按成分行算源与份数）';

-- ---- ⑩之三 不变量 69 / 72（库存预占与可售数按成分算）-------------------------------
ALTER VIEW v_invariant_checks_inventory RENAME TO v_invariant_checks_inventory_base;

COMMENT ON VIEW v_invariant_checks_inventory_base IS
    '库存侧不变量自检（013 修订了第 69 / 72 条：组合按成分行算）';

CREATE VIEW v_invariant_checks_inventory AS
WITH raw (seq, check_name, expected, actual) AS (
    SELECT b.seq, b.check_name, b.expected, b.actual
      FROM v_invariant_checks_inventory_base b
     WHERE b.seq NOT IN (69, 72)
    UNION ALL
    -- 69：每条明细都要有预占；有成分行的明细按成分各占一份
    --
    -- 预占的**状态**不参与判定：退款后预占变成 voided（卖过又收回来，兑现量仍然是原数，
    -- 事实不许改写），但「这一单占过多少库存」这件事必须还查得到。
    -- 把状态也卡成 consumed 的话，退过款的订单就查不到自己的预占了 ——
    -- 那是「事实不许被改写」这条规矩的另一半：作废不是消失。
    SELECT 69,
           '每条订单明细都必须有对应的库存预占（组合按成分）',
           0,
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND NOT EXISTS (
                     SELECT 1 FROM sales_order_item_source s
                      WHERE s.order_item_id = oi.id
                        AND EXISTS (SELECT 1 FROM inventory_hold h
                                     WHERE h.order_id = oi.order_id
                                       AND h.product_session_id IS NOT DISTINCT FROM s.product_session_id
                                       AND h.ticket_type_id IS NOT DISTINCT FROM s.ticket_type_id
                                       AND h.supplier_id IS NOT DISTINCT FROM s.supplier_id
                                       AND h.supplier_session_id IS NOT DISTINCT FROM s.supplier_session_id
                                       AND h.quantity = s.admission_quantity)))
           + (SELECT count(*)
                FROM sales_order_item oi
               WHERE NOT EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
                 AND NOT EXISTS (SELECT 1 FROM inventory_hold h
                                  WHERE h.order_id = oi.order_id
                                    AND h.product_session_id IS NOT DISTINCT FROM oi.session_id
                                    AND h.ticket_type_id IS NOT DISTINCT FROM oi.ticket_type_id
                                    AND h.supplier_id IS NOT DISTINCT FROM oi.supplier_id
                                    AND h.quantity = oi.quantity))
    UNION ALL
    -- 72：卖出的量不得超过落单时看到的源侧可售数（组合逐成分比）
    SELECT 72,
           '订单卖出的量不得超过落单时看到的源侧可售数（组合逐成分）',
           0,
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN sales_order_item_source s ON s.order_item_id = oi.id
              LEFT JOIN LATERAL (
                    SELECT e AS ent
                      FROM jsonb_array_elements(
                              COALESCE(oi.detail_snapshot->'availability'->'sources', '[]'::jsonb)) AS e
                     WHERE (e->>'component_variant_id')::bigint = s.component_variant_id
                       AND (e->>'supplier_variant_id')::bigint = s.supplier_variant_id
                     ORDER BY (e->>'remaining_qty')::int NULLS FIRST
                     LIMIT 1
              ) a ON true
             WHERE COALESCE((a.ent->>'known')::boolean, false) IS TRUE
               AND COALESCE((a.ent->>'remaining_qty')::int, 0) < s.admission_quantity)
           + (SELECT count(*)
                FROM sales_order_item oi
               WHERE NOT EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
                 AND COALESCE(((oi.detail_snapshot->'availability')->>'known')::boolean, false) IS TRUE
                 AND COALESCE(((oi.detail_snapshot->'availability')->>'remaining_qty')::integer, 0) < oi.quantity)
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_inventory IS
    '库存侧不变量自检（第 69 / 72 条按 013 修订：组合按成分行算预占与可售数）';

-- ---- ⑩之四 不变量 75（采纳源要覆盖它服务的那份成分）-------------------------------
ALTER VIEW v_invariant_checks_validity RENAME TO v_invariant_checks_validity_base;

COMMENT ON VIEW v_invariant_checks_validity_base IS
    '有效期与覆盖侧不变量自检（013 修订了第 75 条：组合按成分行判覆盖）';

CREATE VIEW v_invariant_checks_validity AS
WITH raw (seq, check_name, expected, actual) AS (
    SELECT b.seq, b.check_name, b.expected, b.actual
      FROM v_invariant_checks_validity_base b
     WHERE b.seq <> 75
    UNION ALL
    -- 75：卖出去的订单必须是用能装配出该可售单元的源出的
    --     组合没有单一映射：预订的源要覆盖它服务的那一份成分。
    SELECT 75,
           '卖出去的订单必须是用能装配出该可售单元的源出的（组合按成分）',
           0,
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN booking b ON b.order_item_id = oi.id
             WHERE b.supplier_variant_id IS NOT NULL
               AND NOT (
                 EXISTS (SELECT 1 FROM supplier_variant_mapping svm
                          WHERE svm.supplier_variant_id = b.supplier_variant_id
                            AND svm.product_variant_id = oi.product_variant_id
                            AND svm.status = 'active'
                            AND fn_variant_covered(svm.coverage, oi.product_variant_id))
                 OR EXISTS (SELECT 1 FROM sales_order_item_source s
                             JOIN supplier_variant_mapping svm
                               ON svm.supplier_variant_id = b.supplier_variant_id
                              AND svm.product_variant_id = s.component_variant_id
                              AND svm.status = 'active'
                            WHERE s.id = b.order_item_source_id
                              AND s.order_item_id = oi.id
                              AND fn_variant_covered(svm.coverage, s.component_variant_id))
               ))
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_validity IS
    '有效期与覆盖侧不变量自检（第 75 条按 013 修订：组合按成分行判覆盖）';

-- -------------------------------------------------------------------------------------
-- ⑪ 总视图：并集
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
    SELECT * FROM v_invariant_checks_validity
    UNION ALL
    SELECT * FROM v_invariant_checks_readmodel
    UNION ALL
    SELECT * FROM v_invariant_checks_composition
    UNION ALL
    SELECT * FROM v_invariant_checks_combo;

COMMENT ON VIEW v_invariant_checks IS '全部 86 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';

-- -------------------------------------------------------------------------------------
-- ⑫ 012 的两处注释更新（注释不是结构，改它不违反「已应用迁移不许改」）
--   012 的文首写的是「定价与预订还没接组合」—— 本段接上了，
--   但「组合的供给只走配方、不许直接挂源映射」这条不变。
-- -------------------------------------------------------------------------------------
COMMENT ON FUNCTION fn_guard_combo_mapping() IS
    '守卫：组合变体的供给只走配方（supplier_variant_composition），不许直接挂源映射 —— 否则会按一个源 SKU 给整张套餐定价（013 起组合已能卖，这条守卫照旧生效）';

COMMENT ON FUNCTION fn_guard_included_relation() IS
    '守卫：组合声明（included）只许挂在 combo 变体上 —— 挂在基础变体上会悄悄改掉它的覆盖要求';
