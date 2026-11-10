-- =====================================================================================
-- 023 可履约源数：一个口径，三种形态都算得对
-- =====================================================================================
-- 背景
--   C 端的日历格子带一个 source_count，注释写的是「有几个源能履约这个变体」。
--   C 端模型里那一列是给前端的关键信号：只有 1 个源的组合没有备源，源挂了要提前知道
--   （docs/c-end-model.md §3.3）。
--
--   原来这一列只在**单张**形态上算得对：
--     刷新作业的 source_count 是「源映射 × 当天的源侧报价」的行数 ——
--     而配方与套装按设计**没有源映射**（不变量 81：组合不许直接挂源映射），
--     所以它们的格子一律是 0。
--   0 的意思是「一个源都供不了」——
--   而这些组合在对照视图里明明 can_fulfil = true、supplier_count = 1、
--   售价也摆在那里。C 端读到的却是「0 个源」。
--   一个可售的套餐说成「没有源能供」，前端就该按没有供给处理：要么下架，要么报缺货。
--
-- 口径（023 定死）
--   「有几个源能供这个可售单元（这一天、这个渠道）」由一个函数算：
--   fn_variant_supply_source_count(variant, date, channel)。
--   三种形态各按自己的供给路径算，不是三份实现：
--     单张：路由能选出的源（fn_route_candidates —— 绑定 + 覆盖 + 当天有价 + 汇率可得）。
--           选源与定价同源（硬约束 15）：能选出来的源就是能供的源。
--     配方：成分的源 SKU（成分当天有价才算能供）——
--           一个配方由同一个源的几个 SKU 拼出来，那个源仍然只有 1 个。
--     套装：源侧那个整套 SKU 的源（017：套装的源就是那个整套 SKU）。
--   源数不是成分数：2 份成人 + 1 份儿童是 3 个成分、1 个源。
--   源数不是价格行数：同一个源当天有两行报价也还是 1 个源。
--
-- 这次改了什么
--   1. 新增 fn_variant_supply_source_count（唯一实现）。
--   2. 整体替换 fn_refresh_read_models（日历格子的 source_count 改走这个函数）。
--   3. 整体替换 fn_sync_combo_calendar（它原来数的是成分行数，更离谱）。
--   4. 不变量 108：日历的可履约源数必须等于这个函数算出来的数 ——
--      谁再把 source_count 写回「源映射 × 报价行数」，当场红。
--
-- 没改什么（刻意）
--   v_variant_supply_forms 的 supplier_count 不动：
--   那一列答的是「这个形态由哪几个源组成」（声明层面 —— 源下架了也还数着它，
--   那是 022 刻意保留的事实），日历的 source_count 答的是「这一天有几个源能供」。
--   两件事，两个名字，两个口径。混成一个数才是把两件事搅在一起。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 唯一实现：几个源能供这个可售单元（这一天、这个渠道）
--
-- 返回的是**源**（供应商），不是源 SKU、不是成分、不是价格行。
-- 三种形态的供给路径不同，所以各按自己的路径算，但只有这一个出处。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_variant_supply_source_count(
    p_variant_id bigint,
    p_date date,
    p_channel_id bigint
)
RETURNS int
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        -- 套装：源侧把整套当一个 SKU 卖，那一个 SKU 的源就是它的供给（017）。
        WHEN EXISTS (SELECT 1
                       FROM supplier_variant_bundle svb
                      WHERE svb.product_variant_id = p_variant_id
                        AND svb.status = 'active')
            THEN (SELECT count(DISTINCT bc.supplier_id)
                    FROM fn_bundle_components(p_variant_id, p_date, p_channel_id,
                                              fn_price_row_currency(p_channel_id)) bc
                   WHERE bc.set_cost IS NOT NULL)
        -- 配方：成分的源 SKU。成分当天有价才算能供。
        WHEN EXISTS (SELECT 1
                       FROM supplier_variant_composition svc
                      WHERE svc.product_variant_id = p_variant_id
                        AND svc.status = 'active')
            THEN (SELECT count(DISTINCT cc.supplier_id)
                    FROM fn_combo_components(p_variant_id, p_date, p_channel_id,
                                             fn_price_row_currency(p_channel_id)) cc
                   WHERE cc.unit_cost IS NOT NULL)
        -- 单张：路由能选出来的源就是能供的源（硬约束 15：选源与定价同源）。
        ELSE (SELECT count(DISTINCT sup.id)
                FROM fn_route_candidates(p_variant_id, p_date, p_channel_id,
                                         fn_price_row_currency(p_channel_id)) rc
                JOIN supplier_product sp ON sp.id = rc.supplier_product_id
                JOIN supplier sup ON sup.id = sp.supplier_id)
    END::int;
