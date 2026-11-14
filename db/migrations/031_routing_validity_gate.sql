-- =====================================================================================
-- 031 —— 兑现窗口的选源门禁：短于承诺的源不许出现在路由候选集里
--
-- 合同：spec/15-validity.md §5.10 第五口径、§4.13 不变量 123
-- 领域：docs/ddd.md（源层 → 规范层的差异表达）
-- 物理：docs/schema-design.md
--
-- 【为什么有这一条】
--
-- 030 把「源侧兑现窗口短于规范侧承诺的源不进候选」写进了 fn_route_candidates，
-- 但**没人查这条判据有没有生效**。
--
-- 不变量 122 查的是另一件事：卖出去的订单用的源兑现窗口短于承诺。
-- 它是**事后**的判据 —— 没有卖出去过的单子永远不触发它。
-- 于是有一个危险窗口：判据写错了（或者被人改回旧版本），
-- 系统照样卖得出去，只是卖的时候用了兑现不起的源；
-- 等到有人真的下单了，122 才会红 —— 那时候钱已经收了。
--
-- 选源这一步是**事前**的：候选集里根本不该出现兑现不起的源。
-- 所以门禁要挂在候选集上，而不是挂在已成交的订单上。
--
-- 【这一条查什么】
--
-- v_variant_routing_candidates 是选源的读模型（它走 fn_route_candidates，
-- 与定价函数同一份候选集、同一份排序键 —— 硬约束 15）。
-- 查它的输出：任何一行候选，其源变体的兑现窗口都不得短于该可售单元的承诺。
--
-- 这一条是**自证**的：它读的就是判据本身作用的那个集合。
-- 拿自己证明自己永远是绿的 —— 所以它与不变量 122 互为独立的两条：
--   122 读「卖出去的」（事后），123 读「候选集里的」（事前）。
-- 两条走的是不同的表（sales_order_item+booking vs 路由视图），
-- 任何一条判据失效都会让另一条仍然有效 —— 不会一起绿。
--
-- 【为什么不写在函数里】
--
-- 因为它要检查的是**函数输出**的性质，而函数输出不落在表里。
-- 视图是唯一能同时读到「判据的结果」和「承诺」的形状。
-- 同一条思路在别处也有：不变量 43 查选源与定价是不是同一份实现，
-- 用的也是视图对视图。
--
-- 【NULL 怎么办】
--
-- 源侧没报兑现窗口（NULL）= 没给约束 = 不拦（硬约束 22、34 同一条口径）。
-- 所以判据只管「源侧报了且不够」的情况，NULL 不算违规。
-- 这与 030 的选源判据是同一条口径：NULL 放行。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 不变量 123：候选集里不许有兑现不起的源
-- -------------------------------------------------------------------------------------
--
-- 放在 030 建的那个分支视图里（同一条主题：源侧兑现窗口）。
-- 030 建的时候它只有 122 一条，现在加 123 ——
-- 视图的形状不变（还是 seq/check_name/expected/actual/passed/result 六列），
-- 所以 CREATE OR REPLACE 就够，不需要 DROP。
CREATE OR REPLACE VIEW v_invariant_checks_source_validity AS
WITH raw (seq, check_name, actual) AS (
    -- 122：卖出去的订单用的源，其兑现的有效期窗口不得短于该可售单元承诺的有效期
    SELECT 122, '卖出去的订单用的源必须兑现得起该可售单元承诺的有效期',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN booking b ON b.order_item_id = oi.id
              JOIN supplier_variant sv ON sv.id = b.supplier_variant_id
             WHERE sv.valid_days IS NOT NULL
               AND sv.valid_days < fn_variant_validity_days(oi.product_variant_id))
    UNION ALL
    -- 123：选源的候选集里，不许出现兑现窗口短于承诺的源。
    -- 事前判据：候选集不对的时候，一个单子都还没卖出去 ——
    -- 122 那时还是绿的，123 当场就红。
    SELECT 123, '选源候选集里的源必须兑现得起该可售单元承诺的有效期',
           (SELECT count(*)
              FROM v_variant_routing_candidates rc
              JOIN supplier_variant sv ON sv.id = rc.supplier_variant_id
             WHERE sv.valid_days IS NOT NULL
               AND sv.valid_days < fn_variant_validity_days(rc.product_variant_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_source_validity IS
    '源侧兑现窗口侧不变量（122 事后 / 123 事前）：122 查卖出去的订单用的源兑现窗口短于承诺；'
    '123 查选源候选集里的源兑现窗口短于承诺 —— 候选集不对时 122 还是绿的，123 当场红';

-- -------------------------------------------------------------------------------------
-- ② 把新分支接进 v_invariant_checks（唯一来源：这里 UNION ALL 一次）
-- -------------------------------------------------------------------------------------
-- 分支清单与 030 相同（v_invariant_checks_source_validity 已经在清单里），
-- 这里重新定义一遍是因为 v_invariant_checks 的定义本身要跟着分支视图的定义走 ——
-- 分支视图换了定义，聚合视图也得重建（CREATE OR REPLACE VIEW 会拒绝
-- 与旧定义不兼容的替换，所以整段照抄 030 的清单，形状一个字没变）。
--
-- 抄漏一个分支的后果是 v_invariant_checks 少一条门禁，
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
