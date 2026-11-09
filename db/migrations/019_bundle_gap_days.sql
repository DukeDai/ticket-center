-- =====================================================================================
-- 019 · 套装的缺口天数只数「真卖不掉」的那几天
--
-- 问题：
--   v_variant_bundle.gap_days 数的是 v_bundle_gap 里的行数，
--   而 v_bundle_gap 一行一天 —— 里面混着「这一天能卖」（reason 为空）的行。
--   于是套装明明天天能卖，读视图却报「有 N 天卖不掉」，理由还是空的。
--   运营看到这句话只会以为漏配了源，去查一个不存在的问题。
--
-- 改法：
--   gap_days 只数 reason 非空的行。gap_reasons 早就只收非空的，两边口径对齐。
--
-- 为什么单开一个迁移：
--   017 已经应用到主库，账本里记着它的校验和 —— 改它就是内容漂移。
--   DDL 只增不改：改视图就新增一个迁移。
--
-- 校验方式：套装的 gap_days 必须与 gap_reasons 的条目数一致，
-- 且没有缺口时 gap_days = 0（而不是「有 N 天卖不掉：」）。
-- =====================================================================================

CREATE OR REPLACE VIEW v_variant_bundle AS
SELECT svb.id                    AS bundle_id,
       svb.product_variant_id,
       pv.variant_code,
       pv.variant_key,
       pv.product_id,
       svb.supplier_variant_id,
       sv.supplier_product_id,
       sv.external_variant_id     AS source_set_sku,
       COALESCE(sv.title, '')     AS source_set_title,
       sup.code                   AS supplier_code,
       svb.valid_days             AS set_valid_days,
       fn_variant_validity_days(svb.product_variant_id) AS union_days,
       (svb.valid_days >= fn_variant_validity_days(svb.product_variant_id)) AS covers_window,
       (SELECT count(*)
          FROM supplier_variant_bundle_part p
         WHERE p.bundle_id = svb.id) AS part_count,
       (SELECT COALESCE(sum(p.quantity), 0)
          FROM supplier_variant_bundle_part p
         WHERE p.bundle_id = svb.id) AS admissions_per_set,
       (SELECT jsonb_agg(jsonb_build_object(
                   'component_variant_id', p.component_variant_id,
                   'variant_code',         cpv.variant_code,
                   'quantity',             p.quantity,
                   'audience_code',        COALESCE(ctt.code, ''),
                   'valid_days',           fn_variant_validity_days(p.component_variant_id))
                 ORDER BY p.id)
          FROM supplier_variant_bundle_part p
          JOIN product_variant cpv ON cpv.id = p.component_variant_id
          LEFT JOIN ticket_type ctt ON ctt.id = cpv.ticket_type_id
         WHERE p.bundle_id = svb.id) AS parts,
       (SELECT count(*)
          FROM v_bundle_gap g
         WHERE g.product_variant_id = svb.product_variant_id
           AND g.supplier_variant_id = svb.supplier_variant_id
           AND g.reason <> '') AS gap_days,
       (SELECT COALESCE(jsonb_agg(DISTINCT g.reason), '[]'::jsonb)
          FROM v_bundle_gap g
         WHERE g.product_variant_id = svb.product_variant_id
           AND g.supplier_variant_id = svb.supplier_variant_id
           AND g.reason <> '') AS gap_reasons
  FROM supplier_variant_bundle svb
  JOIN product_variant pv ON pv.id = svb.product_variant_id
  JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id
  JOIN supplier_product sp ON sp.id = sv.supplier_product_id
  JOIN supplier sup ON sup.id = sp.supplier_id
 WHERE svb.status = 'active';

COMMENT ON VIEW v_variant_bundle IS
    '套装的供给形态：一行一个套装（规范变体 ← 整套源 SKU）+ 成分构成 + 有效期窗口 + 缺口诊断'
    '（gap_days 只数真卖不掉的天数）';
