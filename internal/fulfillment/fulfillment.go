// Package fulfillment 是支付后履约链路（支付 → 预订 → 出券）的客户端接口。
//
// 履约的实现也只有一个：库里的那一组函数（db/migrations/005_fulfillment.sql）。
// 这个包只负责把请求拼成参数、把结果读回来 —— 不在这里判断状态该往哪走，
// 不在这里算履约状态，不在这里拼票码与持票人的对应关系。理由与 internal/order 一样：
//
//   - 状态机由机制保证（硬约束 17）。合法流转写在 state_transition 表里，
//     触发器挡住非法流转。Go 侧再写一遍 if/else，迟早会写岔；
//   - 订单的履约状态只有一套推导（fn_apply_order_fulfillment）。
//     Go 侧再算一遍，就会出现「明细已出券、订单还挂在 booking_pending」；
//   - 钱是 NUMERIC（硬约束 5）。Go 标准库没有十进制类型，
//     金额一律以字符串进出这个包。
//
// 所以 Go 侧只做四件事：拼参数、收结果、把库的报错原样带出去、把事实报上去。
package fulfillment

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"ticket-center/internal/store"
)

// Service 是履约入口。
type Service struct {
	db *store.DB
}

// New 构造履约服务。
func New(db *store.DB) *Service { return &Service{db: db} }

// ---------------------------------------------------------------- 支付

// PaymentRequest 是一笔支付入账请求。
//
// Amount 是十进制文本（如 "1171.60"）。这里刻意不给 float64：
// 金额用二进制浮点过一遍就已经丢精度了（硬约束 5）。
type PaymentRequest struct {
	OrderID int64
	// Method 是支付方式（alipay / wechat / card …）。
	Method string
	// Amount 是实付金额，必须等于订单应付金额。
	Amount string
	// Currency 是支付币种，必须等于订单币种。
	Currency string
	// Provider 与 ProviderTxnID 一起构成渠道流水的幂等键。
	Provider      string
	ProviderTxnID string
	// RawPayload 是渠道回调原文（归档用，硬约束 8）。
	RawPayload map[string]any
}

// PaymentResult 是支付入账的结果。
type PaymentResult struct {
	PaymentID int64
	OrderID   int64
	// OrderStatus 是订单当前状态（paid / awaiting_payment …）。
	OrderStatus string
	// Paid 的口径是「本次调用是否新记了一笔支付」，不是「订单现在是不是已支付」。
	// 幂等重放时 Paid=false，但 OrderStatus 仍然是 paid。
	Paid bool
}

// RecordPayment 支付入账。
//
// 幂等由库里的 fn_record_payment 保证：
//   - 同一笔渠道流水重复入账 → 返回原来的支付记录，Paid=false；
//   - 同一笔渠道流水记到另一张单上 → 报错（对账时两笔对不上，当场拦下）；
//   - 金额或币种与订单不符 → 报错（差一分钱要等到结算才爆，那时已经晚了）。
func (s *Service) RecordPayment(req PaymentRequest) (*PaymentResult, error) {
	if s.db == nil {
		return nil, fmt.Errorf("支付入账需要数据库连接")
	}
	if req.OrderID == 0 {
		return nil, fmt.Errorf("支付入账需要订单 id")
	}
	if strings.TrimSpace(req.Method) == "" {
		return nil, fmt.Errorf("支付入账需要支付方式")
	}
	if strings.TrimSpace(req.Amount) == "" {
		return nil, fmt.Errorf("支付入账需要金额")
	}
	if err := checkDecimal(req.Amount); err != nil {
		return nil, err
	}

	raw, err := jsonPayload(req.RawPayload)
	if err != nil {
		return nil, fmt.Errorf("支付原文序列化失败：%w", err)
	}

	sql := fmt.Sprintf(
		`SELECT payment_id, order_id, order_status, paid
           FROM fn_record_payment(
                   p_order_id        => %s,
                   p_payment_method  => %s,
                   p_amount          => %s::numeric,
                   p_currency        => %s,
                   p_provider        => %s,
                   p_provider_txn_id => %s,
                   p_raw_payload     => %s::jsonb);`,
		store.Quote(req.OrderID),
		store.Quote(req.Method),
		store.Quote(req.Amount),
		store.Quote(req.Currency),
		quoteOrNull(req.Provider),
		quoteOrNull(req.ProviderTxnID),
		store.Quote(raw))

	rows, err := s.db.Rows(sql)
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("支付入账没有返回结果")
	}
	r := rows[0]
	return &PaymentResult{
		PaymentID:   parseInt(r["payment_id"]),
		OrderID:     parseInt(r["order_id"]),
		OrderStatus: r["order_status"],
		Paid:        r["paid"] == "t" || r["paid"] == "true",
	}, nil
}

