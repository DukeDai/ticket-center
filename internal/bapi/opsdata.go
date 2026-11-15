package bapi

import (
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// 这个文件是运营读侧的**唯一**取数处：所有读端点都从这里拿行。
//
// 为什么单独一个文件而不是散在各个 handler 里：
//   - 口径只有一份。运营台的「缺口」「可履约」「佣金」这些词在各端点里
//     各写一遍 SQL，就是各写一份口径 —— 迟早分叉。
//   - 拼查询走 store.NewSQL(...).Bind(...)，值在绑定的当场被转义
//     （硬约束 40）。这里不用 fmt.Sprintf 拼值。
//   - 每个 SELECT 的列都带显式别名：psql 的 CSV 输出把表达式原样当列名，
//     几个 COALESCE 挤成同一个列名，取值就全乱了。

// ChannelOverview 是一行渠道总览。
type ChannelOverview struct {
	ChannelID         int64  `json:"channel_id"`
	ChannelCode       string `json:"channel_code"`
	ChannelName       string `json:"channel_name"`
	ChannelType       string `json:"channel_type"`
	ChannelStatus     string `json:"channel_status"`
	SettlementMode    string `json:"settlement_mode"`
	CommissionRate    string `json:"commission_rate"`
	DefaultCurrency   string `json:"default_currency"`
	TaxPolicy         string `json:"tax_policy"`
	ChannelConfig     string `json:"channel_config"`
	OnlineListings    int64  `json:"online_listings"`
	DraftListings     int64  `json:"draft_listings"`
	OrderCount        int64  `json:"order_count"`
	PaidOrderCount    int64  `json:"paid_order_count"`
	UnpaidOrderCount  int64  `json:"unpaid_order_count"`
	SuspectedLostCnt  int64  `json:"suspected_lost_count"`
}

// ChannelOverviews 返回渠道总览。channelID 大于 0 时只看那一个渠道。
func ChannelOverviews(db *store.DB, channelID int64) ([]ChannelOverview, error) {
	sql := store.NewSQL(
		`SELECT channel_id, channel_code, channel_name, channel_type, channel_status,
                settlement_mode, commission_rate, default_currency, tax_policy, channel_config,
                online_listings, draft_listings, order_count, paid_order_count,
                unpaid_order_count, suspected_lost_count
           FROM v_ops_channel_overview`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	sql.Text(" ORDER BY channel_id")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ChannelOverview, 0, len(rows))
	for _, r := range rows {
		out = append(out, ChannelOverview{
			ChannelID:        parseInt64(r["channel_id"]),
			ChannelCode:      r["channel_code"],
			ChannelName:      r["channel_name"],
			ChannelType:      r["channel_type"],
			ChannelStatus:    r["channel_status"],
			SettlementMode:   r["settlement_mode"],
			CommissionRate:   r["commission_rate"],
			DefaultCurrency:  r["default_currency"],
			TaxPolicy:        r["tax_policy"],
			ChannelConfig:    r["channel_config"],
			OnlineListings:   parseInt64(r["online_listings"]),
			DraftListings:    parseInt64(r["draft_listings"]),
			OrderCount:       parseInt64(r["order_count"]),
			PaidOrderCount:   parseInt64(r["paid_order_count"]),
			UnpaidOrderCount: parseInt64(r["unpaid_order_count"]),
			SuspectedLostCnt: parseInt64(r["suspected_lost_count"]),
		})
	}
	return out, nil
}

// CatalogRow 是一行商品目录（一个商品 × 一个渠道）。
type CatalogRow struct {
	ProductID        int64  `json:"product_id"`
	ProductCode      string `json:"product_code"`
	ProductTitle     string `json:"product_title"`
	Subtitle         string `json:"subtitle"`
	ProductStatus    string `json:"product_status"`
	CategoryName     string `json:"category_name"`
	CityName         string `json:"city_name"`
	VariantCount     int64  `json:"variant_count"`
	ChannelListingID int64  `json:"channel_listing_id"`
	ChannelID        int64  `json:"channel_id"`
	ChannelCode      string `json:"channel_code"`
	ChannelName      string `json:"channel_name"`
	ChannelType      string `json:"channel_type"`
	DefaultCurrency  string `json:"default_currency"`
	ListingStatus    string `json:"listing_status"`
	PricePolicy      string `json:"price_policy"`
	StockPolicy      string `json:"stock_policy"`
	BookingPolicy    string `json:"booking_policy"`
	RefundPolicyOvr  string `json:"refund_policy_override"`
	MinOrderQty      int64  `json:"min_order_qty"`
	MaxOrderQty      int64  `json:"max_order_qty"`
	SortWeight       int64  `json:"sort_weight"`
	PublishedAt      string `json:"published_at"`
	SourceCount      int64  `json:"source_count"`
}

// Catalog 返回商品目录。筛选条件都可选：0 / 空串表示不过滤。
func Catalog(db *store.DB, channelID int64, keyword, listingStatus string) ([]CatalogRow, error) {
	sql := store.NewSQL(
		`SELECT product_id, product_code, product_title, subtitle, product_status,
                category_name, city_name, variant_count, channel_listing_id, channel_id,
                channel_code, channel_name, channel_type, default_currency, listing_status,
                price_policy, stock_policy, booking_policy, refund_policy_override,
                min_order_qty, max_order_qty, sort_weight, published_at, source_count
           FROM v_ops_product_catalog`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	if listingStatus != "" {
		w.Eq("listing_status", listingStatus)
	}
	if keyword != "" {
		// 关键词是用户输入，要转义后再进 LIKE。用 ESCAPE 挡住 % 与 _ 通配符 ——
		// 否则搜「100%」会变成「任意字符」。
		w.Like("product_code", keyword)
		w.OrLike("product_title", keyword)
		w.CloseGroup()
	}
	sql.Text(" ORDER BY product_code, channel_code")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]CatalogRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, CatalogRow{
			ProductID:        parseInt64(r["product_id"]),
			ProductCode:      r["product_code"],
			ProductTitle:     r["product_title"],
			Subtitle:         r["subtitle"],
			ProductStatus:    r["product_status"],
			CategoryName:     r["category_name"],
			CityName:         r["city_name"],
			VariantCount:     parseInt64(r["variant_count"]),
			ChannelListingID: parseInt64(r["channel_listing_id"]),
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
			SourceCount:      parseInt64(r["source_count"]),
		})
	}
	return out, nil
}

