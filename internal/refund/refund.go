// Package refund 是退款链路的客户端接口。
//
// 退款的实现也只有一个：库里的那一组函数（db/migrations/007_refund.sql）。
// 这个包只负责把请求拼成参数、把结果读回来 —— 不在这里判断能不能退、
// 不在这里算该退多少、不在这里改订单状态。理由与 internal/order /
// internal/fulfillment 一样：
//
//   - 退款的资格与金额口径在库里（硬约束 19 的同类要求）。
//     Go 侧再判一遍「能不能退」，就会出现两份规则；
//   - 「有没有真的收到钱」由 sales_payment 里成功的支付记录决定，
//     不是由订单状态决定 —— 订单状态是人写进去的，支付记录是事实；
//   - 钱是 NUMERIC（硬约束 5）。Go 标准库没有十进制类型，
//     金额一律以字符串进出这个包。
//
// 所以 Go 侧只做四件事：拼参数、收结果、把库的报错原样带出去、把事实报上去。
package refund

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Service 是退款入口。
type Service struct {
	db *store.DB
}

// New 构造退款服务。
func New(db *store.DB) *Service { return &Service{db: db} }

// ---------------------------------------------------------------- 发起

// Request 是发起退款的请求。
//
// Amount 是十进制文本（如 "368.00"），必须等于订单实付金额。
// 这里刻意不给 float64：金额用二进制浮点过一遍就已经丢精度了（硬约束 5）。
type Request struct {
	OrderID int64
	// Amount 是退款金额，必须等于订单实付金额（整单退款）。
	Amount string
	// Reason 是退款原因（留痕用）。
	Reason string
	// RequestedBy 是发起人。
	RequestedBy string
	// IdempotencyKey 必填：重放一次退款就是多退一次钱。
	IdempotencyKey string
}

// Refund 是一笔退款单。
type Refund struct {
	RefundID int64
	RefundNo string
	OrderNo  string
	// OrderStatus 是订单当前状态（发起后一般是 refunding）。
	OrderStatus string
	// Requested 为 false 表示这笔退款之前已经发起过（幂等重放）。
	Requested bool
}

// RequestRefund 发起一笔整单退款。
//
// 幂等由库里的 fn_request_refund 保证：
//   - 同一幂等键重复发起 → 返回原来的退款单，Requested=false；
//   - 同一幂等键配不同内容 → 报错（重放一次就是多退一次钱）；
//   - 金额不等于订单实付 → 报错；
//   - 没有成功的支付记录 → 报错（没收到钱退什么）；
//   - 券已核销 → 报错（票已经用了，退钱要人工处理）。
func (s *Service) RequestRefund(req Request) (*Refund, error) {
	if s.db == nil {
		return nil, fmt.Errorf("发起退款需要数据库连接")
	}
	if req.OrderID == 0 {
		return nil, fmt.Errorf("发起退款需要订单 id")
	}
	if strings.TrimSpace(req.Amount) == "" {
		return nil, fmt.Errorf("发起退款需要金额")
	}
	if err := checkDecimal(req.Amount); err != nil {
		return nil, err
	}
	if strings.TrimSpace(req.IdempotencyKey) == "" {
		return nil, fmt.Errorf("发起退款需要幂等键（重放一次就多退一次钱）")
	}

	sql := fmt.Sprintf(
		`SELECT refund_id, refund_no, order_no, order_status, requested
           FROM fn_request_refund(
                   p_order_id        => %s,
                   p_amount          => %s::numeric,
                   p_reason          => %s,
                   p_requested_by    => %s,
                   p_idempotency_key => %s);`,
		store.Quote(req.OrderID),
		store.Quote(req.Amount),
		quoteOrNull(req.Reason),
		quoteOrNull(req.RequestedBy),
		store.Quote(req.IdempotencyKey))

	rows, err := s.db.Rows(sql)
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("发起退款没有返回结果")
	}
	r := rows[0]
	return &Refund{
		RefundID:    parseInt(r["refund_id"]),
		RefundNo:    r["refund_no"],
		OrderNo:     r["order_no"],
		OrderStatus: r["order_status"],
		Requested:   r["requested"] == "t" || r["requested"] == "true",
	}, nil
}