// ---------------------------------------------------------------- 预订

// Booking 是一条预订。
type Booking struct {
	BookingID int64
	BookingNo string
	// OrderItemID 是这条预订对应的订单明细。
	OrderItemID int64
	// Created 为 false 表示这条预订之前已经建过（幂等重放）。
	Created bool
}

// CreateBookings 给一张已支付的订单建预订。
//
// 预订的源场次由库里的 product_session_source 绑定决定，
// 不按日期猜（同一天可能有好几个场次，猜错就是发错场的票）。
// 已建过的预订不会被重复创建。
func (s *Service) CreateBookings(orderID int64) ([]Booking, error) {
	if s.db == nil {
		return nil, fmt.Errorf("建预订需要数据库连接")
	}
	if orderID == 0 {
		return nil, fmt.Errorf("建预订需要订单 id")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT booking_id, booking_no, order_item_id, created
           FROM fn_create_bookings(%s);`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]Booking, 0, len(rows))
	for _, r := range rows {
		out = append(out, Booking{
			BookingID:   parseInt(r["booking_id"]),
			BookingNo:   r["booking_no"],
			OrderItemID: parseInt(r["order_item_id"]),
			Created:     r["created"] == "t" || r["created"] == "true",
		})
	}
	return out, nil
}

// RequestResult 是发起预订请求的结果。
type RequestResult struct {
	BookingID int64
	BookingNo string
	// AttemptNo 是本次是第几次尝试（重试也走这里，attempt_count 递增）。
	AttemptNo int
	Status    string
}

// RequestBooking 发起一次预订请求（pending → requested）。
//
// 这一步只表示「准备发出去了」，不代表源侧已经受理。
// 源侧回应之后要调 RecordAttempt 归档，再调 CompleteBooking 落结果。
func (s *Service) RequestBooking(bookingID int64, request map[string]any) (*RequestResult, error) {
	if s.db == nil {
		return nil, fmt.Errorf("发起预订需要数据库连接")
	}
	if bookingID == 0 {
		return nil, fmt.Errorf("发起预订需要预订 id")
	}
	payload, err := jsonPayload(request)
	if err != nil {
		return nil, fmt.Errorf("请求报文序列化失败：%w", err)
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT booking_id, booking_no, attempt_no, status
           FROM fn_request_booking(%s, %s::jsonb);`,
		store.Quote(bookingID), store.Quote(payload)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("发起预订没有返回结果")
	}
	r := rows[0]
	return &RequestResult{
		BookingID: parseInt(r["booking_id"]),
		BookingNo: r["booking_no"],
		AttemptNo: int(parseInt(r["attempt_no"])),
		Status:    r["status"],
	}, nil
}

// AttemptRequest 是一次预订尝试的归档内容。
type AttemptRequest struct {
	BookingID int64
	// Request / Response 是发给源侧的请求体与源侧响应体（原文归档）。
	Request  map[string]any
	Response map[string]any
	// HTTPStatus 与 LatencyMS 是这次调用的观测值。
	HTTPStatus int
	LatencyMS  int
	// ErrorType 是错误四分类（retriable / fatal / auth / rate_limit / timeout）。
	ErrorType    string
	ErrorMessage string
}