// escapeLike 把 LIKE 里的通配符转义掉。
//
// 不转义的话，搜「50%」会匹配到「50」开头的任何字符串 ——
// 用户搜一个含 % 的型号词，结果里混进一堆不相干的，那是「搜不准」，
// 不是「搜到多个」。
func escapeLike(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}

// OrderRow 是一行订单。
type OrderRow struct {
	OrderID           int64  `json:"order_id"`
	OrderNo           string `json:"order_no"`
	ChannelID         int64  `json:"channel_id"`
	ChannelCode       string `json:"channel_code"`
	ChannelName       string `json:"channel_name"`
	CustomerID        int64  `json:"customer_id"`
	CustomerName      string `json:"customer_name"`
	MemberCode        string `json:"member_code"`
	OrderStatus       string `json:"order_status"`
	PaymentStatus     string `json:"payment_status"`
	FulfillmentStatus string `json:"fulfillment_status"`
	Currency          string `json:"currency"`
	Subtotal          string `json:"subtotal"`
	Discount          string `json:"discount"`
	Tax               string `json:"tax"`
	Total             string `json:"total"`
	CostTotal         string `json:"cost_total"`
	CommissionAmount  string `json:"commission_amount"`
	IdempotencyKey    string `json:"idempotency_key"`
	BuyerNote         string `json:"buyer_note"`
	PlacedAt          string `json:"placed_at"`
	ConfirmedAt       string `json:"confirmed_at"`
	CompletedAt       string `json:"completed_at"`
	ItemCount         int64  `json:"item_count"`
	VoucherCount      int64  `json:"voucher_count"`
	BookingCount      int64  `json:"booking_count"`
}

// OrderFilter 是订单列表的筛选条件。
type OrderFilter struct {
	ChannelID int64
	Status    string
	Payment   string
	Keyword   string
	Limit     int
	Offset    int
}

// Orders 返回订单列表。
func Orders(db *store.DB, f OrderFilter) ([]OrderRow, error) {
	sql := store.NewSQL(
		`SELECT order_id, order_no, channel_id, channel_code, channel_name, customer_id,
                customer_name, member_code, order_status, payment_status, fulfillment_status,
                currency, subtotal, discount, tax, total, cost_total, commission_amount,
                idempotency_key, buyer_note, placed_at, confirmed_at, completed_at,
                item_count, voucher_count, booking_count
           FROM v_ops_order_list`)
	w := newWhere(sql)
	if f.ChannelID > 0 {
		w.Eq("channel_id", f.ChannelID)
	}
	if f.Status != "" {
		w.Eq("order_status", f.Status)
	}
	if f.Payment != "" {
		w.Eq("payment_status", f.Payment)
	}
	if f.Keyword != "" {
		w.Like("order_no", f.Keyword)
		w.OrLike("COALESCE(customer_name,'')", f.Keyword)
		w.CloseGroup()
	}
	sql.Text(" ORDER BY placed_at DESC LIMIT ").Bind(f.Limit)
	sql.Text(" OFFSET ").Bind(f.Offset)
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]OrderRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, OrderRow{
			OrderID:           parseInt64(r["order_id"]),
			OrderNo:           r["order_no"],
			ChannelID:         parseInt64(r["channel_id"]),
			ChannelCode:       r["channel_code"],
			ChannelName:       r["channel_name"],
			CustomerID:        parseInt64(r["customer_id"]),
			CustomerName:      r["customer_name"],
			MemberCode:        r["member_code"],
			OrderStatus:       r["order_status"],
			PaymentStatus:     r["payment_status"],
			FulfillmentStatus: r["fulfillment_status"],
			Currency:          r["currency"],
			Subtotal:          r["subtotal"],
			Discount:          r["discount"],
			Tax:               r["tax"],
			Total:             r["total"],
			CostTotal:         r["cost_total"],
			CommissionAmount:  r["commission_amount"],
			IdempotencyKey:    r["idempotency_key"],
			BuyerNote:         r["buyer_note"],
			PlacedAt:          r["placed_at"],
			ConfirmedAt:       r["confirmed_at"],
			CompletedAt:       r["completed_at"],
			ItemCount:         parseInt64(r["item_count"]),
			VoucherCount:      parseInt64(r["voucher_count"]),
			BookingCount:      parseInt64(r["booking_count"]),
		})
	}
	return out, nil
}

