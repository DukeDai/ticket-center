-- =============================================================================
-- 021 供给形态对照：三种异构供给形态放在同一个视图里对齐
--
-- 为什么要有这个视图
-- ----------------
-- 异构融合到这一步有三种形态：
--
--   方向 A（单张）  一个源 SKU 覆盖住一个可售单元         supplier_variant_mapping.coverage
--   方向 B（配方）  一个可售单元由多个源 SKU 按份数组成   supplier_variant_composition
--   方向 B（套装）  源侧把整套当一个 SKU 卖               supplier_variant_bundle
--
-- 但选源与覆盖的读侧（v_variant_routing_candidates / v_variant_source_coverage）
-- 只认方向 A：配方与套装的变体在那些视图里一行都没有。
-- 于是「这个可售单元有哪几种供给形态、分别由谁供、供的是什么结构」这个问题
-- 没人答得上来 —— 运营看到的是一个空白，不是一份对照。
--
-- 这个视图把三种形态放在同一张表上对齐：
--   supply_form = 'single' | 'recipe' | 'bundle'
-- 一行 = 一个可售单元 × 一天 × 一个渠道 × 一种形态。
--
-- 事实从哪来（不许重算）
-- ------------------------
--   单张：候选与排序来自 fn_route_candidates（选源的唯一实现）
--   配方：成分来自 fn_combo_components（配方成分的唯一读法）
--   套装：成分来自 fn_bundle_components（套装成分的唯一读法）
--   交付什么（入场份数 / 人群编码 / 天数）来自 fn_variant_composition
--          （C 端构成读模型 c_variant_composition 的同一个来源）
--
-- 门禁（102-104）
--   102 声明过的形态不许在视图里消失
--   103 视图里的成本必须等于定价函数算的成本（事实不许分叉）
--   104 视图里的入场份数必须等于 C 端构成读模型的份数（两个读模型不许分叉）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 声明过的形态：这个可售单元声明了哪几种供给形态
--
-- 「声明」是唯一的事实来源：形态不许从覆盖关系推断（硬约束 29）。
-- 这个视图只回答「声明了什么」，不回答「当天卖不卖得掉」。
-- -----------------------------------------------------------------------------
CREATE VIEW v_variant_declared_forms AS
WITH days AS (
    -- 可卖日：默认售价行有哪几天，就比哪几天。
    SELECT DISTINCT pc.product_variant_id, pc.date
      FROM price_calendar pc
     WHERE pc.channel_id IS NULL
       AND pc.status = 'active'
)
SELECT d.product_variant_id,
       d.date,
       EXISTS (SELECT 1
                 FROM supplier_variant_mapping svm
                WHERE svm.product_variant_id = d.product_variant_id
                  AND svm.status = 'active')          AS has_single,
       EXISTS (SELECT 1
                 FROM supplier_variant_composition svc
                WHERE svc.product_variant_id = d.product_variant_id
                  AND svc.status = 'active')          AS has_recipe,
       EXISTS (SELECT 1
                 FROM supplier_variant_bundle svb
                WHERE svb.product_variant_id = d.product_variant_id
                  AND svb.status = 'active')          AS has_bundle
  FROM days d;

COMMENT ON VIEW v_variant_declared_forms IS
    '每个可售单元每天声明了哪几种供给形态（单张 / 配方 / 套装）—— 形态的唯一来源是声明，不是推断';