// Attempt 是一次归档好的尝试。
type Attempt struct {
	AttemptID int64
	AttemptNo int
}

// RecordAttempt 归档一次预订尝试。
//
// 硬约束 8：原始报文必须归档。同一次尝试重复归档走 upsert ——
// 崩溃重跑会再调一次，撞唯一索引报错等于把重试堵死。
func (s *Service) RecordAttempt(req AttemptRequest) (*Attempt, error) {
	if s.db == nil {
		return nil, fmt.Errorf("归档预订尝试需要数据库连接")
	}
	if req.BookingID == 0 {
		return nil, fmt.Errorf("归档预订尝试需要预订 id")
	}
	requestJSON, err := jsonPayload(req.Request)
	if err != nil {
		return nil, fmt.Errorf("请求报文序列化失败：%w", err)
	}
	responseJSON, err := jsonPayload(req.Response)
	if err != nil {
		return nil, fmt.Errorf("响应报文序列化失败：%w", err)
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT attempt_id, attempt_no
           FROM fn_record_booking_attempt(
                   p_booking_id    => %s,
                   p_request       => %s::jsonb,
                   p_response      => %s::jsonb,
                   p_http_status   => %s,
                   p_latency_ms    => %s,
                   p_error_type    => %s,
                   p_error_message => %s);`,
		store.Quote(req.BookingID),
		store.Quote(requestJSON),
		store.Quote(responseJSON),
		quoteIntOrNull(req.HTTPStatus),
		quoteIntOrNull(req.LatencyMS),
		quoteOrNull(req.ErrorType),
		quoteOrNull(req.ErrorMessage)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("归档预订尝试没有返回结果")
	}
	r := rows[0]
	return &Attempt{
		AttemptID: parseInt(r["attempt_id"]),
		AttemptNo: int(parseInt(r["attempt_no"])),
	}, nil
}

// ---------------------------------------------------------------- 出券

// Voucher 是一张券。
type Voucher struct {
	VoucherID int64
	VoucherNo string
	// Code 是票码。源侧给了就用源侧的；没给就自己生成一个随机码 ——
	// 券号是连号的，当票码用等于把闸机的钥匙公开。
	Code string
	// HolderSequence 是这张券对应第几名持票人（按团报价时是 1，权益含全部份数）。
	HolderSequence int
	// Created 为 false 表示这张券之前已经发过（幂等重放）。
	Created bool
}

// IssueVoucher 出券。
//
// Codes 是**本次要发的那些券的票码**，按持票人序号升序。
// 码数必须等于还要发的张数 —— 少一个就报错，不拿一张券顶两个人的票。
// 已经发够了的券不会被重发（返回原有的那些，Created=false）。
func (s *Service) IssueVoucher(bookingID int64, codes []string, raw map[string]any) ([]Voucher, error) {
	if s.db == nil {
		return nil, fmt.Errorf("出券需要数据库连接")
	}
	if bookingID == 0 {
		return nil, fmt.Errorf("出券需要预订 id")
	}
	payload, err := jsonPayload(raw)
	if err != nil {
		return nil, fmt.Errorf("出券原文序列化失败：%w", err)
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT voucher_id, voucher_no, code, holder_sequence, created
           FROM fn_issue_voucher(%s, %s::text[], %s::jsonb);`,
		store.Quote(bookingID), codesLiteral(codes), store.Quote(payload)))
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]Voucher, 0, len(rows))
	for _, r := range rows {
		out = append(out, Voucher{
			VoucherID:      parseInt(r["voucher_id"]),
			VoucherNo:      r["voucher_no"],
			Code:           r["code"],
			HolderSequence: int(parseInt(r["holder_sequence"])),
			Created:        r["created"] == "t" || r["created"] == "true",
		})
	}
	return out, nil
}