// FulfillmentGapRow 是一行履约漏斗。
type FulfillmentGapRow struct {
	OrderID           int64  `json:"order_id"`
	OrderNo           string `json:"order_no"`
	ChannelID         int64  `json:"channel_id"`
	ChannelCode       string `json:"channel_code"`
	OrderStatus       string `json:"order_status"`
	PaymentStatus     string `json:"payment_status"`
	PlacedAt          string `json:"placed_at"`
	BookingCount      int64  `json:"booking_count"`
	ConfirmedBookings int64  `json:"confirmed_bookings"`
	FailedBookings    int64  `json:"failed_bookings"`
	VoucherCount      int64  `json:"voucher_count"`
	IssuedVouchers    int64  `json:"issued_vouchers"`
	UsedVouchers      int64  `json:"used_vouchers"`
	SuspectedLost     bool   `json:"suspected_lost"`
}

// FulfillmentGaps 返回履约漏斗。lostOnly 为 true 时只回「付了没出票」的那些。
func FulfillmentGaps(db *store.DB, channelID int64, lostOnly bool) ([]FulfillmentGapRow, error) {
	sql := store.NewSQL(
		`SELECT order_id, order_no, channel_id, channel_code, order_status, payment_status,
                placed_at, booking_count, confirmed_bookings, failed_bookings,
                voucher_count, issued_vouchers, used_vouchers, suspected_lost
           FROM v_ops_fulfillment_gap`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	if lostOnly {
		w.Raw("suspected_lost")
	}
	sql.Text(" ORDER BY placed_at DESC")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]FulfillmentGapRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, FulfillmentGapRow{
			OrderID:           parseInt64(r["order_id"]),
			OrderNo:           r["order_no"],
			ChannelID:         parseInt64(r["channel_id"]),
			ChannelCode:       r["channel_code"],
			OrderStatus:       r["order_status"],
			PaymentStatus:     r["payment_status"],
			PlacedAt:          r["placed_at"],
			BookingCount:      parseInt64(r["booking_count"]),
			ConfirmedBookings: parseInt64(r["confirmed_bookings"]),
			FailedBookings:    parseInt64(r["failed_bookings"]),
			VoucherCount:      parseInt64(r["voucher_count"]),
			IssuedVouchers:    parseInt64(r["issued_vouchers"]),
			UsedVouchers:      parseInt64(r["used_vouchers"]),
			SuspectedLost:     r["suspected_lost"] == "t" || r["suspected_lost"] == "true",
		})
	}
	return out, nil
}

// SupplyFormRow 是一行供给形态。
type SupplyFormRow struct {
	ProductVariantID  int64  `json:"product_variant_id"`
	VariantCode       string `json:"variant_code"`
	VariantTitle      string `json:"variant_title"`
	VariantRole       string `json:"variant_role"`
	ProductID         int64  `json:"product_id"`
	ProductCode       string `json:"product_code"`
	ProductTitle      string `json:"product_title"`
	Date              string `json:"date"`
	ChannelID         int64  `json:"channel_id"`
	SupplyForm        string `json:"supply_form"`
	SupplierCodes     string `json:"supplier_codes"`
	SupplierCount     int64  `json:"supplier_count"`
	SourceCurrencies  string `json:"source_currencies"`
	CostInTarget      string `json:"cost_in_target"`
	Currency          string `json:"currency"`
	BaseCurrency      string `json:"base_currency"`
	ComponentCount    int64  `json:"component_count"`
	AdmissionQuantity int64  `json:"admission_quantity"`
	AudienceCodes     string `json:"audience_codes"`
	ValidDays         int64  `json:"valid_days"`
	CanFulfil         bool   `json:"can_fulfil"`
	Gaps              string `json:"gaps"`
	Candidates        string `json:"candidates"`
}