-- -----------------------------------------------------------------------------
-- 三种形态的对照
-- -----------------------------------------------------------------------------
CREATE VIEW v_variant_supply_forms AS
WITH
-- ① 可卖日 + 渠道上下文。
--    结算币种与定价模式取自上架行 —— 定价函数读的是同一样东西（fn_price_variant 的 ctx）。
ctx AS (
    SELECT d.product_variant_id,
           d.date,
           cl.channel_id,
           fn_price_row_currency(cl.channel_id) AS target_currency,
           COALESCE(NULLIF(cl.price_policy->>'mode', ''), 'cost_plus') AS mode
      FROM (SELECT DISTINCT pc.product_variant_id, pc.date
              FROM price_calendar pc
             WHERE pc.channel_id IS NULL
               AND pc.status = 'active') d
      JOIN product_variant pv
        ON pv.id = d.product_variant_id
       AND pv.status = 'active'
      JOIN channel_listing cl
        ON cl.product_id = pv.product_id
       AND cl.status = 'online'
),
-- ② 单张候选：选源的唯一实现。
route AS (
    SELECT ctx.product_variant_id,
           ctx.date,
           ctx.channel_id,
           rc.supplier_product_id,
           rc.supplier_variant_id,
           rc.source_currency,
           rc.net_price,
           rc.cost_base,
           rc.route_rank
      FROM ctx
      CROSS JOIN LATERAL fn_route_candidates(ctx.product_variant_id, ctx.date,
                                             ctx.channel_id, ctx.target_currency) rc
),
-- ③ 单张的声明（源映射）：覆盖住这个可售单元的源 SKU。
single_decl AS (
    SELECT ctx.product_variant_id,
           ctx.date,
           ctx.channel_id,
           svm.id                AS supply_ref,
           sv.id                 AS supplier_variant_id,
           sv.external_variant_id,
           sp.id                 AS supplier_product_id,
           sup.code              AS supplier_code,
           svm.coverage,
           fn_variant_covered(svm.coverage, ctx.product_variant_id) AS covers,
           fn_variant_coverage_gaps(svm.coverage, ctx.product_variant_id) AS gaps
      FROM ctx
      JOIN supplier_variant_mapping svm
        ON svm.product_variant_id = ctx.product_variant_id
       AND svm.status = 'active'
      JOIN supplier_variant sv
        ON sv.id = svm.supplier_variant_id
       AND sv.status = 'active'
      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
      JOIN supplier sup ON sup.id = sp.supplier_id
),
-- ④ 单张的每一行：声明 + 当天有没有价。
single_rows AS (
    SELECT sd.product_variant_id,
           sd.date,
           sd.channel_id,
           sd.supply_ref,
           sd.supplier_variant_id,
           sd.external_variant_id,
           sd.supplier_product_id,
           sd.supplier_code,
           sd.coverage,
           sd.covers,
           r.source_currency,
           r.net_price,
           r.route_rank,
           CASE WHEN r.supplier_variant_id IS NOT NULL
                THEN fn_convert(r.net_price, r.source_currency,
                                fn_price_row_currency(sd.channel_id), sd.date)
                ELSE NULL END AS cost_in_target,
           CASE WHEN NOT sd.covers              THEN sd.gaps
                WHEN r.supplier_variant_id IS NULL THEN ARRAY['当天没有可用报价']::text[]
                ELSE ARRAY[]::text[] END      AS gaps
      FROM single_decl sd
      LEFT JOIN route r
        ON r.product_variant_id = sd.product_variant_id
       AND r.date              = sd.date
       AND r.channel_id        = sd.channel_id
       AND r.supplier_variant_id = sd.supplier_variant_id
),
single_form0 AS (
    SELECT product_variant_id,
           date,
           channel_id,
           'single'::text AS supply_form,
           array_agg(DISTINCT supplier_code)          AS supplier_codes,
           count(DISTINCT supplier_code)              AS supplier_count,
           array_agg(DISTINCT external_variant_id)    AS external_variant_ids,
           array_remove(array_agg(DISTINCT source_currency), NULL) AS source_currencies,
           -- 成本取**选源选中的那一个**（route_rank = 1），不是各源里的最小值。
           -- 选源按基准币种排序（fn_route_candidates），最小值按本行币种排 ——
           -- 渠道币种不是基准币种时这两个「最小」不是同一个源。
           -- 取错会出现「对照视图说成本 A，定价函数算出来是 B」，
           -- 而不变量 103 就是为了当场抓住这种分叉。
           min(cost_in_target) FILTER (WHERE route_rank = 1) AS cost_in_target,
           bool_or(covers AND cost_in_target IS NOT NULL) AS can_fulfil,
           jsonb_agg(jsonb_build_object(
                        'supply_ref',         supply_ref,
                        'supplier_code',      supplier_code,
                        'external_variant_id', external_variant_id,
                        'supplier_product_id', supplier_product_id,
                        'source_currency',    source_currency,
                        'net_price',          net_price,
                        'cost_in_target',     cost_in_target,
                        'route_rank',         route_rank,
                        'coverage',           coverage,
                        -- 这个源自己的缺口（覆盖不住 / 当天没价）。
                        -- 逐源看 —— 形态整体卖不掉的原因归形态的 gaps，
                        -- 混在一起会出现「✓ 能供，却说当天没报价」这种自相矛盾的话。
                        'gaps',              gaps
                    ) ORDER BY route_rank NULLS LAST, supplier_code) AS candidates
      FROM single_rows
     GROUP BY product_variant_id, date, channel_id
),
-- 缺口单独摊平：每个源各有各的缺口，摊平后去重才算这个形态的缺口。
single_gap_rows AS (
    SELECT sr.product_variant_id, sr.date, sr.channel_id, g
      FROM single_rows sr
      CROSS JOIN LATERAL unnest(sr.gaps) g
),
single_gaps AS (
    SELECT product_variant_id, date, channel_id, array_agg(DISTINCT g) AS gaps
      FROM single_gap_rows
     GROUP BY product_variant_id, date, channel_id
),
single_form AS (
    SELECT sf.product_variant_id,
           sf.date,
           sf.channel_id,
           sf.supply_form,
           sf.supplier_codes,
           sf.supplier_count,
           sf.external_variant_ids,
           sf.source_currencies,
           sf.cost_in_target,
           sf.can_fulfil,
           sf.candidates,
           -- 形态的缺口 = 这个形态整体卖不掉的原因。
           -- 能供的时候不报缺口 —— 逐源的缺口在 candidates 里，
           -- 混在一起会出现「✓ 能供，却说当天没报价」这种自相矛盾的话。
           CASE WHEN sf.can_fulfil THEN ARRAY[]::text[]
                ELSE COALESCE(sg.gaps, ARRAY[]::text[]) END AS gaps
      FROM single_form0 sf
      LEFT JOIN single_gaps sg
        ON sg.product_variant_id = sf.product_variant_id
       AND sg.date = sf.date
       AND sg.channel_id = sf.channel_id
),
-- ⑤ 配方的每一行：源侧配方的一个成分。
recipe_rows AS (
    SELECT ctx.product_variant_id,
           ctx.date,
           ctx.channel_id,
           ctx.mode,
           cc.component_variant_id,
           cc.component_key,
           cc.quantity,
           cc.supplier_variant_id,
           cc.supplier_product_id,
           cc.supplier_id,
           cc.net_price,
           cc.source_currency,
           cc.fx_rate,
           cc.fx_as_of,
           cc.unit_cost,
           cc.is_price_locked,
           cc.product_session_id,
           cc.supplier_session_id
      FROM ctx
      CROSS JOIN LATERAL fn_combo_components(ctx.product_variant_id, ctx.date,
                                             ctx.channel_id, ctx.target_currency) cc
),
recipe_form0 AS (
    SELECT r.product_variant_id,
           r.date,
           r.channel_id,
           'recipe'::text AS supply_form,
           array_agg(DISTINCT sup.code)              AS supplier_codes,
           count(DISTINCT sup.id)                    AS supplier_count,
           array_agg(DISTINCT sv.external_variant_id) AS external_variant_ids,
           array_remove(array_agg(DISTINCT r.source_currency), NULL) AS source_currencies,
           sum(r.unit_cost * r.quantity)             AS cost_in_target,
           count(*)                                  AS parts,
           count(r.unit_cost)                        AS priced_parts,
           count(DISTINCT r.supplier_session_id)     AS session_count,
           count(DISTINCT r.supplier_id)             AS distinct_suppliers,
           count(*) FILTER (WHERE r.is_price_locked) AS locked_parts,
           max(r.mode)                             AS mode,
           jsonb_agg(jsonb_build_object(
                        'component_variant_id', r.component_variant_id,
                        'component_key',        r.component_key,
                        'quantity',             r.quantity,
                        'supplier_code',        sup.code,
                        'external_variant_id',  sv.external_variant_id,
                        'supplier_product_id',  r.supplier_product_id,
                        'source_currency',      r.source_currency,
                        'net_price',            r.net_price,
                        'unit_cost',            r.unit_cost,
                        'fx_rate',              r.fx_rate,
                        'fx_as_of',             r.fx_as_of
                    ) ORDER BY r.component_variant_id) AS candidates
      FROM recipe_rows r
      JOIN supplier_variant sv ON sv.id = r.supplier_variant_id
      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
      JOIN supplier sup ON sup.id = sp.supplier_id
     GROUP BY r.product_variant_id, r.date, r.channel_id
),
recipe_form AS (
    SELECT rf.product_variant_id,
           rf.date,
           rf.channel_id,
           rf.supply_form,
           rf.supplier_codes,
           rf.supplier_count,
           rf.external_variant_ids,
           rf.source_currencies,
           rf.cost_in_target,
           (rf.priced_parts = rf.parts
            AND rf.session_count = 1
            AND rf.distinct_suppliers = 1
            AND rf.locked_parts = 0
            AND rf.mode <> 'per_group')             AS can_fulfil,
           rf.candidates,
           ARRAY_REMOVE(ARRAY[
               CASE WHEN rf.priced_parts < rf.parts THEN '成分当天没有报价' END,
               CASE WHEN rf.session_count <> 1       THEN '成分不在同一场次' END,
               CASE WHEN rf.distinct_suppliers <> 1  THEN '成分跨源' END,
               CASE WHEN rf.locked_parts > 0         THEN '成分锁价' END,
               CASE WHEN rf.mode = 'per_group'       THEN '按团报价' END
           ], NULL)                                  AS gaps
      FROM recipe_form0 rf
),
-- ⑥ 套装的每一行：源侧整套的一个成分（成本是整套的，分摊到成分）。
bundle_rows AS (
    SELECT ctx.product_variant_id,
           ctx.date,
           ctx.channel_id,
           ctx.mode,
           bp.component_variant_id,
           bp.component_key,
           bp.quantity,
           bp.supplier_variant_id,
           bp.supplier_product_id,
           bp.supplier_id,
           bp.source_ticket_type_id,
           bp.net_price,
           bp.source_currency,
           bp.fx_rate,
           bp.fx_as_of,
           bp.set_cost,
           bp.unit_cost,
           bp.bundle_valid_days,
           bp.covers_components,
           bp.is_price_locked,
           bp.product_session_id,
           bp.supplier_session_id
      FROM ctx
      CROSS JOIN LATERAL fn_bundle_components(ctx.product_variant_id, ctx.date,
                                              ctx.channel_id, ctx.target_currency) bp
),
bundle_form0 AS (
    SELECT b.product_variant_id,
           b.date,
           b.channel_id,
           'bundle'::text AS supply_form,
           array_agg(DISTINCT sup.code)               AS supplier_codes,
           count(DISTINCT sup.id)                     AS supplier_count,
           array_agg(DISTINCT sv.external_variant_id) AS external_variant_ids,
           array_remove(array_agg(DISTINCT b.source_currency), NULL) AS source_currencies,
           max(b.set_cost)                            AS cost_in_target,
           count(*)                                   AS parts,
           count(b.set_cost)                          AS priced_parts,
           sum(b.quantity)                            AS units,
           count(DISTINCT b.supplier_session_id)      AS session_count,
           count(*) FILTER (WHERE b.is_price_locked)  AS locked_parts,
           bool_and(b.covers_components)              AS covers_components,
           max(b.source_ticket_type_id)               AS source_ticket_type_id,
           max(b.bundle_valid_days)                   AS bundle_valid_days,
           max(b.mode)                                AS mode,
           jsonb_agg(jsonb_build_object(
                        'component_variant_id', b.component_variant_id,
                        'component_key',        b.component_key,
                        'quantity',             b.quantity,
                        'supplier_code',        sup.code,
                        'external_variant_id',  sv.external_variant_id,
                        'supplier_product_id',  b.supplier_product_id,
                        'source_ticket_type_id', b.source_ticket_type_id,
                        'source_currency',      b.source_currency,
                        'net_price',            b.net_price,
                        'set_cost',             b.set_cost,
                        'unit_cost',            b.unit_cost,
                        'fx_rate',              b.fx_rate,
                        'fx_as_of',             b.fx_as_of
                    ) ORDER BY b.component_variant_id) AS candidates
      FROM bundle_rows b
      JOIN supplier_variant sv ON sv.id = b.supplier_variant_id
      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
      JOIN supplier sup ON sup.id = sp.supplier_id
     GROUP BY b.product_variant_id, b.date, b.channel_id
),
bundle_form AS (
    SELECT bf.product_variant_id,
           bf.date,
           bf.channel_id,
           bf.supply_form,
           bf.supplier_codes,
           bf.supplier_count,
           bf.external_variant_ids,
           bf.source_currencies,
           bf.cost_in_target,
           (bf.priced_parts = bf.parts
            AND bf.units > 0
            AND bf.session_count = 1
            AND bf.locked_parts = 0
            AND bf.covers_components
            AND bf.source_ticket_type_id IS NOT NULL
            AND bf.mode <> 'per_group')             AS can_fulfil,
           bf.candidates,
           ARRAY_REMOVE(ARRAY[
               CASE WHEN bf.priced_parts < bf.parts  THEN '套装当天没有源侧报价' END,
               CASE WHEN bf.units = 0                 THEN '套装没有声明成分' END,
               CASE WHEN bf.session_count <> 1       THEN '套装没有绑定源场次' END,
               CASE WHEN bf.locked_parts > 0         THEN '套装锁价' END,
               CASE WHEN NOT bf.covers_components     THEN '源侧整套有效期盖不住成分窗口' END,
               CASE WHEN bf.source_ticket_type_id IS NULL THEN '套装没有源侧票种（算不出库存池）' END,
               CASE WHEN bf.mode = 'per_group'       THEN '按团报价' END
           ], NULL)                                  AS gaps
      FROM bundle_form0 bf
),
-- ⑦ 交付什么：入场份数 / 人群编码 / 天数。
--    来源是 fn_variant_composition —— C 端构成读模型的同一个来源，不许另算一遍。
delivered AS (
    SELECT pv.id AS product_variant_id,
           pv.variant_role,
           pv.ticket_type_id,
           fn_variant_validity_days(pv.id) AS valid_days,
           COALESCE(vc.component_count, 0) AS component_count,
           COALESCE(vc.admission_quantity, 1) AS admission_quantity,
           COALESCE(vc.audience_codes,
                    ARRAY[COALESCE(tt.code, '')]::text[]) AS audience_codes
      FROM product_variant pv
      LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id
      LEFT JOIN LATERAL (
            SELECT count(*)::int       AS component_count,
                   sum(fvc.quantity)   AS admission_quantity,
                   array_agg(DISTINCT fvc.audience_code) AS audience_codes
              FROM fn_variant_composition(pv.id) fvc
      ) vc ON true
),
-- ⑧ 三种形态并到一起。
forms AS (
    SELECT s.product_variant_id, s.date, s.channel_id, s.supply_form,
           s.supplier_codes, s.supplier_count, s.external_variant_ids, s.source_currencies,
           round(s.cost_in_target, 2) AS cost_in_target, s.can_fulfil, s.gaps, s.candidates
      FROM single_form s
    UNION ALL
    SELECT r.product_variant_id, r.date, r.channel_id, r.supply_form,
           r.supplier_codes, r.supplier_count, r.external_variant_ids, r.source_currencies,
           round(r.cost_in_target, 2) AS cost_in_target, r.can_fulfil, r.gaps, r.candidates
      FROM recipe_form r
    UNION ALL
    SELECT b.product_variant_id, b.date, b.channel_id, b.supply_form,
           b.supplier_codes, b.supplier_count, b.external_variant_ids, b.source_currencies,
           round(b.cost_in_target, 2) AS cost_in_target, b.can_fulfil, b.gaps, b.candidates
      FROM bundle_form b
)
SELECT f.product_variant_id,
       pv.variant_code,
       pv.title              AS variant_title,
       pv.variant_role,
       p.id                  AS product_id,
       p.product_code,
       p.title               AS product_title,
       f.date,
       f.channel_id,
       f.supply_form,
       f.supplier_codes,
       f.supplier_count,
       f.external_variant_ids,
       f.source_currencies,
       f.cost_in_target,
       fn_price_row_currency(f.channel_id) AS currency,
       fn_base_currency()                  AS base_currency,
       d.component_count,
       d.admission_quantity,
       d.audience_codes,
       d.valid_days,
       f.can_fulfil,
       f.gaps,
       f.candidates
  FROM forms f
  JOIN product_variant pv ON pv.id = f.product_variant_id
  JOIN product p ON p.id = pv.product_id
  JOIN delivered d ON d.product_variant_id = f.product_variant_id;

