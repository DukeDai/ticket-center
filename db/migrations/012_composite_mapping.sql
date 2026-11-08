-- =====================================================================================
-- 012 组合映射（异构融合的第二个方向）
-- =====================================================================================
-- 为什么有这一段：
--   到 011 为止，我们只处理了异构融合的**一个方向**：
--
--     方向 A（已建模）：一个源 SKU 覆盖多个规范变体。
--       zowoyoo 的 ZWO-1D-BASE 一个源变体能装出成人 / 儿童 / 老年三个可售单元。
--       模型：supplier_variant_mapping.coverage + fn_variant_covered。
--
--   但真实报文里还有**另一个方向**：
--
--     方向 B（本次）：一个规范变体由多个源 SKU 按数量组成。
--       GlobalTix 官方示例的「家庭套餐」：2 份成人门票 + 2 份成人快速通行证
--       + 1 份儿童门票 + 1 份儿童快速通行证，源侧是**一个**映射表达式
--       （"80041201-8004120101|2+80041201-8004120102|2+..."），
--       源侧一次预订就下完。
--
--   我们原来的模型里没有「组合」这个概念，于是这份报文只能被判成
--   「当前模型表达不了的源侧结构」—— 报告里写着，但系统没法卖。
--
--   方向 A 和方向 B 不是一回事：
--     A 是「一个源变体 → 多个我们的可售单元」（源比我们细）；
--     B 是「一个我们的可售单元 → 多个源变体」（我们比源细，是组合套餐）。
--   两个方向同时存在，才叫「融合」。
--
-- 这一段的口径：
--   1. 组合在规范侧有声明（组合套餐 = 若干组件变体，各要几份），
--      在源侧有配方（若干源 SKU，各要几份）。**两侧必须逐项对得上**。
--   2. 数量住在一处：规范侧在 product_variant_relation.quantity，
--      源侧在 supplier_variant_composition.quantity。
--   3. 源侧的每个成分必须顶得住一个声明的组件（覆盖得住、数量一致）——
--      「源侧给的是 2 大 1 小，我们卖的是 1 大 1 小」是最贵的一种错。
--   4. 组合的成分必须来自同一个源（不变量 78）：一次预订只能给一个源，
--      跨源的组合是另一个形状的问题（要拆单），不是这里要解决的。
--   5. **组件暂时只能是单个可售单元，不能再是组合**（一层，不许嵌套）：
--      组件要是组合，两侧的对账就得递归算，错了没人说得清。
--      结构上用触发器挡住（fn_guard_included_relation）。
--   6. 定价与预订还没接组合（组合的成本 = Σ 组件成本 × 数量，
--      一次预订要带整组 SKU）—— 在这两样落地之前，
--      组合变体**不参与选源与定价**，宁可少卖，不可卖错。
--      这条不能只写在文档里：守卫触发器 fn_guard_combo_mapping
--      挡住「组合直接挂源映射」，不变量 81 再复查一遍。
--      代价是源侧把整套套餐当一个 SKU 卖（方向 A）的情况接不了 ——
--      从 coverage 看不出一个源 SKU 是「一整套」还是「一张谁都能用的票」，
--      看不出来就不能猜。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 规范侧：组合套餐的组件数量
--
-- product_variant_relation 原来只说「父变体包含子变体」，没说包含几个。
-- 「2 大 1 小」这种套餐，数量是本质的一部分 —— 没有数量就只是一张成分表。
-- -------------------------------------------------------------------------------------
ALTER TABLE product_variant_relation
    ADD COLUMN quantity NUMERIC(8,2) NOT NULL DEFAULT 1;

ALTER TABLE product_variant_relation
    ADD CONSTRAINT pvr_quantity_check CHECK (quantity > 0);

COMMENT ON COLUMN product_variant_relation.quantity IS
    '组合套餐里每个组件要几份（2 大 1 小 → 成人组件 quantity=2、儿童组件 quantity=1）';

COMMENT ON TABLE product_variant_relation IS
    '变体可叠加关系：园区通票=基础票+园区升级，快速通行证=基础票+加购件，组合套餐=若干组件×数量';

