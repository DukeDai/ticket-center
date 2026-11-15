package bapi

import (
	"fmt"
	"strings"

	"ticket-center/internal/store"
)

// 这个文件是**商品详情**的取数处：运营台点进一个商品之后要看的那些东西。
//
// 为什么单开一个文件，而不是塞进 opsdata.go：
//   - opsdata.go 是「运营台首页那几张表」；商品详情是**钻取**，
//     数据量与形状都不一样（一个商品几十行，不是几千行）。
//   - 详情页按 product_id 收窄，一个函数一次取一块（源绑定 / 变体 / 上架 /
//     价格 / 文案），前端一块一块渲染 —— 一条大 SQL 拼五个 jsonb 数组，
//     拼坏了整页都出不来。
//
// 口径纪律：
//   - 读侧只读 v_ops_product_* 读模型，不在请求链路里 join 主数据
//     （硬约束 10 的精神）。
//   - 金额一律以字符串出（NUMERIC，Go 没有十进制类型）。
//   - 不重算任何事实：成本、份数、可履约都是库里的口径。

// ProductSourceRow 是一行源绑定（商品 ← 源条目）。
//
// 判定依据（MatchEvidence）带出来是这一块的核心 —— 人工判过的映射，
// 最怕机器下一次同步把依据洗掉；运营看不到依据就只能凭感觉点「通过」。
type ProductSourceRow struct {
	MappingID          int64  `json:"mapping_id"`
	ProductID          int64  `json:"product_id"`
	ProductCode        string `json:"product_code"`
	ProductTitle       string `json:"product_title"`
	SupplierID         int64  `json:"supplier_id"`
	SupplierCode       string `json:"supplier_code"`
	SupplierName       string `json:"supplier_name"`
	SupplierProductID  int64  `json:"supplier_product_id"`
	ExternalID         string `json:"external_id"`
	ExternalCode       string `json:"external_code"`
	ExternalURL        string `json:"external_url"`
	RawTitle           string `json:"raw_title"`
	AvailabilityMode   string `json:"availability_mode"`
	SupplierProdStatus string `json:"supplier_product_status"`
	LastSyncedAt       string `json:"last_synced_at"`
	MatchType          string `json:"match_type"`
	Confidence         string `json:"confidence"`
	MatchEvidence      string `json:"match_evidence"`
	IsPrimary          bool   `json:"is_primary"`
	MappingStatus      string `json:"mapping_status"`
	CreatedBy          string `json:"created_by"`
	CreatedAt          string `json:"created_at"`
	UpdatedAt          string `json:"updated_at"`
}

// ProductSources 读一个商品的源绑定。
//
// pending_review 的排在前面 —— 那是**待审队列**，运营先看它。
func ProductSources(db *store.DB, productID int64) ([]ProductSourceRow, error) {
	sql := store.NewSQL(
		`SELECT mapping_id, product_id, product_code, product_title, supplier_id,
                supplier_code, supplier_name, supplier_product_id, external_id,
                external_code, external_url, raw_title, availability_mode,
                supplier_product_status, last_synced_at, match_type, confidence,
                match_evidence, is_primary, mapping_status, created_by, created_at, updated_at
           FROM v_ops_product_source`)
	w := newWhere(sql)
	w.Eq("product_id", productID)
	// 待审的在前，其次是主映射，最后按源码排 —— 顺序稳定，运营来回翻页不会乱。
	sql.Text(` ORDER BY CASE mapping_status
                              WHEN 'pending_review' THEN 0
                              WHEN 'active' THEN 1
                              ELSE 2 END,
                            is_primary DESC, supplier_code`)
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ProductSourceRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, ProductSourceRow{
			MappingID:          parseInt64(r["mapping_id"]),
			ProductID:          parseInt64(r["product_id"]),
			ProductCode:        r["product_code"],
			ProductTitle:       r["product_title"],
			SupplierID:         parseInt64(r["supplier_id"]),
			SupplierCode:       r["supplier_code"],
			SupplierName:       r["supplier_name"],
			SupplierProductID:  parseInt64(r["supplier_product_id"]),
			ExternalID:         r["external_id"],
			ExternalCode:       r["external_code"],
			ExternalURL:        r["external_url"],
			RawTitle:           r["raw_title"],
			AvailabilityMode:   r["availability_mode"],
			SupplierProdStatus: r["supplier_product_status"],
			LastSyncedAt:       r["last_synced_at"],
			MatchType:          r["match_type"],
			Confidence:         r["confidence"],
			MatchEvidence:      r["match_evidence"],
			IsPrimary:          parseBool(r["is_primary"]),
			MappingStatus:      r["mapping_status"],
			CreatedBy:          r["created_by"],
			CreatedAt:          r["created_at"],
			UpdatedAt:          r["updated_at"],
		})
	}
	return out, nil
}

