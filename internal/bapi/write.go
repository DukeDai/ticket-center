package bapi

import (
	"fmt"
	"net/http"
	"strings"

	"ticket-center/internal/fulfillment"
	"ticket-center/internal/order"
	"ticket-center/internal/refund"
	"ticket-center/internal/reassign"
	"ticket-center/internal/store"
)

// 这个文件是运营台的**写侧**。
//
// 三条口径写死：
//
//  1. 写路径一律走库里的唯一实现。Go 侧只拼参数、只读结果：
//     不重算金额、不重排源、不自己算状态、不自己判退款资格、不自己判能不能进场。
//
//  2. 每个写端点都要先确认**这个资源属于哪个渠道**。
//     internal/order、internal/fulfillment、internal/refund、internal/reassign
//     都是库函数的薄封装，故意只按 id 定位、不带权限判断 ——
//     权限是调用方的事，这里就是那个调用方。
//     少了这一步，运营台一个 id 就能改到别的渠道的单。
//
//  3. 要留操作人痕迹的动作（放行退款、改派）只给 admin，
//     并且把 operator.code 传进库函数 —— 痕迹是追责的依据。

// writeHandlers 收齐写侧要用的服务。
type writeHandlers struct {
	orders      *order.Service
	fulfillment *fulfillment.Service
	refunds     *refund.Service
	reassign    *reassign.Service
}

// newWriteHandlers 构造写侧服务。
func newWriteHandlers(db *store.DB) *writeHandlers {
	return &writeHandlers{
		orders:      order.New(db),
		fulfillment: fulfillment.New(db),
		refunds:     refund.New(db),
		reassign:    reassign.New(db),
	}
}

// -------------------------------------------------------------------------------------
// 下单
// -------------------------------------------------------------------------------------

// handlePlaceOrder 下单。
//
// 请求体直接吃 order.Request 的形状（channel_id / customer_id /
// idempotency_key / items / holders / contact / buyer_note）。
//
// 幂等键必填：重放一次下单 = 落两单。
func (s *Server) handlePlaceOrder(w http.ResponseWriter, r *http.Request) {
	op, ok := s.requireWrite(w, r)
	if !ok {
		return
	}
	var req order.Request
	if err := decodeJSON(r, &req); err != nil {
		badRequest(w, err)
		return
	}
	if strings.TrimSpace(req.IdempotencyKey) == "" {
		badRequest(w, fmt.Errorf("idempotency_key 必填（重放一次就是落两单）"))
		return
	}
	if req.ChannelID <= 0 {
		badRequest(w, fmt.Errorf("channel_id 必填"))
		return
	}
	o, err := s.write.orders.Place(req)
	if err != nil {
		// 库函数报的是业务错（幂等命中、库存不足、实名不齐…），
		// 这些不是服务端故障，是 409/400 级别的拒绝。
		writeErr(w, http.StatusConflict, "place_order_failed", err.Error())
		return
	}
	_ = op
	writeJSON(w, http.StatusCreated, map[string]any{"order": o})
}

// -------------------------------------------------------------------------------------
// 支付
// -------------------------------------------------------------------------------------

