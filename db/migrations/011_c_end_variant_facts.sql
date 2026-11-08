-- =====================================================================================
-- 011 C 端读模型带上差异事实（c_variant_facts + 变体日历的有效期终点）
-- =====================================================================================
-- 为什么有这一段：
--   到 010 为止，「异构产品的差异」在主数据里已经表达清楚了：
--     轴（product_axis / product_axis_option）、覆盖（coverage）、
--     有效期（valid_days）、差异对照（v_variant_comparison）。
--   但**C 端看不到它们**。
--
--   读模型（c_product_card / c_variant_calendar）只带价格与可售天数。
--   于是 C 端拿不到「这个变体是几日的」「覆盖哪些园区」「能不能退」——
--   前端要显示这些，只能在请求链路里 join 主数据，
--   而硬约束 10 明写「C 端列表/日历只读读模型，不在请求链路里 join 主数据」。
--
--   最要命的是有效期：两日票和单日票在日历上长得一模一样（都是「一格」），
--   用户按「当天有效」理解两日票，第二天拿着票到门口才发现进不去。
--   这正是 010 想根治的问题 —— 治到主数据为止，只治了一半。
--
-- 这一段的口径：
--   1. 差异事实进读模型，不进请求链路。c_variant_facts 是「变体级差异」的读模型，
--      一行一个 (渠道, 变体)：人群 / 轴取值 / 有效天数 / 退款口径。
--   2. 事实只写一份：读模型里的每个字段都从 v_variant_comparison 取，
--      不在刷新函数里另算一遍（有效天数走 fn_variant_validity_days，
--      轴取值走 product_variant_option —— 都是唯一读法）。
--   3. 读模型不许与主数据分叉：门禁 76 逐字段比对，
--      漏跑刷新作业当场报出来（读模型可重建，但重建前它就是错的）。
--   4. 日历格子带有效期终点：valid_to = 格子日期 + 有效天数，
--      前端不用自己加一天（加一天和应用侧加一天，早晚有一天对不上）。
--   5. 哪些变体上这个渠道，由日历格子决定（c_variant_calendar 是入口）：
--      刷新建事实、也清掉已经没有格子的旧事实（读模型可重建）。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 表结构
-- -------------------------------------------------------------------------------------

-- 变体级差异事实：渠道 × 变体
CREATE TABLE c_variant_facts (
    channel_id              BIGINT      NOT NULL REFERENCES channel(id)         ON DELETE CASCADE,
    product_variant_id      BIGINT      NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    product_id              BIGINT      NOT NULL REFERENCES product(id)         ON DELETE CASCADE,
    variant_code            TEXT        NOT NULL DEFAULT '',
    title                   TEXT        NOT NULL DEFAULT '',
    -- 人群：沿用票种编码（adult / child / senior / standard）
    audience                TEXT        NOT NULL DEFAULT '',
    -- 轴取值：{"pass_type":"1d","park_scope":"studio_only", ...}
    axes                    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    -- 有效几天（010 的 valid_days，唯一读法 fn_variant_validity_days）
    valid_days              INTEGER     NOT NULL DEFAULT 1 CHECK (valid_days > 0),
    -- 退款口径（商品级承诺）
    refundable              BOOLEAN     NOT NULL DEFAULT FALSE,
    refund_fee_percent      NUMERIC(5,2) NOT NULL DEFAULT 0,
    synced_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, product_variant_id)
);

COMMENT ON TABLE c_variant_facts IS
    'C 端变体级差异事实读模型：人群 / 轴取值 / 有效天数 / 退款口径（主数据的差异不许在请求链路里 join 出来）';

-- 日历格子带有效期终点：前端不用自己加一天
ALTER TABLE c_variant_calendar ADD COLUMN valid_to DATE;

COMMENT ON COLUMN c_variant_calendar.valid_to IS
    '有效期终点 = 格子日期 + 该变体的有效天数（唯一读法 fn_variant_validity_days）';

-- -------------------------------------------------------------------------------------
-- ② 差异对照视图补一列 product_id
--
-- C 端的变体事实要指回商品（详情页按商品取变体列表）。
-- 010 建这个视图时只给了 product_code —— 够看，不够用。
-- CREATE OR REPLACE VIEW 只能往末尾加列，所以加在最后。
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
       p.id AS product_id
  FROM product_variant pv
  JOIN product p ON p.id = pv.product_id
  LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id;

COMMENT ON VIEW v_variant_comparison IS
    '可售单元的差异对照表：人群、轴取值、有效期、退款口径、可用源 —— 两个变体差在哪，一行看清';

