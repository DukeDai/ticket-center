-- =============================================================================
-- 022 — 供给形态不许因为源 SKU 下架而缩小（2026-11-10）
--
-- 问题：
--   配方（方向 B）的成分行与套装（方向 B 的第三种形态）都在解析成分时
--   JOIN supplier_variant ... AND status = 'active'。
--   源侧把某个 SKU 下架时，那一行直接消失：
--     - 配方：成分少了一个，定价函数看到的是「少一个成分的套餐」，
--       于是按剩下的成分重新定价 —— 收 3 份入场的钱，出 1 份票。
--       C 端构成读模型还写着 2 个成分 / 3 份入场 —— 读侧与写侧分叉。
--     - 套装：整套的成分全没了，形态行从对照视图里**消失** ——
--       不是「卖不掉」，是「看不见」。
--
-- 口径（与硬约束 25「少一个成分 = 源侧少给一份」一致）：
--   - 声明过的成分不许因为源 SKU 下架而消失。成分行留着，只是没有价。
--   - 少了价的成分 = 这个形态整体卖不掉（定价函数的 n_priced = n_parts 门禁
--     已经守着这一条，不用另写一套）。
--   - 卖不掉要说清为什么：缺口里点名「成分的源 SKU 已下架」。
--   - 源侧下架是事实，我们改不了源侧，也不该为了留住事实而改写历史订单；
--     但我们不能把「少一个成分的套餐」当成「这个套餐」卖出去。
--     宁可少卖，不可卖错。
--
-- 这里改三个东西：
--   1. fn_combo_components   —— 成分行不因源 SKU 下架而消失（没价就是没价）。
--   2. fn_bundle_components  —— 套装成分行不因整套 SKU 下架而消失。
--   3. v_variant_supply_forms —— 形态行必须留着，并把缺口说清。
--
-- 不变量 105-107：
--   105 配方的成分不许因为源 SKU 下架而消失
--   106 成分的源 SKU 下架时配方套餐不许还能卖
--   107 套装的源 SKU 下架时套装不许还能卖
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ① fn_combo_components：成分行不许因为源 SKU 下架而消失
--
-- 改的地方只有一处语义：**源的可用性从「决定这一行在不在」改成「决定这一行有没有价」**。
-- 之前 JOIN supplier_variant ... AND status='active' 把下架的源整个丢掉，
-- 配方于是静悄悄地变成了一个更小的套餐。现在源下架时这一行还在，
-- 只是没有报价 —— 定价函数的 n_priced = n_parts 门禁会挡住它，
-- 对照视图也会把缺口说出来。
--
-- 函数签名不变（RETURNS TABLE 一个字没动）：
-- 「源 SKU 在不在架」由调用方自己 JOIN supplier_variant 判定，
-- 不在本函数里另立一份口径。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_combo_components(p_variant_id bigint, p_date date, p_channel_id bigint, p_target_currency text)
 RETURNS TABLE(component_variant_id bigint, component_key text, component_ticket_type_id bigint, quantity numeric, supplier_variant_id bigint, supplier_product_id bigint, supplier_id bigint, net_price numeric, source_currency text, fx_rate numeric, fx_as_of date, unit_cost numeric, product_session_id bigint, supplier_session_id bigint, source_min_margin numeric, is_price_locked boolean)
 LANGUAGE sql
 STABLE
