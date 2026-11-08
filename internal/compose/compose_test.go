package compose_test

import (
	"strings"
	"testing"

	"ticket-center/internal/compose"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 组合映射（异构融合方向 B）的行为约定：
//   - 源侧一条组合表达式（多个源 SKU 按数量）要能解成一张配方；
//   - 每一段配到规范侧声明的一个组件上，配不出来就报错，不猜；
//   - 数量必须一致：源侧要 2 份，规范侧就得声明 2 份；
//   - 组合的成分必须来自同一个源；
//   - 落库后不变量 78-80 全绿。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

// setup 在种子库上摆一个「家庭套餐（2 大 1 小）」的组合场景：
// 规范侧声明两个组件，源侧两个 SKU 各顶一个。
func setup(t *testing.T, db *store.DB) {
	t.Helper()
	stmts := []string{
		// 组合变体（规范侧）
		`INSERT INTO product_variant (id, product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order)
		 OVERRIDING SYSTEM VALUE VALUES (30, 6, 'USJ-FAMILY-TEST', 'test:family', '家庭套餐（测试）', 'combo', NULL, 'active', 90);`,
		// 声明组件：成人票 ×2、儿童票 ×1
		`INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
		 VALUES (30, 9, 'included', 2, '{}'::jsonb, 10),
		        (30, 10, 'included', 1, '{}'::jsonb, 20);`,
		// 源侧两个 SKU（挂在 zowoyoo 的源商品 10 下 —— 同一个源）
		`INSERT INTO supplier_variant (id, supplier_product_id, external_variant_id, title, variant_attrs, status)
		 OVERRIDING SYSTEM VALUE VALUES (30, 10, 'TEST-ADULT', '成人票（测试）', '{}'::jsonb, 'active'),
		        (31, 10, 'TEST-CHILD', '儿童票（测试）', '{}'::jsonb, 'active');`,
		// 方向 A 的映射：这两个源 SKU 确实能装出对应组件（组合映射的覆盖证据）
		`INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, coverage, is_exact, match_type, confidence, status)
		 VALUES (30, 9, '{"axes":{"audience":["adult"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}', true, 'manual', 1.000, 'active'),
		        (31, 10, '{"axes":{"audience":["child"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}', true, 'manual', 1.000, 'active');`,
	}
	for _, s := range stmts {
		if err := db.Exec(s); err != nil {
			t.Fatalf("铺场景失败：%v\n%s", err, s)
		}
	}
}

// adultPart / childPart 是源侧的两段。
func adultPart(qty int) compose.Part {
	return compose.Part{
		Variant: compose.SourceVariant{
			ID:         30,
			ExternalID: "TEST-ADULT",
			Coverage: normalize.Coverage{Axes: map[string][]string{
				"audience": {"adult"}, "pass_type": {"1d"}, "park_scope": {"studio_only"},
			}},
		},
		Quantity: qty,
	}
}

func childPart(qty int) compose.Part {
	return compose.Part{
		Variant: compose.SourceVariant{
			ID:         31,
			ExternalID: "TEST-CHILD",
			Coverage: normalize.Coverage{Axes: map[string][]string{
				"audience": {"child"}, "pass_type": {"1d"}, "park_scope": {"studio_only"},
			}},
		},
		Quantity: qty,
	}
}

func TestResolvePairsEachSourceSkuWithDeclaredComponent(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	plan, err := compose.Resolve(db, "test:family", []compose.Part{adultPart(2), childPart(1)})
	if err != nil {
		t.Fatalf("解组合失败：%v", err)
	}
	if len(plan.Resolved) != 2 {
		t.Fatalf("配方该有两行，实际 %d 行", len(plan.Resolved))
	}
	byKey := map[string]compose.Resolved{}
	for _, r := range plan.Resolved {
		byKey[r.Key] = r
	}
	adult, ok := byKey["adult:1d:studio_only"]
	if !ok {
		t.Fatalf("配方里没有成人票组件：%+v", plan.Resolved)
	}
	if adult.ExternalID != "TEST-ADULT" || adult.SourceQuantity != "2" {
		t.Fatalf("成人票组件配错了：%+v", adult)
	}
	child, ok := byKey["child:1d:studio_only"]
	if !ok {
		t.Fatalf("配方里没有儿童票组件：%+v", plan.Resolved)
	}
	if child.ExternalID != "TEST-CHILD" || child.SourceQuantity != "1" {
		t.Fatalf("儿童票组件配错了：%+v", child)
	}
	// 整张配方合起来覆盖得住这个组合本身。
	if !plan.CoveredByUnion {
		t.Fatalf("整张配方合起来应该覆盖得住组合，缺口：%v", plan.UnionGaps)
	}
}

func TestResolveRejectsQuantityMismatch(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	// 规范侧声明成人票 2 份，源侧却要 3 份 —— 对不上，当场报错。
	_, err := compose.Resolve(db, "test:family", []compose.Part{adultPart(3), childPart(1)})
	if err == nil {
		t.Fatal("数量对不上应当报错")
	}
	if !strings.Contains(err.Error(), "对不上") {
		t.Fatalf("报错要说清是数量对不上，实际：%v", err)
	}
}

func TestResolveRejectsSourceSkuCoveringNothing(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	// 老年票覆盖不住任何声明的组件。
	part := adultPart(2)
	part.Variant.Coverage = normalize.Coverage{Axes: map[string][]string{
		"audience": {"senior"}, "pass_type": {"1d"}, "park_scope": {"studio_only"},
	}}
	_, err := compose.Resolve(db, "test:family", []compose.Part{part, childPart(1)})
	if err == nil {
		t.Fatal("覆盖不住任何组件应当报错")
	}
	if !strings.Contains(err.Error(), "覆盖不住") {
		t.Fatalf("报错要说清是覆盖不住，实际：%v", err)
	}
}

func TestResolveRejectsMissingComponent(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	// 源侧只给了成人票 —— 儿童票没人顶，配方不完整。
	_, err := compose.Resolve(db, "test:family", []compose.Part{adultPart(2)})
	if err == nil {
		t.Fatal("少一个成分应当报错")
	}
	if !strings.Contains(err.Error(), "child:1d:studio_only") {
		t.Fatalf("报错要说清缺哪个组件，实际：%v", err)
	}
}

func TestResolveRejectsUnknownCombo(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	if _, err := compose.Resolve(db, "test:no-such-combo", []compose.Part{adultPart(2)}); err == nil {
		t.Fatal("不存在的组合应当报错")
	}
}

func TestApplyWritesRecipeAndKeepsInvariantsGreen(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	plan, err := compose.Resolve(db, "test:family", []compose.Part{adultPart(2), childPart(1)})
	if err != nil {
		t.Fatalf("解组合失败：%v", err)
	}
	if err := compose.Apply(db, plan); err != nil {
		t.Fatalf("写配方失败：%v", err)
	}

	n, err := db.Scalar(`SELECT count(*) FROM supplier_variant_composition
	                     WHERE status = 'active' AND product_variant_id = 30;`)
	if err != nil {
		t.Fatalf("数配方行失败：%v", err)
	}
	if n != "2" {
		t.Fatalf("配方该有两行，实际 %s 行", n)
	}

	// 再写一次，结果一样（幂等）。
	if err := compose.Apply(db, plan); err != nil {
		t.Fatalf("重复写配方失败：%v", err)
	}
	n, err = db.Scalar(`SELECT count(*) FROM supplier_variant_composition
	                     WHERE status = 'active' AND product_variant_id = 30;`)
	if err != nil {
		t.Fatalf("数配方行失败：%v", err)
	}
	if n != "2" {
		t.Fatalf("重复写之后配方该还是两行，实际 %s 行", n)
	}

	// 不变量 78-80 必须全绿。
	bad, err := db.Scalar(`SELECT count(*) FROM v_invariant_checks WHERE seq >= 78 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if bad != "0" {
		t.Fatalf("组合映射侧不变量有 %s 条不通过", bad)
	}
}

func TestApplyRetiresCompositionDroppedFromExpression(t *testing.T) {
	db := seeded(t)
	setup(t, db)

	plan, err := compose.Resolve(db, "test:family", []compose.Part{adultPart(2), childPart(1)})
	if err != nil {
		t.Fatalf("解组合失败：%v", err)
	}
	if err := compose.Apply(db, plan); err != nil {
		t.Fatalf("写配方失败：%v", err)
	}

	// 源侧表达式改了（儿童票不给了）：旧的那行退成 retired，不删 ——
	// 卖过的事实不许被改写。
	plan.Resolved = plan.Resolved[:1]
	if err := compose.Apply(db, plan); err != nil {
		t.Fatalf("改写配方失败：%v", err)
	}
	active, err := db.Scalar(`SELECT count(*) FROM supplier_variant_composition
	                          WHERE status = 'active' AND product_variant_id = 30;`)
	if err != nil {
		t.Fatalf("数在用配方失败：%v", err)
	}
	if active != "1" {
		t.Fatalf("在用配方该剩一行，实际 %s 行", active)
	}
	retired, err := db.Scalar(`SELECT count(*) FROM supplier_variant_composition
	                            WHERE status = 'retired' AND product_variant_id = 30;`)
	if err != nil {
		t.Fatalf("数退掉配方失败：%v", err)
	}
	if retired != "1" {
		t.Fatalf("退掉的配方该有一行，实际 %s 行", retired)
	}
}
