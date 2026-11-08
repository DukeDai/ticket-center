// Package variant 是异构差异模型的读侧。
//
// 它只读四张视图，不做任何计算：
//
//	Compare      —— v_variant_comparison：可售单元之间差在哪（人群 / 轴 / 有效期 / 退款口径 / 可用源）
//	Coverage     —— v_variant_source_coverage：这个可售单元有哪些源能供、缺什么
//	Feed         —— v_c_variant_feed：C 端读模型里的变体行（请求链路不许 join 主数据，差异靠它带出来）
//	Composition  —— v_c_variant_composition：组合由谁组成（几份成人、几份儿童、各管几天）
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