COMMENT ON VIEW v_variant_supply_forms IS
    '三种异构供给形态（单张 / 配方 / 套装）在同一张表上对齐：一个可售单元 × 一天 × 一个渠道 × 一种形态';

-- -----------------------------------------------------------------------------
-- 不变量 102-104
--
-- 102 声明过的形态不许在对照视图里消失
-- 103 对照视图的成本必须等于定价函数算的成本
-- 104 对照视图的入场份数必须等于 C 端构成读模型的份数
-- -----------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_supply_forms_021 AS
WITH raw(seq, check_name, actual) AS (
    -- 102：声明过的形态不许在对照视图里消失。
    --
    -- 形态的唯一来源是声明（映射 / 配方 / 套装）。少了任何一种，
    -- 运营在这个可售单元上看到的就是一份缺了一块的对照 ——
    -- 「这个变体没人供」和「没人看得见它有人供」长得一模一样。
    SELECT 102,
           '声明过的供给形态不许在对照视图里消失',
           (SELECT count(*)
              FROM v_variant_declared_forms df
             WHERE (df.has_single
                    AND NOT EXISTS (SELECT 1 FROM v_variant_supply_forms f
                                     WHERE f.product_variant_id = df.product_variant_id
                                       AND f.date = df.date
                                       AND f.supply_form = 'single'))
                OR (df.has_recipe
                    AND NOT EXISTS (SELECT 1 FROM v_variant_supply_forms f
                                     WHERE f.product_variant_id = df.product_variant_id
                                       AND f.date = df.date
                                       AND f.supply_form = 'recipe'))
                OR (df.has_bundle
                    AND NOT EXISTS (SELECT 1 FROM v_variant_supply_forms f
                                     WHERE f.product_variant_id = df.product_variant_id
                                       AND f.date = df.date
                                       AND f.supply_form = 'bundle')))
    UNION ALL
    -- 103：对照视图的成本必须等于定价函数算的成本。
    --
    -- 对照视图是读模型，读模型与定价函数各算一遍钱，就是两份事实：
    -- 运营按对照视图看到的成本与收银台收的钱对不上，
    -- 「按 A 源的价格卖、按 B 源出票」换了个地方发生。
    -- 定价函数当天判不可售的（没有价格行）不比 —— 那时候没有可比的对象。
    SELECT 103,
           '供给形态对照视图的成本必须等于定价函数算的成本',
           (SELECT count(*)
              FROM v_variant_supply_forms f
              CROSS JOIN LATERAL fn_price_variant(f.product_variant_id, f.date,
                                                 f.channel_id, f.channel_id) p
             WHERE f.cost_in_target IS DISTINCT FROM p.cost_price)
    UNION ALL
    -- 104：对照视图的入场份数必须等于 C 端构成读模型的份数。
    --
    -- 两个读模型讲的是同一件事：一个可售单元给客户几张票。
    -- 对照视图说 3 份、C 端构成说 2 份 —— 详情页写「2 成人 + 1 儿童」，
    -- 闸机那边按 2 张放。份数守恒靠这一个口径。
    SELECT 104,
           '供给形态对照视图的入场份数必须等于 C 端构成读模型的份数',
           (SELECT count(*)
              FROM v_variant_supply_forms f
              JOIN (SELECT product_variant_id, sum(q) AS admissions
                      FROM (SELECT product_variant_id, component_variant_id,
                                   max(quantity) AS q
                              FROM c_variant_composition
                             GROUP BY product_variant_id, component_variant_id) x
                     GROUP BY product_variant_id) c
                ON c.product_variant_id = f.product_variant_id
             WHERE f.supply_form IN ('recipe', 'bundle')
               AND f.admission_quantity IS DISTINCT FROM c.admissions)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_supply_forms_021 IS
    '供给形态对照侧不变量（102-104）：形态不许丢、成本不许分叉、份数不许分叉';

-- -----------------------------------------------------------------------------
-- 总表：加进 102 / 103 / 104
-- -----------------------------------------------------------------------------
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
UNION ALL SELECT v_invariant_checks_supply_forms_021.seq, v_invariant_checks_supply_forms_021.check_name, v_invariant_checks_supply_forms_021.expected, v_invariant_checks_supply_forms_021.actual, v_invariant_checks_supply_forms_021.passed, v_invariant_checks_supply_forms_021.result FROM v_invariant_checks_supply_forms_021;
