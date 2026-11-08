// Package order 是下单的客户端接口。
//
// 下单的实现只有一个：库里的 fn_place_order()（db/migrations/004_place_order.sql）。
// 这个包只负责把请求拼成 JSONB、把结果读回来 —— 不在这里再算一遍钱，
// 也不在这里再排一遍源。理由与 internal/pricing 一样：
//
//   - 钱必须是 NUMERIC（硬约束 5），Go 标准库没有十进制类型；
//   - 选源与定价必须同源（硬约束 15）。定价函数既选源又定价，
//     如果 Go 侧再排一次，就会出现「按 A 源的价格卖、按 B 源出票」。
//
// 所以 Go 侧只做三件事：拼参数、收结果、把库的报错原样带出去。
package order

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Item 是一行明细。
type Item struct {
	VariantID int64  `json:"variant_id"`
	Quantity  int    `json:"quantity"`
	VisitDate string `json:"visit_date"` // YYYY-MM-DD
}

// Holder 是一名持票人的一个字段。
//
// 字段口径由 checkout_requirement 说（哪些字段必填、上限、格式），
// 这里只负责把收上来的值送进去。
//
// VariantID 指的是**成分变体**：普通商品就是它自己，组合套餐则是包里的那一档
// （家庭套票里的成人档 = 变体 9，儿童档 = 变体 10）。
//
// ItemIndex 指的是**明细行**（从 1 开始）。平时不用填：
// 同一个成分变体只出现在一行明细里时，光看 VariantID 就分得清。
// 只有当同一个成分变体同时出现在多行明细里（一张家庭套票 + 一张单买成人票），
// 才必须填它指明是哪一行 —— 否则库里的 fn_place_order 会当场报错，
// 因为「这份姓名属于哪一行」分不清时不能猜（猜错就是把甲的实名绑到乙的票上）。
//
// 一旦有人的 ItemIndex 非零，整单都得填 —— 漏填的那条匹配不上任何行。
type Holder struct {
	VariantID int64  `json:"variant_id"`
	Sequence  int    `json:"sequence"`   // 第几名持票人，从 1 开始
	FieldCode string `json:"field_code"` // 如 holder_name / id_number
	Value     string `json:"value"`
	ItemIndex int    `json:"item_index,omitempty"` // 明细行号，从 1 开始；0 = 不指定
}

// Request 是一笔下单请求。
type Request struct {
	ChannelID      int64          `json:"channel_id"`
	CustomerID     int64          `json:"customer_id"`
	IdempotencyKey string         `json:"idempotency_key"`
	Items          []Item         `json:"items"`
	Holders        []Holder       `json:"holders"`
	Contact        map[string]any `json:"contact"`
	BuyerNote      string         `json:"buyer_note"`
}

// Order 是一张落库的订单。
//
// 金额一律是字符串：库里是 NUMERIC，用 float64 接住就是丢精度。
type Order struct {
	ID       int64  `json:"order_id"`
	No       string `json:"order_no"`
	Status   string `json:"order_status"`
	Currency string `json:"order_currency"`
	Subtotal string `json:"order_subtotal"`
	Total    string `json:"order_total"`
	// Created 为 false 表示这是幂等命中：同一笔请求重复提交，拿到的是同一张单。
	Created bool `json:"created"`
}

// OrderItem 是一行明细的读回结果。
type OrderItem struct {
	ID               int64  `json:"order_item_id"`
	ProductID        int64  `json:"product_id"`
	VariantID        int64  `json:"product_variant_id"`
	SupplierID       int64  `json:"supplier_id"`
	SupplierProduct  int64  `json:"supplier_product_id"`
	Quantity         int    `json:"quantity"`
	UnitPrice        string `json:"unit_price"`
	TotalPrice       string `json:"total_price"`
	Currency         string `json:"currency"`
	PricingBasis     string `json:"pricing_basis"`
	Status           string `json:"status"`
	Title            string `json:"title"`
	VisitDate        string `json:"visit_date"`
	CostSourceProdID int64  `json:"cost_source_product_id"`
}

// Detail 是订单加上它的明细。
type Detail struct {
	Order Order
	Items []OrderItem
}

// Service 是下单入口。
type Service struct {
	db *store.DB
}

// New 构造下单服务。
func New(db *store.DB) *Service { return &Service{db: db} }

