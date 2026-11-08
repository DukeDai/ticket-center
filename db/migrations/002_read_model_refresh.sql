-- =====================================================================================
-- 002_read_model_refresh.sql — C 端读模型刷新作业（单一实现）
-- =====================================================================================
-- 为什么要有这个：
--   C 端列表页与日历只读读模型（硬约束 10），读模型必须可重建。
--   但「重建」这个动作此前只存在于 db/seed.sql 的两段内联 UPDATE 里 ——
--   种子跑一次就没了。生产环境里没有任何东西会刷新卡片，
--   于是源价一改、渠道一调，列表页还挂着旧起价，
--   只能靠 v_c_readmodel_drift 事后发现（那已经是客诉之后了）。
--
-- 做什么：
--   1. c_product_card：起价 / 划线价 / 最近可售日 / 可售天数；
--   2. c_variant_calendar：当日价格区间 / 可履约源数。
--
-- 口径必须与漂移检测完全一致：
--   v_c_readmodel_drift 用「渠道专属价优先、取最低、排除加购件」算真值，
--   刷新也用同一套规则。若两份口径各写各的，刷新完还会被判成漂移 ——
--   等于自己告自己，而且没人会去查是哪一个错了。
--
-- 边界（有意不做）：
--   - 不新建日历格子：格子该不该出现由上架与库存同步决定，不由定价决定；
--   - 不改 c_product_calendar：商品级格子带票种价格与库存状态
--     （sold_out / closed），由库存同步作业写，半更新比不更新更糟。
-- =====================================================================================

CREATE OR REPLACE FUNCTION fn_refresh_read_models() RETURNS TABLE(cards_updated INT, variant_cells_updated INT)
LANGUAGE plpgsql AS $$
DECLARE
  v_cards    INT := 0;
  v_variants INT := 0;
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

  -- ② 变体日历：当日价格区间 + 可履约源数
  UPDATE c_variant_calendar cvc
     SET price_min    = t.price_min,
         price_max    = t.price_max,
         source_count = t.source_count,
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
                 AND spc.status = 'available') AS source_count
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

  RETURN QUERY SELECT v_cards, v_variants;
END;
$$;

COMMENT ON FUNCTION fn_refresh_read_models() IS 'C 端读模型刷新作业：重建卡片起价与变体日历格子，口径与 v_c_readmodel_drift 一致';