// ProductVariantRow 是一行可售单元（变体）。
type ProductVariantRow struct {
	ProductVariantID     int64  `json:"product_variant_id"`
	ProductID            int64  `json:"product_id"`
	ProductCode          string `json:"product_code"`
	VariantCode          string `json:"variant_code"`
	VariantKey           string `json:"variant_key"`
	VariantTitle         string `json:"variant_title"`
	VariantRole          string `json:"variant_role"`
	TicketTypeID         int64  `json:"ticket_type_id"`
	TicketTypeCode       string `json:"ticket_type_code"`
	TicketTypeName       string `json:"ticket_type_name"`
	VariantStatus        string `json:"variant_status"`
	SortOrder            int64  `json:"sort_order"`
	AxisValues           string `json:"axis_values"`
	AxisValidDays        int64  `json:"axis_valid_days"`
	ComponentCount       int64  `json:"component_count"`
	SupplierMappingCount int64  `json:"supplier_mapping_count"`
	PriceRowCount        int64  `json:"price_row_count"`
}

// ProductVariants 读一个商品的可售单元。
func ProductVariants(db *store.DB, productID int64) ([]ProductVariantRow, error) {
	sql := store.NewSQL(
		`SELECT product_variant_id, product_id, product_code, variant_code, variant_key,
                variant_title, variant_role, ticket_type_id, ticket_type_code,
                ticket_type_name, variant_status, sort_order, axis_values,
                axis_valid_days, component_count, supplier_mapping_count, price_row_count
           FROM v_ops_product_variant`)
	w := newWhere(sql)
	w.Eq("product_id", productID)
	sql.Text(" ORDER BY sort_order, variant_code")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ProductVariantRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, ProductVariantRow{
			ProductVariantID:     parseInt64(r["product_variant_id"]),
			ProductID:            parseInt64(r["product_id"]),
			ProductCode:          r["product_code"],
			VariantCode:          r["variant_code"],
			VariantKey:           r["variant_key"],
			VariantTitle:         r["variant_title"],
			VariantRole:          r["variant_role"],
			TicketTypeID:         parseInt64(r["ticket_type_id"]),
			TicketTypeCode:       r["ticket_type_code"],
			TicketTypeName:       r["ticket_type_name"],
			VariantStatus:        r["variant_status"],
			SortOrder:            parseInt64(r["sort_order"]),
			AxisValues:           r["axis_values"],
			AxisValidDays:        parseInt64(r["axis_valid_days"]),
			ComponentCount:       parseInt64(r["component_count"]),
			SupplierMappingCount: parseInt64(r["supplier_mapping_count"]),
			PriceRowCount:        parseInt64(r["price_row_count"]),
		})
	}
	return out, nil
}

// ProductListingRow 是一行上架配置（商品 × 渠道）。
type ProductListingRow struct {
	ChannelListingID    int64  `json:"channel_listing_id"`
	ProductID           int64  `json:"product_id"`
	ProductCode         string `json:"product_code"`
	ProductTitle        string `json:"product_title"`
	ChannelID           int64  `json:"channel_id"`
	ChannelCode         string `json:"channel_code"`
	ChannelName         string `json:"channel_name"`
	ChannelType         string `json:"channel_type"`
	DefaultCurrency     string `json:"default_currency"`
	ListingStatus       string `json:"listing_status"`
	PricePolicy         string `json:"price_policy"`
	StockPolicy         string `json:"stock_policy"`
	BookingPolicy       string `json:"booking_policy"`
	RefundPolicyOvr     string `json:"refund_policy_override"`
	MinOrderQty         int64  `json:"min_order_qty"`
	MaxOrderQty         int64  `json:"max_order_qty"`
	SortWeight          int64  `json:"sort_weight"`
	PublishedAt         string `json:"published_at"`
	CreatedAt           string `json:"created_at"`
	SourceCount         int64  `json:"source_count"`
}

