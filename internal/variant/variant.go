// Package variant 是异构差异模型的读侧。
//
// 它只读四张视图，不做任何计算：
//
//	Compare      —— v_variant_comparison：可售单元之间差在哪（人群 / 轴 / 有效期 / 退款口径 / 可用源）
//	Coverage     —— v_variant_source_coverage：这个可售单元有哪些源能供、缺什么
//	Feed         —— v_c_variant_feed：C 端读模型里的变体行（请求链路不许 join 主数据，差异靠它带出来）
//	Composition  —— v_c_variant_composition：组合由谁组成（几份成人、几份儿童、各管几天）
//	Bundle       —— v_variant_bundle：套装由谁组成（源侧把整套当一个 SKU 卖的情形）
//	SupplyForm   —— v_variant_supply_forms：三种供给形态在同一张表上对齐（单张 / 配方 / 套装）
//
// 为什么不自己算：轴取值、有效天数、覆盖判定都有唯一实现
// （fn_variant_validity_days / fn_variant_covered），
// 在 Go 里再写一遍就是第二份实现 —— 两份实现迟早分叉，
// 而分叉的后果是「展示说两日票、发出来的是一天有效期的券」。
package variant

import (
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Comparison 是一行可售单元的差异对照。
type Comparison struct {
	ProductVariantID      int64  `json:"product_variant_id"`
	ProductID             int64  `json:"product_id"`
	VariantCode           string `json:"variant_code"`
	VariantTitle          string `json:"variant_title"`
	ProductCode           string `json:"product_code"`
	ProductTitle          string `json:"product_title"`
	Audience              string `json:"audience"`
	Axes                  string `json:"axes"`
	ValidDays             int    `json:"valid_days"`
	SingleUse             string `json:"single_use"`
	Timezone              string `json:"timezone"`
	Refundable            bool   `json:"refundable"`
	RefundFeePercent      string `json:"refund_fee_percent"`
	RefundCutoffHours     int    `json:"refund_cutoff_hours"`
	DurationMinutes       int    `json:"duration_minutes"`
	AgeLimitMin           int    `json:"age_limit_min"`
	SourceCount           int    `json:"source_count"`
	FulfilableSourceCount int    `json:"fulfilable_source_count"`
	Suppliers             string `json:"suppliers"`
}

// Coverage 是一行「可售单元 × 源」的覆盖情况。
type Coverage struct {
	ProductVariantID  int64  `json:"product_variant_id"`
	VariantCode       string `json:"variant_code"`
	SupplierCode      string `json:"supplier_code"`
	ExternalVariantID string `json:"external_variant_id"`
	SourceVariantTitl string `json:"source_variant_title"`
	Coverage          string `json:"coverage"`
	CanFulfil         bool   `json:"can_fulfil"`
	Gaps              string `json:"gaps"`
}

// Feed 是一行 C 端读模型里的变体。
type Feed struct {
	ChannelID        int64  `json:"channel_id"`
	ProductVariantID int64  `json:"product_variant_id"`
	ProductID        int64  `json:"product_id"`
	VariantCode      string `json:"variant_code"`
	Title            string `json:"title"`
	Audience         string `json:"audience"`
	Axes             string `json:"axes"`
	ValidDays        int    `json:"valid_days"`
	Refundable       bool   `json:"refundable"`
	RefundFeePercent string `json:"refund_fee_percent"`
	PriceMin         string `json:"price_min"`
	PriceMax         string `json:"price_max"`
	AvailableDays    int    `json:"available_days"`
	FirstDate        string `json:"first_date"`
	LastDate         string `json:"last_date"`
	// 组合（异构融合方向 B）的事实：这是不是一个套餐、有几个成分、成分是谁。
	IsCombo        bool   `json:"is_combo"`
	ComboAudience  string `json:"combo_audience"`
	ComponentCount int    `json:"component_count"`
	Composition    string `json:"composition"`
}

// Component 是一行组合成分（C 端详情页渲染「2 成人 + 1 儿童」用）。
//
// 字段全是语言无关的结构化事实：人群是编码不是文案，
// 份数与天数是数字 —— 展示文案由前端按 locale 拼，不在后端拼。
type Component struct {
	ChannelID          int64  `json:"channel_id"`
	ProductVariantID   int64  `json:"product_variant_id"`
	VariantKey         string `json:"variant_key"`
	ComponentVariantID int64  `json:"component_variant_id"`
	VariantCode        string `json:"variant_code"`
	Title              string `json:"title"`
	Sequence           int    `json:"sequence"`
	Quantity           string `json:"quantity"`
	AudienceCode       string `json:"audience_code"`
	ValidDays          int    `json:"valid_days"`
}

// Bundle 是一行套装（源侧把整套当一个 SKU 卖）。
//
// 套装是异构融合的第三种形态：
// 方向 A 是一个源 SKU 覆盖多个可售单元，
// 方向 B 的配方是一个可售单元由多个源 SKU 按份数组成，
// 套装是**一个源 SKU 把整套当一个 SKU 卖** —— 从 coverage 看不出来是哪种，
// 所以要单独声明（supplier_variant_bundle），不许靠猜。
type Bundle struct {
	BundleID          int64  `json:"bundle_id"`
	ProductVariantID  int64  `json:"product_variant_id"`
	ProductID         int64  `json:"product_id"`
	VariantCode       string `json:"variant_code"`
	VariantKey        string `json:"variant_key"`
	SupplierVariantID int64  `json:"supplier_variant_id"`
	SupplierProductID int64  `json:"supplier_product_id"`
	SourceSetSKU      string `json:"source_set_sku"`
	SourceSetTitle    string `json:"source_set_title"`
	SupplierCode      string `json:"supplier_code"`
	// SetValidDays 是源侧整套能用的天数，UnionDays 是规范侧成分窗口的并集。
	// 前者不小于后者，套装才盖得住成分（否则第二天进门进不去）。
	SetValidDays string `json:"set_valid_days"`
	UnionDays    int    `json:"union_days"`
	CoversWindow bool   `json:"covers_window"`
	PartCount    int    `json:"part_count"`
	// AdmissionsPerSet 是这一套能进场的份数（2 成人 + 1 儿童 = 3）。
	AdmissionsPerSet string `json:"admissions_per_set"`
	// Parts 是成分构成（JSON），每项带份数、人群编码、各管几天。
	Parts string `json:"parts"`
	// GapDays 是卖不掉的天数，GapReasons 是原因清单。
	GapDays    int    `json:"gap_days"`
	GapReasons string `json:"gap_reasons"`
}

// SupplyForm 是一行「可售单元 × 一天 × 渠道 × 供给形态」的对照。
//
// 异构融合有三种形态，形态不同、供给方式不同、成本口径也不同：
//
//	single —— 一个源 SKU 顶住这个可售单元（方向 A）
//	recipe —— 多个源 SKU 按份数组成这个可售单元（方向 B 的配方）
//	bundle —— 源侧自己把整套当一个 SKU 卖（方向 B 的套装）
//
// 三者放在同一张表上对齐，是为了能一眼看出「同一份交付，不同的供给方式、
// 不同的成本、不同的缺口」。形态各自的候选明细在 Candidates 里。
type SupplyForm struct {
	ProductVariantID int64  `json:"product_variant_id"`
	VariantCode      string `json:"variant_code"`
	VariantTitle     string `json:"variant_title"`
	VariantRole      string `json:"variant_role"`
	ProductID        int64  `json:"product_id"`
	ProductCode      string `json:"product_code"`
	ProductTitle     string `json:"product_title"`
	Date             string `json:"date"`
	ChannelID        int64  `json:"channel_id"`
	// SupplyForm 是形态：single / recipe / bundle。
	SupplyForm string `json:"supply_form"`
	// SupplierCodes 是这一形态背后的源（可能多个）。
	SupplierCodes string `json:"supplier_codes"`
	SupplierCount int    `json:"supplier_count"`
	// ExternalVariantIDs 是源侧的 SKU 标识。
	ExternalVariantIDs string `json:"external_variant_ids"`
	// SourceCurrencies 是源币种。组合可能跨币种（每个成分各自留痕）。
	SourceCurrencies string `json:"source_currencies"`
	// CostInTarget 是成本折算到本行币种；Currency 是本行币种。
	CostInTarget string `json:"cost_in_target"`
	Currency     string `json:"currency"`
	BaseCurrency string `json:"base_currency"`
	// ComponentCount 是成分个数，AdmissionQuantity 是入场份数（2 成人 + 1 儿童 = 3）。
	ComponentCount    int    `json:"component_count"`
	AdmissionQuantity string `json:"admission_quantity"`
	AudienceCodes     string `json:"audience_codes"`
	ValidDays         int    `json:"valid_days"`
	// CanFulfil 是这一形态当天卖不卖得掉。
	CanFulfil bool `json:"can_fulfil"`
	// Gaps 是卖不掉的原因（为空就是没有缺口）。
	Gaps string `json:"gaps"`
	// Candidates 是候选明细（JSON），每个源一条：单价、币种、成本、覆盖声明。
	Candidates string `json:"candidates"`
}

// BundlePart 是一行套装成分。
type BundlePart struct {
	ProductVariantID   int64  `json:"product_variant_id"`
	SupplierVariantID  int64  `json:"supplier_variant_id"`
	BundleID           int64  `json:"bundle_id"`
	PartID             int64  `json:"part_id"`
	ComponentVariantID int64  `json:"component_variant_id"`
	VariantCode        string `json:"variant_code"`
	Title              string `json:"title"`
	Quantity           string `json:"quantity"`
	AudienceCode       string `json:"audience_code"`
	ValidDays          int    `json:"valid_days"`
}

// BundleRows 返回套装清单。variantID 为 0 时返回全部套装。
//
// 它只读视图，不重算份数与有效期 —— 那是主数据的事（fn_variant_validity_days）。
func BundleRows(db *store.DB, variantID int64) ([]Bundle, error) {
	sql := `SELECT bundle_id, product_variant_id, product_id, variant_code, variant_key,
	               supplier_variant_id, supplier_product_id, source_set_sku, source_set_title,
	               supplier_code, set_valid_days::text AS set_valid_days, union_days,
	               covers_window, part_count, admissions_per_set::text AS admissions_per_set,
	               COALESCE(parts::text, '[]') AS parts,
	               gap_days, COALESCE(gap_reasons::text, '[]') AS gap_reasons
	          FROM v_variant_bundle`
	if variantID > 0 {
		sql += fmt.Sprintf(" WHERE product_variant_id = %d", variantID)
	}
	sql += " ORDER BY product_variant_id, bundle_id"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]Bundle, 0, len(rows))
	for _, r := range rows {
		out = append(out, Bundle{
			BundleID:          atoi64(r["bundle_id"]),
			ProductVariantID:  atoi64(r["product_variant_id"]),
			ProductID:         atoi64(r["product_id"]),
			VariantCode:       r["variant_code"],
			VariantKey:        r["variant_key"],
			SupplierVariantID: atoi64(r["supplier_variant_id"]),
			SupplierProductID: atoi64(r["supplier_product_id"]),
			SourceSetSKU:      r["source_set_sku"],
			SourceSetTitle:    r["source_set_title"],
			SupplierCode:      r["supplier_code"],
			SetValidDays:      r["set_valid_days"],
			UnionDays:         atoi(r["union_days"]),
			CoversWindow:      atobool(r["covers_window"]),
			PartCount:         atoi(r["part_count"]),
			AdmissionsPerSet:  r["admissions_per_set"],
			Parts:             r["parts"],
			GapDays:           atoi(r["gap_days"]),
			GapReasons:        r["gap_reasons"],
		})
	}
	return out, nil
}