// CompleteRequest 是源侧结果落库的请求。
type CompleteRequest struct {
	BookingID int64
	// Status 只能是 confirmed / failed / cancelled。
	Status string
	// ExternalBookingID 是源侧预订号。
	ExternalBookingID string
	// Response 是源侧响应原文。
	Response map[string]any
	// ErrorCode / ErrorMessage 只在失败时有值。
	ErrorCode    string
	ErrorMessage string
	// Codes 是要发的票码（confirmed 时用）。
	Codes []string
	// IssueVoucher 为 false 时只落确认，不出券 ——
	//	用于「源先确认、票后到」的场景：先推进到 confirmed，等票到了再 IssueVoucher。
	IssueVoucher bool
}

// Completion 是源侧结果落库后的状态。
type Completion struct {
	BookingID int64
	BookingNo string
	Status    string
	VoucherID int64
	VoucherNo string
	// VoucherCount 是这次发了多少张券。
	VoucherCount int
	// OrderStatus 是推导之后的订单状态（不是调用方写的）。
	OrderStatus string
}

// CompleteBooking 落源侧结果（requested → confirmed / failed / cancelled）。
//
// confirmed 且 IssueVoucher 为 true 时连带出券。
// 订单的履约状态由库里的唯一实现推导后返回。
func (s *Service) CompleteBooking(req CompleteRequest) (*Completion, error) {
	if s.db == nil {
		return nil, fmt.Errorf("落预订结果需要数据库连接")
	}
	if req.BookingID == 0 {
		return nil, fmt.Errorf("落预订结果需要预订 id")
	}
	switch req.Status {
	case "confirmed", "failed", "cancelled":
	default:
		return nil, fmt.Errorf("预订结果只能是 confirmed / failed / cancelled，收到 %q", req.Status)
	}
	payload, err := jsonPayload(req.Response)
	if err != nil {
		return nil, fmt.Errorf("响应报文序列化失败：%w", err)
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT booking_id, booking_no, status, voucher_id, voucher_no, voucher_count, order_status
           FROM fn_complete_booking(
                   p_booking_id          => %s,
                   p_status              => %s,
                   p_external_booking_id => %s,
                   p_response            => %s::jsonb,
                   p_error_code          => %s,
                   p_error_message       => %s,
                   p_codes               => %s::text[],
                   p_issue_voucher       => %s);`,
		store.Quote(req.BookingID),
		store.Quote(req.Status),
		quoteOrNull(req.ExternalBookingID),
		store.Quote(payload),
		quoteOrNull(req.ErrorCode),
		quoteOrNull(req.ErrorMessage),
		codesLiteral(req.Codes),
		store.Quote(req.IssueVoucher)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("落预订结果没有返回结果")
	}
	r := rows[0]
	return &Completion{
		BookingID:    parseInt(r["booking_id"]),
		BookingNo:    r["booking_no"],
		Status:       r["status"],
		VoucherID:    parseInt(r["voucher_id"]),
		VoucherNo:    r["voucher_no"],
		VoucherCount: int(parseInt(r["voucher_count"])),
		OrderStatus:  r["order_status"],
	}, nil
}

// RetryResult 是失败重报的结果。
type RetryResult struct {
	BookingID int64
	BookingNo string
	Status    string
}

// RetryBooking 失败重报（failed → pending）。
//
// 源侧失败不等于这笔单完了：可能是库存被占位、可能是超时。
// 重报只是把预订放回 pending，等下一次重试窗口再发一次。
func (s *Service) RetryBooking(bookingID int64, nextRetryAt *time.Time) (*RetryResult, error) {
	if s.db == nil {
		return nil, fmt.Errorf("失败重报需要数据库连接")
	}
	if bookingID == 0 {
		return nil, fmt.Errorf("失败重报需要预订 id")
	}
	var retryAt any
	if nextRetryAt != nil {
		retryAt = nextRetryAt.UTC().Format(time.RFC3339)
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT booking_id, booking_no, status
           FROM fn_retry_booking(%s, %s::timestamptz);`,
		store.Quote(bookingID), store.Quote(retryAt)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("失败重报没有返回结果")
	}
	r := rows[0]
	return &RetryResult{
		BookingID: parseInt(r["booking_id"]),
		BookingNo: r["booking_no"],
		Status:    r["status"],
	}, nil
}