// ProductListings 读一个商品在各渠道的上架配置。
func ProductListings(db *store.DB, productID int64) ([]ProductListingRow, error) {
	sql := store.NewSQL(
		`SELECT channel_listing_id, product_id, product_code, product_title, channel_id,
                channel_code, channel_name, channel_type, default_currency, listing_status,
                price_policy, stock_policy, booking_policy, refund_policy_override,
                min_order_qty, max_order_qty, sort_weight, published_at, created_at, source_count
           FROM v_ops_product_listing`)
	w := newWhere(sql)
	w.Eq("product_id", productID)
	sql.Text(" ORDER BY channel_code")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ProductListingRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, ProductListingRow{
			ChannelListingID: parseInt64(r["channel_listing_id"]),
			ProductID:        parseInt64(r["product_id"]),
			ProductCode:      r["product_code"],
			ProductTitle:     r["product_title"],
			ChannelID:        parseInt64(r["channel_id"]),
			ChannelCode:      r["channel_code"],
			ChannelName:      r["channel_name"],
			ChannelType:      r["channel_type"],
			DefaultCurrency:  r["default_currency"],
			ListingStatus:    r["listing_status"],
			PricePolicy:      r["price_policy"],
			StockPolicy:      r["stock_policy"],
			BookingPolicy:    r["booking_policy"],
			RefundPolicyOvr:  r["refund_policy_override"],
			MinOrderQty:      parseInt64(r["min_order_qty"]),
			MaxOrderQty:      parseInt64(r["max_order_qty"]),
			SortWeight:       parseInt64(r["sort_weight"]),
			PublishedAt:      r["published_at"],
			CreatedAt:        r["created_at"],
			SourceCount:      parseInt64(r["source_count"]),
		})
	}
	return out, nil
}

// ProductPriceRow 是一行售价。
//
// SellPrice 是**我们对外报的价**，不是成交价 ——
// 成交价在订单明细的快照里（历史不可变，硬约束 7）。
type ProductPriceRow struct {
	PriceCalendarID    int64  `json:"price_calendar_id"`
	ProductID          int64  `json:"product_id"`
	ProductCode        string `json:"product_code"`
	ProductVariantID   int64  `json:"product_variant_id"`
	VariantCode        string `json:"variant_code"`
	VariantTitle       string `json:"variant_title"`
	PriceDate          string `json:"price_date"`
	SessionID          int64  `json:"session_id"`
	ChannelID          int64  `json:"channel_id"`
	ChannelCode        string `json:"channel_code"`
	CostSourceProduct  int64  `json:"cost_source_product_id"`
	CostSupplierCode   string `json:"cost_supplier_code"`
	SellPrice          string `json:"sell_price"`
	ListPrice          string `json:"list_price"`
	DiscountPct        string `json:"discount_pct"`
	CostPrice          string `json:"cost_price"`
	Currency           string `json:"currency"`
	FXRate             string `json:"fx_rate"`
	FXAsOf             string `json:"fx_as_of"`
	PriceLocked        bool   `json:"price_locked"`
	Source             string `json:"source"`
	Status             string `json:"status"`
	PriceRule          string `json:"price_rule"`
	SyncedAt           string `json:"synced_at"`
	UpdatedAt          string `json:"updated_at"`
}