// handleRecordPayment 支付入账。
//
// 请求体：{order_id, method, amount, currency, provider, provider_txn_id}。
//
// 幂等由 fn_record_payment 保证：同一笔渠道流水重复入账返回原记录、
// Paid=false；同一笔流水记到另一张单上则报错。
func (s *Server) handleRecordPayment(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireWrite(w, r); !ok {
		return
	}
	// 订单 id 来自路径，不来自请求体 ——
	// 路径是资源的身份；请求体里的同名字段只是冗余，
	// 两处都能写的话，就会出现「路径说 A、体里说 B」而取了其中一个。
	orderID, err := pathID(r, "order_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	var req struct {
		Method        string         `json:"method"`
		Amount        string         `json:"amount"`
		Currency      string         `json:"currency"`
		Provider      string         `json:"provider"`
		ProviderTxnID string         `json:"provider_txn_id"`
		RawPayload    map[string]any `json:"raw_payload"`
	}
	if err := decodeJSON(r, &req); err != nil {
		badRequest(w, err)
		return
	}
	if _, err := s.orderChannel(orderID); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	res, err := s.write.fulfillment.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       orderID,
		Method:        req.Method,
		Amount:        req.Amount,
		Currency:      req.Currency,
		Provider:      req.Provider,
		ProviderTxnID: req.ProviderTxnID,
		RawPayload:    req.RawPayload,
	})
	if err != nil {
		writeErr(w, http.StatusConflict, "payment_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"payment": res})
}

// -------------------------------------------------------------------------------------
// 出券
// -------------------------------------------------------------------------------------

// handleIssueVoucher 出券。
//
// 请求体：{booking_id, ticket_codes:[...], raw_payload:{...}}。
//
// 票码数必须等于要发的张数 —— 票码数与张数对不上当场报错，不将就。
func (s *Server) handleIssueVoucher(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireWrite(w, r); !ok {
		return
	}
	// 预订 id 来自路径（同上）。
	bookingID, err := pathID(r, "booking_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	var req struct {
		TicketCode []string       `json:"ticket_codes"`
		RawPayload map[string]any `json:"raw_payload"`
	}
	if err := decodeJSON(r, &req); err != nil {
		badRequest(w, err)
		return
	}
	if _, err := s.bookingChannel(bookingID); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	vouchers, err := s.write.fulfillment.IssueVoucher(bookingID, req.TicketCode, req.RawPayload)
	if err != nil {
		writeErr(w, http.StatusConflict, "issue_voucher_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"vouchers": vouchers})
}

// -------------------------------------------------------------------------------------
// 退款
// -------------------------------------------------------------------------------------

// handleRequestRefund 发起退款。
//
// 请求体：{order_id, amount, reason, idempotency_key}。
//
// 金额必须等于按承诺算出的应付退款额 —— 少退客户投诉，多退公司承担。
// 应付额向库问（fn_refund_policy），这里不自己算。
func (s *Server) handleRequestRefund(w http.ResponseWriter, r *http.Request) {
	op, ok := s.requireWrite(w, r)
	if !ok {
		return
	}
	var req struct {
		OrderID        int64  `json:"order_id"`
		Amount         string `json:"amount"`
		Reason         string `json:"reason"`
		IdempotencyKey string `json:"idempotency_key"`
	}
	if err := decodeJSON(r, &req); err != nil {
		badRequest(w, err)
		return
	}
	if req.OrderID <= 0 {
		badRequest(w, fmt.Errorf("order_id 必填"))
		return
	}
	if strings.TrimSpace(req.IdempotencyKey) == "" {
		badRequest(w, fmt.Errorf("idempotency_key 必填（重放一次就多退一次钱）"))
		return
	}
	if _, err := s.orderChannel(req.OrderID); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	// 退款金额向库问：库里判「能不能退」「该退多少」。
	// 这里不自己判资格、不自己算金额 ——
	// 自己算就是第二份实现，两份实现迟早分叉。
	expected, err := s.refundExpectedAmount(req.OrderID)
	if err != nil {
		writeErr(w, http.StatusConflict, "refund_not_allowed", err.Error())
		return
	}
	if strings.TrimSpace(req.Amount) == "" {
		req.Amount = expected
	}
	ref, err := s.write.refunds.RequestRefund(refund.Request{
		OrderID:        req.OrderID,
		Amount:         req.Amount,
		Reason:         req.Reason,
		RequestedBy:    op.Code,
		IdempotencyKey: req.IdempotencyKey,
	})
	if err != nil {
		writeErr(w, http.StatusConflict, "refund_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"refund": ref})
}

// handleApproveRefund 放行退款。
//
// 请求体：{refund_id}。
//
// 放行人记在 sales_refund.approved_by —— 走 fn_approve_refund(approved_by)，
// 这里传的是 operator.code。
//
// 放行与发起各判一次 —— 发起到放行之间时间在走，截止时长会被吃掉。
// 那是库里的口径，这里不重复判。
func (s *Server) handleApproveRefund(w http.ResponseWriter, r *http.Request) {
	op, ok := s.requireApprove(w, r)
	if !ok {
		return
	}
	// 退款单 id 来自路径，不来自请求体（同 handleRecordPayment 的理由）。
	refundID, err := pathID(r, "refund_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	if _, err := s.refundChannel(refundID); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	approval, err := s.write.refunds.ApproveRefund(refundID, op.Code)
	if err != nil {
		writeErr(w, http.StatusConflict, "approve_refund_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"approval": approval})
}

// -------------------------------------------------------------------------------------
// 改派
// -------------------------------------------------------------------------------------

// handleReassign 改派。
//
// 请求体：{order_id, order_item_id, reason}。
//
// 改派 = 重新选源 + 重新定价，两样都取自 fn_price_variant（库里做）。
// 这里只把 id 传过去。
func (s *Server) handleReassign(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireApprove(w, r); !ok {
		return
	}
	// 订单 id 与明细 id 都来自路径（同上）。
	orderID, err := pathID(r, "order_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	itemID, err := pathID(r, "order_item_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if err := decodeJSON(r, &req); err != nil {
		badRequest(w, err)
		return
	}
	if _, err := s.orderChannel(orderID); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	res, err := s.write.reassign.Reassign(orderID, itemID, req.Reason)
	if err != nil {
		writeErr(w, http.StatusConflict, "reassign_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"reassign": res})
}

// -------------------------------------------------------------------------------------
// 归属校验
// -------------------------------------------------------------------------------------

// orderChannel 查一张订单属于哪个渠道。
//
// 找不到就报错，不返回 0 —— 「不知道属于谁」与「属于渠道 0」不是一回事。
func (s *Server) orderChannel(orderID int64) (int64, error) {
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT channel_id FROM sales_order WHERE id = %s;`, store.Quote(orderID)))
	if err != nil {
		return 0, store.PLError(err)
	}
	if len(rows) == 0 {
		return 0, fmt.Errorf("订单 %d 不存在", orderID)
	}
	return parseInt64(rows[0]["channel_id"]), nil
}

// bookingChannel 查一条预订属于哪个渠道（经订单）。
func (s *Server) bookingChannel(bookingID int64) (int64, error) {
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT o.channel_id
           FROM booking b JOIN sales_order o ON o.id = b.order_id
          WHERE b.id = %s;`, store.Quote(bookingID)))
	if err != nil {
		return 0, store.PLError(err)
	}
	if len(rows) == 0 {
		return 0, fmt.Errorf("预订 %d 不存在", bookingID)
	}
	return parseInt64(rows[0]["channel_id"]), nil
}

// refundChannel 查一笔退款属于哪个渠道（经订单）。
func (s *Server) refundChannel(refundID int64) (int64, error) {
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT o.channel_id
           FROM sales_refund r JOIN sales_order o ON o.id = r.order_id
          WHERE r.id = %s;`, store.Quote(refundID)))
	if err != nil {
		return 0, store.PLError(err)
	}
	if len(rows) == 0 {
		return 0, fmt.Errorf("退款单 %d 不存在", refundID)
	}
	return parseInt64(rows[0]["channel_id"]), nil
}

// refundExpectedAmount 向库问这笔订单「按承诺该退多少」。
//
// 承诺的读法与执行者是 fn_refund_policy —— 那是唯一一份。
// 这里只是把它问出来，Go 侧不自己算（自己算就是第二份实现）。
func (s *Server) refundExpectedAmount(orderID int64) (string, error) {
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT expected_amount::text AS expected_amount,
                refundable, within_cutoff, cutoff_hours
           FROM fn_refund_policy(%s);`, store.Quote(orderID)))
	if err != nil {
		return "", store.PLError(err)
	}
	if len(rows) == 0 {
		return "", fmt.Errorf("订单 %d 没有退款承诺", orderID)
	}
	r := rows[0]
	if r["refundable"] != "t" && r["refundable"] != "true" {
		return "", fmt.Errorf("订单 %d 按承诺不可退", orderID)
	}
	amount := strings.TrimSpace(r["expected_amount"])
	if amount == "" {
		return "", fmt.Errorf("订单 %d 没有承诺的应付退款额", orderID)
	}
	return amount, nil
}