// ---------------------------------------------------------------- 履约状态

// Fulfillment 是订单履约状态的推导结果。
type Fulfillment struct {
	OrderID int64
	// OrderStatus 是推导后的订单状态。
	OrderStatus string
	// FulfillmentStatus 是履约口径：unfulfilled / partial / fulfilled / failed。
	FulfillmentStatus string
	// DeliveredQty 是已出券的份数，RequestedQty 是应出券的份数。
	DeliveredQty int
	RequestedQty int
}

// ApplyFulfillment 推导订单的履约状态。
//
// 订单的履约状态不归调用方写：调用方只报事实（付了、订了、出票了），
// 推导由库里的唯一实现 fn_apply_order_fulfillment 完成。
// 幂等：同样的事实推出来的状态一样。
func (s *Service) ApplyFulfillment(orderID int64) (*Fulfillment, error) {
	if s.db == nil {
		return nil, fmt.Errorf("推导履约状态需要数据库连接")
	}
	if orderID == 0 {
		return nil, fmt.Errorf("推导履约状态需要订单 id")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT order_id, order_status, fulfillment_status, delivered_qty, requested_qty
           FROM fn_apply_order_fulfillment(%s);`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("推导履约状态没有返回结果")
	}
	r := rows[0]
	return &Fulfillment{
		OrderID:           parseInt(r["order_id"]),
		OrderStatus:       r["order_status"],
		FulfillmentStatus: r["fulfillment_status"],
		DeliveredQty:      int(parseInt(r["delivered_qty"])),
		RequestedQty:      int(parseInt(r["requested_qty"])),
	}, nil
}

// ---------------------------------------------------------------- 读侧

// OrderState 是一张订单的履约全景。
type OrderState struct {
	OrderID           int64
	OrderNo           string
	Status            string
	PaymentStatus     string
	FulfillmentStatus string
	Currency          string
	Total             string
	Items             []ItemState
	Bookings          []BookingState
	Vouchers          []VoucherState
}

// ItemState 是一行明细的履约状态。
type ItemState struct {
	ItemID   int64
	Title    string
	Quantity int
	Status   string
	// DeliveredQty 是这一行已出券的份数。
	DeliveredQty int
}

// BookingState 是一条预订的状态。
type BookingState struct {
	BookingID int64
	BookingNo string
	ItemID    int64
	Status    string
	// AttemptCount 是已经发起过几次尝试。
	AttemptCount int
	// ExternalBookingID 是源侧预订号。
	ExternalBookingID string
	ErrorCode         string
	ErrorMessage      string
}

// VoucherState 是一张券的状态。
type VoucherState struct {
	VoucherID int64
	VoucherNo string
	Code      string
	Status    string
	// HolderSnapshot 是出票时固化的持票人快照（凭证上显示什么）。
	HolderSnapshot string
}

// Show 读一张订单的履约全景（订单 + 明细 + 预订 + 券）。
//
// 这是只读的：不推导、不推进，只是把库里的现状读出来。
func (s *Service) Show(orderID int64) (*OrderState, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读订单履约状态需要数据库连接")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT o.id, o.order_no, o.status, o.payment_status, o.fulfillment_status,
                o.currency, o.total::text
           FROM sales_order o
          WHERE o.id = %s;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("订单 %d 不存在", orderID)
	}
	r := rows[0]
	st := &OrderState{
		OrderID:           parseInt(r["id"]),
		OrderNo:           r["order_no"],
		Status:            r["status"],
		PaymentStatus:     r["payment_status"],
		FulfillmentStatus: r["fulfillment_status"],
		Currency:          strings.TrimSpace(r["currency"]),
		Total:             r["total"],
	}

	itemRows, err := s.db.Rows(fmt.Sprintf(
		`SELECT oi.id, COALESCE(oi.detail_snapshot->>'title', '') AS title,
                oi.quantity, oi.status,
                COALESCE((
                    SELECT sum(ve.quantity)
                      FROM voucher_entitlement ve
                      JOIN voucher v ON v.id = ve.voucher_id
                     WHERE v.order_item_id = oi.id
                       AND v.status IN ('issued','used')
                       AND ve.entitlement_type = 'admission'), 0) AS delivered_qty
           FROM sales_order_item oi
          WHERE oi.order_id = %s
          ORDER BY oi.id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, ir := range itemRows {
		st.Items = append(st.Items, ItemState{
			ItemID:       parseInt(ir["id"]),
			Title:        ir["title"],
			Quantity:     int(parseInt(ir["quantity"])),
			Status:       ir["status"],
			DeliveredQty: int(parseInt(ir["delivered_qty"])),
		})
	}

	bookingRows, err := s.db.Rows(fmt.Sprintf(
		`SELECT id, booking_no, COALESCE(order_item_id::text, '') AS order_item_id,
                status, attempt_count, COALESCE(external_booking_id, '') AS external_booking_id,
                COALESCE(error_code, '') AS error_code, COALESCE(error_message, '') AS error_message
           FROM booking
          WHERE order_id = %s
          ORDER BY id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, br := range bookingRows {
		st.Bookings = append(st.Bookings, BookingState{
			BookingID:         parseInt(br["id"]),
			BookingNo:         br["booking_no"],
			ItemID:            parseInt(br["order_item_id"]),
			Status:            br["status"],
			AttemptCount:      int(parseInt(br["attempt_count"])),
			ExternalBookingID: br["external_booking_id"],
			ErrorCode:         br["error_code"],
			ErrorMessage:      br["error_message"],
		})
	}

	voucherRows, err := s.db.Rows(fmt.Sprintf(
		`SELECT id, voucher_no, COALESCE(code, '') AS code, status,
                holder_snapshot::text
           FROM voucher
          WHERE order_id = %s
          ORDER BY id;`, store.Quote(orderID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, vr := range voucherRows {
		st.Vouchers = append(st.Vouchers, VoucherState{
			VoucherID:      parseInt(vr["id"]),
			VoucherNo:      vr["voucher_no"],
			Code:           vr["code"],
			Status:         vr["status"],
			HolderSnapshot: vr["holder_snapshot"],
		})
	}
	return st, nil
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

// quoteIntOrNull 0 → NULL，否则给出 SQL 字面量。
//
// HTTP 状态 0 不是合法值，别把它当 0 存进去。
func quoteIntOrNull(n int) string {
	if n == 0 {
		return "NULL"
	}
	return store.Quote(n)
}

// codesLiteral 把票码列表拼成 SQL 数组字面量。
//
// 空列表给 NULL（不是空数组）：空数组在库里会被当成「发了 0 个票码」，
// 而 NULL 的口径是「源侧没给票码，用我们自己的券号」—— 这两件事不一样。
func codesLiteral(codes []string) string {
	if len(codes) == 0 {
		return "NULL"
	}
	parts := make([]string, 0, len(codes))
	for _, c := range codes {
		parts = append(parts, store.Quote(c))
	}
	return "ARRAY[" + strings.Join(parts, ",") + "]"
}

// checkDecimal 校验金额是十进制文本。
//
// 用正则而不是 ParseFloat：float64 会把 1171.60 变成 1171.5999999999999，
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
