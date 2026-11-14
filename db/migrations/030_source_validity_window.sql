-- =====================================================================================
-- 030 —— 源侧兑现窗口：源变体上的 valid_days 与「短于承诺不许赢下选源」
--
-- 合同：spec/15-validity.md §5.10 第五口径、§4.13 不变量 122
-- 领域：docs/ddd.md（源层 → 规范层的差异表达）
-- 物理：docs/schema-design.md
--
-- 【为什么有这一条】
--
-- 规范侧的 valid_days（product_axis_option.valid_days）是**我们承诺给客户的天数**；
-- 源侧的天数是**源侧肯兑现的天数**。这是两件事。
--
-- 修复前的断链：GlobalTix 报文里带 validityDays（见 docs/connector-contract.md §6.2
-- 「价格有效期：validityDays 决定」），但：
--   - 归一化规则里没有承载它的通道（configs/mapping_rules.json 没有这条规则），
--     源侧的值从来没进过系统；
--   - 演练器的规范层写手（scripts/mapping_dryrun.py）写 product_axis_option 时
--     没写 valid_days 列 —— 于是所有选项都是 NULL，
--     fn_variant_validity_days 的 COALESCE(MAX(...), 1) 把**每一个**变体都算成 1 天，
--     包括规范侧明明写着「双日票」的那个。两日票在演练路径上被静悄悄缩成一天。
--
-- 而选源时没有任何一条判据看源侧兑现窗口：一个只管一天的源 SKU 照样能赢下
-- route_rank=1，然后按两日票的价卖出去 —— 客户第二天拿着只管一天的券到门口，
-- 闸机判 expired。钱收了、票买了、门不认。
--
-- 【这一条怎么做】
--
-- 源侧的兑现窗口住在源变体上（supplier_variant.valid_days）：
--   NULL = 源侧没报 = 源侧没给约束 = 不拦（与硬约束 34「读不到 = 源侧没给约束 = 不拦」
--   同一条口径）。不许拿别的源的数字顶上，也不许猜。
--
-- 选源时多一条判据（fn_route_candidates）：源侧报了天数且短于规范侧承诺时，
-- 这个源不进候选。方向是收紧 —— 源侧报 1 天、规范侧承诺 2 天时，
-- 不许把这个源提升成两日票的供货。
--
-- 这与套装形态的既有做法同源：supplier_variant_bundle.valid_days 盖不住成分窗口时，
-- 套装判不可售（fn_bundle_components.covers_components + 缺口理由
-- 「源侧整套有效期盖不住成分窗口」）。单张形态现在补上这条 ——
-- 套装能表达源侧更窄的权益，单张形态不能，这就是可证明的不对称。
--
-- 【口径冲突怎么办】
--
-- 源侧同时给了一句营销标签（GlobalTix 的 passType）与一个兑现窗口（validityDays）时，
-- **以兑现窗口为准**：docs/connector-contract.md §6.2 已经声明
-- 「价格有效期：validityDays 决定」。标签可以写「两日票」而实际只管一天；
-- 拿标签当承诺，闸机会判过期。
--
-- 【已卖出的单子怎么办】
--
-- 卖了之后这条不许变（与不变量 75 同一条口径）：真发现源侧兑现窗口短于承诺，
-- 走退款，不是把历史订单改成「当时就不该卖」。不变量 122 复查这件事。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 源侧兑现窗口：加列
-- -------------------------------------------------------------------------------------
-- 只增不改（硬约束 3）：基线 001 已应用，改它等于内容漂移，所以新增列走这里。
--
-- 为什么是 INTEGER 而不是 NUMERIC：有效天数是整数天（源侧报 1 天 / 2 天），
-- 规范侧的 product_axis_option.valid_days 也是 INTEGER —— 两边同型，
-- 比较时不需要跨类型转换（跨类型转换是最容易藏舍入误差的地方）。
ALTER TABLE supplier_variant
    ADD COLUMN valid_days INTEGER;

-- 大于 0：0 天与负天数不是「没报」，是源侧报了错的东西 —— 那种数据不许进库，
-- 它会让「短于承诺」的判据算出一个假答案。
ALTER TABLE supplier_variant
    ADD CONSTRAINT supplier_variant_valid_days_ck CHECK (valid_days IS NULL OR valid_days > 0);

COMMENT ON COLUMN supplier_variant.valid_days IS
    '源侧兑现的有效期天数（连续几天）：NULL = 源侧没报 = 没给约束 = 不拦；'
    '规范侧的承诺在 product_axis_option.valid_days，唯一读法 fn_variant_validity_days';