$$;

COMMENT ON FUNCTION fn_variant_supply_source_count(bigint, date, bigint) IS
    '有几个源能供这个可售单元（这一天、这个渠道）：单张按路由选出的源、配方按成分的源 SKU、套装按整套那个 SKU；一个配方由一个源的几个 SKU 拼出来时仍然只有 1 个源';

-- -------------------------------------------------------------------------------------
-- ② 刷新作业：日历格子的可履约源数改走唯一实现
--
-- 015 已经整体替换过 fn_refresh_read_models（返回类型多了一个 OUT 参数），
-- 这里签名不变，CREATE OR REPLACE 就够（改函数体不改返回类型）。
-- 正文与 015 逐字相同，只改了 source_count 那一处。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_refresh_read_models()
RETURNS TABLE(cards_updated INT, variant_cells_updated INT, variant_facts_updated INT)
LANGUAGE plpgsql AS $$
DECLARE
  v_cards    INT := 0;
  v_variants INT := 0;
  v_facts    INT := 0;
BEGIN
  -- ① 卡片：起价 / 划线价 / 最近可售日 / 可售天数
  --    可见价格集 = 该渠道自己的售价行 + 默认行（channel_id IS NULL）。
  --    取价时渠道专属行优先；没有专属行才用默认行（与漂移检测同口径）。
  WITH win AS (
    SELECT card.channel_id,
           card.product_id,
           card.locale,
           MIN(pc.sell_price) FILTER (WHERE pc.channel_id = card.channel_id) AS chan_min,
           MIN(pc.sell_price) FILTER (WHERE pc.channel_id IS NULL)       AS base_min,
           MIN(pc.date)       FILTER (WHERE pc.channel_id = card.channel_id) AS chan_first,
           MIN(pc.date)       FILTER (WHERE pc.channel_id IS NULL)       AS base_first,
           COUNT(DISTINCT pc.date) FILTER (WHERE pc.channel_id = card.channel_id) AS chan_days,
           COUNT(DISTINCT pc.date) FILTER (WHERE pc.channel_id IS NULL)       AS base_days
      FROM c_product_card card
      LEFT JOIN price_calendar pc
        ON pc.product_id = card.product_id
       AND pc.status = 'active'
       AND pc.date >= current_date
       AND pc.date <= current_date + 30
       AND (pc.channel_id = card.channel_id OR pc.channel_id IS NULL)
       -- 加购件不是「入门价」：快速通行证 ¥398 不该出现在起价里。
       AND NOT EXISTS (SELECT 1 FROM product_variant pv
                        WHERE pv.id = pc.product_variant_id AND pv.variant_role = 'addon')
     GROUP BY card.channel_id, card.product_id, card.locale
  ), picked AS (
    SELECT win.*,
           -- 划线价必须和起价取自同一行，否则会出现「起价按 A、划线价按 B」。
           (SELECT pc.list_price
              FROM price_calendar pc
             WHERE pc.product_id = win.product_id
               AND pc.status = 'active'
               AND pc.date >= current_date
               AND pc.date <= current_date + 30
               AND (CASE WHEN win.chan_min IS NOT NULL
                         THEN pc.channel_id = win.channel_id
                         ELSE pc.channel_id IS NULL END)
               AND NOT EXISTS (SELECT 1 FROM product_variant pv
                                WHERE pv.id = pc.product_variant_id AND pv.variant_role = 'addon')
             ORDER BY pc.sell_price, pc.date
             LIMIT 1) AS list_price
      FROM win
  )
  UPDATE c_product_card c
     SET from_price         = COALESCE(p.chan_min, p.base_min),
         list_price         = p.list_price,
         next_available_date = CASE WHEN p.chan_min IS NOT NULL THEN p.chan_first ELSE p.base_first END,
         available_days     = CASE WHEN p.chan_min IS NOT NULL THEN p.chan_days ELSE p.base_days END,
         synced_at          = now()
    FROM picked p
   WHERE c.channel_id = p.channel_id
     AND c.product_id = p.product_id
     AND c.locale = p.locale;
  GET DIAGNOSTICS v_cards = ROW_COUNT;

  -- ② 变体日历：当日价格区间 + 可履约源数 + 有效期终点
  UPDATE c_variant_calendar cvc
     SET price_min    = t.price_min,
         price_max    = t.price_max,
         source_count = t.source_count,
         valid_to     = t.valid_to,
         synced_at    = now()
    FROM (
      SELECT cvc2.channel_id,
             cvc2.product_variant_id,
             cvc2.date,
             MIN(pc.sell_price) AS price_min,
             MAX(pc.sell_price) AS price_max,
             -- 可履约源数走唯一实现（023）：单张 / 配方 / 套装三种形态各按自己的口径算。
             fn_variant_supply_source_count(cvc2.product_variant_id, cvc2.date, cvc2.channel_id) AS source_count,
             -- 有效期终点：格子日期 + 这个变体有效几天
             cvc2.date + fn_variant_validity_days(cvc2.product_variant_id) AS valid_to
        FROM c_variant_calendar cvc2
        JOIN LATERAL (
          SELECT pc.sell_price
            FROM price_calendar pc
           WHERE pc.product_variant_id = cvc2.product_variant_id
             AND pc.date = cvc2.date
             AND pc.status = 'active'
             AND (pc.channel_id = cvc2.channel_id OR pc.channel_id IS NULL)
        ) pc ON true
       GROUP BY cvc2.channel_id, cvc2.product_variant_id, cvc2.date
    ) t
   WHERE cvc.channel_id = t.channel_id
     AND cvc.product_variant_id = t.product_variant_id
     AND cvc.date = t.date;
  GET DIAGNOSTICS v_variants = ROW_COUNT;

  -- ③ 变体事实：这个变体差在哪（人群 / 轴取值 / 有效天数 / 退款口径 / 组合构成）
  --
  -- 范围：只写「这个渠道的日历上有格子」的变体 ——
  -- 日历是 C 端的入口，没有格子的变体本来就不该出现在这个渠道。
  --
  -- 事实来源：v_variant_comparison（差异的唯一汇总口径）。
  INSERT INTO c_variant_facts (channel_id, product_variant_id, product_id, variant_code, title,
                               audience, axes, valid_days, refundable, refund_fee_percent,
                               is_combo, combo_audience, component_count,
                               synced_at)
  SELECT DISTINCT ON (cvc.channel_id, cvc.product_variant_id)
         cvc.channel_id,
         cvc.product_variant_id,
         cmp.product_id,
         cmp.variant_code,
         cmp.variant_title,
         cmp.audience,
         COALESCE(cmp.axes, '{}'::jsonb),
         cmp.valid_days,
         cmp.refundable,
         cmp.refund_fee_percent,
         cmp.is_combo,
         COALESCE(cmp.combo_audience, ''),
         cmp.component_count,
         now()
    FROM c_variant_calendar cvc
    JOIN v_variant_comparison cmp ON cmp.product_variant_id = cvc.product_variant_id
   ORDER BY cvc.channel_id, cvc.product_variant_id
  ON CONFLICT (channel_id, product_variant_id) DO UPDATE
     SET product_id         = EXCLUDED.product_id,
         variant_code       = EXCLUDED.variant_code,
         title              = EXCLUDED.title,
         audience           = EXCLUDED.audience,
         axes               = EXCLUDED.axes,
         valid_days         = EXCLUDED.valid_days,
         refundable         = EXCLUDED.refundable,
         refund_fee_percent = EXCLUDED.refund_fee_percent,
         is_combo           = EXCLUDED.is_combo,
         combo_audience     = EXCLUDED.combo_audience,
         component_count    = EXCLUDED.component_count,
         synced_at          = EXCLUDED.synced_at;
  GET DIAGNOSTICS v_facts = ROW_COUNT;

  -- ④ 组合构成：成分来自 fn_variant_composition（唯一读法）
  --
  -- 范围与事实一致：这个渠道的日历上有格子的组合变体。
  INSERT INTO c_variant_composition (channel_id, product_variant_id, component_variant_id,
                                     sequence, quantity, audience_code, valid_days, title,
                                     synced_at)
  SELECT DISTINCT ON (cvc.channel_id, cvc.product_variant_id, comp.component_variant_id)
         cvc.channel_id,
         cvc.product_variant_id,
         comp.component_variant_id,
         comp.sort_order,
         comp.quantity,
         comp.audience_code,
         comp.valid_days,
         comp.variant_title,
         now()
    FROM c_variant_calendar cvc
    CROSS JOIN LATERAL fn_variant_composition(cvc.product_variant_id) comp
   ORDER BY cvc.channel_id, cvc.product_variant_id, comp.component_variant_id
  ON CONFLICT (channel_id, product_variant_id, component_variant_id) DO UPDATE
     SET sequence      = EXCLUDED.sequence,
         quantity      = EXCLUDED.quantity,
         audience_code = EXCLUDED.audience_code,
         valid_days    = EXCLUDED.valid_days,
         title         = EXCLUDED.title,
         synced_at     = EXCLUDED.synced_at;

  -- ⑤ 清掉已经没有格子的旧事实与旧构成
  --    读模型可重建：日历上撤掉的变体，事实也该撤掉，
  --    不然 C 端会看到一个「有事实、没格子」的幽灵变体。
  DELETE FROM c_variant_facts f
   WHERE NOT EXISTS (SELECT 1
                       FROM c_variant_calendar cvc
                      WHERE cvc.channel_id = f.channel_id
                        AND cvc.product_variant_id = f.product_variant_id);

  DELETE FROM c_variant_composition c
   WHERE NOT EXISTS (SELECT 1
                       FROM c_variant_facts f
                      WHERE f.channel_id = c.channel_id
                        AND f.product_variant_id = c.product_variant_id);

  RETURN QUERY SELECT v_cards, v_variants, v_facts;
