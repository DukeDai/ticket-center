package refund_test

import (
	"fmt"
	"strconv"
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
//   - 退款金额必须等于**按该单退款承诺算出的应付退款额**（整单退款），
//     少一分多一分都当场拦下；有手续费承诺时它不等于订单实付；
//   - 承诺不可退 → 报错；距开场不足 cutoff_hours → 报错（发起与放行各判一次）；
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

// payableAmount 向库问「按承诺该退多少」。
//
// fn_refund_policy 是退款承诺的唯一读法 —— 测试也不另算一遍，
// 免得 Go 侧与库里的口径分叉（那正是这套门禁要防的事）。
func payableAmount(t *testing.T, db *store.DB, orderID int64) string {
	t.Helper()
	s, err := db.Scalar(`SELECT expected_amount::text FROM fn_refund_policy(` + store.Quote(orderID) + `);`)
	if err != nil {
		t.Fatalf("读应付退款额失败：%v", err)
	}
	if s == "" {
		t.Fatalf("订单 %d 没有应付退款额", orderID)
	}
	return s
}

// policyRow 读一单生效的退款承诺（fn_refund_policy 是唯一读法）。
func policyRow(t *testing.T, db *store.DB, orderID int64) map[string]string {
	t.Helper()
	rows, err := db.Rows(`SELECT refundable::text, cutoff_hours::text, fee_percent::text,
                                  expected_amount::text, within_cutoff::text, has_cutoff_point::text
                             FROM fn_refund_policy(` + store.Quote(orderID) + `);`)
	if err != nil {
		t.Fatalf("读退款承诺失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatalf("订单 %d 读不到退款承诺", orderID)
	}
	return rows[0]
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

// amountCents 把十进制金额文本转成「分」的整数。
//
// 用整数分而不是 float64：二进制浮点过一遍就会把 368.00 变成
// 367.99999999999994，期望值本身就是错的（硬约束 5）。
func amountCents(t *testing.T, s string) string {
	t.Helper()
	raw := strings.TrimSpace(s)
	neg := strings.HasPrefix(raw, "-")
	raw = strings.TrimPrefix(raw, "-")
	intPart, fracPart, _ := strings.Cut(raw, ".")
	fracPart += "00"
	if len(fracPart) < 2 {
		fracPart = fracPart + strings.Repeat("0", 2-len(fracPart))
	}
	n, err := strconv.ParseInt(intPart+fracPart[:2], 10, 64)
	if err != nil {
		t.Fatalf("金额 %q 不是十进制数", s)
	}
	if neg {
		n = -n
	}
	return strconv.FormatInt(n, 10)
}

// formatCents 把「分」的整数还原成两位小数的金额文本。
func formatCents(cents int64) string {
	sign := ""
	if cents < 0 {
		sign = "-"
		cents = -cents
	}
	return sign + strconv.FormatInt(cents/100, 10) + "." + fmt.Sprintf("%02d", cents%100)
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
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

func TestRefundRequestRejectsAmountDifferentFromPayableAmount(t *testing.T) {
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
		t.Fatal("金额与应付退款额不符不该放行")
	}
	if !strings.Contains(err.Error(), "退款金额与应付退款额不符") {
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-REPLAY",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if _, err := svc.ApproveRefund(res.RefundID, "boss@test"); err != nil {
		t.Fatalf("放行退款失败：%v", err)
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
		Amount:         payableAmount(t, db, o.ID),
		Reason:         "源侧超时",
		IdempotencyKey: "RF-KEY-FAIL",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if _, err := svc.ApproveRefund(res.RefundID, "boss@test"); err != nil {
		t.Fatalf("放行退款失败：%v", err)
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
		Amount:         payableAmount(t, db, o.ID),
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
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-TWICE",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if _, err := svc.ApproveRefund(res.RefundID, "boss@test"); err != nil {
		t.Fatalf("放行退款失败：%v", err)
	}
	if _, err := svc.CompleteRefund(refund.CompleteRequest{RefundID: res.RefundID, Success: true}); err != nil {
		t.Fatalf("落退款结果失败：%v", err)
	}
	// 退完再退一次（换个幂等键）—— 钱只能退一次。
	_, err = svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
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

// TestRefundCannotBeCompletedWithoutApproval 守住「放行是退款里的一步」。
//
// 以前完成退款只拦终态（succeeded / failed / rejected），requested 状态的
// 退款能被直接结掉 —— 那放行这一步就形同虚设，谁都能把钱退出去。
func TestRefundCannotBeCompletedWithoutApproval(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-noapprove-001", "ALI-RF-NOAPPROVE")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-NOAPPROVE",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}

	_, err = svc.CompleteRefund(refund.CompleteRequest{
		RefundID:         res.RefundID,
		Success:          true,
		SupplierRefundID: "EXT-RF-NOAPPROVE",
	})
	if err == nil {
		t.Fatal("没放行的退款不该能被完成")
	}
	if !strings.Contains(err.Error(), "不能完成") {
		t.Fatalf("报错要说清是状态不对，实际：%v", err)
	}

	// 钱没退，状态就不许提前改：订单还挂在 refunding。
	status, err := db.Scalar(`SELECT status FROM sales_order WHERE id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读订单状态失败：%v", err)
	}
	if status != "refunding" {
		t.Fatalf("订单状态应该还是 refunding，实际 %s", status)
	}
	invariantsGreen(t, db)
}

// TestRefundRequestRejectsNonRefundablePromise 守住「承诺不可退就不能退」。
//
// product.refund_policy 是我们自己对客户的承诺。它写着 refundable=false 时，
// 退款必须当场被挡下 —— 承诺写在纸上没人执行，等于没有承诺。
//
// 变体 6（SKU-IT-DOGES）的商品承诺是「不可退」。它没有实名要求，
// 所以这条下单路自己建，不走 placeOrder（那条路要求变体有实名要求）。
func TestRefundRequestRejectsNonRefundablePromise(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 6)
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "rf-nonref-001",
		Items:          []order.Item{{VariantID: 6, Quantity: 1, VisitDate: date}},
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}
	if _, err := fulfillment.New(db).RecordPayment(fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        o.Total,
		Currency:      o.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-RF-NONREF",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}

	// 承诺确实是「不可退」—— 不是因为别的错才被挡下的。
	pol := policyRow(t, db, o.ID)
	if pol["refundable"] != "false" {
		t.Fatalf("变体 6 的商品承诺应该是不可退，实际 %s", pol["refundable"])
	}

	_, err = refund.New(db).RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-NONREF",
	})
	if err == nil {
		t.Fatal("承诺不可退的订单不该能发起退款")
	}
	if !strings.Contains(err.Error(), "退款承诺是「不可退」") {
		t.Fatalf("报错要说清是承诺不可退，实际：%v", err)
	}
	invariantsGreen(t, db)
}

// TestRefundRequestRejectsPastCutoff 守住「距开场不足 cutoff_hours 不许退」。
//
// 承诺里写了 cutoff_hours —— 距开场不足这么多小时就不接受退款。
// 把场次的开始时间挪到「一会儿之后」，就落进截止点里，发起退款必须被挡下。
//
// 参照点是 product_session.start_at（没有就退回 session_date），
// 判定是 now() > 参照点 − cutoff_hours：时间不够了，就是过了截止点。
func TestRefundRequestRejectsPastCutoff(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-cutoff-001", "ALI-RF-CUTOFF")

	// 挪场次时间之前，先确认还在截止点之外 —— 否则这个测试证明不了什么。
	before := policyRow(t, db, o.ID)
	if before["has_cutoff_point"] != "true" {
		t.Fatalf("这一单该有截止参照点，实际 has_cutoff_point=%s", before["has_cutoff_point"])
	}
	if before["within_cutoff"] != "false" {
		t.Fatalf("挪时间之前不该已经在截止点里，实际 within_cutoff=%s", before["within_cutoff"])
	}

	// 把场次挪到 2 小时后 —— 承诺的截止窗口是 48 小时，所以稳稳落进截止点里。
	if err := db.Exec(`UPDATE product_session
                        SET start_at = now() + interval '2 hours'
                      WHERE id = (SELECT session_id FROM sales_order_item
                                   WHERE order_id = ` + store.Quote(o.ID) + ` LIMIT 1);`); err != nil {
		t.Fatalf("挪场次时间失败：%v", err)
	}

	after := policyRow(t, db, o.ID)
	if after["within_cutoff"] != "true" {
		t.Fatalf("挪时间之后应该已在截止点里，实际 within_cutoff=%s", after["within_cutoff"])
	}

	_, err := refund.New(db).RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-CUTOFF",
	})
	if err == nil {
		t.Fatal("距开场不足 cutoff_hours 不该能发起退款")
	}
	if !strings.Contains(err.Error(), "已过退款截止点") {
		t.Fatalf("报错要说清是过了截止点，实际：%v", err)
	}
	invariantsGreen(t, db)
}

// TestRefundAmountIsNetOfPromisedFee 守住「应付退款额 = 实付 − 承诺的手续费」。
//
// 变体 9 的商品承诺有 10% 手续费。所以应付退款额不等于订单实付。
//
// 这里的关键不是「算出 0.9 倍」，而是**金额必须向库问**：
// Go 侧自己乘一遍就多了一份口径（硬约束 20 的同类要求）。
// 所以断言的是「库说的应付额与实付的比例等于承诺的比例」——
// 期望值由这一单自己的实付与承诺费率推出来，不抄一个写死的数
// （写死的数换个订单就是错的，且没人说得清它错在哪）。
func TestRefundAmountIsNetOfPromisedFee(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-fee-001", "ALI-RF-FEE")

	pol := policyRow(t, db, o.ID)
	if pol["fee_percent"] != "10.000000" && pol["fee_percent"] != "10" {
		t.Fatalf("变体 9 的商品承诺应该是 10%% 手续费，实际 %s", pol["fee_percent"])
	}

	// 期望值 = 实付 × (1 − 手续费率)。用整数分算，避免浮点。
	paidCents := parseInt(amountCents(t, o.Total))
	feeCents := paidCents * 10 / 100
	wantCents := paidCents - feeCents
	want := formatCents(wantCents)
	if pol["expected_amount"] != want {
		t.Fatalf("应付退款额应该是 %s（实付 %s 减 10%% 手续费），实际 %s",
			want, o.Total, pol["expected_amount"])
	}

	// 应付额确实不等于订单实付 —— 这正是手续费承诺在起作用。
	if payableAmount(t, db, o.ID) == o.Total {
		t.Fatalf("有 10%% 手续费承诺时应付退款额不该等于实付（都是 %s）", o.Total)
	}

	// 按应付额发起退款应当被接受 —— 承诺与执行者对得上。
	svc := refund.New(db)
	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-FEE",
	})
	if err != nil {
		t.Fatalf("按应付退款额发起退款失败：%v", err)
	}
	if _, err := svc.ApproveRefund(res.RefundID, "boss@test"); err != nil {
		t.Fatalf("放行退款失败：%v", err)
	}
	if _, err := svc.CompleteRefund(refund.CompleteRequest{RefundID: res.RefundID, Success: true}); err != nil {
		t.Fatalf("落退款结果失败：%v", err)
	}

	// 退款单上存的金额就是应付额。
	st, err := svc.Show(res.RefundID)
	if err != nil {
		t.Fatalf("读退款单失败：%v", err)
	}
	if st.Amount != want {
		t.Fatalf("退款单金额应该是 %s，实际 %s", want, st.Amount)
	}
	invariantsGreen(t, db)
}

// TestRefundApproveRechecksPromise 守住「放行时再判一遍承诺」。
//
// 发起到放行之间有时间差，cutoff_hours 会被这段时间吃掉。
// 发起时距开场还有几十小时，放行时场次挪到两小时后 —— 这一笔
// 在发起时合法，在放行时就该被挡下。
//
// 所以放行这一步要**重判**，不是照抄发起时的结论。
func TestRefundApproveRechecksPromise(t *testing.T) {
	db := seeded(t)
	o := paidOrder(t, db, "rf-recheck-001", "ALI-RF-RECHECK")
	svc := refund.New(db)

	res, err := svc.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-KEY-RECHECK",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}

	// 发起之后、放行之前，场次挪到截止点里。
	if err := db.Exec(`UPDATE product_session
                        SET start_at = now() + interval '2 hours'
                      WHERE id = (SELECT session_id FROM sales_order_item
                                   WHERE order_id = ` + store.Quote(o.ID) + ` LIMIT 1);`); err != nil {
		t.Fatalf("挪场次时间失败：%v", err)
	}

	_, err = svc.ApproveRefund(res.RefundID, "boss@test")
	if err == nil {
		t.Fatal("过了截止点不该能放行退款")
	}
	if !strings.Contains(err.Error(), "不能放行退款") {
		t.Fatalf("报错要说清是放行时被挡下，实际：%v", err)
	}

	// 钱没退，订单就还挂在 refunding 上。
	if got := orderStatus(t, db, o.ID); got != "refunding" {
		t.Fatalf("放行被挡下时订单状态应该还是 refunding，实际 %s", got)
	}
	invariantsGreen(t, db)
}
