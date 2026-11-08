package refund_test

import (
	"strings"
	"testing"

	"ticket-center/internal/fulfillment"
	"ticket-center/internal/order"
	"ticket-center/internal/redemption"
	"ticket-center/internal/refund"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 退款的行为约定：
//   - 退款金额必须等于订单实付（整单退款），少一分多一分都当场拦下；
//   - 幂等键必填：重放一次退款就是多退一次钱；
//   - 同一个幂等键配不同内容要报错，不能静默返回上一笔；
//   - 订单状态推进到 refunding 是发起的时候 —— 免得一边退一边出票；
//   - 退款失败时订单照着退款前的状态退回去；
//   - 退款成功后事实一起改（明细/凭证/预订/支付/订单），不变量全绿。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

// priceDate 找一个该变体确实有售价的日期。
func priceDate(t *testing.T, db *store.DB, variantID int64) string {
	t.Helper()
	d, err := db.Scalar(`SELECT date::text FROM price_calendar
                          WHERE product_variant_id = ` + store.Quote(variantID) + `
                            AND status = 'active'
                          ORDER BY date LIMIT 1;`)
	if err != nil {
		t.Fatalf("查售价日期失败：%v", err)
	}
	if d == "" {
		t.Fatalf("变体 %d 没有售价行", variantID)
	}
	return d
}

func requiredFields(t *testing.T, db *store.DB, variantID int64) []string {
	t.Helper()
	rows, err := db.Query(`SELECT cr.field_code
                             FROM checkout_requirement cr
                             JOIN product_variant pv ON pv.ticket_type_id = cr.ticket_type_id
                            WHERE pv.id = ` + store.Quote(variantID) + `
                              AND cr.required
                            ORDER BY cr.sort_order;`)
	if err != nil {
		t.Fatalf("查实名要求失败：%v", err)
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r[0])
	}
	if len(out) == 0 {
		t.Fatalf("变体 %d 没有实名要求", variantID)
	}
	return out
}

func holdersFor(variantID int64, qty int, fields []string) []order.Holder {
	out := make([]order.Holder, 0, qty*len(fields))
	for seq := 1; seq <= qty; seq++ {
		for _, f := range fields {
			out = append(out, order.Holder{
				VariantID: variantID,
				Sequence:  seq,
				FieldCode: f,
				Value:     "测试值" + f,
			})
		}
	}
	return out
}

// placeOrder 下单并返回订单。
func placeOrder(t *testing.T, db *store.DB, key string, variantID int64, qty int) *order.Order {
	t.Helper()
	date := priceDate(t, db, variantID)
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: key,
		Items:          []order.Item{{VariantID: variantID, Quantity: qty, VisitDate: date}},
		Holders:        holdersFor(variantID, qty, requiredFields(t, db, variantID)),
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}
	return o
}

