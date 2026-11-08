package normalize

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func rulesPath(t *testing.T) string {
	t.Helper()
	p := filepath.Join("..", "..", "configs", "mapping_rules.json")
	if _, err := os.Stat(p); err != nil {
		t.Skipf("找不到规则文件：%v", err)
	}
	return p
}

func TestUnionCoverage(t *testing.T) {
	a := Coverage{Axes: map[string][]string{"audience": {"adult"}, "pass_type": {"1d"}}}
	b := Coverage{Axes: map[string][]string{"audience": {"child"}, "pass_type": {"1d"}}}
	u := UnionCoverage([]Coverage{a, b})
	if len(u.Axes["audience"]) != 2 {
		t.Errorf("并集人群不对：%v", u.Axes["audience"])
	}
	if len(u.Axes["pass_type"]) != 1 {
		t.Errorf("并集票种不对：%v", u.Axes["pass_type"])
	}
}

func TestNormalizeTripComFixture(t *testing.T) {
	rules, err := LoadRules(rulesPath(t))
	if err != nil {
		t.Fatalf("读规则失败：%v", err)
	}
	p := filepath.Join("..", "..", "fixtures", "trip_com_catalog.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("找不到样例报文：%v", err)
	}
	res, err := rules.Normalize("trip_com", raw)
	if err != nil {
		t.Fatalf("归一化失败：%v", err)
	}
	if len(res.Products) != 3 {
		t.Errorf("源商品 = %d，期望 3", len(res.Products))
	}
	if len(res.Variants) != 10 {
		t.Errorf("源变体 = %d，期望 10", len(res.Variants))
	}
	// 每个源变体都必须带覆盖声明
	for _, v := range res.Variants {
		if len(v.Coverage.Axes) == 0 {
			t.Errorf("源变体 %s 没有覆盖声明", v.ExternalID)
		}
	}
	// 价格：报价必须挂在拥有该变体的商品上
	priceCount := 0
	for _, prod := range res.Products {
		for vid, rows := range prod.Prices {
			if len(rows) == 0 {
				continue
			}
			priceCount += len(rows)
			owned := false
			for _, v := range prod.Variants {
				if v.ExternalID == vid {
					owned = true
				}
			}
			if !owned {
				t.Errorf("商品 %s 挂了不属于自己的变体报价 %s", prod.ExternalID, vid)
			}
		}
	}
	if priceCount == 0 {
		t.Error("没有解析出任何报价行")
	}
}

func TestPriceRowsNestedCalendar(t *testing.T) {
	rules, err := LoadRules(rulesPath(t))
	if err != nil {
		t.Fatalf("读规则失败：%v", err)
	}
	rule := rules.Sources["trip_com"]
	res := map[string]any{
		"resourceID": 1,
		"calendarDetailList": []any{
			map[string]any{"date": "2026-11-16", "salePrice": 558.0, "netPrice": 545.0, "currency": "CNY", "stock": 20},
			map[string]any{"date": "2026-11-17", "salePrice": 558.0, "netPrice": 545.0, "currency": "CNY", "stock": 10},
		},
	}
	rows := priceRows(res, rule)
	if len(rows) != 2 {
		t.Fatalf("报价行 = %d，期望 2（嵌套日历一天一条）", len(rows))
	}
	if rows[0].Date != "2026-11-16" || rows[1].Date != "2026-11-17" {
		t.Errorf("日期不对：%v", rows)
	}
}

func TestPriceRowsFlatFallback(t *testing.T) {
	rules, err := LoadRules(rulesPath(t))
	if err != nil {
		t.Fatalf("读规则失败：%v", err)
	}
	rule := rules.Sources["trip_com"]
	res := map[string]any{"resourceID": 1, "date": "2026-11-16", "salePrice": 558.0, "netPrice": 545.0}
	rows := priceRows(res, rule)
	if len(rows) != 1 {
		t.Fatalf("报价行 = %d，期望 1（平铺形态兼容）", len(rows))
	}
	if rows[0].Date != "2026-11-16" {
		t.Errorf("日期不对：%s", rows[0].Date)
	}
}

func TestNormalizeGlobalTixCompositeExpression(t *testing.T) {
	rules, err := LoadRules(rulesPath(t))
	if err != nil {
		t.Fatalf("读规则失败：%v", err)
	}
	p := filepath.Join("..", "..", "fixtures", "globaltix_catalog.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("找不到样例报文：%v", err)
	}
	res, err := rules.Normalize("globaltix", raw)
	if err != nil {
		t.Fatalf("归一化失败：%v", err)
	}
	composite := 0
	for _, e := range res.CompositeExpressions {
		if e.IsComposite {
			composite++
		}
	}
	if composite == 0 {
		t.Error("没有解析出组合表达式（GlobalTix 的 A|2+B|1）")
	}
	for _, e := range res.CompositeExpressions {
		for _, p := range e.Parts {
			if p.Qty < 1 {
				t.Errorf("组合表达式份数不对：%+v", p)
			}
		}
	}
}

func TestDig(t *testing.T) {
	obj := map[string]any{"a": map[string]any{"b": "c"}}
	if v := Dig(obj, "a.b"); v != "c" {
		t.Errorf("Dig = %v", v)
	}
	if v := Dig(obj, "a.x.y"); v != nil {
		t.Errorf("缺失路径应返回 nil，得到 %v", v)
	}
}

func TestResolveAxesCaseInsensitive(t *testing.T) {
	raw := map[string]any{"bandCode": "ADULT"}
	rules := []AxisRule{{AxisCode: "audience", ValuePath: "bandCode",
		ValueMap: map[string]string{"adult": "adult"}}}
	out := ResolveAxes(raw, rules)
	if out["audience"] != "adult" {
		t.Errorf("轴取值解析失败：%v", out)
	}
}

func TestResolveFlagsEquals(t *testing.T) {
	yes := true
	rules := map[string]FlagRule{"is_price_locked": {Path: "isPrivatePrice", Equals: &yes}}
	out := ResolveFlags(map[string]any{"isPrivatePrice": true}, rules)
	if !out["is_price_locked"] {
		t.Error("标志解析失败")
	}
	out = ResolveFlags(map[string]any{}, rules)
	if out["is_price_locked"] {
		t.Error("缺失字段应为 false")
	}
}

func TestCoverageJSONRoundTrip(t *testing.T) {
	cov := Coverage{Axes: map[string][]string{"audience": {"adult"}}, Excludes: []string{}}
	raw, err := json.Marshal(cov)
	if err != nil {
		t.Fatal(err)
	}
	var back Coverage
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if len(back.Axes["audience"]) != 1 {
		t.Errorf("往返失败：%v", back)
	}
}