// ProductPrices 读一个商品的售价行。
func ProductPrices(db *store.DB, productID int64) ([]ProductPriceRow, error) {
	sql := store.NewSQL(
		`SELECT price_calendar_id, product_id, product_code, product_variant_id,
                variant_code, variant_title, price_date, session_id, channel_id,
                channel_code, cost_source_product_id, cost_supplier_code, sell_price,
                list_price, discount_pct, cost_price, currency, fx_rate, fx_as_of,
                price_locked, source, status, price_rule, synced_at, updated_at
           FROM v_ops_product_price`)
	w := newWhere(sql)
	w.Eq("product_id", productID)
	sql.Text(" ORDER BY price_date, variant_code")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ProductPriceRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, ProductPriceRow{
			PriceCalendarID:   parseInt64(r["price_calendar_id"]),
			ProductID:         parseInt64(r["product_id"]),
			ProductCode:       r["product_code"],
			ProductVariantID:  parseInt64(r["product_variant_id"]),
			VariantCode:       r["variant_code"],
			VariantTitle:      r["variant_title"],
			PriceDate:         r["price_date"],
			SessionID:         parseInt64(r["session_id"]),
			ChannelID:         parseInt64(r["channel_id"]),
			ChannelCode:       r["channel_code"],
			CostSourceProduct: parseInt64(r["cost_source_product_id"]),
			CostSupplierCode:  r["cost_supplier_code"],
			SellPrice:         r["sell_price"],
			ListPrice:         r["list_price"],
			DiscountPct:       r["discount_pct"],
			CostPrice:         r["cost_price"],
			Currency:          r["currency"],
			FXRate:            r["fx_rate"],
			FXAsOf:            r["fx_as_of"],
			PriceLocked:       parseBool(r["price_locked"]),
			Source:            r["source"],
			Status:            r["status"],
			PriceRule:         r["price_rule"],
			SyncedAt:          r["synced_at"],
			UpdatedAt:         r["updated_at"],
		})
	}
	return out, nil
}

// ProductContentRow 是一行展示文案。
type ProductContentRow struct {
	ContentKind string `json:"content_kind"`
	ContentID   int64  `json:"content_id"`
	ProductID   int64  `json:"product_id"`
	ProductCode string `json:"product_code"`
	Locale      string `json:"locale"`
	Kind        string `json:"kind"`
	Content     string `json:"content"`
	Title       string `json:"title"`
	SortOrder   int64  `json:"sort_order"`
}

// ProductContents 读一个商品的展示文案（亮点 / 包含 / 须知）。
func ProductContents(db *store.DB, productID int64) ([]ProductContentRow, error) {
	sql := store.NewSQL(
		`SELECT content_kind, content_id, product_id, product_code, locale, kind,
                content, title, sort_order
           FROM v_ops_product_content`)
	w := newWhere(sql)
	w.Eq("product_id", productID)
	sql.Text(" ORDER BY content_kind, sort_order")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ProductContentRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, ProductContentRow{
			ContentKind: r["content_kind"],
			ContentID:   parseInt64(r["content_id"]),
			ProductID:   parseInt64(r["product_id"]),
			ProductCode: r["product_code"],
			Locale:      r["locale"],
			Kind:        r["kind"],
			Content:     r["content"],
			Title:       r["title"],
			SortOrder:   parseInt64(r["sort_order"]),
		})
	}
	return out, nil
}

// ProductDetail 是一个商品的完整视图。
//
// 详情页是运营台的**钻取**页：点进来就是为了看这一个商品的内部结构，
// 所以这里把六块拼在一起 —— 商品头、源绑定、可售单元、上架配置、售价、文案。
//
// 与订单详情同一个例外（spec/22-b-side-console.md §5.28「读侧只读运营读模型」）：
// 列表走读模型，详情才展开 —— 但展开的也是读模型，不在请求链路里 join 主数据。
type ProductDetail struct {
	ProductID     int64                `json:"product_id"`
	ProductCode   string               `json:"product_code"`
	ProductTitle  string               `json:"product_title"`
	Subtitle      string               `json:"subtitle"`
	ProductStatus string               `json:"product_status"`
	CategoryName  string               `json:"category_name"`
	CityName      string               `json:"city_name"`
	VariantCount  int64                `json:"variant_count"`
	MappingCount  int64                `json:"mapping_count"`
	PriceRowCount int64                `json:"price_row_count"`
	ChannelCount  int64                `json:"channel_count"`
	Sources       []ProductSourceRow   `json:"sources"`
	Variants      []ProductVariantRow  `json:"variants"`
	Listings      []ProductListingRow  `json:"listings"`
	Prices        []ProductPriceRow    `json:"prices"`
	Contents      []ProductContentRow  `json:"contents"`
}