-- -------------------------------------------------------------------------------------
-- ② 源侧：组合表达式的落地
--
-- 一行 = 「要用这个源 SKU 装出这个组合，得订几份、顶的是哪个组件」。
--
-- 为什么单独记 component_variant_id（这个源 SKU 顶的是哪个规范组件），
-- 而不是靠「数量相同 + 覆盖得住」去猜：
--   两个组件数量一样、又被同一个源 SKU 覆盖得住的时候，猜就是瞎猜。
--   把配对关系记下来，对账才是「源侧这一行 ↔ 规范侧那一行」逐行比。
-- -------------------------------------------------------------------------------------
CREATE TABLE supplier_variant_composition (
    id                   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- 组合（规范侧）。只有 variant_role='combo' 的变体能当组合。
    product_variant_id   BIGINT      NOT NULL REFERENCES product_variant(id)   ON DELETE CASCADE,
    -- 这个源 SKU 顶的是哪个声明的组件
    component_variant_id BIGINT      NOT NULL REFERENCES product_variant(id)   ON DELETE CASCADE,
    -- 要订的是哪个源 SKU
    supplier_variant_id  BIGINT      NOT NULL REFERENCES supplier_variant(id)  ON DELETE CASCADE,
    -- 订几份（源侧表达式里的 |2 就是它）
    quantity             NUMERIC(8,2) NOT NULL DEFAULT 1 CHECK (quantity > 0),
    status               TEXT        NOT NULL DEFAULT 'active',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ssvc_uk UNIQUE (product_variant_id, supplier_variant_id),
    CONSTRAINT ssvc_status_check CHECK (status IN ('active', 'retired'))
);

CREATE INDEX ix_ssvc_variant ON supplier_variant_composition (product_variant_id, status);
CREATE INDEX ix_ssvc_source  ON supplier_variant_composition (supplier_variant_id, status);
CREATE INDEX ix_ssvc_component ON supplier_variant_composition (component_variant_id, status);

COMMENT ON TABLE supplier_variant_composition IS
    '组合映射的源侧配方：一个组合变体由哪些源 SKU 按数量组成（GlobalTix 的组合表达式落地处）';

COMMENT ON COLUMN supplier_variant_composition.component_variant_id IS
    '这个源 SKU 顶的是哪个声明的组件（配对关系记在这里，对账逐行比，不靠猜）';

COMMENT ON COLUMN supplier_variant_composition.quantity IS
    '该源 SKU 在组合里要订几份（源侧表达式 "SKU|2" 的 2）';

-- -------------------------------------------------------------------------------------
-- ③ 守卫：'included' 只许挂在组合上
--
-- 为什么要有这个触发器：
--   fn_variant_covered（③之二）把组合的要求取成「组件要求的并集」。
--   一旦有人在**基础变体**上挂了一条 'included' 关系，
--   这个基础变体的覆盖要求就悄悄变了 —— 而规则是全局的，
--   改一条关系会让所有选源结果跟着变，还没人知道。
--   所以：'included' 关系只许挂在 combo 上，当场拦住。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_included_relation()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_role TEXT;
BEGIN
    IF NEW.relation_type <> 'included' THEN
        RETURN NEW;
    END IF;
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = NEW.parent_variant_id;
    IF v_role IS DISTINCT FROM 'combo' THEN
        RAISE EXCEPTION
            '变体 % 的 role 是 %，组合声明（included）只许挂在 combo 上',
            NEW.parent_variant_id, COALESCE(v_role, '不存在');
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_included_relation
    BEFORE INSERT OR UPDATE ON product_variant_relation
    FOR EACH ROW EXECUTE FUNCTION fn_guard_included_relation();

COMMENT ON FUNCTION fn_guard_included_relation() IS
    '守卫：组合声明（included）只许挂在 combo 变体上 —— 挂在基础变体上会悄悄改掉它的覆盖要求';