// SupplyForms 返回供给形态对照。channelID、productID、date 都可选。
func SupplyForms(db *store.DB, channelID, productID int64, date string, onlyGaps bool) ([]SupplyFormRow, error) {
	sql := store.NewSQL(
		`SELECT product_variant_id, variant_code, variant_title, variant_role,
                product_id, product_code, product_title, date, channel_id, supply_form,
                supplier_codes, supplier_count, source_currencies, cost_in_target,
                currency, base_currency, component_count, admission_quantity,
                audience_codes, valid_days, can_fulfil, gaps, candidates
           FROM v_ops_supply_forms`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	if productID > 0 {
		w.Eq("product_id", productID)
	}
	if date != "" {
		w.Eq("date", date)
	}
	if onlyGaps {
		w.Raw("NOT can_fulfil")
	}
	sql.Text(" ORDER BY product_code, variant_code, date, channel_id")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]SupplyFormRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, SupplyFormRow{
			ProductVariantID:  parseInt64(r["product_variant_id"]),
			VariantCode:       r["variant_code"],
			VariantTitle:      r["variant_title"],
			VariantRole:       r["variant_role"],
			ProductID:         parseInt64(r["product_id"]),
			ProductCode:       r["product_code"],
			ProductTitle:      r["product_title"],
			Date:              r["date"],
			ChannelID:         parseInt64(r["channel_id"]),
			SupplyForm:        r["supply_form"],
			SupplierCodes:     r["supplier_codes"],
			SupplierCount:     parseInt64(r["supplier_count"]),
			SourceCurrencies:  r["source_currencies"],
			CostInTarget:      r["cost_in_target"],
			Currency:          r["currency"],
			BaseCurrency:      r["base_currency"],
			ComponentCount:    parseInt64(r["component_count"]),
			AdmissionQuantity: parseInt64(r["admission_quantity"]),
			AudienceCodes:     r["audience_codes"],
			ValidDays:         parseInt64(r["valid_days"]),
			CanFulfil:         r["can_fulfil"] == "t" || r["can_fulfil"] == "true",
			Gaps:              r["gaps"],
			Candidates:        r["candidates"],
		})
	}
	return out, nil
}

// RefundRow 是一行退款。
type RefundRow struct {
	RefundID            int64  `json:"refund_id"`
	RefundNo            string `json:"refund_no"`
	OrderID             int64  `json:"order_id"`
	OrderNo             string `json:"order_no"`
	ChannelID           int64  `json:"channel_id"`
	ChannelCode         string `json:"channel_code"`
	CustomerID          int64  `json:"customer_id"`
	RefundStatus        string `json:"refund_status"`
	RefundAmount        string `json:"refund_amount"`
	Currency            string `json:"currency"`
	Reason              string `json:"reason"`
	RequestedBy         string `json:"requested_by"`
	ApprovedBy          string `json:"approved_by"`
	PreviousOrderStatus string `json:"previous_order_status"`
	ErrorCode           string `json:"error_code"`
	ErrorMessage        string `json:"error_message"`
	IdempotencyKey      string `json:"idempotency_key"`
	RequestedAt         string `json:"requested_at"`
	ApprovedAt          string `json:"approved_at"`
	CompletedAt         string `json:"completed_at"`
}

// Refunds 返回退款台账。
func Refunds(db *store.DB, channelID int64, status string) ([]RefundRow, error) {
	sql := store.NewSQL(
		`SELECT refund_id, refund_no, order_id, order_no, channel_id, channel_code,
                customer_id, refund_status, refund_amount, currency, reason,
                requested_by, approved_by, previous_order_status, error_code, error_message,
                idempotency_key, requested_at, approved_at, completed_at
           FROM v_ops_refund_ledger`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	if status != "" {
		w.Eq("refund_status", status)
	}
	sql.Text(" ORDER BY requested_at DESC")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]RefundRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, RefundRow{
			RefundID:            parseInt64(r["refund_id"]),
			RefundNo:            r["refund_no"],
			OrderID:             parseInt64(r["order_id"]),
			OrderNo:             r["order_no"],
			ChannelID:           parseInt64(r["channel_id"]),
			ChannelCode:         r["channel_code"],
			CustomerID:          parseInt64(r["customer_id"]),
			RefundStatus:        r["refund_status"],
			RefundAmount:        r["refund_amount"],
			Currency:            r["currency"],
			Reason:              r["reason"],
			RequestedBy:         r["requested_by"],
			ApprovedBy:          r["approved_by"],
			PreviousOrderStatus: r["previous_order_status"],
			ErrorCode:           r["error_code"],
			ErrorMessage:        r["error_message"],
			IdempotencyKey:      r["idempotency_key"],
			RequestedAt:         r["requested_at"],
			ApprovedAt:          r["approved_at"],
			CompletedAt:         r["completed_at"],
		})
	}
	return out, nil
}

// RedemptionRow 是一行核销记录。
type RedemptionRow struct {
	RedemptionID    int64  `json:"redemption_id"`
	VoucherID       int64  `json:"voucher_id"`
	VoucherNo       string `json:"voucher_no"`
	TicketCode      string `json:"ticket_code"`
	OrderID         int64  `json:"order_id"`
	OrderNo         string `json:"order_no"`
	ChannelID       int64  `json:"channel_id"`
	ChannelCode     string `json:"channel_code"`
	Result          string `json:"result"`
	Reason          string `json:"reason"`
	GateID          int64  `json:"gate_id"`
	GateName        string `json:"gate_name"`
	GateOperatorID  int64  `json:"gate_operator_id"`
	OperatorID      string `json:"operator_id"`
	ConsumedQty     int64  `json:"consumed_quantity"`
	ScannedAt       string `json:"scanned_at"`
}