-- -------------------------------------------------------------------------------------
-- ③ 刷新作业：整体替换 fn_refresh_read_models（002 已应用，改它等于内容漂移）
--
-- 三处改动：
--   a. 变体日历格子补 valid_to；
--   b. 新增 c_variant_facts 的写入（upsert）；
--   c. 清掉已经没有日历格子的旧事实（读模型可重建，主数据是唯一真相）；
--   d. 返回值多一个计数（读模型变了，报告也得跟着变）。
--
-- 口径来源只有一处：v_variant_comparison（它是差异的唯一汇总口径）。
-- 这里不重算 valid_days、不重算 axes —— 重算就是第二份实现。
--
-- 为什么是 DROP + CREATE 而不是 CREATE OR REPLACE：
--   返回值多了一个 OUT 参数，行类型就变了 ——
--   PostgreSQL 不许「改函数的返回类型」（报 "cannot change return type"）。
--   先按参数个数判断再删：只有当它还是 002 那一版（2 个 OUT 参数）才删，
--   万一这个迁移重跑（引擎虽然不重跑，但脚本会被人手重放），也不会把新版删掉。
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
    v_out_modes TEXT[];
BEGIN
    SELECT p.proargmodes INTO v_out_modes
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'fn_refresh_read_models'
       AND p.pronargs = 0;

    IF v_out_modes IS NOT NULL AND array_length(v_out_modes, 1) <> 3 THEN
        EXECUTE 'DROP FUNCTION fn_refresh_read_models()';
    END IF;
END $$;

CREATE FUNCTION fn_refresh_read_models()
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

  -- ③ 变体事实：这个变体差在哪（人群 / 轴取值 / 有效天数 / 退款口径）
  --
  -- 范围：只写「这个渠道的日历上有格子」的变体 ——
  -- 日历是 C 端的入口，没有格子的变体本来就不该出现在这个渠道。
  --
  -- 事实来源：v_variant_comparison（差异的唯一汇总口径）。
  INSERT INTO c_variant_facts (channel_id, product_variant_id, product_id, variant_code, title,
                               audience, axes, valid_days, refundable, refund_fee_percent,
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
         synced_at          = EXCLUDED.synced_at;
  GET DIAGNOSTICS v_facts = ROW_COUNT;

  -- ④ 清掉已经没有格子的旧事实
  --    读模型可重建：日历上撤掉的变体，事实也该撤掉，
  --    不然 C 端会看到一个「有事实、没格子」的幽灵变体。
  DELETE FROM c_variant_facts f
   WHERE NOT EXISTS (SELECT 1
                       FROM c_variant_calendar cvc
                      WHERE cvc.channel_id = f.channel_id
                        AND cvc.product_variant_id = f.product_variant_id);

  RETURN QUERY SELECT v_cards, v_variants, v_facts;
END;
$$;

COMMENT ON FUNCTION fn_refresh_read_models() IS
    'C 端读模型刷新作业：卡片起价、变体日历格子（含有效期终点）、变体差异事实；口径与 v_c_readmodel_drift 一致';

-- -------------------------------------------------------------------------------------
-- ④ C 端变体读视图
--
-- 一行一个 (渠道, 变体)：差异事实 + 这个渠道上的价格与可售天数。
-- 前端一次查完，不用再 join 日历、不用再回主数据。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_c_variant_feed AS
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
       cal.last_date
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
    'C 端变体读视图：差异事实（人群/轴/有效天数/退款口径）+ 本渠道价格区间与可售天数，一行一变体';

-- -------------------------------------------------------------------------------------
-- ⑤ 不变量（76-77）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_readmodel AS
WITH raw (seq, check_name, actual) AS (
    -- 76：读模型里的变体事实不许与主数据分叉 ——
    --     漏跑刷新作业时这里当场红（读模型可重建，但重建前它就是错的）。
    SELECT 76, 'C 端读模型的变体事实必须与主数据一致',
           (SELECT count(*)
              FROM c_variant_facts f
              JOIN v_variant_comparison cmp ON cmp.product_variant_id = f.product_variant_id
             WHERE f.audience          <> cmp.audience
                OR f.axes              <> COALESCE(cmp.axes, '{}'::jsonb)
                OR f.valid_days        <> cmp.valid_days
                OR f.refundable        <> cmp.refundable
                OR f.refund_fee_percent <> cmp.refund_fee_percent)
    UNION ALL
    -- 77：日历格子的有效期终点必须等于格子日期加有效天数 ——
    --     前端不许自己加一天；这里红了就说明有人改了有效期口径。
    SELECT 77, '变体日历格子的有效期终点必须等于格子日期加有效天数',
           (SELECT count(*)
              FROM c_variant_calendar cvc
             WHERE cvc.valid_to IS DISTINCT FROM
                   cvc.date + fn_variant_validity_days(cvc.product_variant_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_readmodel IS
    'C 端读模型侧不变量（76-77）：读模型不许与主数据分叉、日历有效期终点不许被算错';

-- -------------------------------------------------------------------------------------
-- ⑥ 总视图：并集
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
    SELECT * FROM v_invariant_checks_readmodel;

COMMENT ON VIEW v_invariant_checks IS '全部 77 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