-- -------------------------------------------------------------------------------------
-- ④ 覆盖判定的口径：组合的要求 = 组件要求的并集
--
-- 为什么组合要这么判：
--   组合（家庭套餐）本身没有人群、也没有轴取值 —— 它是「若干可售单元的配方」。
--   按原来的判定（人群 + 各轴取值），它的要求是空集，
--   于是**任何**源 SKU 都「覆盖得住」它 —— 一个人群票就能顶掉整张家庭套餐。
--   这就是方向 A 与方向 B 打架的地方：组合不该被单个源 SKU 供给。
--
--   所以组合的要求 = 各组件要求的并集：
--     家庭套餐 = 成人票 + 成人快速通行证 + 儿童票 + 儿童快速通行证
--     → 要求 {人群:成人, 人群:儿童, 票种:1d, 园区:工作室, 加购:快速通行证}
--     → 单个源 SKU 覆盖不全（要么没有儿童、要么没有快速通行证）→ 覆盖不住 ✓
--     → 整张配方（各成分覆盖的并集）覆盖得住 ✓
--
--   把「要求集合」抽成一个函数（fn_variant_requirements），
--   判定、缺口、精确匹配三处共用它 ——
--   同一份要求算三遍，就是三处可能算出三个答案。
--
--   整体替换 fn_variant_covered / fn_variant_coverage_gaps
--   （001 已应用，改它等于内容漂移 —— 见文首，与 005/006/009/010 同一个套路）。
--   对**没有组合声明**的变体，判定结果与原来一模一样（要求集合不变）。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_variant_requirements(p_variant_id BIGINT)
RETURNS TABLE(axis_code TEXT, option_code TEXT)
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE chain(variant_id) AS (
        SELECT p_variant_id
      UNION
        SELECT r.child_variant_id
          FROM product_variant_relation r
          JOIN chain c ON c.variant_id = r.parent_variant_id
         WHERE r.relation_type = 'included'
    )
    SELECT 'audience'::text, tt.code::text
      FROM chain c
      JOIN product_variant pv ON pv.id = c.variant_id
      JOIN ticket_type tt ON tt.id = pv.ticket_type_id
    UNION
    SELECT ax.axis_code::text, opt.option_code::text
      FROM chain c
      JOIN product_variant_option pvo ON pvo.product_variant_id = c.variant_id
      JOIN product_axis ax ON ax.id = pvo.axis_id
      JOIN product_axis_option opt ON opt.id = pvo.axis_option_id
$$;

COMMENT ON FUNCTION fn_variant_requirements(BIGINT) IS
    '变体要求的能力集合：人群 + 各轴取值；组合的要求取组件要求的并集';

CREATE OR REPLACE FUNCTION fn_variant_covered(p_coverage JSONB, p_variant_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
          FROM fn_variant_requirements(p_variant_id) req
         WHERE NOT (COALESCE(p_coverage->'axes'->req.axis_code, '[]'::jsonb) ? req.option_code)
            OR (COALESCE(p_coverage->'excludes', '[]'::jsonb) ? req.option_code)
    );
$$;

COMMENT ON FUNCTION fn_variant_covered(JSONB, BIGINT) IS
    '变体覆盖判定：源变体的 coverage 是否完整覆盖规范变体的全部能力（人群 + 各轴取值）；组合的要求取组件要求的并集';

CREATE OR REPLACE FUNCTION fn_variant_coverage_gaps(p_coverage JSONB, p_variant_id BIGINT)
RETURNS TEXT[]
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(array_agg(req.axis_code || ':' || req.option_code
                              ORDER BY req.axis_code, req.option_code), '{}'::text[])
      FROM fn_variant_requirements(p_variant_id) req
     WHERE NOT (COALESCE(p_coverage->'axes'->req.axis_code, '[]'::jsonb) ? req.option_code)
        OR (COALESCE(p_coverage->'excludes', '[]'::jsonb) ? req.option_code);
$$;

COMMENT ON FUNCTION fn_variant_coverage_gaps(JSONB, BIGINT) IS
    '覆盖缺口：列出源变体缺哪些能力（运营排查用，如 "park_scope:studio_snw"）；组合的要求取组件要求的并集';