// Redemptions 返回核销记录。
func Redemptions(db *store.DB, channelID int64, result string, limit int) ([]RedemptionRow, error) {
	sql := store.NewSQL(
		`SELECT redemption_id, voucher_id, voucher_no, ticket_code, order_id, order_no,
                channel_id, channel_code, result, reason, gate_id, gate_name,
                gate_operator_id, operator_id, consumed_quantity, scanned_at
           FROM v_ops_redemption_log`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	if result != "" {
		w.Eq("result", result)
	}
	sql.Text(" ORDER BY scanned_at DESC LIMIT ").Bind(limit)
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]RedemptionRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, RedemptionRow{
			RedemptionID:   parseInt64(r["redemption_id"]),
			VoucherID:      parseInt64(r["voucher_id"]),
			VoucherNo:      r["voucher_no"],
			TicketCode:     r["ticket_code"],
			OrderID:        parseInt64(r["order_id"]),
			OrderNo:        r["order_no"],
			ChannelID:      parseInt64(r["channel_id"]),
			ChannelCode:    r["channel_code"],
			Result:         r["result"],
			Reason:         r["reason"],
			GateID:         parseInt64(r["gate_id"]),
			GateName:       r["gate_name"],
			GateOperatorID: parseInt64(r["gate_operator_id"]),
			OperatorID:     r["operator_id"],
			ConsumedQty:    parseInt64(r["consumed_quantity"]),
			ScannedAt:      r["scanned_at"],
		})
	}
	return out, nil
}

// HoldRow 是一行库存预占。
type HoldRow struct {
	HoldID           int64  `json:"hold_id"`
	HoldNo           string `json:"hold_no"`
	ChannelID        int64  `json:"channel_id"`
	ChannelCode      string `json:"channel_code"`
	ProductSessionID int64  `json:"product_session_id"`
	TicketTypeID     int64  `json:"ticket_type_id"`
	SupplierID       int64  `json:"supplier_id"`
	Quantity         int64  `json:"quantity"`
	HoldStatus       string `json:"hold_status"`
	CartID           int64  `json:"cart_id"`
	OrderID          int64  `json:"order_id"`
	CreatedAt        string `json:"created_at"`
	ExpiresAt        string `json:"expires_at"`
	ReleasedAt       string `json:"released_at"`
}

// Holds 返回库存预占。
func Holds(db *store.DB, channelID int64, status string, limit int) ([]HoldRow, error) {
	sql := store.NewSQL(
		`SELECT hold_id, hold_no, channel_id, channel_code, product_session_id,
                ticket_type_id, supplier_id, quantity, hold_status, cart_id, order_id,
                created_at, expires_at, released_at
           FROM v_ops_inventory_hold`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	if status != "" {
		w.Eq("hold_status", status)
	}
	sql.Text(" ORDER BY created_at DESC LIMIT ").Bind(limit)
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]HoldRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, HoldRow{
			HoldID:           parseInt64(r["hold_id"]),
			HoldNo:           r["hold_no"],
			ChannelID:        parseInt64(r["channel_id"]),
			ChannelCode:      r["channel_code"],
			ProductSessionID: parseInt64(r["product_session_id"]),
			TicketTypeID:     parseInt64(r["ticket_type_id"]),
			SupplierID:       parseInt64(r["supplier_id"]),
			Quantity:         parseInt64(r["quantity"]),
			HoldStatus:       r["hold_status"],
			CartID:           parseInt64(r["cart_id"]),
			OrderID:          parseInt64(r["order_id"]),
			CreatedAt:        r["created_at"],
			ExpiresAt:        r["expires_at"],
			ReleasedAt:       r["released_at"],
		})
	}
	return out, nil
}

// SupplierHealthRow 是一行源健康度。
type SupplierHealthRow struct {
	SupplierID      int64  `json:"supplier_id"`
	Code            string `json:"code"`
	Name            string `json:"name"`
	Status          string `json:"status"`
	ActiveProducts  int64  `json:"active_products"`
	MappedProducts  int64  `json:"mapped_products"`
	Payloads1h      int64  `json:"payloads_1h"`
	LastSyncAt      string `json:"last_sync_at"`
	FailedJobs24h   int64  `json:"failed_jobs_24h"`
}

// SupplierHealth 返回源健康度。
func SupplierHealth(db *store.DB) ([]SupplierHealthRow, error) {
	rows, err := db.Rows(
		`SELECT supplier_id, code, name, status, active_products, mapped_products,
                payloads_1h, last_sync_at, failed_jobs_24h
           FROM v_ops_supplier_health ORDER BY code;`)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]SupplierHealthRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, SupplierHealthRow{
			SupplierID:     parseInt64(r["supplier_id"]),
			Code:           r["code"],
			Name:           r["name"],
			Status:         r["status"],
			ActiveProducts: parseInt64(r["active_products"]),
			MappedProducts: parseInt64(r["mapped_products"]),
			Payloads1h:     parseInt64(r["payloads_1h"]),
			LastSyncAt:     r["last_sync_at"],
			FailedJobs24h:  parseInt64(r["failed_jobs_24h"]),
		})
	}
	return out, nil
}

// SettlementGapRow 是一行结算缺口。
type SettlementGapRow struct {
	SupplierID       int64  `json:"supplier_id"`
	SupplierCode     string `json:"supplier_code"`
	BookingID        int64  `json:"booking_id"`
	BookingNo        string `json:"booking_no"`
	ExternalBookingID string `json:"external_booking_id"`
	BookingStatus    string `json:"booking_status"`
	ConfirmedAt      string `json:"confirmed_at"`
	OrderNo          string `json:"order_no"`
	SettlementLines  int64  `json:"settlement_lines"`
}