// BundlePartRows 返回套装成分明细。variantID 为 0 时返回全部套装的成分。
func BundlePartRows(db *store.DB, variantID int64) ([]BundlePart, error) {
	sql := `SELECT product_variant_id, supplier_variant_id, bundle_id, part_id,
	               component_variant_id, variant_code, title,
	               quantity::text AS quantity, audience_code, valid_days
	          FROM v_variant_bundle_part`
	if variantID > 0 {
		sql += fmt.Sprintf(" WHERE product_variant_id = %d", variantID)
	}
	sql += " ORDER BY product_variant_id, bundle_id, part_id"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]BundlePart, 0, len(rows))
	for _, r := range rows {
		out = append(out, BundlePart{
			ProductVariantID:   atoi64(r["product_variant_id"]),
			SupplierVariantID:  atoi64(r["supplier_variant_id"]),
			BundleID:           atoi64(r["bundle_id"]),
			PartID:             atoi64(r["part_id"]),
			ComponentVariantID: atoi64(r["component_variant_id"]),
			VariantCode:        r["variant_code"],
			Title:              r["title"],
			Quantity:           r["quantity"],
			AudienceCode:       r["audience_code"],
			ValidDays:          atoi(r["valid_days"]),
		})
	}
	return out, nil
}

// Compare 返回可售单元的差异对照。productID 为 0 时不按商品过滤。
func Compare(db *store.DB, productID int64) ([]Comparison, error) {
	sql := `SELECT product_variant_id, product_id, variant_code, variant_title,
	               product_code, product_title, audience, COALESCE(axes::text, '{}') AS axes,
	               valid_days, single_use, timezone, refundable,
	               refund_fee_percent::text AS refund_fee_percent, refund_cutoff_hours,
	               duration_minutes, age_limit_min,
	               source_count, fulfilable_source_count,
	               COALESCE(suppliers::text, '') AS suppliers
	          FROM v_variant_comparison`
	if productID > 0 {
		sql += fmt.Sprintf(" WHERE product_id = %d", productID)
	}
	sql += " ORDER BY product_variant_id"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]Comparison, 0, len(rows))
	for _, r := range rows {
		out = append(out, Comparison{
			ProductVariantID:      atoi64(r["product_variant_id"]),
			ProductID:             atoi64(r["product_id"]),
			VariantCode:           r["variant_code"],
			VariantTitle:          r["variant_title"],
			ProductCode:           r["product_code"],
			ProductTitle:          r["product_title"],
			Audience:              r["audience"],
			Axes:                  r["axes"],
			ValidDays:             atoi(r["valid_days"]),
			SingleUse:             r["single_use"],
			Timezone:              r["timezone"],
			Refundable:            atobool(r["refundable"]),
			RefundFeePercent:      r["refund_fee_percent"],
			RefundCutoffHours:     atoi(r["refund_cutoff_hours"]),
			DurationMinutes:       atoi(r["duration_minutes"]),
			AgeLimitMin:           atoi(r["age_limit_min"]),
			SourceCount:           atoi(r["source_count"]),
			FulfilableSourceCount: atoi(r["fulfilable_source_count"]),
			Suppliers:             r["suppliers"],
		})
	}
	return out, nil
}