-- 精确匹配（is_exact）：覆盖的每一项都是这个变体要的，且这个变体要的每一项都被覆盖，
-- 而且不多不少 —— 源侧多声明一个取值就是宽覆盖（方向 A），不是精确匹配。
--
-- 为什么要有这个：is_exact 是「这个源 SKU 恰好等于这个可售单元」还是「这个源 SKU
-- 更宽、还覆盖了别的可售单元」的标记。方向 A（zowoyoo 一个源变体覆盖成人/儿童/老年）
-- 就靠它区分。没有它，宽覆盖会被当成精确匹配，
-- 于是「按 A 源的价格卖、按 B 源出票」这类问题在数据上看不出来。
CREATE OR REPLACE FUNCTION fn_variant_coverage_is_exact(p_coverage JSONB, p_variant_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
          FROM fn_variant_requirements(p_variant_id) req
         WHERE NOT (COALESCE(p_coverage->'axes'->req.axis_code, '[]'::jsonb) ? req.option_code))
       AND NOT EXISTS (
        SELECT 1
          FROM jsonb_each(COALESCE(p_coverage->'axes', '{}'::jsonb)) e
         WHERE NOT EXISTS (
            SELECT 1
              FROM fn_variant_requirements(p_variant_id) req
             WHERE req.axis_code = e.key
               AND COALESCE(e.value, '[]'::jsonb) ? req.option_code))
$$;

COMMENT ON FUNCTION fn_variant_coverage_is_exact(JSONB, BIGINT) IS
    '精确匹配判定：覆盖范围恰好等于这个变体的要求（不多不少）；宽覆盖（方向 A）返回 false';

-- -------------------------------------------------------------------------------------
-- ⑤ 守卫：配方只许挂在组合上
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_composition_parent()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_role TEXT;
BEGIN
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = NEW.product_variant_id;
    IF v_role IS DISTINCT FROM 'combo' THEN
        RAISE EXCEPTION
            '配方只能挂在 combo 变体上（变体 % 的 role 是 %）',
            NEW.product_variant_id, COALESCE(v_role, '不存在');
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_composition_parent
    BEFORE INSERT OR UPDATE ON supplier_variant_composition
    FOR EACH ROW EXECUTE FUNCTION fn_guard_composition_parent();

COMMENT ON FUNCTION fn_guard_composition_parent() IS
    '守卫：组合配方只许挂在 combo 变体上';

-- -------------------------------------------------------------------------------------
-- ⑤之二 守卫：组合变体不许直接挂源映射
--
-- 为什么必须有这个守卫：
--   组合的成本 = Σ 组件成本 × 数量，一次预订要带整组源 SKU。
--   定价与预订还没接组合（见文首第 6 条），所以组合**不参与选源与定价**。
--
--   但「组合不参与」如果只写在文档里，就等于靠自觉：
--   只要有人（或者某个同步脚本）在 supplier_variant_mapping 里挂了一行
--   组合变体，fn_route_candidates 就会把它当成正常候选，
--   fn_price_variant 会用**一个**源 SKU 的成本给整张套餐定价 ——
--   收 3 个人的钱，出 1 张票。这是本项目最贵的一种 bug。
--
--   覆盖判定挡不住这一手：组合的要求是组件要求的并集，
--   一个「成人+儿童通用票」源 SKU 确实能覆盖住组合的要求，
--   但它是不是「一整套套餐」从 coverage 看不出来 ——
--   它也可能是「一張誰都能用的票」，那按套餐卖就是超卖。
--   看不出来就不能猜，所以从机制上挡住：组合的供给只走配方。
--
--   代价：源侧把整套套餐当**一个** SKU 卖（方向 A）的情况，现在接不了。
--   这是「宁可少卖，不可卖错」的选择。要支持它，得先在源 SKU 上
--   明确标出「这就是一整套」（比如 supplier_variant.packing_size），
--   那是另一段工作。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_combo_mapping()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_role TEXT;
BEGIN
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = NEW.product_variant_id;
    IF v_role = 'combo' THEN
        RAISE EXCEPTION
            '变体 % 是组合套餐，它的供给走配方（supplier_variant_composition），不许直接挂源映射',
            NEW.product_variant_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_combo_mapping
    BEFORE INSERT OR UPDATE ON supplier_variant_mapping
    FOR EACH ROW EXECUTE FUNCTION fn_guard_combo_mapping();

COMMENT ON FUNCTION fn_guard_combo_mapping() IS
    '守卫：组合变体的供给只走配方（supplier_variant_composition），不许直接挂源映射 —— 否则会按一个源 SKU 给整张套餐定价';

