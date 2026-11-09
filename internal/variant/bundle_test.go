package variant_test

import (
	"strconv"
	"testing"

	"ticket-center/internal/variant"
)

// 套装（源侧把整套当一个 SKU 卖）的行为约定：
//
//   - 套装必须被认出来：它由哪个源 SKU 供、包含什么、一套能进几个人；
//   - 套装的成分必须与规范声明逐项对得上（份数一致）——
//     源侧说「2 成人 + 1 儿童」，规范侧说「2 成人 + 1 儿童」，两边必须一样；
//   - 源侧整套的有效期必须盖住成分窗口 —— 盖不住就是第二天进不去；
//   - 套装与配方型组合是两种形态，一个可售单元不许同时是两种。

func TestBundleRowsExposeTheWholeSet(t *testing.T) {
	db := seeded(t)

	rows, err := variant.BundleRows(db, 0)
	if err != nil {
		t.Fatalf("查套装失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("种子里有套装，读视图却查不到")
	}

	r := rows[0]
	if r.VariantCode != "USJ-FAMILY-2A1C-SET" {
		t.Fatalf("套装的规范变体不对：%s", r.VariantCode)
	}
	if r.SourceSetSKU != "ZWO-FAMILY-SET" {
		t.Fatalf("套装的源 SKU 不对：%s", r.SourceSetSKU)
	}
	if r.PartCount != 2 {
		t.Fatalf("套装应有 2 个成分，实际 %d", r.PartCount)
	}
	if r.AdmissionsPerSet != "3.00" {
		t.Fatalf("一套应能进 3 个人（2 成人 + 1 儿童），实际 %s", r.AdmissionsPerSet)
	}
	if r.Parts == "" || r.Parts == "[]" {
		t.Fatalf("套装没带出成分构成：%s", r.Parts)
	}
}

func TestBundleSetDaysMustCoverTheComponentWindow(t *testing.T) {
	db := seeded(t)

	rows, err := variant.BundleRows(db, 0)
	if err != nil {
		t.Fatalf("查套装失败：%v", err)
	}
	for _, r := range rows {
		if !r.CoversWindow {
			t.Fatalf("套装 %s 的源侧整套有效期 %s 天盖不住成分窗口 %d 天",
				r.VariantCode, r.SetValidDays, r.UnionDays)
		}
		if r.SetValidDays == "" {
			t.Fatalf("套装 %s 没有源侧整套有效期", r.VariantCode)
		}
	}
}

func TestBundlePartsMatchTheCanonicalDeclaration(t *testing.T) {
	db := seeded(t)

	rows, err := variant.BundleRows(db, 0)
	if err != nil {
		t.Fatalf("查套装失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("种子里有套装，读视图却查不到")
	}
	parts, err := variant.BundlePartRows(db, rows[0].ProductVariantID)
	if err != nil {
		t.Fatalf("查套装成分失败：%v", err)
	}
	if len(parts) != rows[0].PartCount {
		t.Fatalf("套装头说 %d 个成分，明细有 %d 行", rows[0].PartCount, len(parts))
	}

	byAudience := map[string]variant.BundlePart{}
	for _, p := range parts {
		byAudience[p.AudienceCode] = p
	}
	adult, ok := byAudience["adult"]
	if !ok {
		t.Fatalf("成分里没有成人：%v", parts)
	}
	if adult.Quantity != "2.00" {
		t.Fatalf("成人份数应为 2，实际 %s", adult.Quantity)
	}
	child, ok := byAudience["child"]
	if !ok {
		t.Fatalf("成分里没有儿童：%v", parts)
	}
	if child.Quantity != "1.00" {
		t.Fatalf("儿童份数应为 1，实际 %s", child.Quantity)
	}

	// 成分的份数必须与规范侧的声明一致 —— 两边分叉就是卖错规格。
	for _, p := range parts {
		declared, err := db.Scalar(`SELECT r.quantity::text
		                              FROM product_variant_relation r
		                             WHERE r.parent_variant_id = ` + strconv.FormatInt(rows[0].ProductVariantID, 10) + `
		                               AND r.child_variant_id = ` + strconv.FormatInt(p.ComponentVariantID, 10) + `
		                               AND r.relation_type = 'included';`)
		if err != nil {
			t.Fatalf("查规范声明失败：%v", err)
		}
		if declared == "" {
			t.Fatalf("成分 %s 在规范侧没有声明", p.VariantCode)
		}
		if declared != p.Quantity {
			t.Fatalf("成分 %s 的份数 %s 与规范声明 %s 对不上", p.VariantCode, p.Quantity, declared)
		}
	}
}

// TestBundleIsNotAlsoARecipe 守住「形态唯一」。
//
// 同一个可售单元既是配方（我们把几个源 SKU 拼起来）又是套装（源侧自己卖整套），
// 定价走哪条路就说不清了 —— 成本会算两遍，或者只算一遍。
func TestBundleIsNotAlsoARecipe(t *testing.T) {
	db := seeded(t)

	rows, err := variant.BundleRows(db, 0)
	if err != nil {
		t.Fatalf("查套装失败：%v", err)
	}
	for _, r := range rows {
		both, err := db.Scalar(`SELECT count(*) FROM supplier_variant_composition svc
		                          WHERE svc.product_variant_id = ` + strconv.FormatInt(r.ProductVariantID, 10) + `
		                            AND svc.status = 'active';`)
		if err != nil {
			t.Fatalf("查配方声明失败：%v", err)
		}
		if both != "0" {
			t.Fatalf("变体 %s 既是套装又是配方", r.VariantCode)
		}
	}
}
