package variant_test

import (
	"strconv"
	"strings"
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
	"ticket-center/internal/variant"
)

// 异构差异模型的行为约定：
//   - 两个可售单元差在哪，一行对照看得出来（人群 / 轴 / 有效期 / 退款口径）；
//   - 有效期是数据不是常量：两日票报 2 天，不许报成 1 天；
//   - 源供不了某个变体时要说清缺什么，不许装作能供；
//   - 差异要走到 C 端读模型上（请求链路不许 join 主数据）。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

func find(t *testing.T, rows []variant.Comparison, code string) variant.Comparison {
	t.Helper()
	for _, r := range rows {
		if r.VariantCode == code {
			return r
		}
	}
	t.Fatalf("对照表里没有变体 %s", code)
	return variant.Comparison{}
}

func TestCompareShowsWhatMakesTwoVariantsDifferent(t *testing.T) {
	db := seeded(t)

	rows, err := variant.Compare(db, 0)
	if err != nil {
		t.Fatalf("查对照表失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("对照表不该是空的")
	}

	// 园区范围不同：studio_only vs studio_snw。
	only := find(t, rows, "USJ-ADULT-1D-STD")
	snw := find(t, rows, "USJ-ADULT-1D-SNW")
	if !strings.Contains(only.Axes, `"park_scope": "studio_only"`) {
		t.Fatalf("轴取值没带出来：%s", only.Axes)
	}
	if !strings.Contains(snw.Axes, `"park_scope": "studio_snw"`) {
		t.Fatalf("轴取值没带出来：%s", snw.Axes)
	}
	if only.Axes == snw.Axes {
		t.Fatal("两个变体的轴取值不同，对照表却显示成一样")
	}
	if only.Audience != "adult" || snw.Audience != "adult" {
		t.Fatalf("人群读错了：%q / %q", only.Audience, snw.Audience)
	}
}

func TestCompareReportsValidityDaysFromAxisOption(t *testing.T) {
	db := seeded(t)

	rows, err := variant.Compare(db, 0)
	if err != nil {
		t.Fatalf("查对照表失败：%v", err)
	}

	two := find(t, rows, "USJ-ADULT-2D-STD")
	if two.ValidDays != 2 {
		t.Fatalf("两日票的有效天数应为 2，实际 %d", two.ValidDays)
	}
	one := find(t, rows, "USJ-ADULT-1D-STD")
	if one.ValidDays != 1 {
		t.Fatalf("单日票的有效天数应为 1，实际 %d", one.ValidDays)
	}
}

func TestCompareCountsOnlySourcesThatCanFulfil(t *testing.T) {
	db := seeded(t)

	rows, err := variant.Compare(db, 0)
	if err != nil {
		t.Fatalf("查对照表失败：%v", err)
	}

	// 1D-SNW 的儿童票只有 zowoyoo 一家能供（trip.com 没这个变体）。
	childSnw := find(t, rows, "USJ-CHILD-1D-SNW")
	if childSnw.SourceCount != 1 || childSnw.FulfilableSourceCount != 1 {
		t.Fatalf("SNW 儿童票的源计数不对：有源 %d、能供 %d",
			childSnw.SourceCount, childSnw.FulfilableSourceCount)
	}

	// 两日票有两个源，都能供。
	two := find(t, rows, "USJ-ADULT-2D-STD")
	if two.SourceCount != 2 || two.FulfilableSourceCount != 2 {
		t.Fatalf("两日票的源计数不对：有源 %d、能供 %d",
			two.SourceCount, two.FulfilableSourceCount)
	}
	if !strings.Contains(two.Suppliers, "trip_com") || !strings.Contains(two.Suppliers, "zowoyoo") {
		t.Fatalf("可用源列表不对：%s", two.Suppliers)
	}
}

func TestSourceCoverageReportsGapWhenSourceCannotCover(t *testing.T) {
	db := seeded(t)

	// 先确认种子状态下两家源都能供两日票。
	rows, err := variant.SourceCoverage(db, 14)
	if err != nil {
		t.Fatalf("查覆盖失败：%v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("两日票应有两条源覆盖，实际 %d", len(rows))
	}
	for _, r := range rows {
		if !r.CanFulfil {
			t.Fatalf("种子状态下 %s 应该能供两日票：%v", r.SupplierCode, r.Gaps)
		}
	}

	// 把某家源的覆盖改成「不含两日票」——现实里就是源侧不卖两日票。
	if err := db.Exec(`UPDATE supplier_variant_mapping svm
	                     SET coverage = jsonb_set(coverage, '{axes,pass_type}', '["1d"]'::jsonb)
	                   WHERE svm.product_variant_id = 14
	                     AND EXISTS (SELECT 1 FROM supplier_variant sv
	                                 JOIN supplier_product sp ON sp.id = sv.supplier_product_id
	                                 JOIN supplier sup ON sup.id = sp.supplier_id
	                                WHERE sv.id = svm.supplier_variant_id AND sup.code = 'zowoyoo');`); err != nil {
		t.Fatalf("改覆盖失败：%v", err)
	}

	rows, err = variant.SourceCoverage(db, 14)
	if err != nil {
		t.Fatalf("查覆盖失败：%v", err)
	}
	var bad *variant.Coverage
	for i := range rows {
		if rows[i].SupplierCode == "zowoyoo" {
			bad = &rows[i]
		}
	}
	if bad == nil {
		t.Fatal("覆盖表里没有 zowoyoo 这一行")
	}
	if bad.CanFulfil {
		t.Fatal("源供不了两日票，却报成能供")
	}
	if !strings.Contains(bad.Gaps, "pass_type:2d") {
		t.Fatalf("缺什么要说清，实际缺口是 %q", bad.Gaps)
	}
}

func TestFeedCarriesDifferencesToCEndReadModel(t *testing.T) {
	db := seeded(t)

	rows, err := variant.FeedRows(db, 1, 0)
	if err != nil {
		t.Fatalf("查 C 端变体读视图失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("C 端变体读视图不该是空的")
	}

	byCode := map[string]variant.Feed{}
	for _, r := range rows {
		byCode[r.VariantCode] = r
	}

	two, ok := byCode["USJ-ADULT-2D-STD"]
	if !ok {
		t.Fatal("C 端读视图里没有两日票")
	}
	if two.ValidDays != 2 {
		t.Fatalf("C 端读模型里的有效天数应为 2，实际 %d", two.ValidDays)
	}
	if !strings.Contains(two.Axes, `"pass_type": "2d"`) {
		t.Fatalf("C 端读模型里的轴取值没带出来：%s", two.Axes)
	}
	if two.PriceMin == "" || two.PriceMin == "0" {
		t.Fatalf("C 端读模型里没有价格：%+v", two)
	}
	if two.FirstDate == "" || two.LastDate == "" {
		t.Fatalf("C 端读模型里没有可售日期区间：%+v", two)
	}
	if two.AvailableDays < 1 {
		t.Fatalf("C 端读模型里没有可售天数：%+v", two)
	}
}

func TestFeedMatchesVariantFactsRowForRow(t *testing.T) {
	db := seeded(t)

	rows, err := variant.FeedRows(db, 0, 0)
	if err != nil {
		t.Fatalf("查 C 端变体读视图失败：%v", err)
	}

	facts, err := db.Scalar("SELECT count(*) FROM c_variant_facts;")
	if err != nil {
		t.Fatalf("数读模型事实失败：%v", err)
	}
	n, err := strconv.Atoi(facts)
	if err != nil {
		t.Fatalf("读模型事实行数不是一个数：%q", facts)
	}
	if len(rows) != n {
		t.Fatalf("读视图 %d 行，读模型事实 %s 行，对不上", len(rows), facts)
	}
}

func TestCalendarValidToEqualsDatePlusValidityDays(t *testing.T) {
	db := seeded(t)

	bad, err := db.Scalar(`SELECT count(*) FROM c_variant_calendar cvc
	                        WHERE cvc.valid_to IS DISTINCT FROM
	                              cvc.date + fn_variant_validity_days(cvc.product_variant_id);`)
	if err != nil {
		t.Fatalf("查有效期终点失败：%v", err)
	}
	if bad != "0" {
		t.Fatalf("有 %s 个日历格子的有效期终点算错了", bad)
	}
}
