package sync

import (
	"strings"
	"testing"

	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// testDB 起一个一次性库，载入 schema + seed。
func testDB(t *testing.T) *store.DB {
	t.Helper()
	name := testdb.New(t, testdb.Options{Seed: true})
	return store.New(name)
}

// adultCoverage 是能覆盖住 USJ 成人一日工作室票（变体 9）的覆盖声明。
//
// 这三条轴取值就是变体 9 的要求（fn_variant_requirements(9)）：
// pass_type=1d / park_scope=studio_only / audience=adult。
//
// 它同时盖住了别的只要求 audience=adult 的变体 —— 这是**宽覆盖**
// （方向 A：��个源 SKU 覆盖多个可售单元），判定由库里的
// fn_variant_covered 给出，Go 侧不猜。
func adultCoverage() normalize.Coverage {
	return normalize.Coverage{
		Axes: map[string][]string{
			"pass_type":  {"1d"},
			"park_scope": {"studio_only"},
			"audience":   {"adult"},
		},
	}
}

// wideCoverage 只覆盖住一半（缺 park_scope），所以盖不住变体 9。
func wideCoverage() normalize.Coverage {
	return normalize.Coverage{
		Axes: map[string][]string{
			"pass_type": {"1d"},
			"audience":  {"adult"},
		},
	}
}

// sampleCatalog 造一份归一化产物：一个源商品、一个源变体、一条报价。
func sampleCatalog(coverage normalize.Coverage) Catalog {
	return Catalog{
		SupplierCode: "trip_com",
		Products: []normalize.Product{{
			ExternalID: "21081935",
			Name:       "上海迪士尼乐园一日票",
			Raw:        map[string]any{"productID": "21081935", "name": "上海迪士尼乐园一日票"},
			Variants: []normalize.Variant{{
				ExternalID: "sku-adult-1d",
				Title:      "成人票 · 一日",
				Coverage:   coverage,
				Attrs:      map[string]any{"audience": "adult"},
				Raw:        map[string]any{"skuId": "sku-adult-1d"},
				Numbers:    map[string]int{"valid_days": 1},
			}},
			Prices: map[string][]normalize.PriceRow{
				"sku-adult-1d": {{
					ResourceID: "sku-adult-1d",
					Date:       "2026-12-01",
					SalePrice:  floatPtr(520.00),
					NetPrice:   floatPtr(480.00),
					Currency:   "CNY",
					Stock:      intPtr(100),
				}},
			},
		}},
	}
}

func floatPtr(f float64) *float64 { return &f }
func intPtr(i int) *int           { return &i }

// supplierIDOf 读源 id。
func supplierIDOf(t *testing.T, db *store.DB, code string) int64 {
	t.Helper()
	v, err := db.Scalar("SELECT id FROM supplier WHERE code = '" + code + "';")
	if err != nil {
		t.Fatalf("读源失败：%v", err)
	}
	return parseID(v)
}

// TestCoverageComesFromTheDatabase 覆盖判定是库判的，不是 Go 判的。
//
// 这条是硬约束 25：判定只有一个实现（fn_variant_covered）。
// 覆盖得准不准也是同一条规则（fn_variant_coverage_is_exact）。
func TestCoverageComesFromTheDatabase(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	// 精确覆盖 → 盖住变体 9（成人一日工作室）。
	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(adultCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if len(plan.Products) != 1 {
		t.Fatalf("计划里应该有一个商品，实际 %d 个", len(plan.Products))
	}
	covered := plan.Products[0].Variants[0].Covered
	if len(covered) == 0 {
		t.Fatal("精确覆盖没盖住任何规范变体")
	}
	found9 := false
	for _, c := range covered {
		if c.ProductVariantID == 9 {
			found9 = true
			if !c.IsExact {
				t.Error("变体 9 的覆盖应当是精确的（is_exact=true）")
			}
		}
	}
	if !found9 {
		t.Errorf("精确覆盖没有盖住变体 9，实际盖住 %v", covered)
	}

	// 缺一条轴 → 盖不住变体 9。
	plan2, err := buildPlan(db, sid, "trip_com", sampleCatalog(wideCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	for _, c := range plan2.Products[0].Variants[0].Covered {
		if c.ProductVariantID == 9 {
			t.Error("缺 park_scope 的覆盖盖住了变体 9 —— 判定不该在 Go 侧")
		}
	}
}

// TestNewSourceProductIsPendingReview 源侧新来的商品落在 pending_review。
//
// 「它该对应我们哪个商品」是判断，同步作业不做（spec §5.27 第四条）。
//
// 这里用**宽覆盖**（盖住了但不是精确覆盖）：精确覆盖走的是「规则判」那条路，
// 规则自己就能判 —— 那不是「没人判过」。
func TestNewSourceProductIsPendingReview(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(wideCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if got := plan.Products[0].Status; got != "pending_review" {
		t.Errorf("源商品状态 = %q，期望 pending_review", got)
	}
	if got := plan.Products[0].Variants[0].Status; got != "pending_review" {
		t.Errorf("源变体状态 = %q，期望 pending_review", got)
	}
}

// TestEmptyExternalIDIsRejected 外部标识是空的源商品，当场报错，不落。
//
// 不变量 128「不许有匿名商品」：external_id 是幂等锚点的一半，
// 空标识落进库，这一行当场违反 128 —— 而唯一键
// (supplier_id, external_id) 恰恰拦不住它（两行都合法）。
//
// 空标识从哪来：归一化的 id 路径取不到值时 toString(nil) 给的是 ""。
// 源侧 schema 变了、报文是部分响应、新源字段名对不上 —— 都会走到这儿。
//
// **写之前挡住，而不是让 128 事后抓**：128 变红时你只知道「库里坏了」，
// 不知道是哪一次同步干的。同步作业当场报错，运维一眼看出是哪个源。
func TestEmptyExternalIDIsRejected(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	before := countRows(t, db)

	catalog := sampleCatalog(adultCoverage())
	catalog.Products[0].ExternalID = ""

	_, err := buildPlan(db, sid, "trip_com", catalog)
	if err == nil {
		t.Fatalf("空外部标识的源商品本该报错，却算出了计划")
	}
	if !strings.Contains(err.Error(), "外部标识") {
		t.Errorf("错误信息没说出是外部标识的问题：%v", err)
	}

	// 一行都不许落。
	after := countRows(t, db)
	for _, tbl := range []string{
		"supplier_product", "supplier_variant", "supplier_variant_mapping",
		"supplier_price_calendar", "product_mapping",
	} {
		if after[tbl] != before[tbl] {
			t.Errorf("%s 落了 %d 行 —— 报错之前不该有任何写入", tbl, after[tbl]-before[tbl])
		}
	}
}

// TestEmptyVariantExternalIDIsRejected 外部标识是空的源变体，同样当场报错。
func TestEmptyVariantExternalIDIsRejected(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	catalog := sampleCatalog(adultCoverage())
	catalog.Products[0].Variants[0].ExternalID = ""

	_, err := buildPlan(db, sid, "trip_com", catalog)
	if err == nil {
		t.Fatalf("空外部标识的源变体本该报错，却算出了计划")
	}
	if !strings.Contains(err.Error(), "外部标识") {
		t.Errorf("错误信息没说出是外部标识的问题：%v", err)
	}
}

// TestMachineMappingDoesNotBecomeActiveOnItsOwn 机器写的映射不许自己变成 active。
//
// 不变量 132-133：待审核的事实不许漏进可用路径。
//
// 这里用**宽覆盖**：盖住了变体 9，但不是精确覆盖（多给了一条轴），
// 所以「规则判」的那条路走不通 —— 只能等��判。
func TestMachineMappingDoesNotBecomeActiveOnItsOwn(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(wideCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	for _, m := range plan.Products[0].Mappings {
		if m.Status == "active" {
			t.Errorf("没人判过的商品映射落成了 active（product_id=%d）", m.ProductID)
		}
		if m.MatchType != "rule" {
			t.Errorf("机器写的映射 match_type = %q，期望 rule", m.MatchType)
		}
		if m.Confidence > 0.95 {
			t.Errorf("机器写的映射置信度 = %v，封顶 0.95（留 1.000 是冒充人工确认）", m.Confidence)
		}
	}
	for _, v := range plan.Products[0].Variants {
		for _, m := range v.Mappings {
			if m.Status == "active" {
				t.Errorf("没人判过的变体映射落成了 active（product_variant_id=%d）", m.ProductVariantID)
			}
		}
	}
}

// TestApplyIsIdempotent 重放一次同步不会多落任何东西。
//
// 幂等边界是现有的唯一键（spec §5.27 第一条）。
func TestApplyIsIdempotent(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	catalog := sampleCatalog(adultCoverage())

	before := countRows(t, db)

	plan, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}
	afterFirst := countRows(t, db)

	// 重放一次。
	plan2, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if err := apply(db, plan2); err != nil {
		t.Fatalf("重放落库失败：%v", err)
	}
	afterSecond := countRows(t, db)

	if !sameCounts(afterFirst, afterSecond) {
		t.Errorf("重放一次多了行：第一次 %v，第二次 %v", afterFirst, afterSecond)
	}
	if afterFirst["supplier_product"] <= before["supplier_product"] {
		t.Errorf("第一次同步没落进源商品：%v", afterFirst)
	}
}

// TestApplyDoesNotDegradeActiveRows 已经 active 的行不许被降级。
//
// 同步作业只往「更严」的方向走；降级是审批流的动作。
func TestApplyDoesNotDegradeActiveRows(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	// 先落一次，让这批事实进库。
	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(adultCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	// 人把这对认了（模拟审批流的动作）。
	if err := db.Exec("UPDATE product_mapping SET status='active', match_type='manual', " +
		"created_by='ops@demo' WHERE supplier_product_id = " +
		"(SELECT id FROM supplier_product WHERE supplier_id=7 AND external_id='21081935');"); err != nil {
		t.Fatalf("改人工映射失败：%v", err)
	}

	// 再同步一次 —— 这次人工判定还在，映射应该保持 active。
	plan2, err := buildPlan(db, sid, "trip_com", sampleCatalog(adultCoverage()))
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if err := apply(db, plan2); err != nil {
		t.Fatalf("重放落库失败：%v", err)
	}

	status, err := db.Scalar("SELECT status FROM product_mapping WHERE supplier_product_id = " +
		"(SELECT id FROM supplier_product WHERE supplier_id=7 AND external_id='21081935') LIMIT 1;")
	if err != nil {
		t.Fatalf("读映射状态失败：%v", err)
	}
	if status != "active" {
		t.Errorf("人工判过的映射被降级成 %q", status)
	}
}

// TestApplyKeepsHumanMatchEvidence 人工判过的映射，判定依据不许被机器覆盖。
//
// 上一条只守住了 status：映射没被降级，但**判定依据被洗掉了**。
// match_evidence 是「判定依据 JSON」（docs/schema-design.md §3.1）——
// 它的用处就是让自动匹配可解释、可人工复核。人工写下的依据
// （{"signals":[...],"decided_by":"ops@demo"}）被同步作业换成
// {"decoded_by":"sync"} 之后：
//   - 人工为什么这么判的，**没了**；
//   - 这一行开始说「是机器写的」，而机器写的行恰恰是待审核的那类。
//
// 所以人工行的判定依据不许被覆盖 —— 同步作业只往「更严」的方向走，
// 洗掉人的判断依据是往「更松」的方向走（把人工的判断抹成机器的）。
func TestApplyKeepsHumanMatchEvidence(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(adultCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	// 人判过这一对：写上人工的判定依据。
	const humanEvidence = `{"signals": ["title_exact", "same_venue"], "decided_by": "ops@demo"}`
	if err := db.Exec("UPDATE product_mapping SET status='active', match_type='manual', " +
		"created_by='ops@demo', match_evidence='" + humanEvidence + "'::jsonb " +
		"WHERE supplier_product_id = " +
		"(SELECT id FROM supplier_product WHERE supplier_id=7 AND external_id='21081935');"); err != nil {
		t.Fatalf("改人工映射失败：%v", err)
	}

	// 再同步一次。
	plan2, err := buildPlan(db, sid, "trip_com", sampleCatalog(adultCoverage()))
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if err := apply(db, plan2); err != nil {
		t.Fatalf("重放落库失败：%v", err)
	}

	evidence, err := db.Scalar("SELECT match_evidence::text FROM product_mapping WHERE supplier_product_id = " +
		"(SELECT id FROM supplier_product WHERE supplier_id=7 AND external_id='21081935') LIMIT 1;")
	if err != nil {
		t.Fatalf("读判定依据失败：%v", err)
	}
	if evidence != humanEvidence {
		t.Errorf("人工的判定依据被同步作业覆盖了：\n  改前 %s\n  改后 %s", humanEvidence, evidence)
	}
}

// TestSourceVariantValidDaysNullMeansNoConstraint 源侧没报兑现窗口 = 没有约束。
//
// 绝不能折成 0（硬约束 22、34 同一条口径）。
func TestSourceVariantValidDaysNullMeansNoConstraint(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	catalog := sampleCatalog(adultCoverage())
	// 把源变体报的兑现窗口去掉。
	catalog.Products[0].Variants[0].Numbers = map[string]int{}

	plan, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if plan.Products[0].Variants[0].ValidDays != nil {
		t.Errorf("源侧没报兑现窗口却算出了 %v", *plan.Products[0].Variants[0].ValidDays)
	}

	// 报了就照抄。
	catalog2 := sampleCatalog(adultCoverage())
	catalog2.Products[0].Variants[0].Numbers = map[string]int{"valid_days": 2}
	plan2, err := buildPlan(db, sid, "trip_com", catalog2)
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if plan2.Products[0].Variants[0].ValidDays == nil || *plan2.Products[0].Variants[0].ValidDays != 2 {
		t.Errorf("源侧报了兑现窗口 2 天，落库计划里是 %v", plan2.Products[0].Variants[0].ValidDays)
	}
}

// TestExactCoverageCanBecomeActiveByRule 精确覆盖 + 此前没有映射行 → 可以直接 active。
//
// 这是 spec §5.27 的第二条路（「规则做」的那一半）：
// 覆盖是**精确**的（fn_variant_coverage_is_exact 为真），
// 且这一对此前没有任何映射行，规则可以自己判。
func TestExactCoverageCanBecomeActiveByRule(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	// 一个只要求 audience=adult 的变体（变体 7：SKU-CN-THEMEPARK-adult）。
	// 覆盖里只有 audience=adult —— 恰好等于它的要求 → 精确覆盖。
	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(audienceOnlyCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}

	var v7 ProductMappingRows
	found := false
	for _, m := range plan.Products[0].Mappings {
		if m.ProductID == 5 { // 变体 7 属于商品 5（SKU-CN-THEMEPARK）
			v7 = m
			found = true
		}
	}
	if !found {
		t.Fatalf("没有算出品��� 5 的商品映射：%v", plan.Products[0].Mappings)
	}
	if v7.Status != "active" {
		t.Errorf("精确覆盖且此前没有映射行，商品映射状态 = %q，期望 active", v7.Status)
	}
}

// audienceOnlyCoverage 只盖住「只要求 audience=adult」的变体。
//
// 变体 7（SKU-CN-THEMEPARK-adult）的要求就是 audience=adult，
// 所以这份覆盖对它来说是**精确**的。
func audienceOnlyCoverage() normalize.Coverage {
	return normalize.Coverage{
		Axes: map[string][]string{
			"audience": {"adult"},
		},
	}
}

// TestDispositionCountsWhatChanged 台账上的三个计数要真的会数出变更。
//
// created / updated / skipped 是**商品粒度**的：变更检测靠
// supplier_product.content_hash（全表只有源商品有这一列）。
func TestDispositionCountsWhatChanged(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")
	catalog := sampleCatalog(adultCoverage())

	// 第一次：库里没有 → 新建。
	plan, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if plan.Stats.Created != 1 || plan.Stats.Updated != 0 || plan.Stats.Skipped != 0 {
		t.Errorf("第一次同步的计数 = %+v，期望 created=1 其余 0", plan.Stats)
	}
	if plan.Products[0].Disposition != DispositionCreated {
		t.Errorf("第一次同步的处置 = %q，期望 created", plan.Products[0].Disposition)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	// 第二次：报文没变 → 跳过。
	plan2, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if plan2.Stats.Created != 0 || plan2.Stats.Updated != 0 || plan2.Stats.Skipped != 1 {
		t.Errorf("重放一次的计数 = %+v，期望 skipped=1 其余 0", plan2.Stats)
	}
	if plan2.Products[0].Disposition != DispositionSkipped {
		t.Errorf("重放一次的处置 = %q，期望 skipped", plan2.Products[0].Disposition)
	}

	// 第三次：报文变了 → 更新。
	//
	// 改的是**报文本身** —— 变更检测算的是 raw_payload 的哈希，
	// 归一化出来的标题不算（那是我们理解的东西，不是源侧报的东西）。
	catalog3 := sampleCatalog(adultCoverage())
	catalog3.Products[0].Raw = map[string]any{
		"productID": "21081935",
		"name":      "上海迪士尼乐园一日票（改名了）",
	}
	plan3, err := buildPlan(db, sid, "trip_com", catalog3)
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if plan3.Stats.Created != 0 || plan3.Stats.Updated != 1 || plan3.Stats.Skipped != 0 {
		t.Errorf("改了报文之后的计数 = %+v，期望 updated=1 其余 0", plan3.Stats)
	}
	if plan3.Products[0].Disposition != DispositionUpdated {
		t.Errorf("改了报文之后的处置 = %q，期望 updated", plan3.Products[0].Disposition)
	}
}

// TestSkippedProductStillWritesItsPrices 跳过的商品，报价照样落库。
//
// 这条是「跳过 ≠ 不写」的门禁：
// 商品级哈希只覆盖**商品详情**，报价行不在里面 ——
// 源侧只改价不改商品时，哈希不变（skipped），
// 而那一条报价是**新事实**（C 端卡片的价格就靠它）。
//
// 「跳过就不写」会让价格永远停在旧值 —— 读模型永远是旧的。
func TestSkippedProductStillWritesItsPrices(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")
	catalog := sampleCatalog(adultCoverage())

	plan, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	// 源侧只改了价，商品详情一个字没动 → 哈希不变 → skipped。
	catalog2 := sampleCatalog(adultCoverage())
	catalog2.Products[0].Prices["sku-adult-1d"][0].SalePrice = floatPtr(560.00)

	plan2, err := buildPlan(db, sid, "trip_com", catalog2)
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if plan2.Products[0].Disposition != DispositionSkipped {
		t.Fatalf("只改价的处置 = %q，期望 skipped（商品详情没变）", plan2.Products[0].Disposition)
	}
	if err := apply(db, plan2); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	// 价必须落进去 —— 这才是这条测试要守的。
	//
	// 读的是**这一个源商品**的报价行 —— 种子里也有带变体的报价行，
	// 不认源商品就会读到种子那一批去（那批永远不变，测不出任何东西）。
	price, err := db.Scalar("SELECT supplier_price FROM supplier_price_calendar " +
		"WHERE supplier_product_id = (SELECT id FROM supplier_product WHERE external_id = '21081935') " +
		"AND supplier_variant_id IS NOT NULL LIMIT 1;")
	if err != nil {
		t.Fatalf("读报价失败：%v", err)
	}
	if price != "560.00" {
		t.Errorf("报价 = %q，期望 560.00 —— 跳过商品的报价没落库，C 端卡片会一直显示旧价", price)
	}
}

// TestRuleActivationSurvivesTheNextSync 规则判过的映射，下一轮不许被自己判回去。
//
// 这是最容易漏的一条：规则判的那条路要求「此前没有任何映射行」——
// 而规则自己判过之后，这一行**就有了**。
// 下一轮同步再判一次，「没有映射行」不成立 → 落回 pending_review →
// 变体映射跟着落回 → 报价行不再写（只给 active 的映射写）→
// **C 端的价格凭空消失**。
//
// 「判过就是判过」：不管是谁判的，已经 active 的就还是 active。
func TestRuleActivationSurvivesTheNextSync(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")
	catalog := sampleCatalog(adultCoverage())

	// 第一轮：规则判（覆盖精确 + 此前没有映射行）→ active。
	plan, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	status := mapStatus(t, db, "product_mapping", 6)
	if status != "active" {
		t.Fatalf("第一轮之后商品映射状态 = %q，期望 active", status)
	}
	vmStatus := mapStatus(t, db, "supplier_variant_mapping", 9)
	if vmStatus != "active" {
		t.Fatalf("第一轮之后变体映射状态 = %q，期望 active", vmStatus)
	}

	// 第二轮：同一个源商品再来一次。
	plan2, err := buildPlan(db, sid, "trip_com", catalog)
	if err != nil {
		t.Fatalf("重算计划失败：%v", err)
	}
	if err := apply(db, plan2); err != nil {
		t.Fatalf("重放落库失败：%v", err)
	}

	// **断的是计划，不是库里那一行**。
	//
	// 库里的状态有写路径的兜底（已经 active 的不许被降级），
	// 所以只查库里的状态，这一条测试永远绿 ——
	// 而计划已经降级了：第二轮不再产出报价行，
	// **源侧第二次改价就落不进去**（C 端卡片的价格停在旧值）。
	//
	// 所以这里断计划里的状态与报价行数。
	if got := mappingStatusInPlan(plan2, 6); got != "active" {
		t.Errorf("第二轮计划里的商品映射状态 = %q，期望 active（规则判过的不许被自己判回去）", got)
	}
	if got := variantMappingStatusInPlan(plan2, 9); got != "active" {
		t.Errorf("第二轮计划里的变体映射状态 = %q，期望 active", got)
	}
	if n := len(plan2.Products[0].Variants[0].Prices); n != 1 {
		t.Errorf("第二轮计划里的报价行数 = %d，期望 1（映射还是 active，报价就该照写）", n)
	}

	// 库里那一行也不能被降级。
	if got := mapStatus(t, db, "product_mapping", 6); got != "active" {
		t.Errorf("第二轮之后商品映射状态 = %q，期望 active", got)
	}
	if got := mapStatus(t, db, "supplier_variant_mapping", 9); got != "active" {
		t.Errorf("第二轮之后变体映射状态 = %q，期望 active", got)
	}
}

// mappingStatusInPlan 读计划里某个规范商品的商品映射状态。
func mappingStatusInPlan(plan Plan, productID int64) string {
	for _, p := range plan.Products {
		for _, m := range p.Mappings {
			if m.ProductID == productID {
				return m.Status
			}
		}
	}
	return ""
}

// variantMappingStatusInPlan 读计划里某个规范变体的变体映射状态。
func variantMappingStatusInPlan(plan Plan, productVariantID int64) string {
	for _, p := range plan.Products {
		for _, v := range p.Variants {
			for _, m := range v.Mappings {
				if m.ProductVariantID == productVariantID {
					return m.Status
				}
			}
		}
	}
	return ""
}

// TestPendingReviewMappingGetsNoPriceRows 待审核的映射不许有报价行。
//
// spec §5.27：只给 active 的映射写源报价行。
// 给 pending_review 写 = 没审核就上架 ——
// 那条报价会进 fn_route_candidates 的候选集，价格会算出来，货会卖出去。
func TestPendingReviewMappingGetsNoPriceRows(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	// 宽覆盖：盖住了变体 9，但不是精确覆盖 → 规则判不了 → pending_review。
	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(wideCoverage()))
	if err != nil {
		t.Fatalf("算计划失败：%v", err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatalf("落库失败：%v", err)
	}

	n, err := db.Scalar("SELECT count(*) FROM supplier_price_calendar " +
		"WHERE supplier_product_id = (SELECT id FROM supplier_product WHERE external_id = '21081935');")
	if err != nil {
		t.Fatalf("数报价行失败：%v", err)
	}
	if n != "0" {
		t.Errorf("待审核的映射落了 %s 条报价行，期望 0 条", n)
	}
}

// mapStatus 读**这个源商品**在某个规范商品（或规范变体）上的映射状态。
//
// 必须认源商品：种子里已经有好几行 product_mapping 指向同一个规范商品
// （product_id=6 就有三行），不认就会读到种子那一行去 ——
// 测试会为一个跟自己无关的行通过。
func mapStatus(t *testing.T, db *store.DB, table string, id int64) string {
	t.Helper()
	scope := "(SELECT id FROM supplier_product WHERE external_id = '21081935')"
	var sql string
	switch table {
	case "product_mapping":
		sql = "SELECT status FROM product_mapping WHERE supplier_product_id = " + scope +
			" AND product_id = " + store.Quote(id) + " LIMIT 1;"
	case "supplier_variant_mapping":
		sql = "SELECT status FROM supplier_variant_mapping " +
			"WHERE supplier_variant_id IN (SELECT id FROM supplier_variant WHERE supplier_product_id = " + scope + ") " +
			"AND product_variant_id = " + store.Quote(id) + " LIMIT 1;"
	default:
		t.Fatalf("不知道的表 %s", table)
	}
	v, err := db.Scalar(sql)
	if err != nil {
		t.Fatalf("读 %s 状态失败：%v", table, err)
	}
	return v
}

// countRows 数几张表各有几行。
func countRows(t *testing.T, db *store.DB) map[string]int {
	t.Helper()
	out := map[string]int{}
	for _, tbl := range []string{
		"supplier_product", "supplier_variant", "supplier_variant_mapping",
		"supplier_price_calendar", "product_mapping",
	} {
		v, err := db.Scalar("SELECT count(*) FROM " + tbl + ";")
		if err != nil {
			t.Fatalf("数 %s 失败：%v", tbl, err)
		}
		out[tbl] = int(parseID(v))
	}
	return out
}

// sameCounts 比两张计数表。
func sameCounts(a, b map[string]int) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}