// SourceCoverage 返回可售单元的源覆盖情况。variantID 为 0 时返回全部。
func SourceCoverage(db *store.DB, variantID int64) ([]Coverage, error) {
	sql := `SELECT product_variant_id, variant_code, supplier_code,
	               external_variant_id, source_variant_title,
	               coverage::text AS coverage, can_fulfil, COALESCE(gaps::text, '') AS gaps
	          FROM v_variant_source_coverage`
	if variantID > 0 {
		sql += fmt.Sprintf(" WHERE product_variant_id = %d", variantID)
	}
	sql += " ORDER BY product_variant_id, supplier_code, external_variant_id"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]Coverage, 0, len(rows))
	for _, r := range rows {
		out = append(out, Coverage{
			ProductVariantID:  atoi64(r["product_variant_id"]),
			VariantCode:       r["variant_code"],
			SupplierCode:      r["supplier_code"],
			ExternalVariantID: r["external_variant_id"],
			SourceVariantTitl: r["source_variant_title"],
			Coverage:          r["coverage"],
			CanFulfil:         atobool(r["can_fulfil"]),
			Gaps:              r["gaps"],
		})
	}
	return out, nil
}

// FeedRows 返回 C 端读模型里的变体行。productID 为 0 时不按商品过滤。
func FeedRows(db *store.DB, channelID, productID int64) ([]Feed, error) {
	sql := `SELECT channel_id, product_variant_id, product_id, variant_code, title,
	               audience, axes::text AS axes, valid_days, refundable,
	               refund_fee_percent::text AS refund_fee_percent,
	               COALESCE(price_min::text, '') AS price_min,
	               COALESCE(price_max::text, '') AS price_max,
	               available_days,
	               COALESCE(first_date::text, '') AS first_date,
	               COALESCE(last_date::text, '') AS last_date,
	               is_combo, combo_audience, component_count,
	               COALESCE(composition::text, '') AS composition
	          FROM v_c_variant_feed`
	var where []string
	if channelID > 0 {
		where = append(where, fmt.Sprintf("channel_id = %d", channelID))
	}
	if productID > 0 {
		where = append(where, fmt.Sprintf("product_id = %d", productID))
	}
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	sql += " ORDER BY channel_id, product_variant_id"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]Feed, 0, len(rows))
	for _, r := range rows {
		out = append(out, Feed{
			ChannelID:        atoi64(r["channel_id"]),
			ProductVariantID: atoi64(r["product_variant_id"]),
			ProductID:        atoi64(r["product_id"]),
			VariantCode:      r["variant_code"],
			Title:            r["title"],
			Audience:         r["audience"],
			Axes:             r["axes"],
			ValidDays:        atoi(r["valid_days"]),
			Refundable:       atobool(r["refundable"]),
			RefundFeePercent: r["refund_fee_percent"],
			PriceMin:         r["price_min"],
			PriceMax:         r["price_max"],
			AvailableDays:    atoi(r["available_days"]),
			FirstDate:        r["first_date"],
			LastDate:         r["last_date"],
			IsCombo:          atobool(r["is_combo"]),
			ComboAudience:    r["combo_audience"],
			ComponentCount:   atoi(r["component_count"]),
			Composition:      r["composition"],
		})
	}
	return out, nil
}

