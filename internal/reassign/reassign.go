// Package reassign 是改派的客户端接口。
//
// 改派的实现只有一个：库里的 fn_reassign_order_item()
// （db/migrations/024_reassign_order_item.sql）。
// 这个包只负责把参数拼进去、把结果读回来 ——
// 不在这里重排一次源，不在这里重算一次钱（硬约束 15、18）。
//
// 改派是什么：
// 一条明细在下单之后、支付之前跟当前的世界对不上了 ——
// 源侧把那个 SKU 下架了、报价变了、或者出现了更便宜的源。
// 这时明细还钉在原来的源和原来的价上：按旧价卖出去的东西，
// 要么出不了票，要么按一个已经过期的价卖。
//
// 口径写在迁移文件的头里，四条最要紧的：
//
//  1. 改派 = 重新选源 + 重新定价，源与价都取自 fn_price_variant。
//  2. 只发生在未收款的时候。已收款的订单换源，已成交的金额就失去依据了，
//     差价退不退是业务决策（行级退款还没落地），不是这里能编的规则。
//  3. 只对单张形态。配方与套装的源是**声明**的，不是选出来的。
//  4. 只对还没预订过的明细。已经发到源侧的预订是事实，不能靠换源把它抹掉。
//
// 库里报错原样带出去：改派不成的原因只有库里有答案
// （已收款 / 已预订 / 已出票 / 是组合形态 / 当天没有报价），这里不另编一套判断。
package reassign