// Place 下单。
//
// 幂等由库里的 fn_place_order 保证：同一个 channel + 同一个幂等键，
// 重复提交返回同一张单（Created=false）；同一个键配不同的内容会被拒。
// 这里不做幂等键的本地缓存 —— 缓存会骗人，库里那张表才是真相。
func (s *Service) Place(req Request) (*Order, error) {
	if s.db == nil {
		return nil, fmt.Errorf("下单需要数据库连接")
	}
	if req.ChannelID == 0 {
		return nil, fmt.Errorf("下单需要渠道（channel_id）")
	}
	if strings.TrimSpace(req.IdempotencyKey) == "" {
		return nil, fmt.Errorf("下单需要幂等键：重复提交不能产生第二张单")
	}
	if len(req.Items) == 0 {
		return nil, fmt.Errorf("下单明细不能为空")
	}

	items, err := json.Marshal(req.Items)
	if err != nil {
		return nil, fmt.Errorf("明细序列化失败：%w", err)
	}
	holders := req.Holders
	if holders == nil {
		holders = []Holder{}
	}
	if err := checkHolderItems(holders, len(req.Items)); err != nil {
		return nil, err
	}
	holdersJSON, err := json.Marshal(holders)
	if err != nil {
		return nil, fmt.Errorf("持票人序列化失败：%w", err)
	}
	contact := req.Contact
	if contact == nil {
		contact = map[string]any{}
	}
	contactJSON, err := json.Marshal(contact)
	if err != nil {
		return nil, fmt.Errorf("联系信息序列化失败：%w", err)
	}

	var customerID any
	if req.CustomerID != 0 {
		customerID = req.CustomerID
	}
	var buyerNote any
	if req.BuyerNote != "" {
		buyerNote = req.BuyerNote
	}

	sql := fmt.Sprintf(
		`SELECT order_id, order_no, order_status, order_currency,
                order_subtotal::text, order_total::text, created
           FROM fn_place_order(
                   p_channel_id      => %s,
                   p_idempotency_key => %s,
                   p_items           => %s::jsonb,
                   p_customer_id     => %s,
                   p_contact         => %s::jsonb,
                   p_buyer_note      => %s,
                   p_holders         => %s::jsonb);`,
		store.Quote(req.ChannelID),
		store.Quote(req.IdempotencyKey),
		store.Quote(string(items)),
		store.Quote(customerID),
		store.Quote(string(contactJSON)),
		store.Quote(buyerNote),
		store.Quote(string(holdersJSON)))

	rows, err := s.db.Rows(sql)
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("下单没有返回结果")
	}
	r := rows[0]
	o := Order{
		ID:       parseInt(r["order_id"]),
		No:       r["order_no"],
		Status:   r["order_status"],
		Currency: strings.TrimSpace(r["order_currency"]),
		Subtotal: r["order_subtotal"],
		Total:    r["order_total"],
		Created:  r["created"] == "t" || r["created"] == "true",
	}
	return &o, nil
}

// Show 读一张订单（含明细）。
func (s *Service) Show(orderID int64) (*Detail, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读订单需要数据库连接")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT id, order_no, status, currency, subtotal::text, total::text,
                COALESCE(customer_id::text, '') AS customer_id
           FROM sales_order WHERE id = %s;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("订单 %d 不存在", orderID)
	}
	r := rows[0]
	d := Detail{Order: Order{
		ID:       parseInt(r["id"]),
		No:       r["order_no"],
		Status:   r["status"],
		Currency: strings.TrimSpace(r["currency"]),
		Subtotal: r["subtotal"],
		Total:    r["total"],
	}}

	itemRows, err := s.db.Rows(fmt.Sprintf(
		`SELECT oi.id, oi.product_id, COALESCE(oi.product_variant_id::text, '') AS product_variant_id,
                COALESCE(oi.supplier_id::text, '') AS supplier_id,
                COALESCE(oi.supplier_product_id::text, '') AS supplier_product_id,
                oi.quantity, oi.unit_price::text, oi.total_price::text, oi.currency,
                COALESCE(oi.pricing_basis, '') AS pricing_basis, oi.status,
                COALESCE(oi.detail_snapshot->>'title', '') AS title,
                COALESCE(oi.detail_snapshot->>'visit_date', '') AS visit_date,
                COALESCE((oi.detail_snapshot->>'cost_source_product_id')::text, '') AS cost_source_product_id
           FROM sales_order_item oi
          WHERE oi.order_id = %s
          ORDER BY oi.id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, ir := range itemRows {
		d.Items = append(d.Items, OrderItem{
			ID:               parseInt(ir["id"]),
			ProductID:        parseInt(ir["product_id"]),
			VariantID:        parseInt(ir["product_variant_id"]),
			SupplierID:       parseInt(ir["supplier_id"]),
			SupplierProduct:  parseInt(ir["supplier_product_id"]),
			Quantity:         int(parseInt(ir["quantity"])),
			UnitPrice:        ir["unit_price"],
			TotalPrice:       ir["total_price"],
			Currency:         strings.TrimSpace(ir["currency"]),
			PricingBasis:     ir["pricing_basis"],
			Status:           ir["status"],
			Title:            ir["title"],
			VisitDate:        ir["visit_date"],
			CostSourceProdID: parseInt(ir["cost_source_product_id"]),
		})
	}
	return &d, nil
}

// parseInt 解析整数；解析不了就返回 0。
func parseInt(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// checkHolderItems 校核实名的行号口径。
//
// 规则只有一条：**要么全带行号，要么全不带**。
// 混着来，库里那条没带行号的实名匹配不上任何明细行，
// 报出来的是「实名收不齐」这种让人摸不着头脑的话。
//
// 在这里拦下来，是为了让人在调用方就知道自己填错了。
func checkHolderItems(holders []Holder, itemCount int) error {
	withIndex := 0
	for _, h := range holders {
		if h.ItemIndex > 0 {
			withIndex++
		}
	}
	if withIndex == 0 {
		return nil
	}
	if withIndex != len(holders) {
		return fmt.Errorf("实名里带了 item_index 的，每一条实名都必须带 item_index（要么全带，要么全不带）")
	}
	for _, h := range holders {
		if h.ItemIndex < 1 || h.ItemIndex > itemCount {
			return fmt.Errorf("实名的 item_index %d 越界：这一单只有 %d 行明细", h.ItemIndex, itemCount)
		}
	}
	return nil
}