// SettlementGaps 返回结算缺口。
func SettlementGaps(db *store.DB) ([]SettlementGapRow, error) {
	rows, err := db.Rows(
		`SELECT supplier_id, supplier_code, booking_id, booking_no, external_booking_id,
                booking_status, confirmed_at, order_no, settlement_lines
           FROM v_ops_settlement_gap ORDER BY supplier_code;`)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]SettlementGapRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, SettlementGapRow{
			SupplierID:        parseInt64(r["supplier_id"]),
			SupplierCode:      r["supplier_code"],
			BookingID:         parseInt64(r["booking_id"]),
			BookingNo:         r["booking_no"],
			ExternalBookingID: r["external_booking_id"],
			BookingStatus:     r["booking_status"],
			ConfirmedAt:       r["confirmed_at"],
			OrderNo:           r["order_no"],
			SettlementLines:   parseInt64(r["settlement_lines"]),
		})
	}
	return out, nil
}

// ReassignCandidateRow 是一行待改派。
type ReassignCandidateRow struct {
	OrderID            int64  `json:"order_id"`
	OrderNo            string `json:"order_no"`
	OrderItemID        int64  `json:"order_item_id"`
	ChannelID          int64  `json:"channel_id"`
	ChannelCode        string `json:"channel_code"`
	ProductID          int64  `json:"product_id"`
	ProductVariantID   int64  `json:"product_variant_id"`
	VisitDate          string `json:"visit_date"`
	Quantity           int64  `json:"quantity"`
	CurrentSupplierPID int64  `json:"current_supplier_product_id"`
	CurrentSupplier    string `json:"current_supplier"`
	CurrentUnitPrice   string `json:"current_unit_price"`
	CurrentUnitCost    string `json:"current_unit_cost"`
	NewSupplierPID     int64  `json:"new_supplier_product_id"`
	NewSupplier        string `json:"new_supplier"`
	NewUnitPrice       string `json:"new_unit_price"`
	NewUnitCost        string `json:"new_unit_cost"`
	CanReassign        bool   `json:"can_reassign"`
	StaleReason        string `json:"stale_reason"`
}

// ReassignCandidates 返回待改派清单。
func ReassignCandidates(db *store.DB, channelID int64) ([]ReassignCandidateRow, error) {
	sql := store.NewSQL(
		`SELECT order_id, order_no, order_item_id, channel_id, channel_code,
                product_id, product_variant_id, visit_date, quantity,
                current_supplier_product_id, current_supplier,
                current_unit_price, current_unit_cost,
                new_supplier_product_id, new_supplier,
                new_unit_price, new_unit_cost, can_reassign, stale_reason
           FROM v_ops_reassign_candidates`)
	w := newWhere(sql)
	if channelID > 0 {
		w.Eq("channel_id", channelID)
	}
	sql.Text(" ORDER BY order_no, order_item_id")
	q, err := sql.String()
	if err != nil {
		return nil, err
	}
	rows, err := db.Rows(q)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]ReassignCandidateRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, ReassignCandidateRow{
			OrderID:            parseInt64(r["order_id"]),
			OrderNo:            r["order_no"],
			OrderItemID:        parseInt64(r["order_item_id"]),
			ChannelID:          parseInt64(r["channel_id"]),
			ChannelCode:        r["channel_code"],
			ProductID:          parseInt64(r["product_id"]),
			ProductVariantID:   parseInt64(r["product_variant_id"]),
			VisitDate:          r["visit_date"],
			Quantity:           parseInt64(r["quantity"]),
			CurrentSupplierPID: parseInt64(r["current_supplier_product_id"]),
			CurrentSupplier:    r["current_supplier"],
			CurrentUnitPrice:   r["current_unit_price"],
			CurrentUnitCost:    r["current_unit_cost"],
			NewSupplierPID:     parseInt64(r["new_supplier_product_id"]),
			NewSupplier:        r["new_supplier"],
			NewUnitPrice:       r["new_unit_price"],
			NewUnitCost:        r["new_unit_cost"],
			CanReassign:        r["can_reassign"] == "t" || r["can_reassign"] == "true",
			StaleReason:        r["stale_reason"],
		})
	}
	return out, nil
}

// OrderDetail 是一张订单的完整视图（订单 + 明细 + 预订 + 凭证）。
//
// 明细、预订、凭证都从主数据读 —— 这是运营台按需钻取，
// 不是列表页面的读模型。列表走 v_ops_order_list（只读读模型），
// 详情才展开细。这里展开的每一样都是事实表里的原样，不重算。
type OrderDetail struct {
	OrderRow
	Items    []OrderItemRow  `json:"items"`
	Bookings []BookingRow    `json:"bookings"`
	Vouchers []VoucherRow    `json:"vouchers"`
	Payments []PaymentRow    `json:"payments"`
}