END;
$$;

COMMENT ON FUNCTION fn_refresh_read_models() IS
    'C 端读模型刷新作业：卡片起价、变体日历格子（含有效期终点）、变体差异事实、组合构成；口径与 v_c_readmodel_drift 一致';

-- -------------------------------------------------------------------------------------
-- ③ 组合日历同步：格子的可履约源数也走唯一实现
--
-- 017 已经整体替换过 fn_sync_combo_calendar（把套装并进同一个函数），
-- 这里签名不变，CREATE OR REPLACE 就够。正文与 017 逐字相同，只改了 source_count 那一处。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_combo_calendar()
 RETURNS TABLE(price_rows integer, cells integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_price_rows INT := 0;
  v_cells      INT := 0;
BEGIN
  -- ① 组合的售价行
  --
  -- 日期与场次：成分的售价行。
  -- 「所有成分都在同一天、同一场次」才算一份套餐 ——
  -- 少一个成分就是缺一份货（013 的口径），多一个场次就是两张套餐。
  INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency,
                              cost_price, cost_source_product_id, sell_price, list_price,
                              discount_pct, rule, status, source, synced_at, product_variant_id,
                              price_locked, fx_rate, fx_as_of)
  SELECT c.product_id, c.session_id, NULL, NULL, c.date, q.currency,
         q.cost_price, q.supplier_product_id, q.sell_price, q.list_price,
         q.discount_pct, q.rule, 'active', 'calc', now(), c.variant_id,
         q.price_locked, q.fx_rate, q.fx_as_of
    FROM (
      -- 配方组合：日期来自成分的售价行。
      -- 「所有成分都在同一天、同一场次」才算一份套餐 ——
      -- 少一个成分就是缺一份货（013 的口径），多一个场次就是两张套餐。
      SELECT combo.id AS variant_id,
             combo.product_id,
             pc.date,
             pc.session_id
        FROM product_variant combo
        JOIN product_variant_relation r
          ON r.parent_variant_id = combo.id
         AND r.relation_type = 'included'
        JOIN price_calendar pc
          ON pc.product_variant_id = r.child_variant_id
         AND pc.status = 'active'
         AND pc.session_id IS NOT NULL
       WHERE combo.variant_role = 'combo'
       GROUP BY combo.id, combo.product_id, pc.date, pc.session_id
      HAVING count(DISTINCT r.child_variant_id) = (
               SELECT count(*)
                 FROM product_variant_relation r2
                WHERE r2.parent_variant_id = combo.id
                  AND r2.relation_type = 'included')
      UNION
      -- 套装组合（017）：日期来自套装自己的源价行。
      --
      -- 套装的成分可能压根没有单独的售价行（源侧只卖整套），
      -- 所以日期不能只从成分那儿取。
      SELECT combo.id AS variant_id,
             combo.product_id,
             spc.date,
             ps.id
        FROM product_variant combo
        JOIN supplier_variant_bundle svb
          ON svb.product_variant_id = combo.id
         AND svb.status = 'active'
        JOIN supplier_price_calendar spc
          ON spc.supplier_variant_id = svb.supplier_variant_id
         AND spc.product_variant_id = combo.id
         AND spc.status = 'available'
        JOIN LATERAL (
              SELECT p2.id
                FROM product_session p2
               WHERE p2.product_id = combo.product_id
                 AND p2.session_date = spc.date
                 AND p2.status = 'active'
               ORDER BY p2.id
               LIMIT 1) ps ON true
       WHERE combo.variant_role = 'combo'
    ) c
    CROSS JOIN LATERAL fn_price_variant(c.variant_id, c.date, fn_default_context_channel(), NULL) q
   WHERE q.sell_price IS NOT NULL
  ON CONFLICT (product_variant_id, date, COALESCE(channel_id, 0), COALESCE(session_id, 0))
    WHERE product_variant_id IS NOT NULL
  DO UPDATE SET cost_price             = EXCLUDED.cost_price,
                cost_source_product_id = EXCLUDED.cost_source_product_id,
                sell_price             = EXCLUDED.sell_price,
                list_price             = EXCLUDED.list_price,
                discount_pct           = EXCLUDED.discount_pct,
                rule                   = EXCLUDED.rule,
                price_locked           = EXCLUDED.price_locked,
                fx_rate                = EXCLUDED.fx_rate,
                fx_as_of               = EXCLUDED.fx_as_of,
                status                 = 'active',
                source                 = 'calc',
                synced_at              = now();
  GET DIAGNOSTICS v_price_rows = ROW_COUNT;

  -- ② 日历格子：组合在哪些渠道上 = 它的商品在哪些渠道上架
  --
  -- 价格直接取组合自己的售价行（刷新作业算的是同一个值，同一个出处）。
  INSERT INTO c_variant_calendar (channel_id, product_variant_id, date,
                                  price_min, price_max, status, source_count, synced_at)
  SELECT cl.channel_id,
         pc.product_variant_id,
         pc.date,
         MIN(pc.sell_price),
         MAX(pc.sell_price),
         'available',
         -- 可履约源数：源数不是成分数 —— 一个配方由一个源的三个 SKU 拼出来，
         -- 那个源仍然只有 1 个（023 的唯一实现）。
         fn_variant_supply_source_count(pc.product_variant_id, pc.date, cl.channel_id),
         now()
    FROM price_calendar pc
    JOIN product_variant pv ON pv.id = pc.product_variant_id
                          AND pv.variant_role = 'combo'
    JOIN channel_listing cl ON cl.product_id = pv.product_id
                           AND cl.status = 'online'
   WHERE pc.status = 'active'
     AND pc.sell_price IS NOT NULL
     AND pc.channel_id IS NULL
   GROUP BY cl.channel_id, pc.product_variant_id, pc.date
  ON CONFLICT (channel_id, product_variant_id, date)
  DO UPDATE SET price_min    = EXCLUDED.price_min,
                price_max    = EXCLUDED.price_max,
                status       = 'available',
                source_count = EXCLUDED.source_count,
                synced_at    = now();
  GET DIAGNOSTICS v_cells = ROW_COUNT;

  RETURN QUERY SELECT v_price_rows, v_cells;