// ---------------------------------------------------------------- 放行

// Approval 是放行退款的结果。
type Approval struct {
	RefundID int64
	RefundNo string
	// RefundStatus 是退款单状态（requested / approved）。
	RefundStatus string
	// OrderStatus 是订单状态（放行不动订单 —— 钱还没回来）。
	OrderStatus string
}

// ApproveRefund 放行一笔退款（requested → approved）。
//
// 有些退款要先过一道人工（金额大、客服代客操作）。放行只是把退款单
// 挪到 approved，订单状态不动 —— 钱还没回来。
func (s *Service) ApproveRefund(refundID int64, approvedBy string) (*Approval, error) {
	if s.db == nil {
		return nil, fmt.Errorf("放行退款需要数据库连接")
	}
	if refundID == 0 {
		return nil, fmt.Errorf("放行退款需要退款单 id")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT refund_id, refund_no, refund_status, order_status
           FROM fn_approve_refund(%s, %s);`,
		store.Quote(refundID), quoteOrNull(approvedBy)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("放行退款没有返回结果")
	}
	r := rows[0]
	return &Approval{
		RefundID:     parseInt(r["refund_id"]),
		RefundNo:     r["refund_no"],
		RefundStatus: r["refund_status"],
		OrderStatus:  r["order_status"],
	}, nil
}

// ---------------------------------------------------------------- 完成

// CompleteRequest 是退款结果的落库请求。
type CompleteRequest struct {
	RefundID int64
	// Success 为 true 表示钱退回来了，为 false 表示退款失败。
	Success bool
	// SupplierRefundID 是源侧/渠道侧的退款流水号。
	SupplierRefundID string
	// ErrorCode / ErrorMessage 只在失败时有值。
	ErrorCode    string
	ErrorMessage string
	// RawPayload 是渠道回调原文（归档用，硬约束 8）。
	RawPayload map[string]any
}

// Completion 是退款完成后的状态。
type Completion struct {
	RefundID int64
	RefundNo string
	// RefundStatus 是退款单状态（succeeded / failed）。
	RefundStatus string
	OrderNo      string
	// OrderStatus 是订单状态（成功后是 refunded，失败后退回退款前的状态）。
	OrderStatus string
	// OrderPaymentStatus 是订单支付状态（成功后是 refunded）。
	OrderPaymentStatus string
	// OrderFulfillmentStatus 是订单履约状态（成功后是 cancelled）。
	OrderFulfillmentStatus string
}

// CompleteRefund 落退款结果。
//
// 成功时库里的唯一实现一次改完明细 / 凭证 / 预订 / 支付 / 订单，
// 并由不变量 61-64 证明事实与状态没有分叉。
// 失败时订单照着退款前的状态退回去；退不回去就留在 refunding 等人处理。
//
// 幂等：同一笔退款重复落「成功」返回原状态，不重复退一次钱。
// 失败的退款单是终态 —— 要重试得发起一笔新的退款请求（新的幂等键）。
func (s *Service) CompleteRefund(req CompleteRequest) (*Completion, error) {
	if s.db == nil {
		return nil, fmt.Errorf("落退款结果需要数据库连接")
	}
	if req.RefundID == 0 {
		return nil, fmt.Errorf("落退款结果需要退款单 id")
	}
	raw, err := jsonPayload(req.RawPayload)
	if err != nil {
		return nil, fmt.Errorf("退款原文序列化失败：%w", err)
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT refund_id, refund_no, refund_status, order_no, order_status,
                order_payment_status, order_fulfillment_status
           FROM fn_complete_refund(
                   p_refund_id          => %s,
                   p_success            => %s,
                   p_supplier_refund_id => %s,
                   p_error_code         => %s,
                   p_error_message      => %s,
                   p_raw_payload        => %s::jsonb);`,
		store.Quote(req.RefundID),
		store.Quote(req.Success),
		quoteOrNull(req.SupplierRefundID),
		quoteOrNull(req.ErrorCode),
		quoteOrNull(req.ErrorMessage),
		store.Quote(raw)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("落退款结果没有返回结果")
	}
	r := rows[0]
	return &Completion{
		RefundID:               parseInt(r["refund_id"]),
		RefundNo:               r["refund_no"],
		RefundStatus:           r["refund_status"],
		OrderNo:                r["order_no"],
		OrderStatus:            r["order_status"],
		OrderPaymentStatus:     r["order_payment_status"],
		OrderFulfillmentStatus: r["order_fulfillment_status"],
	}, nil
}

