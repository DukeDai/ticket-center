package variant_test

import (
	"testing"

	"ticket-center/internal/variant"
)

// 组合在 C 端的差异事实：
//
//   - 组合在读模型里必须被认出来（是套餐、有几个成分、成分是谁）；
//   - 成分的份数、人群编码、各自的天数必须带出来，且不许与主数据分叉；
//   - 有效期是并集：两日成人 + 一日儿童 = 两天。

func TestFeedCarriesComboComposition(t *testing.T) {
	db := seeded(t)

	rows, err := variant.FeedRows(db, 0, 0)
	if err != nil {
		t.Fatalf("查读模型失败：%v", err)
	}

	var combo *variant.Feed
	for i := range rows {
		if rows[i].IsCombo {
			combo = &rows[i]
			break
		}
	}
	if combo == nil {
		t.Fatal("读模型里没有组合（刷新作业漏跑了？）")
	}
	if combo.ComponentCount != 2 {
		t.Fatalf("组合应有 2 个成分，实际 %d", combo.ComponentCount)
	}
	if combo.ComboAudience == "" {
		t.Fatal("组合应带出成分的人群编码")
	}
	if combo.Composition == "" {
		t.Fatal("组合应带出构成明细")
	}
}

func TestCompositionRowsExposeAudienceAndDays(t *testing.T) {
	db := seeded(t)

	rows, err := variant.CompositionRows(db, 0, 0)
	if err != nil {
		t.Fatalf("查组合成分失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("读模型里没有组合成分记录")
	}

	// 找那张混合窗口的套餐：2 份两日成人 + 1 份一日儿童。
	var mixed []variant.Component
	for _, r := range rows {
		if r.VariantKey == "family:2adult2d:1child1d:studio_only" {
			mixed = append(mixed, r)
		}
	}
	if len(mixed) != 2 {
		t.Fatalf("混合窗口的套餐应有 2 个成分，实际 %d", len(mixed))
	}

	byAudience := map[string]variant.Component{}
	for _, r := range mixed {
		byAudience[r.AudienceCode] = r
	}
	adult, ok := byAudience["adult"]
	if !ok {
		t.Fatalf("成分里没有成人：%v", mixed)
	}
	if adult.Quantity != "2.00" {
		t.Fatalf("成人份数应为 2，实际 %s", adult.Quantity)
	}
	if adult.ValidDays != 2 {
		t.Fatalf("两日成人的成分应管 2 天，实际 %d", adult.ValidDays)
	}

	child, ok := byAudience["child"]
	if !ok {
		t.Fatalf("成分里没有儿童：%v", mixed)
	}
	if child.Quantity != "1.00" {
		t.Fatalf("儿童份数应为 1，实际 %s", child.Quantity)
	}
	if child.ValidDays != 1 {
		t.Fatalf("一日儿童的成分应管 1 天，实际 %d", child.ValidDays)
	}
}

// TestCompositionRowsMustBeReadPerChannel 守住读模型的按渠道读法。
//
// C 端读模型是按渠道建的：一个套餐上了两个渠道就有两份成分明细。
// 不按渠道过滤的话，「2 份成人 + 1 份儿童」被数成两遍 ——
// 详情页会显示 4 份成人，实际只发 2 份。
func TestCompositionRowsMustBeReadPerChannel(t *testing.T) {
	db := seeded(t)

	rows, err := variant.FeedRows(db, 0, 0)
	if err != nil {
		t.Fatalf("查读模型失败：%v", err)
	}

	checked := 0
	for _, r := range rows {
		if !r.IsCombo {
			continue
		}
		comps, err := variant.CompositionRows(db, r.ChannelID, r.ProductVariantID)
		if err != nil {
			t.Fatalf("查组合成分失败：%v", err)
		}
		if len(comps) != r.ComponentCount {
			t.Fatalf("套餐 %s 在渠道 %d 的成分明细有 %d 行，但事实说有 %d 个成分",
				r.VariantCode, r.ChannelID, len(comps), r.ComponentCount)
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("读模型里没有组合，这条测试什么都没验")
	}
}

func TestComboWindowInFeedIsTheUnionOfComponentWindows(t *testing.T) {
	db := seeded(t)

	rows, err := variant.FeedRows(db, 0, 0)
	if err != nil {
		t.Fatalf("查读模型失败：%v", err)
	}
	for _, r := range rows {
		if !r.IsCombo {
			continue
		}
		comps, err := variant.CompositionRows(db, r.ChannelID, r.ProductVariantID)
		if err != nil {
			t.Fatalf("查组合成分失败：%v", err)
		}
		max := 0
		for _, c := range comps {
			if c.ValidDays > max {
				max = c.ValidDays
			}
		}
		if r.ValidDays != max {
			t.Fatalf("组合 %s 给客户 %d 天，但成分窗口的并集是 %d 天",
				r.VariantCode, r.ValidDays, max)
		}
	}
}
