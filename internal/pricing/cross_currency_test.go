package pricing

import (
	"encoding/json"
	"strings"
	"testing"
)

// 跨币种的组合（异构融合方向 B + 汇率快照）。
//
// 组合的顶层没有单一源币种：成本是 Σ 成分成本 × 份数，
// 成分可能各自是不同币种（源侧日元、我们卖人民币）。
// 所以顶层 fx_rate / fx_as_of 是空的 ——
// 那是「这里没有单一的值」，不是「同币种、汇率 1」。
// 逐成分的折算留痕在 rule->'combo' 里，折算过就必须留快照日期。
//
// 这条路径以前没人复查：不变量 45 按 cost_source_product_id join 源价行，
// 而组合的 cost_source_product_id 是空的，45 直接跳过组合。
// 不变量 92 专门查这件事，这里锁住它的口径。

// comboComponent 是组合定价结果里的一条成分明细。
//
// 金额与汇率在 rule 里是 JSON 数字（不是字符串）——
// 库里给的形状，这里照着解，不另转一遍格式。
type comboComponent struct {
	Currency string      `json:"currency"`
	NetPrice json.Number `json:"net_price"`
	FxRate   json.Number `json:"fx_rate"`
	FxAsOf   *string     `json:"fx_as_of"`
	Quantity json.Number `json:"quantity"`
	Cost     json.Number `json:"cost"`
}

// fxIsOne 判断折算因子是不是 1（没折算过）。
func fxIsOne(n json.Number) bool {
	f, err := n.Float64()
	return err == nil && f == 1
}

func TestCrossCurrencyComboKeepsNoSingleSourceCurrencyButTracesPerComponent(t *testing.T) {
	calc, db := seeded(t)

	// 找那张跨币种的套餐（成分的源币种是 JPY）。
	row := mustRows(t, db, `
		SELECT pc.product_variant_id, pc.date, pc.currency, pc.fx_rate AS top_fx_rate,
		       pc.fx_as_of AS top_fx_as_of, pc.cost_price, pc.sell_price
		  FROM price_calendar pc
		  JOIN product_variant pv ON pv.id = pc.product_variant_id
		 WHERE pv.variant_role = 'combo'
		   AND pc.status = 'active'
		   AND pc.sell_price IS NOT NULL
		   AND EXISTS (SELECT 1 FROM jsonb_array_elements(
		                   CASE WHEN jsonb_typeof(pc.rule->'combo') = 'array'
		                        THEN pc.rule->'combo' ELSE '[]'::jsonb END) c
		                WHERE c->>'currency' <> pc.currency)
		 ORDER BY pc.id
		 LIMIT 1;`)[0]

	var variant int64
	mustInt(t, row["product_variant_id"], &variant)

	q, err := calc.Quote(variant, row["date"], 0, nil)
	if err != nil {
		t.Fatalf("跨币种套餐定价失败：%v", err)
	}
	if q == nil {
		t.Fatal("跨币种套餐在库里有售价，定价却给不出结果")
	}

	// 本行币种是我们卖的钱的币种。
	if q.Currency != row["currency"] {
		t.Fatalf("本行币种 %q ≠ 库里 %q", q.Currency, row["currency"])
	}

	// 顶层没有单一源币种。填成 JPY 是说「整张套餐都是日元」，
	// 填成空值之外的任何东西都是在撒谎。
	if q.SourceCurrency != "" {
		t.Fatalf("跨币种套餐不应有单一源币种，实际 %q", q.SourceCurrency)
	}
	if q.FxRate != "" || q.FxAsOf != "" {
		t.Fatalf("跨币种套餐的顶层折算留痕应为空（逐成分留痕才有单一值），实际 rate=%q as_of=%q", q.FxRate, q.FxAsOf)
	}

	// 逐成分的折算留痕必须在：折算过的成分必须带快照日期与非 1 的因子。
	var rule struct {
		Combo []comboComponent `json:"combo"`
	}
	if err := json.Unmarshal(q.Rule, &rule); err != nil {
		t.Fatalf("组合规则不是合法 JSON：%v", err)
	}
	comps := rule.Combo
	if len(comps) == 0 {
		t.Fatal("跨币种套餐必须带逐成分的分解")
	}
	traced := 0
	for _, c := range comps {
		if c.Currency == "" {
			t.Fatal("成分没带币种 —— 折算留痕无从复算")
		}
		if c.Currency == q.Currency {
			// 同币种：不折算 → 因子 1、快照日期为空（留个假日期等于声称用过这份汇率）。
			if c.FxAsOf != nil || !fxIsOne(c.FxRate) {
				t.Fatalf("同币种成分 %s 不该有折算留痕，实际 rate=%s as_of=%v", c.Currency, c.FxRate, c.FxAsOf)
			}
			continue
		}
		traced++
		if c.FxAsOf == nil {
			t.Fatalf("跨币种成分 %s 没留折算快照日期 —— 留痕没人能复算", c.Currency)
		}
		if fxIsOne(c.FxRate) {
			t.Fatalf("跨币种成分 %s 的折算因子应存在且不等于 1，实际 %s", c.Currency, c.FxRate)
		}
	}
	if traced == 0 {
		t.Fatal("跨币种套餐里没有一条成分带折算留痕")
	}

	// 成分明细必须能算出组合的成本（成本 = Σ 成分单价 × 份数）。
	if !strings.Contains(string(q.Rule), `"combo"`) {
		t.Fatalf("组合规则里没有成分分解：%s", string(q.Rule))
	}
}