AS $function$
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
               -- 源 SKU 还在不在架。下架不等于这一行不存在，
               -- 只等于这一行没有价（022：成分不许因为源 SKU 下架而消失）。
               COALESCE(sv.source_active, false) AS source_active,
               COALESCE(cls.min_margin, 0) AS source_min_margin,
               CASE WHEN COALESCE(sv.source_active, false) THEN spc.net_price END AS net_price,
               CASE WHEN COALESCE(sv.source_active, false) THEN spc.currency END AS source_currency,
               CASE WHEN COALESCE(sv.source_active, false) AND spc.net_price IS NOT NULL
                    THEN round(fn_fx_pair_rate(spc.currency, p_target_currency, p_date), 8) END AS fx_rate,
               CASE WHEN COALESCE(sv.source_active, false) AND spc.net_price IS NOT NULL
                    THEN fn_fx_pair_snapshot_date(spc.currency, p_target_currency, p_date) END AS fx_as_of,
               CASE WHEN COALESCE(sv.source_active, false) AND spc.net_price IS NOT NULL
                    THEN round(fn_convert(spc.net_price, spc.currency, p_target_currency, p_date), 2) END AS unit_cost,
               pc.session_id AS price_session_id
          FROM recipe r
          -- 源 SKU 左连接：下架的行也留着（没有价而已）。
          LEFT JOIN LATERAL (
                SELECT s.supplier_product_id,
                       s.is_price_locked,
                       (s.status = 'active') AS source_active
                  FROM supplier_variant s
                 WHERE s.id = r.supplier_variant_id) sv ON true
          LEFT JOIN LATERAL (
                SELECT sp2.supplier_id
                  FROM supplier_product sp2
                 WHERE sp2.id = sv.supplier_product_id) sp ON true
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
$function$;

CREATE OR REPLACE FUNCTION public.fn_bundle_components(p_variant_id bigint, p_date date, p_channel_id bigint, p_target_currency text)
 RETURNS TABLE(component_variant_id bigint, component_key text, component_ticket_type_id bigint, quantity numeric, supplier_variant_id bigint, supplier_product_id bigint, supplier_id bigint, source_ticket_type_id bigint, net_price numeric, source_currency text, fx_rate numeric, fx_as_of date, set_cost numeric, unit_cost numeric, product_session_id bigint, supplier_session_id bigint, source_min_margin numeric, is_price_locked boolean, bundle_valid_days numeric, covers_components boolean)
 LANGUAGE sql
 STABLE