// ProductHead 是商品头（一行一个商品）。
type ProductHead struct {
	ProductID     int64  `json:"product_id"`
	ProductCode   string `json:"product_code"`
	ProductTitle  string `json:"product_title"`
	Subtitle      string `json:"subtitle"`
	ProductStatus string `json:"product_status"`
	CategoryName  string `json:"category_name"`
	CityName      string `json:"city_name"`
	VariantCount  int64  `json:"variant_count"`
	MappingCount  int64  `json:"mapping_count"`
	PriceRowCount int64  `json:"price_row_count"`
	ChannelCount  int64  `json:"channel_count"`
}

// ProductHeadByID 读商品头。
//
// 找不到就是「没有这个商品」，不是「返回一个空的」——
// 详情页要能区分「商品不存在」与「商品存在但什么都没有」。
func ProductHeadByID(db *store.DB, productID int64) (*ProductHead, error) {
	if db == nil {
		return nil, fmt.Errorf("读商品头需要数据库连接")
	}
	if productID <= 0 {
		return nil, fmt.Errorf("product_id 必须是正整数")
	}
	sql := store.NewSQL(
		`SELECT product_id, product_code, product_title, subtitle, product_status,
                category_name, city_name, variant_count, mapping_count,
                price_row_count, channel_count
           FROM v_ops_product_head`)
	w := newWhere(sql)
	w.Eq("product_id", productID)
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("没有找到商品 %d", productID)
	}
	r := rows[0]
	return &ProductHead{
		ProductID:     parseInt64(r["product_id"]),
		ProductCode:   r["product_code"],
		ProductTitle:  r["product_title"],
		Subtitle:      r["subtitle"],
		ProductStatus: r["product_status"],
		CategoryName:  r["category_name"],
		CityName:      r["city_name"],
		VariantCount:  parseInt64(r["variant_count"]),
		MappingCount:  parseInt64(r["mapping_count"]),
		PriceRowCount: parseInt64(r["price_row_count"]),
		ChannelCount:  parseInt64(r["channel_count"]),
	}, nil
}

// ProductDetailByID 读一个商品的详情。
func ProductDetailByID(db *store.DB, productID int64) (*ProductDetail, error) {
	head, err := ProductHeadByID(db, productID)
	if err != nil {
		return nil, err
	}

	d := &ProductDetail{
		ProductID:     head.ProductID,
		ProductCode:   head.ProductCode,
		ProductTitle:  head.ProductTitle,
		Subtitle:      head.Subtitle,
		ProductStatus: head.ProductStatus,
		CategoryName:  head.CategoryName,
		CityName:      head.CityName,
		VariantCount:  head.VariantCount,
		MappingCount:  head.MappingCount,
		PriceRowCount: head.PriceRowCount,
		ChannelCount:  head.ChannelCount,
	}
	if d.Sources, err = ProductSources(db, productID); err != nil {
		return nil, fmt.Errorf("读源绑定失败：%w", err)
	}
	if d.Variants, err = ProductVariants(db, productID); err != nil {
		return nil, fmt.Errorf("读可售单元失败：%w", err)
	}
	if d.Listings, err = ProductListings(db, productID); err != nil {
		return nil, fmt.Errorf("读上架配置失败：%w", err)
	}
	if d.Prices, err = ProductPrices(db, productID); err != nil {
		return nil, fmt.Errorf("读售价行失败：%w", err)
	}
	if d.Contents, err = ProductContents(db, productID); err != nil {
		return nil, fmt.Errorf("读展示文案失败：%w", err)
	}
	return d, nil
}

// parseBool 读库里的布尔列。
//
// psql 的 CSV 输出里布尔是 "t" / "f"（不是 true / false）。
func parseBool(s string) bool {
	return strings.EqualFold(strings.TrimSpace(s), "t") ||
		strings.EqualFold(strings.TrimSpace(s), "true")
}