// CompositionRows 返回 C 端读模型里的组合成分明细。variantID 为 0 时返回全部组合。
//
// channelID 是必答的那一半：C 端读模型是**按渠道**建的，
// 一个套餐上了两个渠道就有两份成分明细 —— 不按渠道过滤，
// 「2 份成人 + 1 份儿童」会被数成两遍。channelID 为 0 表示不限渠道。
//
// 它只读视图，不重算份数与天数 —— 那两样是主数据的事，
// 读模型只是把它们带出来（不让请求链路 join 主数据）。
func CompositionRows(db *store.DB, channelID, variantID int64) ([]Component, error) {
	sql := `SELECT channel_id, product_variant_id, variant_key, component_variant_id,
	               variant_code, title, sequence, quantity::text AS quantity,
	               audience_code, valid_days
	          FROM v_c_variant_composition`
	var where []string
	if channelID > 0 {
		where = append(where, fmt.Sprintf("channel_id = %d", channelID))
	}
	if variantID > 0 {
		where = append(where, fmt.Sprintf("product_variant_id = %d", variantID))
	}
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	sql += " ORDER BY channel_id, product_variant_id, sequence, component_variant_id"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]Component, 0, len(rows))
	for _, r := range rows {
		out = append(out, Component{
			ChannelID:          atoi64(r["channel_id"]),
			ProductVariantID:   atoi64(r["product_variant_id"]),
			VariantKey:         r["variant_key"],
			ComponentVariantID: atoi64(r["component_variant_id"]),
			VariantCode:        r["variant_code"],
			Title:              r["title"],
			Sequence:           atoi(r["sequence"]),
			Quantity:           r["quantity"],
			AudienceCode:       r["audience_code"],
			ValidDays:          atoi(r["valid_days"]),
		})
	}
	return out, nil
}