END;
$function$;
-- -------------------------------------------------------------------------------------
-- ③ 不变量 108：日历的可履约源数必须等于唯一实现算出来的数
--
-- 这一条守着「配方 / 套装的日历不许写 0」：
--   写 0 = 「一个源都供不了」，而这些组合明明在卖。
--   谁把 source_count 改回「源映射 × 报价行数」（配方与套装没有源映射 → 0），
--   这里当场红。
--
-- 也守着读模型不许与主数据分叉（跟第 76 条一个道理）：
--   刷新作业漏跑时，日历里躺着的是旧数，这里当场红。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_supply_source_count_023 AS
WITH raw (seq, check_name, actual) AS (
    SELECT 108,
           '日历的可履约源数必须等于供给口径算出来的源数',
           (SELECT count(*)
              FROM c_variant_calendar cvc
             WHERE cvc.source_count
                   <> fn_variant_supply_source_count(cvc.product_variant_id,
                                                     cvc.date,
                                                     cvc.channel_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_supply_source_count_023 IS
    '可履约源数侧不变量（108）：日历的可履约源数必须等于唯一实现算出来的源数';

-- -------------------------------------------------------------------------------------
-- ④ 总表：加进 108
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
UNION ALL SELECT v_invariant_checks_supply_source_count_023.seq, v_invariant_checks_supply_source_count_023.check_name, v_invariant_checks_supply_source_count_023.expected, v_invariant_checks_supply_source_count_023.actual, v_invariant_checks_supply_source_count_023.passed, v_invariant_checks_supply_source_count_023.result FROM v_invariant_checks_supply_source_count_023;
