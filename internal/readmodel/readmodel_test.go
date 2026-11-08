package readmodel_test

import (
	"testing"

	"ticket-center/internal/readmodel"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 读模型的行为约定：
//   - 刷新后卡片起价必须与价格日历一致（漂移检测说没有就没有）；
//   - 刷新作业漏跑时，漂移检测必须报出来，而且刷新一次就能修好。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

func TestSeededReadModelsHaveNoDrift(t *testing.T) {
	db := seeded(t)
	drifts, err := readmodel.DriftRows(db)
	if err != nil {
		t.Fatalf("查漂移失败：%v", err)
	}
	if len(drifts) != 0 {
		t.Fatalf("种子数据不该有漂移，实际 %d 张：%v", len(drifts), drifts)
	}
}

func TestStaleCardIsDetectedAndFixedByRefresh(t *testing.T) {
	db := seeded(t)

	// 模拟「刷新作业漏跑」：有人改了卡片起价（或源价变了但没刷新）。
	if err := db.Exec(`UPDATE c_product_card SET from_price = from_price + 100
	                     WHERE channel_id = 1 AND product_id = 1 AND locale = 'zh-CN';`); err != nil {
		t.Fatalf("改卡片失败：%v", err)
	}

	drifts, err := readmodel.DriftRows(db)
	if err != nil {
		t.Fatalf("查漂移失败：%v", err)
	}
	if len(drifts) != 1 {
		t.Fatalf("应报出 1 张漂移卡片，实际 %d：%v", len(drifts), drifts)
	}
	if drifts[0].ChannelID != 1 || drifts[0].ProductID != 1 {
		t.Fatalf("漂移卡片定位错了：%v", drifts[0])
	}

	counts, err := readmodel.Refresh(db)
	if err != nil {
		t.Fatalf("刷新失败：%v", err)
	}
	if counts.CardsUpdated == 0 {
		t.Fatal("刷新应更新到卡片")
	}

	drifts, err = readmodel.DriftRows(db)
	if err != nil {
		t.Fatalf("刷新后查漂移失败：%v", err)
	}
	if len(drifts) != 0 {
		t.Fatalf("刷新后不该再有漂移：%v", drifts)
	}
}

func TestRefreshRecomputesPriceFromPriceCalendar(t *testing.T) {
	db := seeded(t)

	before, err := db.Scalar(`SELECT from_price::text FROM c_product_card
	                            WHERE channel_id = 1 AND product_id = 1 AND locale = 'zh-CN';`)
	if err != nil {
		t.Fatalf("读卡片失败：%v", err)
	}

	// 源价涨了 → 重算售价 → 刷新读模型 → 卡片起价跟着变。
	// 取这个商品全部在售行的采纳源（锁价行改净价不生效，所以只动未锁价的）。
	if err := db.Exec(`UPDATE supplier_price_calendar SET net_price = net_price + 50
	                     WHERE supplier_product_id IN (
	                       SELECT cost_source_product_id FROM price_calendar
	                        WHERE product_id = 1 AND channel_id IS NULL AND price_locked = false);`); err != nil {
		t.Fatalf("改源价失败：%v", err)
	}
	if err := db.Exec("SELECT fn_reprice_rows();"); err != nil {
		t.Fatalf("重算售价失败：%v", err)
	}
	if _, err := readmodel.Refresh(db); err != nil {
		t.Fatalf("刷新失败：%v", err)
	}

	after, err := db.Scalar(`SELECT from_price::text FROM c_product_card
	                          WHERE channel_id = 1 AND product_id = 1 AND locale = 'zh-CN';`)
	if err != nil {
		t.Fatalf("读卡片失败：%v", err)
	}
	if before == after {
		t.Fatalf("源价涨了但卡片起价没变：%s", after)
	}

	// 刷新过的卡片不该被判成漂移。
	drifts, err := readmodel.DriftRows(db)
	if err != nil {
		t.Fatalf("查漂移失败：%v", err)
	}
	if len(drifts) != 0 {
		t.Fatalf("刷新后不该有漂移：%v", drifts)
	}
}

func TestRefreshRebuildsVariantFacts(t *testing.T) {
	db := seeded(t)

	counts, err := readmodel.Refresh(db)
	if err != nil {
		t.Fatalf("刷新失败：%v", err)
	}
	if counts.VariantFactsUpdated == 0 {
		t.Fatal("刷新应更新到变体差异事实")
	}

	// 读模型里的变体事实必须与主数据一致（不变量 76）。
	drifted, err := db.Scalar(`SELECT count(*) FROM v_invariant_checks_readmodel
	                            WHERE seq = 76 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if drifted != "0" {
		t.Fatalf("刷新后读模型与主数据仍有分叉：%s", drifted)
	}
}

func TestRefreshDropsFactsForVariantsRemovedFromCalendar(t *testing.T) {
	db := seeded(t)

	before, err := db.Scalar("SELECT count(*) FROM c_variant_facts;")
	if err != nil {
		t.Fatalf("数事实失败：%v", err)
	}
	if before == "0" {
		t.Fatal("种子数据里该有变体事实")
	}

	// 渠道撤下一个变体（现实里就是下架）。
	if err := db.Exec("DELETE FROM c_variant_calendar WHERE channel_id = 1 AND product_variant_id = 16;"); err != nil {
		t.Fatalf("撤日历格子失败：%v", err)
	}
	if _, err := readmodel.Refresh(db); err != nil {
		t.Fatalf("刷新失败：%v", err)
	}

	after, err := db.Scalar("SELECT count(*) FROM c_variant_facts;")
	if err != nil {
		t.Fatalf("数事实失败：%v", err)
	}
	if after == before {
		t.Fatalf("撤下的变体事实没被清掉：%s", after)
	}
	ghost, err := db.Scalar("SELECT count(*) FROM c_variant_facts WHERE product_variant_id = 16;")
	if err != nil {
		t.Fatalf("查幽灵事实失败：%v", err)
	}
	if ghost != "0" {
		t.Fatalf("日历上没格子的变体还留着事实：%s", ghost)
	}
}
