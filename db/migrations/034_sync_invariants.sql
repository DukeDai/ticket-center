-- =====================================================================================
-- 034：同步落库侧不变量（127-133）
--
-- 口径在 spec/20-jobs.md §4.28（它们各自要挡住的那类数据违规）与 §5.27（口径本身）。
-- 这一节守的不是业务规则，是「同步作业不许把事实写坏」。
--
-- 为什么单独一个分支视图：这一组门禁的共同点是「同步作业写出来的行不许是孤儿 /
-- 不许匿名 / 不许漏进可用路径」。它们与交易侧的不变量互不相干，
-- 分开一个分支，改这一组时不会碰到别组。
--
-- 只增不改（硬约束 3）：基线 001 已应用，改它等于内容漂移，所以新增走这里。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 同步落库侧不变量（127-133）
-- -------------------------------------------------------------------------------------
--
-- 127-131 是「不许有孤儿」：源层的每一行都必须能追到一个源商品，
-- 源商品必须能追到一个源。孤儿行是同步作业写了一半崩掉的残留 ——
-- 它不属于任何源，却能被 supplier_variant_mapping 引用，于是
-- 「这个可售单元由谁履约」这个问题有一个指向空处的答案。
--
-- 128 是「不许有匿名商品」：supplier_product_uk 是 (supplier_id, external_id)，
-- 外部标识为空时这一对唯一键**不区分两个不同的商品** ——
-- 重放一次同步就多落一行同名空标识的商品，
-- 而这条唯一键恰恰拦不住它（两行都合法）。
--
-- 132-133 是「待审核不许漏进可用路径」：pending_review 是给
-- 「机器认出来了但人还没认」的事实准备的中间态（§5.27 第四条）。
-- 一个还等着人看的源商品，不许已经挂在规范商品上卖；
-- 一个还等着人看的映射，不许已经声明「这个源能履约这个可售单元」——
-- 那就等于没审核就上架了。
--
-- 这七条对应的表结构约束是**结构性的**（外键 + NOT NULL），
-- 门禁守的是**别让某次迁移把它们放松掉**，以及**别让一条 NULL 或空串绕过去**。
CREATE OR REPLACE VIEW v_invariant_checks_sync AS
WITH raw(seq, check_name, actual) AS (
    -- 127：落下的源商品必须挂在某个源下（不许有孤儿）
    SELECT 127, '落库的源商品必须挂在某个源下',
           (SELECT count(*) FROM supplier_product sp WHERE sp.supplier_id IS NULL)
    UNION ALL
    -- 128：源商品的外部标识不许为空（空标识 = 重放一次就多落一个商品）
    SELECT 128, '源商品的外部标识不许为空',
           (SELECT count(*) FROM supplier_product sp
             WHERE sp.external_id IS NULL OR btrim(sp.external_id) = '')
    UNION ALL
    -- 129：源变体必须挂在某个源商品下
    SELECT 129, '源变体必须挂在某个源商品下',
           (SELECT count(*) FROM supplier_variant sv WHERE sv.supplier_product_id IS NULL)
    UNION ALL
    -- 130：源票种必须挂在某个源商品下
    SELECT 130, '源票种必须挂在某个源商品下',
           (SELECT count(*) FROM supplier_ticket_type stt WHERE stt.supplier_product_id IS NULL)
    UNION ALL
    -- 131：源场次必须挂在某个源商品下
    SELECT 131, '源场次必须挂在某个源商品下',
           (SELECT count(*) FROM supplier_session ss WHERE ss.supplier_product_id IS NULL)
    UNION ALL
    -- 132：待审核的源商品不许挂着有效的规范映射
    --
    -- 这条挡的是「没审核就上架了」：一个还在 pending_review 的源商品，
    -- 已经有了 active 的 product_mapping —— 它已经在可售路径上了，
    -- 而没人看过它对应哪个规范商品。
    SELECT 132, '待审核的源商品不许挂着有效的规范映射',
           (SELECT count(*)
              FROM supplier_product sp
              JOIN product_mapping m ON m.supplier_product_id = sp.id
             WHERE sp.status = 'pending_review' AND m.status = 'active')
    UNION ALL
    -- 133：待审核的规范映射不许出现在有效的覆盖关系里
    --
    -- 变体映射说「这个源变体能履约这个可售单元」——
    -- 它是**声明**，而声明是判断。父级的商品映射还等着人看，
    -- 这条声明就不许是 active（fn_route_candidates 只认 active 的映射）。
    --
    -- **父级是哪一行**：变体映射指向的规范变体属于哪个规范商品，
    -- 那个商品的商品映射（对同一个源商品）就是它的父级。
    -- 不是「这个源商品的所有商品映射」—— 那会把别的商品对的待审核状态
    -- 算到这一对头上，误报一条门禁。
    SELECT 133, '待审核的规范映射不许出现在有效的覆盖关系里',
           (SELECT count(*)
              FROM supplier_variant_mapping svm
              JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
              JOIN product_variant pv ON pv.id = svm.product_variant_id
              JOIN product_mapping m
                ON m.supplier_product_id = sv.supplier_product_id
               AND m.product_id = pv.product_id
             WHERE m.status = 'pending_review' AND svm.status = 'active')
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_sync
    IS '同步落库侧不变量（127-133）：源层不许有孤儿/匿名行；待审核的事实不许漏进可用路径';

-- -------------------------------------------------------------------------------------
-- ② 把新分支接进 v_invariant_checks（唯一来源：这里 UNION ALL 一次）
-- -------------------------------------------------------------------------------------
--
-- 分支清单**不在这里手抄** —— 手抄一遍，下一个人加新分支时漏改一处，
-- v_invariant_checks 就少一条门禁，而少的那条永远不会有人发现（它从来没红过）。
--
-- 取活定义（pg_get_viewdef）再接上新分支：分支清单的唯一来源是库里。
-- 下面这段是按库里的活定义生成的 —— 生成方式见下面的注释。
--
-- **为什么 CREATE OR REPLACE VIEW 要整段重写**：PostgreSQL 要求替换后的定义
-- 与旧定义「列名与顺序相同」，而 UNION ALL 的分支数可以变 ——
-- 所以形状一个字没变，只在末尾多了一个分支。
CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_bundle v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_bundle_020 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_combo_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_composition v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_core_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_fulfill_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_hardening v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_hold_ttl v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_inventory_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_order v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_qty_limits v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_readmodel v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_reassign v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_reassign_basis v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_redemption v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_refund v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_refund_policy v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_source_validity v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_supply_form_shrink_022 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_supply_forms_021 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_supply_source_count_023 v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_tx v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_validity_flat v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_voucher_expiry v
UNION ALL
SELECT v.seq, v.check_name, v.expected, v.actual, v.passed, v.result FROM v_invariant_checks_sync v;

COMMENT ON VIEW v_invariant_checks IS
    '全部不变量：各主题分支的 UNION ALL。门禁条数以本视图为准（见 make counts）';