-- -------------------------------------------------------------------------------------
-- ② 选源：源侧兑现窗口短于规范侧承诺的源，不许赢下选源
-- -------------------------------------------------------------------------------------
-- 整体替换 fn_route_candidates（001 定义，改它等于内容漂移 —— 见文首）。
--
-- 改动只有一处：在 cand 的 WHERE 里加一条判据。排序键不动 ——
-- 选源与定价同源（硬约束 15）指的是同一份候选集与同一份排序，
-- 不是「排序键也要一样」。这里改的是**候选集**（谁有资格进候选），
-- 排序键（cost_base, priority, fallback_order）一个字没动，
-- 所以路由视图与定价函数拿到的仍是同一份候选集。
--
-- 判据的三个方向：
--   - 源侧没报（NULL）      → 不拦（源侧没给约束）
--   - 源侧报的 ≥ 规范侧承诺 → 进候选（源侧兑现得起）
--   - 源侧报的 < 规范侧承诺 → 不进候选（赢了就是按 A 源的价格卖、按 B 源的天数出票）
--
-- 注意 fn_variant_validity_days 对「没有 valid_days 的变体」返回 1（按一天算），
-- 所以一个规范侧没承诺有效期的变体，源侧报 1 天是「盖得住」，报 2 天也是「盖得住」，
-- 只有报 0 天会被 CHECK 挡在库外。这个方向是对的：
-- 规范侧没承诺 = 我们没承诺更长的，源侧报长一点不构成「盖不住」。
CREATE OR REPLACE FUNCTION fn_route_candidates(
    p_variant_id      BIGINT,
    p_date            DATE,
    p_channel_id      BIGINT,
    p_target_currency TEXT
)
RETURNS TABLE (
    supplier_product_id BIGINT,
    supplier_variant_id BIGINT,
    source_currency     TEXT,
    net_price           NUMERIC,
    supplier_price      NUMERIC,
    is_price_locked     BOOLEAN,
    source_min_margin   NUMERIC,
    cost_base           NUMERIC,
    fx_rate_to_target   NUMERIC,
    fx_as_of            DATE,
    priority            INT,
    fallback_order      INT,
    route_rank          INT
)
LANGUAGE sql STABLE AS $$
WITH ctx AS (
    SELECT cl.id AS listing_id
      FROM channel_listing cl
     WHERE cl.channel_id = p_channel_id
       AND cl.status = 'online'
       AND cl.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = p_variant_id)
),
cand AS (
    SELECT spc.supplier_product_id,
           sv.id               AS supplier_variant_id,
           spc.currency        AS source_currency,
           spc.net_price,
           spc.supplier_price,
           sv.is_price_locked,
           cls.min_margin      AS source_min_margin,
           fn_convert(spc.net_price, spc.currency, fn_base_currency(), p_date) AS cost_base,
           round(fn_fx_pair_rate(spc.currency, p_target_currency, p_date), 8)    AS fx_rate_to_target,
           fn_fx_pair_snapshot_date(spc.currency, p_target_currency, p_date)    AS fx_as_of,
           cls.priority,
           cls.fallback_order
      FROM ctx
      JOIN supplier_variant_mapping svm
        ON svm.product_variant_id = p_variant_id AND svm.status = 'active'
      JOIN supplier_variant sv
        ON sv.id = svm.supplier_variant_id AND sv.status = 'active'
      JOIN supplier_price_calendar spc
        ON spc.supplier_variant_id = sv.id
       AND spc.product_variant_id = p_variant_id
       AND spc.date = p_date
       AND spc.status = 'available'
      JOIN channel_listing_source cls
        ON cls.channel_listing_id = ctx.listing_id
       AND cls.supplier_product_id = spc.supplier_product_id
       AND cls.enabled
     WHERE fn_variant_covered(svm.coverage, p_variant_id)
       AND fn_fx_rate(spc.currency, p_date) IS NOT NULL
       AND fn_fx_pair_rate(spc.currency, p_target_currency, p_date) IS NOT NULL
       -- 源侧兑现窗口盖不住规范侧承诺 → 这个源不进候选。
       -- NULL（源侧没报）不拦：源侧没给约束 = 不拦，与硬约束 34 同一条口径。
       AND (sv.valid_days IS NULL
            OR sv.valid_days >= fn_variant_validity_days(p_variant_id))
)
SELECT c.supplier_product_id,
       c.supplier_variant_id,
       c.source_currency,
       c.net_price,
       c.supplier_price,
       c.is_price_locked,
       c.source_min_margin,
       c.cost_base,
       c.fx_rate_to_target,
       c.fx_as_of,
       c.priority,
       c.fallback_order,
       ROW_NUMBER() OVER (ORDER BY c.cost_base, c.priority, c.fallback_order,
                                   c.supplier_product_id) AS route_rank
  FROM cand c;
