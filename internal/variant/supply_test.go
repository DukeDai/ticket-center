package variant_test

import (
	"strconv"
	"strings"
	"testing"

	"ticket-center/internal/variant"
)

// 三种供给形态（单张 / 配方 / 套装）的读侧约定：
//
//   - 形态必须都被认出来：同一份交付，不同的供给方式放在同一张表上对照；
//   - 成本必须与定价函数算的一致 —— 对照视图说 A、定价说 B，就是两份事实分叉；
//   - 能供的时候不许报缺口 —— 「✓ 能供，却说当天没报价」是自相矛盾的话；
//   - 入场份数必须与 C 端构成读模型一致 —— 份数分叉就是卖错规格。

func TestSupplyFormsShowAllThreeForms(t *testing.T) {
	db := seeded(t)

	rows, err := variant.SupplyFormRows(db, 0, "", 0)
	if err != nil {
		t.Fatalf("查供给形态失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("供给形态对照表不该是空的")
	}

	forms := map[string]int{}
	for _, r := range rows {
		forms[r.SupplyForm]++
	}
	for _, want := range []string{"single", "recipe", "bundle"} {
		if forms[want] == 0 {
			t.Fatalf("对照表里没有 %s 形态（种子里三种形态都有）：%v", want, forms)
		}
	}
}

// TestSupplyFormCostMatchesThePricingFunction 守住「对照视图不许自己算钱」。
//
// 成本必须与定价函数（fn_price_variant）算出来的那个一模一样。
// 对不上就是两份实现 —— 一份说 100，一份说 120，运营侧没法对账。
func TestSupplyFormCostMatchesThePricingFunction(t *testing.T) {
	db := seeded(t)

	rows, err := variant.SupplyFormRows(db, 0, "", 0)
	if err != nil {
		t.Fatalf("查供给形态失败：%v", err)
	}
	for _, r := range rows {
		if r.CostInTarget == "" {
			continue
		}
		priced, err := db.Scalar(`SELECT p.cost_price::text
		                          FROM fn_price_variant(` + strconv.FormatInt(r.ProductVariantID, 10) + `,
		                                                DATE '` + r.Date + `',
		                                                ` + strconv.FormatInt(r.ChannelID, 10) + `,
		                                                ` + strconv.FormatInt(r.ChannelID, 10) + `) p;`)
		if err != nil {
			t.Fatalf("调定价函数失败：%v", err)
		}
		if priced == "" {
			continue
		}
		got := r.CostInTarget
		want := priced
		if got != want {
			t.Fatalf("变体 %s %s 渠道 %d 形态 %s：对照视图成本 %s，定价函数 %s",
				r.VariantCode, r.Date, r.ChannelID, r.SupplyForm, got, want)
		}
	}
}

// TestFulfilableFormHasNoGap 守住「能供的时候不许说缺口」。
//
// 逐源的缺口在 candidates 里；形态整体的缺口只在这个形态真的卖不掉时才报。
// 两样混在一起就是「✓ 能供，却说当天没报价」。
func TestFulfilableFormHasNoGap(t *testing.T) {
	db := seeded(t)

	rows, err := variant.SupplyFormRows(db, 0, "", 0)
	if err != nil {
		t.Fatalf("查供给形态失败：%v", err)
	}
	for _, r := range rows {
		if !r.CanFulfil {
			continue
		}
		if strings.TrimSpace(r.Gaps) != "" && strings.TrimSpace(r.Gaps) != "{}" {
			t.Fatalf("变体 %s %s 渠道 %d 形态 %s 能供，却报了缺口：%s",
				r.VariantCode, r.Date, r.ChannelID, r.SupplyForm, r.Gaps)
		}
	}
}

// TestAdmissionQuantityMatchesTheCompositionFeed 守住「份数只写一份」。
//
// 入场份数来自 fn_variant_composition（与 C 端构成读模型同一个来源）。
// 对照视图自己重数一遍 = 第二份实现，分叉就是卖错规格。
func TestAdmissionQuantityMatchesTheCompositionFeed(t *testing.T) {
	db := seeded(t)

	rows, err := variant.SupplyFormRows(db, 0, "", 0)
	if err != nil {
		t.Fatalf("查供给形态失败：%v", err)
	}
	checked := 0
	for _, r := range rows {
		if r.ComponentCount == 0 {
			continue
		}
		checked++
		feed, err := db.Scalar(`SELECT sum(fvc.quantity)::text
		                         FROM v_c_variant_composition fvc
		                         WHERE fvc.product_variant_id = ` + strconv.FormatInt(r.ProductVariantID, 10) + `
		                           AND fvc.channel_id = ` + strconv.FormatInt(r.ChannelID, 10) + `;`)
		if err != nil {
			t.Fatalf("查 C 端构成读模型失败：%v", err)
		}
		if feed == "" {
			continue
		}
		if r.AdmissionQuantity != feed {
			t.Fatalf("变体 %s 渠道 %d：对照视图入场 %s 份，C 端构成读模型 %s 份",
				r.VariantCode, r.ChannelID, r.AdmissionQuantity, feed)
		}
	}
	if checked == 0 {
		t.Fatal("种子里没有配方/套装形态，份数一致性没被验到")
	}
}

// TestSupplyFormSurvivesASourceGoingOffShelf 守住「形态不许因为源 SKU 下架而消失」。
//
// 源侧把 SKU 下架是事实，我们改不了源侧。但这个可售单元仍然被声明着，
// 只是现在没人供 —— 看得见，而且不许还说能供。
//
// 之前这里会静悄悄地变成另一个东西：
//   - 配方少一个成分就按剩下的成分重新定价（收 3 份入场的钱，出 1 份票）；
//   - 套装的形态行整个从对照视图里消失（「没人供」和「没人看得见」长得一样）。
func TestSupplyFormSurvivesASourceGoingOffShelf(t *testing.T) {
	db := seeded(t)

	// 拿一个配方的成分，以及它顶着的那个源 SKU。
	variantID, err := db.Scalar(`SELECT product_variant_id::text
	                               FROM supplier_variant_composition
	                              WHERE status = 'active'
	                              ORDER BY product_variant_id
	                              LIMIT 1;`)
	if err != nil || variantID == "" {
		t.Fatalf("种子里没有配方成分，跳过这条：%v", err)
	}
	sourceVariantID, err := db.Scalar(`SELECT supplier_variant_id::text
	                                   FROM supplier_variant_composition
	                                  WHERE status = 'active'
	                                    AND product_variant_id = ` + variantID + `
	                                  ORDER BY id
	                                  LIMIT 1;`)
	if err != nil || sourceVariantID == "" {
		t.Fatalf("配方 %s 没有成分的源 SKU：%v", variantID, err)
	}

	before, err := variant.SupplyFormRows(db, 0, "", 0)
	if err != nil {
		t.Fatalf("查供给形态失败：%v", err)
	}
	recipeBefore := formOf(before, variantID, "recipe")
	if recipeBefore == nil || !recipeBefore.CanFulfil {
		t.Fatalf("配方 %s 在源 SKU 下架前就该是能供的：%+v", variantID, recipeBefore)
	}

	if err := db.Exec(`UPDATE supplier_variant SET status = 'inactive' WHERE id = ` + sourceVariantID + `;`); err != nil {
		t.Fatalf("把源 SKU 下架失败：%v", err)
	}

	after, err := variant.SupplyFormRows(db, 0, "", 0)
	if err != nil {
		t.Fatalf("查供给形态失败：%v", err)
	}
	recipeAfter := formOf(after, variantID, "recipe")
	if recipeAfter == nil {
		t.Fatalf("配方 %s 的形态行在源 SKU 下架后不见了（形态不许消失）", variantID)
	}
	if recipeAfter.CanFulfil {
		t.Fatalf("配方 %s 的成分有一个源 SKU 已下架，却还说能供", variantID)
	}
	if !strings.Contains(recipeAfter.Gaps, "下架") {
		t.Fatalf("配方 %s 的缺口没说清是源 SKU 下架了：%s", variantID, recipeAfter.Gaps)
	}

	// 定价函数不许再给这个套餐定价 —— 少一个成分的套餐不是这个套餐。
	priced, err := db.Scalar(`SELECT count(*)::text
	                          FROM fn_price_variant(` + variantID + `::bigint,
	                                                (SELECT min(date)::text FROM price_calendar
	                                                  WHERE product_variant_id = ` + variantID + `::bigint
	                                                    AND status = 'active')::date,
	                                                1, 1);`)
	if err != nil {
		t.Fatalf("调定价函数失败：%v", err)
	}
	if priced != "0" {
		t.Fatalf("配方 %s 的成分少了一个，定价函数还给价（收了 3 份入场钱出 1 份票）：%s 行", variantID, priced)
	}
}

// formOf 在对照行里找某个可售单元的某种形态。
func formOf(rows []variant.SupplyForm, variantID, form string) *variant.SupplyForm {
	for i := range rows {
		if strconv.FormatInt(rows[i].ProductVariantID, 10) == variantID && rows[i].SupplyForm == form {
			return &rows[i]
		}
	}
	return nil
}