-- -------------------------------------------------------------------------------------
-- ⑥ 视图：源侧配方 ↔ 规范侧声明，并排
--
-- 运营排查用：这个组合套餐在源侧到底是哪几个 SKU、各几份、顶的是哪个组件；
-- 规范侧声明了什么、各几份 —— 两侧并排，一眼看出对不对得上。
-- -------------------------------------------------------------------------------------
CREATE VIEW v_variant_composition AS
SELECT c.product_variant_id,
       pv.variant_key,
       pv.title            AS variant_title,
       pv.variant_role,
       c.component_variant_id,
       cv.variant_key      AS component_variant_key,
       cv.title            AS component_variant_title,
       c.supplier_variant_id,
       sv.external_variant_id,
       sv.title            AS source_variant_title,
       sup.code            AS supplier_code,
       sp.external_id      AS supplier_product_external_id,
       c.quantity          AS source_quantity,
       r.quantity          AS declared_quantity
  FROM supplier_variant_composition c
  JOIN product_variant pv  ON pv.id = c.product_variant_id
  JOIN product_variant cv  ON cv.id = c.component_variant_id
  JOIN product_variant_relation r
    ON r.parent_variant_id = c.product_variant_id
   AND r.child_variant_id  = c.component_variant_id
   AND r.relation_type     = 'included'
  JOIN supplier_variant sv ON sv.id = c.supplier_variant_id
  JOIN supplier_product sp ON sp.id = sv.supplier_product_id
  JOIN supplier sup        ON sup.id = sp.supplier_id
 WHERE c.status = 'active';

COMMENT ON VIEW v_variant_composition IS
    '组合映射对照：规范侧的组件声明与源侧的配方并排 —— 数量对不上就说明映射错了';

