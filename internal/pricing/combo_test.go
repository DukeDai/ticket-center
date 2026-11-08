package pricing

import (
	"strings"
	"testing"
)

// 组合（异构融合方向 B）的定价结果与普通可售单元不一样：
//
//   - 没有单一的采纳源（成本是 Σ 成分成本 × 份数，逐成分明细在 rule.combo 里）；
//   - 所以供应商商品 id 是空的，源币种 / 源净价 / 折算因子也是空的。
//
// 空的含义是「这里没有单一的值」，不是「同币种、汇率 1」——
// 把它们当成 0 或 1 就是把一份套餐的成本说成了一部分。

func TestComboQuoteHasNoSingleAdoptedSource(t *testing.T) {
	calc, db := seeded(t)

	row := mustRows(t, db, `
		SELECT product_variant_id, date, cost_price, sell_price
		  FROM price_calendar
		 WHERE product_variant_id IN (SELECT id FROM product_variant WHERE variant_role = 'combo')
		   AND status = 'active' AND sell_price IS NOT NULL
		 ORDER BY id
		 LIMIT 1;`)[0]

	var variant int64
	mustInt(t, row["product_variant_id"], &variant)

	q, err := calc.Quote(variant, row["date"], 0, nil)
	if err != nil {
		t.Fatalf("组合定价失败：%v", err)
	}
	if q == nil {
		t.Fatal("组合在库里有售价，定价却给不出结果")
	}
	if !q.IsCombo {
		t.Fatal("组合的定价结果应被认出来是组合")
	}
	if q.SupplierProductID != nil {
		t.Fatalf("组合没有单一采纳源，实际给出了 %d", *q.SupplierProductID)
	}
	if q.CostPrice != row["cost_price"] {
		t.Fatalf("组合成本 %s ≠ 库里 %s", q.CostPrice, row["cost_price"])
	}
	if q.SellPrice != row["sell_price"] {
		t.Fatalf("组合售价 %s ≠ 库里 %s", q.SellPrice, row["sell_price"])
	}
}

func TestComboQuoteCarriesTheComponentBreakdown(t *testing.T) {
	calc, db := seeded(t)

	row := mustRows(t, db, `
		SELECT pc.product_variant_id, pc.date
		  FROM price_calendar pc
		  JOIN product_variant pv ON pv.id = pc.product_variant_id
		 WHERE pv.variant_role = 'combo'
		   AND pc.status = 'active' AND pc.sell_price IS NOT NULL
		 ORDER BY pc.id
		 LIMIT 1;`)[0]

	var variant int64
	mustInt(t, row["product_variant_id"], &variant)

	q, err := calc.Quote(variant, row["date"], 0, nil)
	if err != nil {
		t.Fatalf("组合定价失败：%v", err)
	}
	if len(q.Rule) == 0 {
		t.Fatal("组合的定价结果必须带规则")
	}
	// 规则里必须有逐成分的分解（成本 = Σ 成分单价 × 份数）。
	if !strings.Contains(string(q.Rule), `"combo"`) {
		t.Fatalf("组合的规则里没有成分分解：%s", string(q.Rule))
	}
}