// OrderItemRow 是一行订单明细。
type OrderItemRow struct {
	OrderItemID       int64  `json:"order_item_id"`
	ProductID         int64  `json:"product_id"`
	ProductTitle      string `json:"product_title"`
	ProductVariantID  int64  `json:"product_variant_id"`
	VariantCode       string `json:"variant_code"`
	SupplierID        int64  `json:"supplier_id"`
	SupplierName      string `json:"supplier_name"`
	SupplierProductID int64  `json:"supplier_product_id"`
	Quantity          int64  `json:"quantity"`
	UnitPrice         string `json:"unit_price"`
	UnitCost          string `json:"unit_cost"`
	TotalPrice        string `json:"total_price"`
	Currency          string `json:"currency"`
	PricingBasis      string `json:"pricing_basis"`
	Status            string `json:"status"`
	VisitDate         string `json:"visit_date"`
}

// BookingRow 是一条预订。
type BookingRow struct {
	BookingID        int64  `json:"booking_id"`
	BookingNo        string `json:"booking_no"`
	OrderItemID      int64  `json:"order_item_id"`
	SupplierID       int64  `json:"supplier_id"`
	SupplierName     string `json:"supplier_name"`
	ExternalBookingID string `json:"external_booking_id"`
	Status           string `json:"status"`
	AttemptCount     int64  `json:"attempt_count"`
	ConfirmedAt      string `json:"confirmed_at"`
	CreatedAt        string `json:"created_at"`
}

// VoucherRow 是一张券。
type VoucherRow struct {
	VoucherID    int64  `json:"voucher_id"`
	VoucherNo    string `json:"voucher_no"`
	OrderItemID  int64  `json:"order_item_id"`
	BookingID    int64  `json:"booking_id"`
	Code         string `json:"ticket_code"`
	Status       string `json:"status"`
	IssuedAt     string `json:"issued_at"`
	ValidFrom    string `json:"valid_from"`
	ValidTo      string `json:"valid_to"`
	UsedAt       string `json:"used_at"`
	HolderName   string `json:"holder_name"`
}

// PaymentRow 是一笔支付。
type PaymentRow struct {
	PaymentID      int64  `json:"payment_id"`
	PaymentMethod  string `json:"payment_method"`
	Amount         string `json:"amount"`
	Currency       string `json:"currency"`
	Status         string `json:"status"`
	Provider       string `json:"provider"`
	ProviderTxnID  string `json:"provider_txn_id"`
	PaidAt         string `json:"paid_at"`
}