-- -------------------------------------------------------------------------------------
-- ⑦ 不变量（78-81）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_composition AS
WITH raw (seq, check_name, actual) AS (
    -- 78：组合的成分必须来自同一个源。
    --     一次预订只给一个源；跨源的组合要拆单，那是另一个形状的问题。
    SELECT 78, '组合映射的成分必须来自同一个源',
           (SELECT count(*)
              FROM (SELECT c.product_variant_id
                      FROM supplier_variant_composition c
                      JOIN supplier_variant sv ON sv.id = c.supplier_variant_id
                      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
                      JOIN supplier sup ON sup.id = sp.supplier_id
                     WHERE c.status = 'active'
                     GROUP BY c.product_variant_id
                    HAVING count(DISTINCT sup.id) > 1) x)
    UNION ALL
    -- 79：组合的每个成分都必须对应上一个声明的组件，且覆盖得住。
    --     「源侧给的是成人门票，我们声明的组件是儿童票」—— 这种映射不许存在。
    --     覆盖得住的证据是方向 A 的映射行（那个源 SKU 确实能装出这个组件）。
    SELECT 79, '组合映射的每个成分必须覆盖声明的规范组件',
           (SELECT count(*)
              FROM supplier_variant_composition c
             WHERE c.status = 'active'
               AND NOT EXISTS (
                     SELECT 1
                       FROM product_variant_relation r
                      WHERE r.parent_variant_id = c.product_variant_id
                        AND r.child_variant_id  = c.component_variant_id
                        AND r.relation_type     = 'included'
                        AND r.quantity          = c.quantity)
               AND NOT EXISTS (
                     SELECT 1
                       FROM supplier_variant_mapping m
                      WHERE m.supplier_variant_id = c.supplier_variant_id
                        AND m.product_variant_id  = c.component_variant_id
                        AND m.status = 'active'
                        AND fn_variant_covered(m.coverage, c.component_variant_id)))
    UNION ALL
    -- 80：规范侧声明的每个组件，源侧都必须有且只有一个对应的成分（数量一致）。
    --     少一个成分 = 源侧少给一份；多一个 = 我们多卖了一份；数量不一致 = 卖错规格。
    SELECT 80, '组合映射的规范组件声明必须与源侧成分逐项对得上',
           (SELECT count(*)
              FROM (SELECT r.parent_variant_id, r.child_variant_id,
                           (SELECT count(*)
                              FROM supplier_variant_composition c
                             WHERE c.product_variant_id   = r.parent_variant_id
                               AND c.component_variant_id = r.child_variant_id
                               AND c.quantity            = r.quantity
                               AND c.status = 'active') AS n
                      FROM product_variant_relation r
                     WHERE r.relation_type = 'included'
                       AND EXISTS (SELECT 1 FROM supplier_variant_composition c2
                                    WHERE c2.product_variant_id = r.parent_variant_id
                                      AND c2.status = 'active')) x
             WHERE x.n <> 1)
    UNION ALL
    -- 81：组合变体不许直接挂源映射。
    --     组合的供给只走配方（supplier_variant_composition）。
    --     挂上源映射 = 让定价函数用一个源 SKU 的成本给整张套餐定价
    --     —— 收三个人的钱出一张票。
    --     守卫触发器已经挡住，这里是第二道门（触发器可以被禁用）。
    SELECT 81, '组合变体不得直接挂源映射（供给走配方）',
           (SELECT count(*)
              FROM supplier_variant_mapping m
              JOIN product_variant pv ON pv.id = m.product_variant_id
             WHERE m.status = 'active'
               AND pv.variant_role = 'combo')
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_composition IS
    '组合映射侧不变量（78-81）：成分同源、成分覆盖得住声明的组件、两侧逐项对得上、组合不走直接映射';

-- -------------------------------------------------------------------------------------
-- ⑧ 不变量 29 的口径修订：组合变体不在其管辖范围内
--
-- 不变量 29（原话「active 变体必须有能力定义（人群或至少一个轴取值），
-- 不允许空变体占位」）写于 001，那时每个变体都是叶子 —— 自己带人群或轴取值。
-- 组合变体不是叶子：它没有人群，也没有轴取值，它的能力定义**在它的组件上**
-- （家庭套餐的人群是「成人 + 儿童」，票种是组件的票种）。
-- 按原口径，组合会被判成「空变体占位」—— 那是误判。
--
-- 为什么用改名 + 重建，而不是把 45 条不变量抄一遍改一条：
--   抄一遍就会分叉，分叉的门禁等于没有门禁（003 已经是这个套路）。
--   这里沿用同一招：把原视图改名成 v_invariant_checks_supply（一条不改），
--   再建一个新的 v_invariant_checks_core = 原 45 条（去掉 29）+ 修订后的 29。
--
-- 修订后不变量 29 仍然拦住真正的问题：
--   「一个既没有人群、也没有任何轴取值的 active 变体」—— 空变体占位，照样拦；
--   「一个没有声明任何组件的 combo 变体」—— 同样是空变体（组合的能力全在组件上，
--   没有组件的组合什么都不是），照样拦。
-- -------------------------------------------------------------------------------------
ALTER VIEW v_invariant_checks_core RENAME TO v_invariant_checks_supply;

COMMENT ON VIEW v_invariant_checks_supply IS
    '供给/定价/展示侧 45 条业务不变量自检（012 修订了第 29 条，供给/定价/展示侧其余各条原样保留）';

CREATE VIEW v_invariant_checks_core AS
WITH amended (seq, check_name, expected, actual) AS (
    SELECT 29,
           '在售变体必须有人群或轴取值定义（组合变体除外，但组合必须声明组件）',
           0,
           (SELECT count(*)
              FROM product_variant pv
             WHERE pv.status = 'active'
               AND ( (pv.variant_role <> 'combo'
                      AND pv.ticket_type_id IS NULL
                      AND NOT EXISTS (SELECT 1 FROM product_variant_option pvo
                                       WHERE pvo.product_variant_id = pv.id))
                  OR (pv.variant_role = 'combo'
                      AND NOT EXISTS (SELECT 1 FROM product_variant_relation r
                                       WHERE r.parent_variant_id = pv.id
                                         AND r.relation_type = 'included')) ))
)
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM v_invariant_checks_supply
 WHERE seq <> 29
UNION ALL
SELECT seq, check_name, expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM amended;

COMMENT ON VIEW v_invariant_checks_core IS
    '供给/定价/展示侧 45 条业务不变量自检（第 29 条已按 012 修订：组合变体豁免）';

-- -------------------------------------------------------------------------------------
-- ⑨ 总视图：并集
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
    SELECT * FROM v_invariant_checks_readmodel
    UNION ALL
    SELECT * FROM v_invariant_checks_composition;

COMMENT ON VIEW v_invariant_checks IS '全部 81 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