// ---------------------------------------------------------------- 读侧

// RefundState 是一笔退款单的现状。
type RefundState struct {
	RefundID int64
	RefundNo string
	OrderID  int64
	OrderNo  string
	Amount   string
	Currency string
	Status   string
	// PreviousOrderStatus 是发起退款前订单的状态（退款失败时照它退回去）。
	PreviousOrderStatus string
	ErrorCode           string
	ErrorMessage        string
	SupplierRefundID    string
	Created             string
}

// Show 读一笔退款单。
//
// 这是只读的：不推进、不判断，只是把库里的现状读出来。
func (s *Service) Show(refundID int64) (*RefundState, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读退款单需要数据库连接")
	}
	if refundID == 0 {
		return nil, fmt.Errorf("读退款单需要退款单 id")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT r.id, r.refund_no, r.order_id, o.order_no,
                r.amount::text, r.currency, r.status,
                COALESCE(r.previous_order_status, '') AS previous_order_status,
                COALESCE(r.error_code, '') AS error_code,
                COALESCE(r.error_message, '') AS error_message,
                COALESCE(r.supplier_refund_id, '') AS supplier_refund_id,
                r.created_at::text
           FROM sales_refund r
           JOIN sales_order o ON o.id = r.order_id
          WHERE r.id = %s;`, store.Quote(refundID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("退款单 %d 不存在", refundID)
	}
	r := rows[0]
	return &RefundState{
		RefundID:            parseInt(r["id"]),
		RefundNo:            r["refund_no"],
		OrderID:             parseInt(r["order_id"]),
		OrderNo:             r["order_no"],
		Amount:              r["amount"],
		Currency:            strings.TrimSpace(r["currency"]),
		Status:              r["status"],
		PreviousOrderStatus: r["previous_order_status"],
		ErrorCode:           r["error_code"],
		ErrorMessage:        r["error_message"],
		SupplierRefundID:    r["supplier_refund_id"],
		Created:             r["created"],
	}, nil
}

// ---------------------------------------------------------------- 工具

// parseInt 解析整数；解析不了就返回 0。
func parseInt(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// jsonPayload 把 map 序列化成 JSON 文本；nil 给空对象。
func jsonPayload(m map[string]any) (string, error) {
	if m == nil {
		return "{}", nil
	}
	blob, err := json.Marshal(m)
	if err != nil {
		return "", err
	}
	return string(blob), nil
}

// quoteOrNull 空串 → NULL，否则给出 SQL 字面量。
//
// SQL 里空串和 NULL 不是一回事，别混。返回的是**已经转义好的字面量**，
// 不是原始值 —— 少一次 store.Quote 就是一次注入。
func quoteOrNull(s string) string {
	if strings.TrimSpace(s) == "" {
		return "NULL"
	}
	return store.Quote(s)
}

// checkDecimal 校验金额是十进制文本。
//
// 用正则而不是 ParseFloat：float64 会把 368.00 变成 367.99999999999994，
// 校验本身就是错的。这里只要「长得像数字」，精度交给 NUMERIC。
func checkDecimal(s string) error {
	t := strings.TrimSpace(s)
	if t == "" {
		return fmt.Errorf("金额不能为空")
	}
	i := 0
	if t[0] == '-' || t[0] == '+' {
		i++
	}
	digits := 0
	for ; i < len(t); i++ {
		c := t[i]
		if c >= '0' && c <= '9' {
			digits++
			continue
		}
		if c == '.' && digits > 0 {
			continue
		}
		return fmt.Errorf("金额 %q 不是十进制数", s)
	}
	if digits == 0 {
		return fmt.Errorf("金额 %q 不是十进制数", s)
	}
	return nil
}