import (
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Result 是一次改派的结果。
//
// 金额一律是字符串：库里是 NUMERIC，用 float64 接住就是丢精度（硬约束 5）。
type Result struct {
	OrderItemID int64 `json:"order_item_id"`
	// Outcome：
	//   "reassigned" —— 换源或重新定价成功
	//   "no_change"  —— 当前源与当前价已经是对的那个（幂等：重复调用不改第二次）
	Outcome string `json:"outcome"`
	// PreviousSupplierProductID / NewSupplierProductID 是采纳源（supplier_product）。
	PreviousSupplierProductID int64  `json:"previous_supplier_product_id"`
	PreviousSupplierID        int64  `json:"previous_supplier_id"`
	NewSupplierProductID      int64  `json:"new_supplier_product_id"`
	NewSupplierID             int64  `json:"new_supplier_id"`
	PreviousUnitPrice         string `json:"previous_unit_price"`
	NewUnitPrice              string `json:"new_unit_price"`
	PreviousUnitCost          string `json:"previous_unit_cost"`
	NewUnitCost               string `json:"new_unit_cost"`
	PreviousTotalPrice        string `json:"previous_total_price"`
	NewTotalPrice             string `json:"new_total_price"`
	Currency                  string `json:"currency"`
	Reason                    string `json:"reason"`
}

// Candidate 是一条待改派的明细。
type Candidate struct {
	OrderID     int64  `json:"order_id"`
	OrderNo     string `json:"order_no"`
	OrderItemID int64  `json:"order_item_id"`
	ProductID   int64  `json:"product_id"`
	VariantID   int64  `json:"product_variant_id"`
	VisitDate   string `json:"visit_date"`
	Quantity    int    `json:"quantity"`
	// CurrentSupplierProductID 是明细现在钉着的源。
	CurrentSupplierProductID int64  `json:"current_supplier_product_id"`
	CurrentSupplier          string `json:"current_supplier"`
	CurrentUnitPrice         string `json:"current_unit_price"`
	CurrentUnitCost          string `json:"current_unit_cost"`
	// NewSupplierProductID 是当前世界（fn_price_variant）选出来的源。
	// 源变了 = 它跟 CurrentSupplierProductID 不一样。
	NewSupplierProductID int64  `json:"new_supplier_product_id"`
	NewSupplier          string `json:"new_supplier"`
	NewUnitPrice         string `json:"new_unit_price"`
	NewUnitCost          string `json:"new_unit_cost"`
	// StaleReason 说清差在哪：源变了 / 价变了 / 成本变了 / 当天没有可用报价。
	StaleReason string `json:"stale_reason"`
}

// Service 是改派入口。
type Service struct {
	db *store.DB
}

// New 构造改派服务。
func New(db *store.DB) *Service { return &Service{db: db} }

// Reassign 改派一条明细。
//
// 幂等由库里的 fn_reassign_order_item 保证：当前源、当前价、当前成本都没变时
// 返回 outcome='no_change'，什么都不改（重复调用不会改第二次）。
// 这里不做本地缓存 —— 缓存会骗人，库里那条函数才是真相。
func (s *Service) Reassign(orderID, itemID int64, reason string) (*Result, error) {
	if s.db == nil {
		return nil, fmt.Errorf("改派需要数据库连接")
	}
	if orderID == 0 {
		return nil, fmt.Errorf("改派需要订单号（order_id）")
	}
	if itemID == 0 {
		return nil, fmt.Errorf("改派需要明细行号（order_item_id）")
	}

	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT order_item_id,
                outcome,
                previous_supplier_product_id,
                previous_supplier_id,
                new_supplier_product_id,
                new_supplier_id,
                previous_unit_price::text AS previous_unit_price,
                new_unit_price::text      AS new_unit_price,
                previous_unit_cost::text  AS previous_unit_cost,
                new_unit_cost::text       AS new_unit_cost,
                previous_total_price::text AS previous_total_price,
                new_total_price::text      AS new_total_price,
                currency,
                reason
           FROM fn_reassign_order_item(%s, %s, %s);`,
		store.Quote(orderID), store.Quote(itemID), store.Quote(reason)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("改派没有返回结果")
	}
	r := rows[0]
	res := &Result{
		OrderItemID:               parseInt(r["order_item_id"]),
		Outcome:                   r["outcome"],
		PreviousSupplierProductID: parseInt(r["previous_supplier_product_id"]),
		PreviousSupplierID:        parseInt(r["previous_supplier_id"]),
		NewSupplierProductID:      parseInt(r["new_supplier_product_id"]),
		NewSupplierID:             parseInt(r["new_supplier_id"]),
		PreviousUnitPrice:         r["previous_unit_price"],
		NewUnitPrice:              r["new_unit_price"],
		PreviousUnitCost:          r["previous_unit_cost"],
		NewUnitCost:               r["new_unit_cost"],
		PreviousTotalPrice:        r["previous_total_price"],
		NewTotalPrice:             r["new_total_price"],
		Currency:                  strings.TrimSpace(r["currency"]),
		Reason:                    r["reason"],
	}
	return res, nil
}

// Candidates 列出待改派的明细。
//
// 口径在库里的 v_reassign_candidates（与 fn_reassign_order_item 同一批排除条件：
// 未收款、没预订、没出票、单张形态），这里不重算一遍。
func (s *Service) Candidates() ([]Candidate, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读待改派明细需要数据库连接")
	}
	rows, err := s.db.Rows(
		`SELECT order_id,
                order_no,
                order_item_id,
                product_id,
                product_variant_id,
                COALESCE(to_char(visit_date, 'YYYY-MM-DD'), '') AS visit_date,
                quantity,
                COALESCE(current_supplier_product_id::text, '') AS current_supplier_product_id,
                COALESCE(current_supplier, '')                AS current_supplier,
                COALESCE(current_unit_price::text, '')        AS current_unit_price,
                COALESCE(current_unit_cost::text, '')         AS current_unit_cost,
                COALESCE(new_supplier_product_id::text, '')    AS new_supplier_product_id,
                COALESCE(new_supplier, '')                    AS new_supplier,
                COALESCE(new_unit_price::text, '')            AS new_unit_price,
                COALESCE(new_unit_cost::text, '')             AS new_unit_cost,
                COALESCE(stale_reason, '')                    AS stale_reason
           FROM v_reassign_candidates
          ORDER BY order_id, order_item_id;`)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]Candidate, 0, len(rows))
	for _, r := range rows {
		out = append(out, Candidate{
			OrderID:                  parseInt(r["order_id"]),
			OrderNo:                  r["order_no"],
			OrderItemID:              parseInt(r["order_item_id"]),
			ProductID:                parseInt(r["product_id"]),
			VariantID:                parseInt(r["product_variant_id"]),
			VisitDate:                r["visit_date"],
			Quantity:                 int(parseInt(r["quantity"])),
			CurrentSupplierProductID: parseInt(r["current_supplier_product_id"]),
			CurrentSupplier:          r["current_supplier"],
			CurrentUnitPrice:         r["current_unit_price"],
			CurrentUnitCost:          r["current_unit_cost"],
			NewSupplierProductID:     parseInt(r["new_supplier_product_id"]),
			NewSupplier:              r["new_supplier"],
			NewUnitPrice:             r["new_unit_price"],
			NewUnitCost:              r["new_unit_cost"],
			StaleReason:              r["stale_reason"],
		})
	}
	return out, nil
}

// parseInt 解析整数；解析不了就返回 0。
func parseInt(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return n
}