AS $function$
    WITH bundle AS (
        SELECT svb.id, svb.product_variant_id, svb.supplier_variant_id, svb.valid_days
          FROM supplier_variant_bundle svb
         WHERE svb.product_variant_id = p_variant_id
           AND svb.status = 'active'
    ),
    parts AS (
        SELECT p.bundle_id, p.component_variant_id, p.quantity
          FROM supplier_variant_bundle_part p
          JOIN bundle b ON b.id = p.bundle_id
    ),
    listing AS (
        SELECT cl.id AS listing_id
          FROM channel_listing cl
         WHERE cl.channel_id = p_channel_id
           AND cl.status = 'online'
           AND cl.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = p_variant_id)
    ),
    head AS (
        SELECT b.id, b.product_variant_id, b.supplier_variant_id, b.valid_days,
               sv.supplier_product_id, sp.supplier_id, sv.is_price_locked,
               -- 整套的源 SKU 还在不在架。下架时成分行留着、成本留空（022）。
               COALESCE(sv.source_active, false) AS source_active,
               COALESCE(cls.min_margin, 0) AS source_min_margin,
               CASE WHEN COALESCE(sv.source_active, false) THEN spc.net_price END AS net_price,
               CASE WHEN COALESCE(sv.source_active, false) THEN spc.currency END AS source_currency,
               -- 票种是源侧那个「套」的事实：源下架后它仍然是事实，只是没有库存可占。
               spc.supplier_ticket_type_id,
               CASE WHEN COALESCE(sv.source_active, false) AND spc.net_price IS NOT NULL
                    THEN round(fn_fx_pair_rate(spc.currency, p_target_currency, p_date), 8) END AS fx_rate,
               CASE WHEN COALESCE(sv.source_active, false) AND spc.net_price IS NOT NULL
                    THEN fn_fx_pair_snapshot_date(spc.currency, p_target_currency, p_date) END AS fx_as_of,
               CASE WHEN COALESCE(sv.source_active, false) AND spc.net_price IS NOT NULL
                    THEN round(fn_convert(spc.net_price, spc.currency, p_target_currency, p_date), 2) END AS set_cost,
               ps.id AS product_session_id
          FROM bundle b
          -- 整套的源 SKU 左连接：下架时成分行仍然在，只是没有整套价。
          LEFT JOIN LATERAL (
                SELECT s.supplier_product_id,
                       s.is_price_locked,
                       (s.status = 'active') AS source_active
                  FROM supplier_variant s
                 WHERE s.id = b.supplier_variant_id) sv ON true
          LEFT JOIN LATERAL (
                SELECT sp2.supplier_id
                  FROM supplier_product sp2
                 WHERE sp2.id = sv.supplier_product_id) sp ON true
          -- 套装当天在这个源上的报价：源侧 SKU × 规范组合 × 日期
          LEFT JOIN LATERAL (
                SELECT s.net_price, s.currency, s.supplier_ticket_type_id
                  FROM supplier_price_calendar s
                 WHERE s.supplier_variant_id = b.supplier_variant_id
                   AND s.product_variant_id = b.product_variant_id
                   AND s.date = p_date
                   AND s.status = 'available'
                 ORDER BY s.id
                 LIMIT 1) spc ON true
          LEFT JOIN LATERAL (
                SELECT c2.min_margin
                  FROM channel_listing_source c2
                  JOIN listing l ON l.listing_id = c2.channel_listing_id
                 WHERE c2.supplier_product_id = sv.supplier_product_id
                   AND c2.enabled
                 ORDER BY c2.priority, c2.id
                 LIMIT 1) cls ON true
          -- 规范场次：按日期取这个商品当天的场次（不猜）
          LEFT JOIN LATERAL (
                SELECT p2.id
                  FROM product_session p2
                 WHERE p2.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = b.product_variant_id)
                   AND p2.session_date = p_date
                   AND p2.status = 'active'
                 ORDER BY p2.id
                 LIMIT 1) ps ON true
    ),
    located AS (
        SELECT h.*, pt.component_variant_id, pt.quantity AS part_qty,
               cv.variant_key AS component_key, cv.ticket_type_id AS component_ticket_type_id,
               SUM(pt.quantity) OVER () AS total_units
          FROM head h
          JOIN parts pt ON pt.bundle_id = h.id
          JOIN product_variant cv ON cv.id = pt.component_variant_id
    ),
    -- 分摊：按成分份数比例摊整套成本，余数归最后一个成分。
    -- 用「累计取整 − 上一段累计取整」而不是各自分摊再四舍五入：
    -- 后者会丢分或多分（不变量 98 守着这件事）。
    apportioned AS (
        SELECT l.*,
               CASE WHEN l.set_cost IS NULL OR l.total_units IS NULL OR l.total_units = 0 THEN NULL
                    ELSE round(l.set_cost * l.part_qty / l.total_units, 2) END AS rounded_part,
               row_number() OVER (ORDER BY l.component_variant_id) AS rn,
               count(*) OVER () AS cnt
          FROM located l
    ),
    cum AS (
        SELECT ap.*,
               COALESCE(sum(ap.rounded_part) OVER (
                   ORDER BY ap.component_variant_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS prev_cum
          FROM apportioned ap
    )
    SELECT c.component_variant_id,
           c.component_key,
           c.component_ticket_type_id,
           c.part_qty,
           c.supplier_variant_id,
           c.supplier_product_id,
           c.supplier_id,
           c.supplier_ticket_type_id AS source_ticket_type_id,
           c.net_price,
           c.source_currency,
           c.fx_rate,
           c.fx_as_of,
           c.set_cost,
           CASE WHEN c.set_cost IS NULL THEN NULL
                WHEN c.rn = c.cnt THEN round(c.set_cost - c.prev_cum, 2)
                ELSE c.rounded_part END AS unit_cost,
           c.product_session_id,
           fn_bound_supplier_session(c.product_session_id, c.supplier_product_id) AS supplier_session_id,
           c.source_min_margin,
           c.is_price_locked,
           c.valid_days,
           -- 源侧的整套有效期必须盖住规范侧承诺的窗口（成分窗口的并集）。
           -- 盖不住就是「我们承诺两天，源侧只认一天」——不许卖。
           c.valid_days >= fn_variant_validity_days(c.product_variant_id) AS covers_components
      FROM cum c
     ORDER BY c.component_variant_id;
$function$;
-- -----------------------------------------------------------------------------
-- ③ v_variant_supply_forms：形态不许因为源 SKU 下架而从对照视图里消失
--
-- 列一个没动（CREATE OR REPLACE VIEW 只能往末尾加列），
-- 改的是配方与套装两个分支：
--   - 源 SKU 左连接：下架的成分不再把整行带走；
--   - 缺口点名「成分的源 SKU 已下架」/「套装的源 SKU 已下架」；
--   - 成分缺一个时成本留空：残缺套餐的钱不是这个套餐的钱。
--
-- 视图定义与 021 一致，只有上面这几处不同 —— 这是同一份口径的延续，
-- 不是第二个实现（同一张表上对照这件事只有一个出处）。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_variant_supply_forms AS
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
           fn_variant_coverage_gaps(svm.coverage, ctx.product_variant_id) AS gaps,
           -- 源 SKU 还在不在架（022）。下架不等于这一行不存在：
           -- 这个可售单元仍然被声明着，只是现在没人供 —— 得看得见。
           COALESCE(sv.status = 'active', false) AS source_active
      FROM ctx
      JOIN supplier_variant_mapping svm
        ON svm.product_variant_id = ctx.product_variant_id
       AND svm.status = 'active'
      LEFT JOIN supplier_variant sv
        ON sv.id = svm.supplier_variant_id
      LEFT JOIN supplier_product sp ON sp.id = sv.supplier_product_id
      LEFT JOIN supplier sup ON sup.id = sp.supplier_id
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
           sd.source_active,
           r.source_currency,
           r.net_price,
           r.route_rank,
           CASE WHEN r.supplier_variant_id IS NOT NULL
                THEN fn_convert(r.net_price, r.source_currency,
                                fn_price_row_currency(sd.channel_id), sd.date)
                ELSE NULL END AS cost_in_target,
           CASE WHEN NOT sd.covers              THEN sd.gaps
                WHEN NOT sd.source_active       THEN ARRAY['源 SKU 已下架']::text[]
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
           array_remove(array_agg(DISTINCT supplier_code), NULL) AS supplier_codes,
           count(DISTINCT supplier_code)              AS supplier_count,
           array_remove(array_agg(DISTINCT external_variant_id), NULL) AS external_variant_ids,
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
           array_remove(array_agg(DISTINCT sup.code), NULL) AS supplier_codes,
           count(DISTINCT sup.id)                    AS supplier_count,
           array_remove(array_agg(DISTINCT sv.external_variant_id), NULL) AS external_variant_ids,
           array_remove(array_agg(DISTINCT r.source_currency), NULL) AS source_currencies,
           sum(r.unit_cost * r.quantity)             AS cost_in_target,
           count(*)                                  AS parts,
           count(r.unit_cost)                        AS priced_parts,
           -- 源 SKU 下架的成分（022）：这一行还在，只是没有价。
           count(*) FILTER (WHERE COALESCE(sv.status, 'inactive') <> 'active') AS retired_parts,
           -- 在架但当天没报价的成分
           count(*) FILTER (WHERE sv.status = 'active' AND r.net_price IS NULL) AS missing_price_parts,
           -- 在架、有报价，但折算不到目标币种
           count(*) FILTER (WHERE sv.status = 'active' AND r.net_price IS NOT NULL AND r.unit_cost IS NULL) AS fx_fail_parts,
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
      LEFT JOIN supplier_variant sv ON sv.id = r.supplier_variant_id
      LEFT JOIN supplier_product sp ON sp.id = sv.supplier_product_id
      LEFT JOIN supplier sup ON sup.id = sp.supplier_id
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
           -- 成分缺一个，成本就不是这个套餐的成本：留着会让运营拿一个残缺套餐的钱
           -- 去对账。宁可空着 —— 空着就是「这个套餐现在没有价」。
           CASE WHEN rf.retired_parts > 0 THEN NULL ELSE rf.cost_in_target END AS cost_in_target,
           (rf.priced_parts = rf.parts
            AND rf.retired_parts = 0
            AND rf.session_count = 1
            AND rf.distinct_suppliers = 1
            AND rf.locked_parts = 0
            AND rf.mode <> 'per_group')             AS can_fulfil,
           rf.candidates,
           ARRAY_REMOVE(ARRAY[
               CASE WHEN rf.retired_parts > 0        THEN '成分的源 SKU 已下架' END,
               CASE WHEN rf.missing_price_parts > 0   THEN '成分当天没有报价' END,
               CASE WHEN rf.fx_fail_parts > 0         THEN '成分成本折算不到目标币种' END,
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
           array_remove(array_agg(DISTINCT sup.code), NULL) AS supplier_codes,
           count(DISTINCT sup.id)                     AS supplier_count,
           array_remove(array_agg(DISTINCT sv.external_variant_id), NULL) AS external_variant_ids,
           array_remove(array_agg(DISTINCT b.source_currency), NULL) AS source_currencies,
           max(b.set_cost)                            AS cost_in_target,
           count(*)                                   AS parts,
           count(b.set_cost)                          AS priced_parts,
           -- 整套的源 SKU 下架（022）：形态行留着，只是没有整套价。
           count(*) FILTER (WHERE COALESCE(sv.status, 'inactive') <> 'active') AS retired_parts,
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
      LEFT JOIN supplier_variant sv ON sv.id = b.supplier_variant_id
      LEFT JOIN supplier_product sp ON sp.id = sv.supplier_product_id
      LEFT JOIN supplier sup ON sup.id = sp.supplier_id
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
            AND bf.retired_parts = 0
            AND bf.units > 0
            AND bf.session_count = 1
            AND bf.locked_parts = 0
            AND bf.covers_components
            AND bf.source_ticket_type_id IS NOT NULL
            AND bf.mode <> 'per_group')             AS can_fulfil,
           bf.candidates,
           ARRAY_REMOVE(ARRAY[
               CASE WHEN bf.retired_parts > 0        THEN '套装的源 SKU 已下架' END,
               CASE WHEN bf.retired_parts = 0 AND bf.priced_parts < bf.parts
                    THEN '套装当天没有源侧报价' END,
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
    '三种异构供给形态（单张 / 配方 / 套装）在同一张表上对齐：一个可售单元 × 一天 × 一个渠道 × 一种形态（022：源 SKU 下架时形态仍然在，只是不可售并说明缺口）';
-- -----------------------------------------------------------------------------
-- ④ 不变量 105-107
--
-- 105 配方的成分不许因为源 SKU 下架而消失
-- 106 成分的源 SKU 下架时配方套餐不许还能卖
-- 107 套装的源 SKU 下架时套装不许还能卖
-- -----------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_supply_form_shrink_022 AS
WITH raw(seq, check_name, actual) AS (
    -- 105：配方的成分不许因为源 SKU 下架而消失。
    --
    -- 声明过的成分就是配方里那些行。解析出来的成分必须还是那些行 ——
    -- 少一个，配方就静悄悄地变成了另一个套餐：
    -- C 端写着「2 成人 + 1 儿童」，收银台按剩下的那个成分收钱，
    -- 闸机那边只放一个人进来。收 3 份入场的钱、出 1 份票。
    --
    -- 判定两边都取自事实：一边是配方声明（supplier_variant_composition），
    -- 一边是库里的唯一解析实现（fn_combo_components）。
    SELECT 105,
           '配方的成分不许因为源 SKU 下架而消失',
           (SELECT count(*)
              FROM (SELECT DISTINCT product_variant_id
                      FROM supplier_variant_composition
                     WHERE status = 'active') d
              CROSS JOIN LATERAL (
                    SELECT COALESCE(min(pc.date), current_date) AS date
                      FROM price_calendar pc
                     WHERE pc.product_variant_id = d.product_variant_id
                       AND pc.status = 'active') dt
              CROSS JOIN LATERAL (
                    SELECT count(*) AS resolved
                      FROM fn_combo_components(d.product_variant_id, dt.date,
                                               fn_default_context_channel(),
                                               fn_base_currency()) cc) r
              CROSS JOIN LATERAL (
                    SELECT count(*) AS declared
                      FROM supplier_variant_composition c
                     WHERE c.product_variant_id = d.product_variant_id
                       AND c.status = 'active') dec
             WHERE r.resolved <> dec.declared)
    UNION ALL
    -- 106：成分的源 SKU 下架时，配方套餐不许还能卖。
    --
    -- 两边都要守住：对照视图不许说「能供」，定价函数不许给出价格。
    -- 只守一边的话，运营看到一个「能供」的形态就敢上架，
    -- 或者收银台按一个已经配不齐的套餐收钱。
    SELECT 106,
           '成分的源 SKU 下架时配方套餐不许还能卖',
           (SELECT count(*)
              FROM v_variant_supply_forms f
             WHERE f.supply_form = 'recipe'
               AND EXISTS (SELECT 1
                             FROM supplier_variant_composition c
                             LEFT JOIN supplier_variant sv ON sv.id = c.supplier_variant_id
                            WHERE c.product_variant_id = f.product_variant_id
                              AND c.status = 'active'
                              AND COALESCE(sv.status, 'inactive') <> 'active')
               AND (f.can_fulfil
                    OR EXISTS (SELECT 1
                                 FROM fn_price_variant(f.product_variant_id, f.date,
                                                      f.channel_id, f.channel_id))))
    UNION ALL
    -- 107：套装的源 SKU 下架时，套装不许还能卖。
    --
    -- 与 106 同一件事的另一种形态：源侧把整套当一个 SKU 卖，
    -- 那个 SKU 下架 = 我们卖不出这套 —— 但形态必须继续看得见。
    SELECT 107,
           '套装的源 SKU 下架时套装不许还能卖',
           (SELECT count(*)
              FROM v_variant_supply_forms f
             WHERE f.supply_form = 'bundle'
               AND EXISTS (SELECT 1
                             FROM supplier_variant_bundle svb
                             LEFT JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id
                            WHERE svb.product_variant_id = f.product_variant_id
                              AND svb.status = 'active'
                              AND COALESCE(sv.status, 'inactive') <> 'active')
               AND (f.can_fulfil
                    OR EXISTS (SELECT 1
                                 FROM fn_price_variant(f.product_variant_id, f.date,
                                                      f.channel_id, f.channel_id))))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_supply_form_shrink_022 IS
    '供给形态不许缩小侧不变量（105-107）：成分不许消失、源 SKU 下架时形态不许还能卖';

-- -----------------------------------------------------------------------------
-- 总表：加进 105 / 106 / 107
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
UNION ALL SELECT v_invariant_checks_supply_forms_021.seq, v_invariant_checks_supply_forms_021.check_name, v_invariant_checks_supply_forms_021.expected, v_invariant_checks_supply_forms_021.actual, v_invariant_checks_supply_forms_021.passed, v_invariant_checks_supply_forms_021.result FROM v_invariant_checks_supply_forms_021
UNION ALL SELECT v_invariant_checks_supply_form_shrink_022.seq, v_invariant_checks_supply_form_shrink_022.check_name, v_invariant_checks_supply_form_shrink_022.expected, v_invariant_checks_supply_form_shrink_022.actual, v_invariant_checks_supply_form_shrink_022.passed, v_invariant_checks_supply_form_shrink_022.result FROM v_invariant_checks_supply_form_shrink_022;