$$;

COMMENT ON FUNCTION fn_route_candidates(BIGINT, DATE, BIGINT, TEXT)
  IS '选源的唯一实现：路由视图与定价函数共用同一候选集与同一排序键；route_rank=1 即首选源；源侧兑现窗口盖不住规范侧承诺的源不进候选';

-- -------------------------------------------------------------------------------------
-- ③ 源侧兑现窗口的读模型：看得见差在哪
-- -------------------------------------------------------------------------------------
-- 与 v_variant_bundle 的形状对齐（set_valid_days / union_days / covers_window），
-- 差别只有一个：套装比的是「整套有效期 vs 成分窗口的并集」，
-- 单张比的是「源 SKU 有效期 vs 规范侧承诺」。
--
-- 这张视图是「差异看得见」的落点：运营侧要能一眼看出
-- 「这个变体有两天的承诺，但能供的源只兑现一天」——
-- 看不见的差异等于不存在的差异（与硬约束 30 同一条口径）。
CREATE VIEW v_variant_source_validity AS
SELECT sv.id                     AS supplier_variant_id,
       sv.supplier_product_id,
       sup.code                  AS supplier_code,
       sv.external_variant_id    AS source_sku,
       COALESCE(sv.title, '')    AS source_title,
       svm.product_variant_id,
       pv.variant_code,
       pv.variant_key,
       pv.product_id,
       sv.valid_days             AS source_valid_days,
       fn_variant_validity_days(svm.product_variant_id) AS promised_days,
       -- 源侧没报 = 没给约束，不判「盖不住」；源侧报了才判。
       CASE WHEN sv.valid_days IS NULL THEN NULL
            ELSE (sv.valid_days >= fn_variant_validity_days(svm.product_variant_id))
       END                       AS covers_window,
       CASE WHEN sv.valid_days IS NULL THEN NULL
            WHEN sv.valid_days >= fn_variant_validity_days(svm.product_variant_id)
                 THEN NULL
            ELSE '源侧兑现的有效期短于规范侧承诺'
       END                       AS gap_reason,
       sv.status                 AS source_status
  FROM supplier_variant sv
  JOIN supplier_product sp ON sp.id = sv.supplier_product_id
  JOIN supplier sup ON sup.id = sp.supplier_id
  JOIN supplier_variant_mapping svm
    ON svm.supplier_variant_id = sv.id AND svm.status = 'active'
  JOIN product_variant pv ON pv.id = svm.product_variant_id;

COMMENT ON VIEW v_variant_source_validity IS
    '源侧兑现窗口 vs 规范侧承诺：source_valid_days 是源侧肯兑现的天数，promised_days 是我们承诺的天数；covers_window=NULL 表示源侧没报（没给约束，不拦）';

-- -------------------------------------------------------------------------------------
-- ④ 不变量 122：卖出去的订单用的源，兑现窗口不得短于承诺
-- -------------------------------------------------------------------------------------
-- 与不变量 75 同一条口径（源侧能不能兑现是选源时定的，卖了之后不许改写历史）：
--   75  查「覆盖得住吗」（轴能力）
--   122 查「兑现得起吗」（有效期窗口）
-- 两条都只读事实，不改历史订单。
CREATE VIEW v_invariant_checks_source_validity AS
WITH raw (seq, check_name, actual) AS (
    -- 122：卖出去的订单用的源，其兑现的有效期窗口不得短于该可售单元承诺的有效期
    SELECT 122, '卖出去的订单用的源必须兑现得起该可售单元承诺的有效期',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN booking b ON b.order_item_id = oi.id
              JOIN supplier_variant sv ON sv.id = b.supplier_variant_id
             WHERE sv.valid_days IS NOT NULL
               AND sv.valid_days < fn_variant_validity_days(oi.product_variant_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_source_validity IS
    '源侧兑现窗口侧不变量（122）：卖出去的订单用的源，其兑现窗口不得短于规范侧承诺';

-- 把新分支接进 v_invariant_checks（唯一来源：这里 UNION ALL 一次）。
--
-- 分支清单是手抄的 —— 但手抄的是**视图名**，不是口径。
-- 口径住在每个分支视图自己的定义里（那是唯一的来源）；
-- 这里只负责把分支聚起来。抄漏一个分支的后果是 v_invariant_checks 少一条门禁，
-- 而少的那条永远不会有人发现（它从来没红过）——
-- 所以加分支时这里和 SPEC.md 的快照两处一起改。
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