// OrderDetailByID 读一张订单的完整视图。
func OrderDetailByID(db *store.DB, orderID int64) (*OrderDetail, error) {
	// 直接按 id 查这一单（列表视图带别的筛选条件，这里要的是指定单）。
	rows, err := db.Rows(fmt.Sprintf(
		`SELECT order_id, order_no, channel_id, channel_code, channel_name, customer_id,
                customer_name, member_code, order_status, payment_status, fulfillment_status,
                currency, subtotal, discount, tax, total, cost_total, commission_amount,
                idempotency_key, buyer_note, placed_at, confirmed_at, completed_at,
                item_count, voucher_count, booking_count
           FROM v_ops_order_list WHERE order_id = %s;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("订单 %d 不存在", orderID)
	}
	r := rows[0]
	d := &OrderDetail{OrderRow: OrderRow{
		OrderID:           parseInt64(r["order_id"]),
		OrderNo:           r["order_no"],
		ChannelID:         parseInt64(r["channel_id"]),
		ChannelCode:       r["channel_code"],
		ChannelName:       r["channel_name"],
		CustomerID:        parseInt64(r["customer_id"]),
		CustomerName:      r["customer_name"],
		MemberCode:        r["member_code"],
		OrderStatus:       r["order_status"],
		PaymentStatus:     r["payment_status"],
		FulfillmentStatus: r["fulfillment_status"],
		Currency:          r["currency"],
		Subtotal:          r["subtotal"],
		Discount:          r["discount"],
		Tax:               r["tax"],
		Total:             r["total"],
		CostTotal:         r["cost_total"],
		CommissionAmount:  r["commission_amount"],
		IdempotencyKey:    r["idempotency_key"],
		BuyerNote:         r["buyer_note"],
		PlacedAt:          r["placed_at"],
		ConfirmedAt:       r["confirmed_at"],
		CompletedAt:       r["completed_at"],
		ItemCount:         parseInt64(r["item_count"]),
		VoucherCount:      parseInt64(r["voucher_count"]),
		BookingCount:      parseInt64(r["booking_count"]),
	}}

	itemRows, err := db.Rows(fmt.Sprintf(
		`SELECT oi.id, oi.product_id, COALESCE(p.title, '') AS product_title,
                COALESCE(oi.product_variant_id::text, '') AS product_variant_id,
                COALESCE(pv.variant_code, '') AS variant_code,
                COALESCE(oi.supplier_id::text, '') AS supplier_id,
                COALESCE(sup.name, '') AS supplier_name,
                COALESCE(oi.supplier_product_id::text, '') AS supplier_product_id,
                oi.quantity, oi.unit_price::text, COALESCE(oi.unit_cost::text, '') AS unit_cost,
                oi.total_price::text, oi.currency,
                COALESCE(oi.pricing_basis, '') AS pricing_basis,
                oi.status,
                COALESCE(oi.detail_snapshot->>'title', '') AS snapshot_title,
                COALESCE(oi.detail_snapshot->>'visit_date', '') AS visit_date
           FROM sales_order_item oi
           LEFT JOIN product p ON p.id = oi.product_id
           LEFT JOIN product_variant pv ON pv.id = oi.product_variant_id
           LEFT JOIN supplier sup ON sup.id = oi.supplier_id
          WHERE oi.order_id = %s
          ORDER BY oi.id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, r := range itemRows {
		// 明细标题优先用下单瞬间的快照（历史不可变），
		// 快照没有才回退到现在的商品名 —— 现在的名字可能已经改了。
		title := strings.TrimSpace(r["snapshot_title"])
		if title == "" {
			title = r["product_title"]
		}
		d.Items = append(d.Items, OrderItemRow{
			OrderItemID:       parseInt64(r["id"]),
			ProductID:         parseInt64(r["product_id"]),
			ProductTitle:      title,
			ProductVariantID:  parseInt64(r["product_variant_id"]),
			VariantCode:       r["variant_code"],
			SupplierID:        parseInt64(r["supplier_id"]),
			SupplierName:      r["supplier_name"],
			SupplierProductID: parseInt64(r["supplier_product_id"]),
			Quantity:          parseInt64(r["quantity"]),
			UnitPrice:         r["unit_price"],
			UnitCost:          r["unit_cost"],
			TotalPrice:        r["total_price"],
			Currency:          r["currency"],
			PricingBasis:      r["pricing_basis"],
			Status:            r["status"],
			VisitDate:         r["visit_date"],
		})
	}

	bookingRows, err := db.Rows(fmt.Sprintf(
		`SELECT b.id, b.booking_no, COALESCE(b.order_item_id::text, '') AS order_item_id,
                b.supplier_id, COALESCE(sup.name, '') AS supplier_name,
                COALESCE(b.external_booking_id, '') AS external_booking_id,
                b.status, COALESCE(b.attempt_count, 0),
                COALESCE(b.confirmed_at::text, '') AS confirmed_at,
                b.created_at::text
           FROM booking b
           LEFT JOIN supplier sup ON sup.id = b.supplier_id
          WHERE b.order_id = %s
          ORDER BY b.id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, r := range bookingRows {
		d.Bookings = append(d.Bookings, BookingRow{
			BookingID:         parseInt64(r["id"]),
			BookingNo:         r["booking_no"],
			OrderItemID:       parseInt64(r["order_item_id"]),
			SupplierID:        parseInt64(r["supplier_id"]),
			SupplierName:      r["supplier_name"],
			ExternalBookingID: r["external_booking_id"],
			Status:            r["status"],
			AttemptCount:      parseInt64(r["attempt_count"]),
			ConfirmedAt:       r["confirmed_at"],
			CreatedAt:         r["created_at"],
		})
	}

	voucherRows, err := db.Rows(fmt.Sprintf(
		`SELECT v.id, v.voucher_no, COALESCE(v.order_item_id::text, '') AS order_item_id,
                COALESCE(v.booking_id::text, '') AS booking_id,
                COALESCE(v.code, '') AS code, v.status,
                COALESCE(v.issued_at::text, '') AS issued_at,
                COALESCE(v.valid_from::text, '') AS valid_from,
                COALESCE(v.valid_to::text, '') AS valid_to,
                COALESCE(v.used_at::text, '') AS used_at,
                COALESCE(v.holder_snapshot->>'holder_name', '') AS holder_name
           FROM voucher v WHERE v.order_id = %s ORDER BY v.id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, r := range voucherRows {
		d.Vouchers = append(d.Vouchers, VoucherRow{
			VoucherID:   parseInt64(r["id"]),
			VoucherNo:   r["voucher_no"],
			OrderItemID: parseInt64(r["order_item_id"]),
			BookingID:   parseInt64(r["booking_id"]),
			Code:        r["code"],
			Status:      r["status"],
			IssuedAt:    r["issued_at"],
			ValidFrom:   r["valid_from"],
			ValidTo:     r["valid_to"],
			UsedAt:      r["used_at"],
			HolderName:  r["holder_name"],
		})
	}

	paymentRows, err := db.Rows(fmt.Sprintf(
		`SELECT id, payment_method, amount::text, currency, status,
                COALESCE(provider, '') AS provider,
                COALESCE(provider_txn_id, '') AS provider_txn_id,
                COALESCE(paid_at::text, '') AS paid_at
           FROM sales_payment WHERE order_id = %s ORDER BY id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, r := range paymentRows {
		d.Payments = append(d.Payments, PaymentRow{
			PaymentID:     parseInt64(r["id"]),
			PaymentMethod: r["payment_method"],
			Amount:        r["amount"],
			Currency:      r["currency"],
			Status:        r["status"],
			Provider:      r["provider"],
			ProviderTxnID: r["provider_txn_id"],
			PaidAt:        r["paid_at"],
		})
	}
	return d, nil
}

// parseInt 读库里的整数字段（返回 int）。
func parseInt(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}