// SupplyFormRows 返回三种供给形态的对照行。
//
// variantID / date / channelID 为 0 或空表示不按那一维过滤。
// 它只读视图，不重算成本、不重算入场份数 ——
// 成本由定价函数算（fn_price_variant），份数由 fn_variant_composition 推，
// 两样都在库里算好了，这里只带出来。
func SupplyFormRows(db *store.DB, variantID int64, date string, channelID int64) ([]SupplyForm, error) {
	sql := `SELECT product_variant_id, variant_code, variant_title, variant_role,
	               product_id, product_code, product_title, date::text AS date,
	               channel_id, supply_form,
	               COALESCE(supplier_codes::text, '') AS supplier_codes,
	               supplier_count,
	               COALESCE(external_variant_ids::text, '') AS external_variant_ids,
	               COALESCE(source_currencies::text, '') AS source_currencies,
	               COALESCE(cost_in_target::text, '') AS cost_in_target,
	               currency, base_currency,
	               component_count,
	               admission_quantity::text AS admission_quantity,
	               COALESCE(audience_codes::text, '') AS audience_codes,
	               valid_days, can_fulfil,
	               COALESCE(gaps::text, '') AS gaps,
	               COALESCE(candidates::text, '[]') AS candidates
	          FROM v_variant_supply_forms`
	var where []string
	if variantID > 0 {
		where = append(where, fmt.Sprintf("product_variant_id = %d", variantID))
	}
	if strings.TrimSpace(date) != "" {
		where = append(where, fmt.Sprintf("date = DATE '%s'", strings.TrimSpace(date)))
	}
	if channelID > 0 {
		where = append(where, fmt.Sprintf("channel_id = %d", channelID))
	}
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	sql += " ORDER BY product_variant_id, date, channel_id, supply_form"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]SupplyForm, 0, len(rows))
	for _, r := range rows {
		out = append(out, SupplyForm{
			ProductVariantID:   atoi64(r["product_variant_id"]),
			VariantCode:        r["variant_code"],
			VariantTitle:       r["variant_title"],
			VariantRole:        r["variant_role"],
			ProductID:          atoi64(r["product_id"]),
			ProductCode:        r["product_code"],
			ProductTitle:       r["product_title"],
			Date:               r["date"],
			ChannelID:          atoi64(r["channel_id"]),
			SupplyForm:         r["supply_form"],
			SupplierCodes:      r["supplier_codes"],
			SupplierCount:      atoi(r["supplier_count"]),
			ExternalVariantIDs: r["external_variant_ids"],
			SourceCurrencies:   r["source_currencies"],
			CostInTarget:       r["cost_in_target"],
			Currency:           r["currency"],
			BaseCurrency:       r["base_currency"],
			ComponentCount:     atoi(r["component_count"]),
			AdmissionQuantity:  r["admission_quantity"],
			AudienceCodes:      r["audience_codes"],
			ValidDays:          atoi(r["valid_days"]),
			CanFulfil:          atobool(r["can_fulfil"]),
			Gaps:               r["gaps"],
			Candidates:         r["candidates"],
		})
	}
	return out, nil
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}

func atoi64(s string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n
}

func atobool(s string) bool {
	return strings.EqualFold(strings.TrimSpace(s), "t") || strings.EqualFold(strings.TrimSpace(s), "true")
}
