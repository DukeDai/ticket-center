-- =====================================================================================
-- 015_combo_c_end.sql — 组合在 C 端读模型里画得出来（异构融合方向 B 的最后一里）
-- =====================================================================================
-- 为什么有这一段：
--   013 让组合能一路走到成交（定价 → 预订 → 出券 → 退款），
--   014 把预订的单位改成源 SKU（参数化源下成人与儿童是同一个源 SKU）。
--   但 C 端还是画不出组合，三处都缺：
--
--     1. 组合没有 price_calendar 行 → 日历格子没有价格，卡片起价也不含它；
--     2. 组合的有效期走 fn_variant_validity_days 的兜底（1 天）——
--        一张「2 日成人 + 1 日儿童」的套餐会被标成只管一天，
--        客户第二天拿着票到门口才发现进不去（010 想根治的正是这个）；
--     3. 组合的构成（几份成人、几份儿童、各自几天）在 C 端没有落脚点：
--        c_variant_facts.audience 是空的（组合本来就没有单一人群），
--        前端拿到一个空人群就不知道这是一张家庭套餐。
--
--   这三件事都是**异构差异走到最后一里**的问题：
--   组合是「若干可售单元的配方」，它的差异不在自己身上，在成分身上。
--   所以口径是：组合的窗口 = 成分窗口的并集；组合的构成 = 成分的清单。
--
-- 这一段的口径：
--   1. 组合的成分只有一个读法：fn_variant_composition（读规范侧的成分声明）。
--      源侧的配方（supplier_variant_composition）回答的是「哪个源 SKU 顶哪份成分」，
--      回答的是成本与出票，不回答「这张套餐里有什么」。
--   2. 组合的有效期 = 成分有效期的并集 = 最长的那个（fn_variant_validity_days 扩展）。
--      组合自己没有 valid_days —— valid_days 住在轴选项上（010 的口径），
--      组合没有轴，所以它的天数只能由成分推出来。取最长而不是取最短：
--      少报一天 = 客户白丢一天；多报一天 = 客户按最长的那张票理解，不会吃亏。
--   3. 构成是结构化事实（人群编码 + 份数 + 各自的天数），不是拼出来的文案 ——
--      展示文案要 locale（硬约束 9），拼出来的一句话就成了第二份没有 locale 的文案。
--   4. 组合的价格只有一个出处：定价函数（fn_price_variant 的组合分支）。
--      price_calendar 行由 fn_sync_combo_calendar 建，不许手写。
--   5. 组合的日历格子由「成分当天可售」推导 ——
--      组合在任何源侧都没有对应的商品条目（它是我们自己的配方），
--      源侧同步作业看不见它，所以格子只能由组合自己推导。
--
-- 已知缺口（写进 SPEC §5.13，不假装已经支持）：
--   组合的展示文案还没有 locale 行级表 —— C 端拿到的是人群编码与份数，
--   「2 成人 + 1 儿童」这句中文要么前端拼，要么后面补一张带 locale 的文案表。
--   组合的日历格子目前由本文件同步，不跟普通变体走同一条上架/库存同步路径 ——
--   普通变体的格子由上架与库存同步作业写，那个作业还没实现。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 组合的成分读法（唯一实现）
--
-- 读的是规范侧的成分声明（product_variant_relation，relation_type='included'）：
-- 「这张套餐由哪些可售单元组成、各几份」。
-- 源侧的配方（supplier_variant_composition）回答的是另一件事：
-- 「这个成分由哪个源 SKU 顶」—— 那是成本与出票的事，不是「套餐里有什么」。
--
-- 返回的 audience 是**编码**（adult / child），不是文案：
-- 文案要 locale，编码不需要（硬约束 9）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_variant_composition(p_variant_id BIGINT)
RETURNS TABLE (
    component_variant_id BIGINT,
    quantity             NUMERIC,
    sort_order           INT,
    audience_code        TEXT,
    valid_days           INT,
    variant_title        TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT r.child_variant_id,
           r.quantity,
           r.sort_order,
           COALESCE(tt.code, ''),
           fn_variant_validity_days(r.child_variant_id),
           COALESCE(cpv.title, '')
      FROM product_variant_relation r
      JOIN product_variant cpv ON cpv.id = r.child_variant_id
      LEFT JOIN ticket_type tt ON tt.id = cpv.ticket_type_id
     WHERE r.parent_variant_id = p_variant_id
       AND r.relation_type = 'included'
     ORDER BY r.sort_order, r.id;
$$;

COMMENT ON FUNCTION fn_variant_composition(BIGINT) IS
    '组合的成分读法（唯一实现）：这张套餐由哪些可售单元组成、各几份、各管几天；读规范侧的成分声明';

-- -------------------------------------------------------------------------------------
-- ② 有效期：组合 = 成分窗口的并集
--
-- 010 把有效天数定在轴选项上，并明写「不许写死 +1」。
-- 组合没有轴（它的差异在成分身上），所以组合的天数只能由成分推出来。
--
-- 为什么取最长：
--   成分都是同一个场次、同一日起算（013 的口径：成分不在同一场次就判不可售），
--   所以成分的窗口都是从同一天开始的 [当天, 当天+N)，
--   它们的并集就是最长的那个。取最长 = 不让客户白丢一天。
--
-- 为什么递归调用自己：
--   成分要是组合，窗口要按它的成分再推一遍。
--   组件不许嵌套（触发器 fn_guard_included_relation + 不变量 79），
--   所以这里最多一层；真要是被绕过了，PostgreSQL 会报栈溢出（响亮地失败，不是静默算错）。
--
-- 非组合变体的口径一个字没动（还是轴选项上的 valid_days，取不到按 1 天）。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_variant_validity_days(p_variant_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN EXISTS (SELECT 1
                            FROM product_variant_relation r
                           WHERE r.parent_variant_id = p_variant_id
                             AND r.relation_type = 'included')
             THEN (SELECT MAX(fn_variant_validity_days(r.child_variant_id))
                     FROM product_variant_relation r
                    WHERE r.parent_variant_id = p_variant_id
                      AND r.relation_type = 'included')
             ELSE COALESCE((SELECT MAX(ao.valid_days)
                              FROM product_variant_option pvo
                              JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
                             WHERE pvo.product_variant_id = p_variant_id), 1)
           END;
$$;

COMMENT ON FUNCTION fn_variant_validity_days(BIGINT) IS
    '可售单元的有效期天数（连续几天，从场次当天算起）：普通变体读轴选项上的 valid_days，组合取成分窗口的并集（最长）';

-- -------------------------------------------------------------------------------------
-- ③ 差异对照视图加上组合的列
--
-- CREATE OR REPLACE VIEW 只能往末尾加列，所以这四列加在最后。
-- 加的是结构化事实（份数、人群编码、各自的天数），不是拼出来的文案。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_variant_comparison AS
SELECT pv.id AS product_variant_id,
       pv.variant_code,
       pv.title AS variant_title,
       pv.variant_role,
       pv.status AS variant_status,
       p.product_code,
       p.title AS product_title,
       COALESCE(p.country_code, '') AS country_code,
       COALESCE(tt.code, '') AS audience,
       (SELECT jsonb_object_agg(ax.axis_code, ao.option_code)
          FROM product_variant_option pvo
          JOIN product_axis ax ON ax.id = pvo.axis_id
          JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
         WHERE pvo.product_variant_id = pv.id) AS axes,
       fn_variant_validity_days(pv.id) AS valid_days,
       COALESCE(p.validity_rule->>'single_use', '') AS single_use,
       COALESCE(p.validity_rule->>'timezone', '') AS timezone,
       COALESCE((p.refund_policy->>'refundable')::boolean, FALSE) AS refundable,
       COALESCE((p.refund_policy->>'fee_percent')::numeric, 0) AS refund_fee_percent,
       COALESCE((p.refund_policy->>'cutoff_hours')::int, 0) AS refund_cutoff_hours,
       COALESCE((p.attributes->>'duration_minutes')::int, 0) AS duration_minutes,
       COALESCE((p.attributes->'age_limit'->>'min')::int, 0) AS age_limit_min,
       (SELECT count(*)
          FROM supplier_variant_mapping svm
         WHERE svm.product_variant_id = pv.id AND svm.status = 'active') AS source_count,
       (SELECT count(*)
          FROM supplier_variant_mapping svm
         WHERE svm.product_variant_id = pv.id AND svm.status = 'active'
           AND fn_variant_covered(svm.coverage, pv.id)) AS fulfilable_source_count,
       (SELECT array_agg(DISTINCT sup.code ORDER BY sup.code)
          FROM supplier_variant_mapping svm
          JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
          JOIN supplier_product sp ON sp.id = sv.supplier_product_id
          JOIN supplier sup ON sup.id = sp.supplier_id
         WHERE svm.product_variant_id = pv.id AND svm.status = 'active'
           AND fn_variant_covered(svm.coverage, pv.id)) AS suppliers,
       p.id AS product_id,
       -- ↓ 015 新增：组合的构成（结构化事实）
       (SELECT count(*)
          FROM product_variant_relation r
         WHERE r.parent_variant_id = pv.id AND r.relation_type = 'included') AS component_count,
       EXISTS (SELECT 1
                 FROM product_variant_relation r
                WHERE r.parent_variant_id = pv.id AND r.relation_type = 'included') AS is_combo,
       (SELECT string_agg(DISTINCT comp.audience_code, ',' ORDER BY comp.audience_code)
          FROM fn_variant_composition(pv.id) comp) AS combo_audience,
       (SELECT jsonb_agg(jsonb_build_object(
                   'component_variant_id', comp.component_variant_id,
                   'quantity',             comp.quantity,
                   'audience',             comp.audience_code,
                   'valid_days',           comp.valid_days)
                ORDER BY comp.sort_order, comp.component_variant_id)
          FROM fn_variant_composition(pv.id) comp) AS composition
  FROM product_variant pv
  JOIN product p ON p.id = pv.product_id
  LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id;

COMMENT ON VIEW v_variant_comparison IS
    '可售单元的差异对照表：人群、轴取值、有效期、退款口径、可用源、组合构成 —— 两个变体差在哪，一行看清';

-- -------------------------------------------------------------------------------------
-- ④ C 端的组合构成读模型
--
-- 为什么要有这张表：
--   c_variant_facts 一行一个变体，只能带「这个变体是什么」。
--   组合的差异在成分身上（「2 份成人 + 1 份儿童，各管 1 天」），
--   一行装不下 —— 要么塞进 jsonb（前端自己解，口径散在两端），
--   要么一行一个成分（前端一次查完，口径在库里）。
--   这里选后者：读模型可重建，主数据是唯一真相（硬约束 10）。
--
-- 表里只放语言无关的结构化事实：人群**编码**、份数、各自的天数。
-- 展示文案由 C 端按 locale 自己拼（硬约束 9：文案不进没有 locale 的表）。
-- -------------------------------------------------------------------------------------
CREATE TABLE c_variant_composition (
    channel_id          BIGINT        NOT NULL REFERENCES channel(id)         ON DELETE CASCADE,
    product_variant_id  BIGINT        NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    component_variant_id BIGINT       NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    sequence            INT           NOT NULL DEFAULT 0,
    quantity            NUMERIC(8,2)  NOT NULL DEFAULT 1 CHECK (quantity > 0),
    audience_code       TEXT          NOT NULL DEFAULT '',
    valid_days          INT           NOT NULL DEFAULT 1 CHECK (valid_days > 0),
    title               TEXT          NOT NULL DEFAULT '',
    synced_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, product_variant_id, component_variant_id)
);

COMMENT ON TABLE c_variant_composition IS
    'C 端组合构成读模型：一行一个成分（人群编码 / 份数 / 各自管几天）；组合的差异在成分身上，这一行装不下';

-- 变体事实带上组合的三个字段
ALTER TABLE c_variant_facts ADD COLUMN is_combo BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE c_variant_facts ADD COLUMN combo_audience TEXT NOT NULL DEFAULT '';
ALTER TABLE c_variant_facts ADD COLUMN component_count INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN c_variant_facts.is_combo IS
    '这个可售单元是不是组合（由若干可售单元组成）';
COMMENT ON COLUMN c_variant_facts.combo_audience IS
    '组合覆盖的人群编码集合（adult,child）；普通变体为空';
COMMENT ON COLUMN c_variant_facts.component_count IS
    '组合的成分个数；普通变体为 0';

-- -------------------------------------------------------------------------------------
-- ⑤ 刷新作业：把组合的构成写进读模型
--
-- 011 已经整体替换过 fn_refresh_read_models（返回类型多了一个 OUT 参数）。
-- 这里签名不变，所以 CREATE OR REPLACE 就够（改函数体不改返回类型）。
--
-- 两处新增：
--   a. 写 c_variant_composition（成分来自 fn_variant_composition，唯一读法）；
--   b. c_variant_facts 带上 is_combo / combo_audience / component_count。
--      事实来源还是 v_variant_comparison（差异的唯一汇总口径）——
--      这里不重算成分、不重算天数：重算就是第二份实现。
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
             (SELECT count(*)
                FROM supplier_price_calendar spc
                JOIN supplier_variant_mapping svm
                  ON svm.supplier_variant_id = spc.supplier_variant_id
                 AND svm.product_variant_id = spc.product_variant_id
                 AND svm.status = 'active'
               WHERE spc.product_variant_id = cvc2.product_variant_id
                 AND spc.date = cvc2.date
                 AND spc.status = 'available') AS source_count,
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
-- ⑥ C 端读视图
--
-- v_c_variant_feed 加四列（CREATE OR REPLACE VIEW 只能往末尾加列）：
--   is_combo / combo_audience / component_count / composition
--
-- composition 是 jsonb：前端一次拿到「这张套餐里有什么」，
-- 不用再查第二张表；明细行在 v_c_variant_composition。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_c_variant_feed AS
SELECT f.channel_id,
       f.product_variant_id,
       f.product_id,
       f.variant_code,
       f.title,
       f.audience,
       f.axes,
       f.valid_days,
       f.refundable,
       f.refund_fee_percent,
       cal.price_min,
       cal.price_max,
       COALESCE(cal.available_days, 0) AS available_days,
       cal.first_date,
       cal.last_date,
       -- ↓ 015 新增：组合的构成
       f.is_combo,
       f.combo_audience,
       f.component_count,
       (SELECT jsonb_agg(jsonb_build_object(
                   'component_variant_id', c.component_variant_id,
                   'quantity',             c.quantity,
                   'audience',             c.audience_code,
                   'valid_days',           c.valid_days,
                   'title',                c.title)
                ORDER BY c.sequence, c.component_variant_id)
          FROM c_variant_composition c
         WHERE c.channel_id = f.channel_id
           AND c.product_variant_id = f.product_variant_id) AS composition
  FROM c_variant_facts f
  LEFT JOIN LATERAL (
      SELECT MIN(cvc.price_min) AS price_min,
             MAX(cvc.price_max) AS price_max,
             COUNT(*) FILTER (WHERE cvc.status = 'available') AS available_days,
             MIN(cvc.date) AS first_date,
             MAX(cvc.date) AS last_date
        FROM c_variant_calendar cvc
       WHERE cvc.channel_id = f.channel_id
         AND cvc.product_variant_id = f.product_variant_id
  ) cal ON true;

COMMENT ON VIEW v_c_variant_feed IS
    'C 端变体读视图：差异事实（人群/轴/有效天数/退款口径/组合构成）+ 本渠道价格区间与可售天数，一行一变体';

-- 组合的成分明细：一行一个成分，前端详情页一次查完
CREATE VIEW v_c_variant_composition AS
SELECT c.channel_id,
       c.product_variant_id,
       pv.variant_key,
       c.component_variant_id,
       cpv.variant_code,
       c.title,
       c.sequence,
       c.quantity,
       c.audience_code,
       c.valid_days
  FROM c_variant_composition c
  JOIN product_variant pv ON pv.id = c.product_variant_id
  JOIN product_variant cpv ON cpv.id = c.component_variant_id;

COMMENT ON VIEW v_c_variant_composition IS
    'C 端组合成分明细：一行一个成分（份数 / 人群编码 / 各管几天），供详情页渲染「2 成人 + 1 儿童」';

-- -------------------------------------------------------------------------------------
-- ⑦ 组合的日历与价格同步
--
-- 组合在任何源侧都没有对应的商品条目 —— 它是我们自己的配方，
-- 源侧的目录同步作业看不见它。所以组合的售价行与日历格子只能自己推：
--
--   售价行：日期与场次来自成分的售价行（成分都在同一场次、同一天才谈得上套餐），
--           金额来自定价函数的组合分支（fn_price_variant）——
--           组合的价格不许手写，手写就会和「按配方算成本」对不上。
--   日历格子：组合在哪些渠道上 = 它的商品在哪些渠道上架。
--
-- 幂等：反复跑得到同样的结果（UPSERT）。
-- 什么时候跑：源侧价格同步之后（成分的售价行变了，组合的售价行要跟着变）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_sync_combo_calendar()
RETURNS TABLE (price_rows INT, cells INT)
LANGUAGE plpgsql AS $$
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
         (SELECT count(*)
            FROM supplier_variant_composition svc
           WHERE svc.product_variant_id = pc.product_variant_id
             AND svc.status = 'active'),
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
$$;

COMMENT ON FUNCTION fn_sync_combo_calendar() IS
    '组合的日历与价格同步：按成分的售价行推出组合的售价行（金额来自定价函数），再按上架关系推出日历格子';

-- -------------------------------------------------------------------------------------
-- ⑧ 不变量（89-91）
--
-- 89：组合的有效期不许短于任何一个成分 ——
--     少报一天 = 客户第二天到门口进不去（010 根治过的那个 bug，在组合上复发）。
-- 90：C 端的组合构成必须与主数据一致 ——
--     读模型可重建，但重建前它就是错的；漏跑刷新作业当场报出来。
-- 91：组合的日历格子必须带价格 ——
--     挂着一个卖不了的套餐 = 白占一个位置，用户点进去发现买不了。
--
-- 第 76 条（读模型不许与主数据分叉）同步扩展：组合的三个字段也要比。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks_readmodel AS
WITH raw (seq, check_name, actual) AS (
    -- 76：读模型里的变体事实不许与主数据分叉 ——
    --     漏跑刷新作业时这里当场红（读模型可重建，但重建前它就是错的）。
    --     015 起组合的三个字段也在比对范围内。
    SELECT 76, 'C 端读模型的变体事实必须与主数据一致',
           (SELECT count(*)
              FROM c_variant_facts f
              JOIN v_variant_comparison cmp ON cmp.product_variant_id = f.product_variant_id
             WHERE f.audience          <> cmp.audience
                OR f.axes              <> COALESCE(cmp.axes, '{}'::jsonb)
                OR f.valid_days        <> cmp.valid_days
                OR f.refundable        <> cmp.refundable
                OR f.refund_fee_percent <> cmp.refund_fee_percent
                OR f.is_combo           <> cmp.is_combo
                OR f.combo_audience     <> COALESCE(cmp.combo_audience, '')
                OR f.component_count    <> cmp.component_count)
    UNION ALL
    -- 77：日历格子的有效期终点必须等于格子日期加有效天数 ——
    --     前端不许自己加一天；这里红了就说明有人改了有效期口径。
    SELECT 77, '变体日历格子的有效期终点必须等于格子日期加有效天数',
           (SELECT count(*)
              FROM c_variant_calendar cvc
             WHERE cvc.valid_to IS DISTINCT FROM
                   cvc.date + fn_variant_validity_days(cvc.product_variant_id))
    UNION ALL
    -- 89：组合的有效期必须恰好等于成分窗口的并集
    --
    --     写成「必须等于并集」而不是「不许短于任何一个成分」：
    --     后者只挡住「取最短」，挡不住「取和」（2 日 + 1 日 = 3 天）——
    --     那会让客户拿到一张管三天的套餐，多赔一天。等于并集两头都挡。
    --
    --     成分的窗口独立地从轴选项读（不调 fn_variant_validity_days）。
    --     同一件事算两遍，错了才知道哪一遍错了；
    --     两遍都调同一个函数 = 拿自己证明自己，永远绿灯。
    SELECT 89, '组合的有效期必须恰好等于成分窗口的并集',
           (SELECT count(*)
              FROM product_variant pv
             WHERE pv.variant_role = 'combo'
               AND pv.status = 'active'
               AND EXISTS (SELECT 1
                             FROM product_variant_relation r
                            WHERE r.parent_variant_id = pv.id
                              AND r.relation_type = 'included')
               AND fn_variant_validity_days(pv.id) <> (
                     SELECT MAX(COALESCE((SELECT MAX(ao.valid_days)
                                            FROM product_variant_option pvo
                                            JOIN product_axis_option ao
                                              ON ao.id = pvo.axis_option_id
                                           WHERE pvo.product_variant_id = r.child_variant_id), 1))
                       FROM product_variant_relation r
                      WHERE r.parent_variant_id = pv.id
                        AND r.relation_type = 'included'))
    UNION ALL
    -- 90：C 端的组合构成必须与主数据一致 ——
    --     多了一行、少了一行、份数或天数变了，都算分叉。
    SELECT 90, 'C 端的组合构成必须与主数据一致',
           (SELECT count(*)
              FROM c_variant_composition c
             WHERE NOT EXISTS (SELECT 1
                                 FROM fn_variant_composition(c.product_variant_id) comp
                                WHERE comp.component_variant_id = c.component_variant_id
                                  AND comp.quantity      = c.quantity
                                  AND comp.audience_code = c.audience_code
                                  AND comp.valid_days    = c.valid_days))
           + (SELECT count(*)
                FROM c_variant_facts f
                JOIN LATERAL (SELECT count(*) AS n
                                FROM fn_variant_composition(f.product_variant_id)) fc ON true
               WHERE fc.n > 0
                 AND fc.n <> (SELECT count(*)
                                 FROM c_variant_composition c
                                WHERE c.channel_id = f.channel_id
                                  AND c.product_variant_id = f.product_variant_id))
    UNION ALL
    -- 91：组合的日历格子必须带价格
    SELECT 91, '组合的日历格子必须带价格',
           (SELECT count(*)
              FROM c_variant_calendar cvc
              JOIN product_variant pv ON pv.id = cvc.product_variant_id
             WHERE pv.variant_role = 'combo'
               AND cvc.status = 'available'
               AND cvc.price_min IS NULL)
    UNION ALL
    -- 92：组合的成分折算留痕必须自洽
    --
    --     普通可售单元的折算留痕由不变量 45 复查 ——
    --     它按 cost_source_product_id join 源价行，而组合的 cost_source_product_id 是空的
    --     （成本来自配方，不来自某一个源商品）。所以不变量 45 直接跳过组合，
    --     组合的折算留痕就没人复查了：留个假日期都没人知道。
    --
    --     组合的留痕在 rule->'combo' 里（逐成分一条）：
    --       同币种 → 折算因子 = 1、快照日期为空（没折算过就不留假快照）；
    --       跨币种 → 必须留快照日期，且因子能拿这个日期独立复算出来。
    --     复算用的是留痕里的 fx_as_of —— 留痕日期能独立复算出同一个因子。
    SELECT 92, '组合的成分折算留痕必须自洽',
           (SELECT count(*)
              FROM price_calendar pc
              CROSS JOIN LATERAL jsonb_array_elements(
                     CASE WHEN jsonb_typeof(pc.rule->'combo') = 'array'
                          THEN pc.rule->'combo' ELSE '[]'::jsonb END) AS comp
             WHERE pc.status = 'active'
               AND pc.product_variant_id IN (SELECT id FROM product_variant WHERE variant_role = 'combo')
               AND ( (COALESCE(comp->>'currency', '') = COALESCE(pc.currency, '')
                      AND (comp->>'fx_as_of' IS NOT NULL
                           OR (comp->>'fx_rate')::numeric IS DISTINCT FROM 1))
                 OR (COALESCE(comp->>'currency', '') <> COALESCE(pc.currency, '')
                      AND (comp->>'fx_as_of' IS NULL
                           OR (comp->>'fx_rate')::numeric IS DISTINCT FROM
                              round(fn_fx_pair_rate(comp->>'currency', pc.currency,
                                                   (comp->>'fx_as_of')::date), 8)))) )
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_readmodel IS
    'C 端读模型侧不变量（76-77、89-92）：读模型不许与主数据分叉、日历有效期终点不许被算错、组合的窗口与构成不许走样、组合的折算留痕不许走样';

-- -------------------------------------------------------------------------------------
-- ⑨ 核心不变量按组合的口径修订（16 / 34）
--
-- 组合第一次有了对客售价行，两条老不变量就红了 —— 红的不是数据，是口径：
--
--   16：售价日历的采纳成本必须可追溯到具体源。
--       组合的成本 = Σ 成分成本 × 数量，成本来自**配方里的那些源**，
--       没有「一个具体源」可指，cost_source_product_id 天然为空。
--       所以组合的追溯路径是配方：组合必须有配方（active 的成分行），
--       否则就是一笔查不到来路的成本。
--
--   34：有售价的变体在其上架渠道必须至少有一个可履约源。
--       组合不许直接挂源映射（不变量 81），它的供给走配方 ——
--       所以组合的可履约性是「每个成分都要有一个覆盖得住它的源」，
--       不是「组合自己有一个源」。
--
-- 做法与 003 / 012 / 013 / 014 同一个套路：基线 001 是冻结的，改它等于内容漂移。
-- 先把老视图改名留底，再从留底重建（不复制老行，只重建被改的那两条）。
-- -------------------------------------------------------------------------------------
DROP VIEW v_invariant_checks;

ALTER VIEW v_invariant_checks_core RENAME TO v_invariant_checks_core_base;

COMMENT ON VIEW v_invariant_checks_core_base IS
    '核心不变量留底（001 的口径；015 修订了 16 与 34 —— 组合的追溯路径是配方）';

CREATE VIEW v_invariant_checks_core AS
WITH raw (seq, check_name, actual) AS (
    SELECT seq, check_name, actual
      FROM v_invariant_checks_core_base
     WHERE seq NOT IN (16, 34)
    UNION ALL
    -- 16：售价日历的采纳成本必须可追溯到具体源（015 修订：组合的来源是配方）
    SELECT 16, '售价日历的采纳成本必须可追溯到具体源',
           (SELECT count(*)
              FROM price_calendar pc
              LEFT JOIN product_variant pv ON pv.id = pc.product_variant_id
             WHERE pc.cost_price IS NOT NULL
               AND pc.cost_source_product_id IS NULL
               AND (pv.variant_role IS DISTINCT FROM 'combo'
                    OR NOT EXISTS (SELECT 1
                                     FROM supplier_variant_composition svc
                                    WHERE svc.product_variant_id = pc.product_variant_id
                                      AND svc.status = 'active')))
    UNION ALL
    -- 34：有售价的变体在其上架渠道必须至少有一个可履约源（015 修订：组合的供给走配方）
    SELECT 34, '有售价的变体在其上架渠道必须至少有一个可履约源',
           (SELECT count(*)
              FROM (
                SELECT DISTINCT cl.channel_id, pc.product_variant_id
                  FROM channel_listing cl
                  JOIN price_calendar pc ON pc.product_id = cl.product_id
                                         AND pc.channel_id IS NULL
                                         AND pc.status = 'active'
                 WHERE pc.product_variant_id IS NOT NULL
                   -- 只管「正在卖」的变体。源被停用后重算会把这些行的售价清空，
                   -- 那时它们已经不卖了，不该再算作违规 —— 留着的是一条待清理的骨架行。
                   AND pc.sell_price IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM v_variant_routing_candidates vrc
                                    WHERE vrc.channel_id = cl.channel_id
                                      AND vrc.product_variant_id = pc.product_variant_id)
                   -- 组合没有直接映射（不变量 81：供给走配方），
                   -- 所以「没有路由候选」对组合不算违规：
                   -- 组合的履约性是「每个成分都要有一个覆盖得住它的源」。
                   -- 组合缺了源的成分 → 仍然算违规（那才是真的卖不出去）。
                   AND NOT (
                         EXISTS (SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id
                                    AND r.relation_type = 'included')
                         AND NOT EXISTS (SELECT 1
                                           FROM product_variant_relation r
                                          WHERE r.parent_variant_id = pc.product_variant_id
                                            AND r.relation_type = 'included'
                                            AND NOT EXISTS (SELECT 1
                                                             FROM supplier_variant_mapping svm
                                                            WHERE svm.product_variant_id = r.child_variant_id
                                                              AND svm.status = 'active'
                                                              AND fn_variant_covered(svm.coverage, r.child_variant_id)))
                       )
              ) x)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_core IS
    '核心不变量自检（第 16 / 34 条按 015 修订：组合的成本与供给都走配方）';

-- -------------------------------------------------------------------------------------
-- ⑩ 总视图：并集（重建 —— 上一步改名了核心视图）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks AS
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

COMMENT ON VIEW v_invariant_checks IS
    '全部 92 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