// paidOrder 下单并支付，返回订单（状态 paid，有成功的支付记录）。
func paidOrder(t *testing.T, db *store.DB, key string, txn string) *order.Order {
	t.Helper()
	o := placeOrder(t, db, key, 9, 2)
	if _, err := fulfillment.New(db).RecordPayment(fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        o.Total,
		Currency:      o.Currency,
		Provider:      "alipay",
		ProviderTxnID: txn,
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	return o
}

// parseInt 解析整数（测试里从库里读出来的 id）。
func parseInt(s string) int64 {
	var n int64
	for _, c := range strings.TrimSpace(s) {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// invariantsGreen 断言全库不变量全绿。
func invariantsGreen(t *testing.T, db *store.DB) {
	t.Helper()
	rows, err := db.Rows(`SELECT seq, check_name, actual FROM v_invariant_checks WHERE NOT passed;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("不该出现不变量违规：%v", rows)
	}
}

// orderStatus 读订单当前状态。
func orderStatus(t *testing.T, db *store.DB, orderID int64) string {
	t.Helper()
	s, err := db.Scalar(`SELECT status FROM sales_order WHERE id = ` + store.Quote(orderID) + `;`)
	if err != nil {
		t.Fatalf("读订单状态失败：%v", err)
	}
	return s
}

func TestRefundRequestMovesOrderToRefunding(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-req-001", "ALI-RF-001")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		Reason:         "源侧预订失败",
		RequestedBy:    "ops@test",
		IdempotencyKey: "RF-KEY-001",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if !res.Requested {
		t.Fatal("第一次发起退款应该是新发起")
	}
	if res.RefundNo == "" {
		t.Fatal("退款单号不能为空")
	}
	if res.OrderStatus != "refunding" {
		t.Fatalf("发起后订单状态应该是 refunding，实际 %s", res.OrderStatus)
	}
	if got := orderStatus(t, db, o.ID); got != "refunding" {
		t.Fatalf("库里订单状态应该是 refunding，实际 %s", got)
	}
	invariantsGreen(t, db)
}

func TestRefundRequestRequiresIdempotencyKey(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-nokey-001", "ALI-RF-NOKEY")
	svc := refund.New(db)

	_, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "",
	})
	if err == nil {
		t.Fatal("缺幂等键不该放行")
	}
	if !strings.Contains(err.Error(), "幂等键") {
		t.Fatalf("报错要说清是缺幂等键，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRefundRequestRejectsAmountDifferentFromOrderTotal(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-amt-001", "ALI-RF-AMT")
	svc := refund.New(db)

	// 少退一分 —— 少退的钱客户会来投诉，多退的钱公司自己承担。
	_, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         "0.01",
		IdempotencyKey: "RF-KEY-AMT",
	})
	if err == nil {
		t.Fatal("金额与订单实付不符不该放行")
	}
	if !strings.Contains(err.Error(), "退款金额与订单实付不符") {
		t.Fatalf("报错要说清是金额不符，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRefundRequestReplayWithSameKeyIsIdempotent(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-idem-001", "ALI-RF-IDEM")
	svc := refund.New(db)

	req := refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		Reason:         "源侧预订失败",
		RequestedBy:    "ops@test",
		IdempotencyKey: "RF-KEY-IDEM",
	}
	first, err := svc.RequestRefund(req)
	if err != nil {
		t.Fatalf("第一次发起退款失败：%v", err)
	}
	second, err := svc.RequestRefund(req)
	if err != nil {
		t.Fatalf("重复发起退款失败：%v", err)
	}
	if second.Requested {
		t.Fatal("同一幂等键重复发起不该再退一次")
	}
	if second.RefundID != first.RefundID {
		t.Fatalf("重复发起应该返回同一笔退款单，实际 %d 与 %d", second.RefundID, first.RefundID)
	}

	n, err := db.Scalar(`SELECT count(*) FROM sales_refund WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("数退款单失败：%v", err)
	}
	if n != "1" {
		t.Fatalf("同一幂等键只该有一笔退款单，实际 %s 笔", n)
	}
	invariantsGreen(t, db)
}

func TestRefundRequestWithSameKeyDifferentContentIsRejected(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-hash-001", "ALI-RF-HASH")
	svc := refund.New(db)

	base := refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		Reason:         "源侧预订失败",
		RequestedBy:    "ops@test",
		IdempotencyKey: "RF-KEY-HASH",
	}
	if _, err := svc.RequestRefund(base); err != nil {
		t.Fatalf("第一次发起退款失败：%v", err)
	}

	// 同一个键换个理由再发 —— 静默返回上一笔就等于吞掉一次退款。
	changed := base
	changed.Reason = "换个理由再退一次"
	_, err := svc.RequestRefund(changed)
	if err == nil {
		t.Fatal("同键异内容不该放行")
	}
	if !strings.Contains(err.Error(), "已用于另一笔退款请求") {
		t.Fatalf("报错要说清是同键异内容，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRefundRequestOnUnpaidOrderIsRejected(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "rf-unpaid-001", 9, 2)
	svc := refund.New(db)

	// 没收到钱退什么 —— 订单还没付钱。
	_, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "RF-KEY-UNPAID",
	})
	if err == nil {
		t.Fatal("没支付的订单不该能退款")
	}
	if !strings.Contains(err.Error(), "不能退款") {
		t.Fatalf("报错要说清是订单状态不允许退款，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRefundApproveMovesRefundToApprovedAndKeepsOrderState(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-approve-001", "ALI-RF-APPROVE")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "RF-KEY-APPROVE",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	ap, err := svc.ApproveRefund(res.RefundID, "boss@test")
	if err != nil {
		t.Fatalf("放行退款失败：%v", err)
	}
	if ap.RefundStatus != "approved" {
		t.Fatalf("放行后退款单状态应该是 approved，实际 %s", ap.RefundStatus)
	}
	// 放行只是人工过一道，钱还没回来 —— 订单不能被当成已退款。
	if ap.OrderStatus != "refunding" {
		t.Fatalf("放行后订单状态应该还是 refunding，实际 %s", ap.OrderStatus)
	}
	invariantsGreen(t, db)
}

func TestRefundCompleteSuccessRewritesFactsAndOrder(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-ok-001", "ALI-RF-OK")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		Reason:         "源侧预订失败",
		IdempotencyKey: "RF-KEY-OK",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if _, err := svc.ApproveRefund(res.RefundID, "boss@test"); err != nil {
		t.Fatalf("放行退款失败：%v", err)
	}
	comp, err := svc.CompleteRefund(refund.CompleteRequest{
		RefundID:         res.RefundID,
		Success:          true,
		SupplierRefundID: "EXT-RF-001",
		RawPayload:       map[string]any{"channel": "alipay"},
	})
	if err != nil {
		t.Fatalf("落退款结果失败：%v", err)
	}
	if comp.RefundStatus != "succeeded" {
		t.Fatalf("退款单状态应该是 succeeded，实际 %s", comp.RefundStatus)
	}
	if comp.OrderStatus != "refunded" {
		t.Fatalf("订单状态应该是 refunded，实际 %s", comp.OrderStatus)
	}
	if comp.OrderPaymentStatus != "refunded" {
		t.Fatalf("订单支付状态应该是 refunded，实际 %s", comp.OrderPaymentStatus)
	}
	if comp.OrderFulfillmentStatus != "cancelled" {
		t.Fatalf("订单履约状态应该是 cancelled，实际 %s", comp.OrderFulfillmentStatus)
	}

	// 事实要一起改：明细取消、支付退款。留着「钱退了、状态还挂在 paid」的订单，
	// 对账时两边的口径会对不上。
	itemStatus, err := db.Scalar(`SELECT status FROM sales_order_item WHERE order_id = ` + store.Quote(o.ID) + ` LIMIT 1;`)
	if err != nil {
		t.Fatalf("读明细状态失败：%v", err)
	}
	if itemStatus != "cancelled" && itemStatus != "refunded" {
		t.Fatalf("明细状态应该是 cancelled 或 refunded，实际 %s", itemStatus)
	}
	payStatus, err := db.Scalar(`SELECT status FROM sales_payment WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读支付状态失败：%v", err)
	}
	if payStatus != "refunded" {
		t.Fatalf("支付记录状态应该是 refunded，实际 %s", payStatus)
	}
	invariantsGreen(t, db)
}

func TestRefundCompleteReplayIsIdempotent(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-replay-001", "ALI-RF-REPLAY")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "RF-KEY-REPLAY",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	req := refund.CompleteRequest{RefundID: res.RefundID, Success: true, SupplierRefundID: "EXT-RF-002"}
	if _, err := svc.CompleteRefund(req); err != nil {
		t.Fatalf("落退款结果失败：%v", err)
	}
	second, err := svc.CompleteRefund(req)
	if err != nil {
		t.Fatalf("重复落退款结果失败：%v", err)
	}
	if second.RefundStatus != "succeeded" {
		t.Fatalf("重复落结果后状态还是 succeeded，实际 %s", second.RefundStatus)
	}
	if second.OrderStatus != "refunded" {
		t.Fatalf("重复落结果不该改订单状态，实际 %s", second.OrderStatus)
	}

	n, err := db.Scalar(`SELECT count(*) FROM sales_payment WHERE order_id = ` + store.Quote(o.ID) + ` AND status = 'refunded';`)
	if err != nil {
		t.Fatalf("数退款支付记录失败：%v", err)
	}
	if n != "1" {
		t.Fatalf("退款成功的支付记录只该有一条，实际 %s 条", n)
	}
	invariantsGreen(t, db)
}

func TestRefundCompleteFailureRestoresOrderToPreviousStatus(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-fail-001", "ALI-RF-FAIL")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		Reason:         "源侧超时",
		IdempotencyKey: "RF-KEY-FAIL",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	comp, err := svc.CompleteRefund(refund.CompleteRequest{
		RefundID:     res.RefundID,
		Success:      false,
		ErrorCode:    "SOURCE_TIMEOUT",
		ErrorMessage: "源侧退款超时",
	})
	if err != nil {
		t.Fatalf("落失败结果失败：%v", err)
	}
	if comp.RefundStatus != "failed" {
		t.Fatalf("退款单状态应该是 failed，实际 %s", comp.RefundStatus)
	}
	// 退不回去的订单得留在 refunding 等人处理；退得回去的必须退回退款前的状态。
	if got := orderStatus(t, db, o.ID); got != "paid" && got != "refunding" {
		t.Fatalf("退款失败后订单状态应该是 paid 或 refunding，实际 %s", got)
	}
	if got := orderStatus(t, db, o.ID); got == "refunded" {
		t.Fatal("退款失败订单不该是 refunded")
	}

	// 失败原因要留痕：源侧为什么没退成，得能查。
	st, err := svc.Show(res.RefundID)
	if err != nil {
		t.Fatalf("读退款单失败：%v", err)
	}
	if st.ErrorCode != "SOURCE_TIMEOUT" {
		t.Fatalf("退款单错误码应该是 SOURCE_TIMEOUT，实际 %q", st.ErrorCode)
	}
	if st.PreviousOrderStatus != "paid" {
		t.Fatalf("退款前订单状态应该记为 paid，实际 %q", st.PreviousOrderStatus)
	}
	invariantsGreen(t, db)
}

func TestRefundOnUsedVoucherIsRejected(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-used-001", "ALI-RF-USED")
	ful := fulfillment.New(db)

	bookings, err := ful.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if _, err := ful.RequestBooking(bookings[0].BookingID, nil); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}
	if _, err := ful.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         bookings[0].BookingID,
		Status:            "confirmed",
		ExternalBookingID: "EXT-BK-USED",
		Codes:             []string{"C1", "C2"},
		IssueVoucher:      true,
	}); err != nil {
		t.Fatalf("确认预订失败：%v", err)
	}
	// 把券真核销掉 —— 票已经用掉了，钱不该全退。
	// 这里必须走真的核销路径：手工 UPDATE 出一个 used 的券，
	// 不变量 65（已核销的凭证必须有成功的核销记录）会当场报警。
	voucherID, err := db.Scalar(`SELECT id::text FROM voucher WHERE order_id = ` + store.Quote(o.ID) + ` ORDER BY id LIMIT 1;`)
	if err != nil {
		t.Fatalf("查券失败：%v", err)
	}
	if voucherID == "" {
		t.Fatal("订单没有发出券")
	}
	if err := db.Exec(`UPDATE voucher
                         SET valid_from = now() - interval '1 hour',
                             valid_to   = now() - interval '1 hour' + (valid_to - valid_from)
                       WHERE id = ` + store.Quote(voucherID) + `;`); err != nil {
		t.Fatalf("调整券有效期失败：%v", err)
	}
	if _, err := redemption.New(db).Redeem(redemption.Request{
		VoucherID: parseInt(voucherID),
		GateID:    1,
	}); err != nil {
		t.Fatalf("核销失败：%v", err)
	}

	svc := refund.New(db)
	_, err = svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "RF-KEY-USED",
	})
	if err == nil {
		t.Fatal("有已核销的票不该能整单退款")
	}
	if !strings.Contains(err.Error(), "已核销") {
		t.Fatalf("报错要说清是票已核销，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRefundTwiceOnSameOrderIsRejected(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-twice-001", "ALI-RF-TWICE")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "RF-KEY-TWICE",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if _, err := svc.CompleteRefund(refund.CompleteRequest{RefundID: res.RefundID, Success: true}); err != nil {
		t.Fatalf("落退款结果失败：%v", err)
	}
	// 退完再退一次（换个幂等键）—— 钱只能退一次。
	_, err = svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         o.Total,
		IdempotencyKey: "RF-KEY-TWICE-2",
	})
	if err == nil {
		t.Fatal("已退款的订单不该能再退一次")
	}
	if !strings.Contains(err.Error(), "已经退过款") {
		t.Fatalf("报错要说清是已经退过款，实际：%v", err)
	}
	invariantsGreen(t, db)
}
