package redemption_test

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

// 核销的行为约定：
//   - 一次扫票一条记录，成功失败都落 —— 重复扫票是事实，不能压掉；
//   - 一张券最多成功核销一次（唯一索引兜底），第二次记 duplicate；
//   - 过期 / 作废 / 已退款 / 还没出票的券不认，但要说清原因；
//   - 正在退款的订单不认核销（钱在退的时候把人放进去，退款就退不干净）；
//   - 核销成功后额度用尽、券变 used、领域事件落一条（不变量 65-68）。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

// priceDate 找一个该变体确实有售价的日期。
func priceDate(t *testing.T, db *store.DB, variantID int64) string {
	t.Helper()
	d, err := db.Scalar(`SELECT date::text FROM price_calendar
                          WHERE product_variant_id = ` + store.Quote(variantID) +
		` AND status = 'active' ORDER BY date LIMIT 1;`)
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
                            WHERE pv.id = ` + store.Quote(variantID) +
		` AND cr.required ORDER BY cr.sort_order;`)
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

// paidOrder 下单并支付，返回订单。
func paidOrder(t *testing.T, db *store.DB, key string, txn string) *order.Order {
	t.Helper()
	date := priceDate(t, db, 9)
	variantID := int64(9)
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: key,
		Items:          []order.Item{{VariantID: variantID, Quantity: 2, VisitDate: date}},
		Holders:        holdersFor(variantID, 2, requiredFields(t, db, variantID)),
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
		ProviderTxnID: txn,
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	return o
}

// ticketedOrder 下单 → 支付 → 预订 → 出券，返回订单和它发出的券 id。
func ticketedOrder(t *testing.T, db *store.DB, key, txn string) (*order.Order, []int64) {
	t.Helper()
	o := paidOrder(t, db, key, txn)
	ful := fulfillment.New(db)
	bookings, err := ful.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	for i, b := range bookings {
		if _, err := ful.RequestBooking(b.BookingID, nil); err != nil {
			t.Fatalf("发起预订失败：%v", err)
		}
		if _, err := ful.CompleteBooking(fulfillment.CompleteRequest{
			BookingID:         b.BookingID,
			Status:            "confirmed",
			ExternalBookingID: "EXT-BK-" + key,
			Codes:             []string{"C1-" + key, "C2-" + key},
			IssueVoucher:      true,
		}); err != nil {
			t.Fatalf("确认预订失败：%v", err)
		}
		_ = i
	}
	ids, err := db.Query(`SELECT id::text FROM voucher WHERE order_id = ` + store.Quote(o.ID) + ` ORDER BY id;`)
	if err != nil {
		t.Fatalf("查券失败：%v", err)
	}
	out := make([]int64, 0, len(ids))
	for _, r := range ids {
		out = append(out, parseInt(r[0]))
	}
	if len(out) == 0 {
		t.Fatalf("订单 %d 没发出券", o.ID)
	}
	return o, out
}

// openWindow 把券的有效期挪到现在（fixture）。
//
// 种子里券的有效期在未来的场次日上 —— 真场次就是那天才开门。
// 测试要在「有效期内」这一支上跑，就得把窗口挪到当下。
func openWindow(t *testing.T, db *store.DB, voucherID int64) {
	t.Helper()
	if err := db.Exec(`UPDATE voucher
                         SET valid_from = now() - interval '1 hour',
                             valid_to   = now() - interval '1 hour' + (valid_to - valid_from)
                       WHERE id = ` + store.Quote(voucherID) + `;`); err != nil {
		t.Fatalf("调整券有效期失败：%v", err)
	}
}

// payableAmount 向库问「按承诺该退多少」。
//
// fn_refund_policy 是退款承诺的唯一读法 —— 测试也不另算一遍，
// 免得 Go 侧与库里的口径分叉（那正是这套门禁要防的事）。
// 有手续费承诺时应付额不等于订单实付，拿实付去发起会被当场挡下。
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

func TestRedeemSuccessConsumesEntitlementAndMarksVoucherUsed(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-ok-001", "ALI-RD-001")
	openWindow(t, db, vouchers[0])

	res, err := redemption.New(db).Redeem(redemption.Request{
		VoucherID: vouchers[0],
		GateID:    1,
		DeviceID:  "POS-HK-0117",
	})
	if err != nil {
		t.Fatalf("核销失败：%v", err)
	}
	if res.Result != "success" {
		t.Fatalf("核销结果应该是 success，实际 %s（%s）", res.Result, res.Reason)
	}
	if res.VoucherStatus != "used" {
		t.Fatalf("核销后券状态应该是 used，实际 %s", res.VoucherStatus)
	}
	if res.ConsumedQuantity != 1 {
		t.Fatalf("按人计价一券一张，消耗额度应该是 1，实际 %d", res.ConsumedQuantity)
	}

	status, err := db.Scalar(`SELECT status FROM voucher WHERE id = ` + store.Quote(vouchers[0]) + `;`)
	if err != nil {
		t.Fatalf("读券状态失败：%v", err)
	}
	if status != "used" {
		t.Fatalf("库里券状态应该是 used，实际 %s", status)
	}
	consumed, err := db.Scalar(`SELECT consumed_quantity::text FROM voucher_entitlement WHERE voucher_id = ` + store.Quote(vouchers[0]) + `;`)
	if err != nil {
		t.Fatalf("读额度失败：%v", err)
	}
	if consumed != "1" {
		t.Fatalf("额度应该被用尽为 1，实际 %s", consumed)
	}

	// 状态一变就要有领域事件（硬约束 17）。
	ev, err := db.Scalar(`SELECT count(*) FROM event_outbox
                            WHERE event_type = 'VoucherRedeemed'
                              AND aggregate_type = 'voucher'
                              AND aggregate_id = ` + store.Quote(vouchers[0]) + `;`)
	if err != nil {
		t.Fatalf("查领域事件失败：%v", err)
	}
	if ev != "1" {
		t.Fatalf("应该落一条 VoucherRedeemed 事件，实际 %s 条", ev)
	}
	invariantsGreen(t, db)
}

func TestRedeemByCodeFindsTheVoucher(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-code-001", "ALI-RD-CODE")
	openWindow(t, db, vouchers[0])

	code, err := db.Scalar(`SELECT code FROM voucher WHERE id = ` + store.Quote(vouchers[0]) + `;`)
	if err != nil {
		t.Fatalf("读票码失败：%v", err)
	}
	res, err := redemption.New(db).Redeem(redemption.Request{
		Code:     code,
		GateID:   1,
		DeviceID: "POS-HK-0117",
	})
	if err != nil {
		t.Fatalf("按票码核销失败：%v", err)
	}
	if res.Result != "success" {
		t.Fatalf("核销结果应该是 success，实际 %s（%s）", res.Result, res.Reason)
	}
	if res.VoucherID != vouchers[0] {
		t.Fatalf("核销的券应该是 %d，实际 %d", vouchers[0], res.VoucherID)
	}
	invariantsGreen(t, db)
}

func TestRedeemSecondScanIsDuplicateAndKeepsBothRecords(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-dup-001", "ALI-RD-DUP")
	openWindow(t, db, vouchers[0])
	svc := redemption.New(db)

	first, err := svc.Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1})
	if err != nil {
		t.Fatalf("第一次核销失败：%v", err)
	}
	second, err := svc.Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1})
	if err != nil {
		t.Fatalf("第二次核销失败：%v", err)
	}
	if second.Result != "duplicate" {
		t.Fatalf("第二次扫票应该是 duplicate，实际 %s", second.Result)
	}
	// 重扫要带回第一次的记录：调用方据此对账（网络重试丢响应 vs 恶意重复扫码）。
	if second.OriginalRedemptionID != first.RedemptionID {
		t.Fatalf("重复扫票应该带回首次核销记录 %d，实际 %d", first.RedemptionID, second.OriginalRedemptionID)
	}
	if second.OriginalScannedAt == "" {
		t.Fatal("重复扫票应该带回首次核销时间")
	}

	// 事实不压掉：两次扫票两条记录。
	n, err := db.Scalar(`SELECT count(*) FROM voucher_redemption WHERE voucher_id = ` + store.Quote(vouchers[0]) + `;`)
	if err != nil {
		t.Fatalf("数核销记录失败：%v", err)
	}
	if n != "2" {
		t.Fatalf("两次扫票应该留两条核销记录，实际 %s 条", n)
	}
	invariantsGreen(t, db)
}

func TestRedeemGroupVoucherConsumesWholeGroup(t *testing.T) {
	db := seeded(t)
	// 种子里的券 7 是按团报价的整团一券（额度 7 人）。
	openWindow(t, db, 7)

	res, err := redemption.New(db).Redeem(redemption.Request{VoucherID: 7, GateID: 1})
	if err != nil {
		t.Fatalf("核销失败：%v", err)
	}
	if res.Result != "success" {
		t.Fatalf("核销结果应该是 success，实际 %s（%s）", res.Result, res.Reason)
	}
	// 按团报价：一次扫票整团进场，额度一次用尽。
	if res.ConsumedQuantity != 7 {
		t.Fatalf("整团一券一次应该消耗 7 个额度，实际 %d", res.ConsumedQuantity)
	}
	invariantsGreen(t, db)
}

func TestRedeemNotYetValidIsFailed(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-future-001", "ALI-RD-FUTURE")
	// 券的有效期在未来的场次日上 —— 没到日子进不了场。

	res, err := redemption.New(db).Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1})
	if err != nil {
		t.Fatalf("核销不该报错：%v", err)
	}
	if res.Result != "failed" {
		t.Fatalf("没到有效期应该是 failed，实际 %s", res.Result)
	}
	if res.Reason != "not_yet_valid" {
		t.Fatalf("原因应该是 not_yet_valid，实际 %s", res.Reason)
	}
	if res.VoucherStatus != "issued" {
		t.Fatalf("没过核销不该改券状态，实际 %s", res.VoucherStatus)
	}
	invariantsGreen(t, db)
}

func TestRedeemPastValidToIsExpired(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-expired-001", "ALI-RD-EXP")
	if err := db.Exec(`UPDATE voucher
                         SET valid_from = now() - interval '2 days',
                             valid_to   = now() - interval '2 days' + (valid_to - valid_from)
                       WHERE id = ` + store.Quote(vouchers[0]) + `;`); err != nil {
		t.Fatalf("调整券有效期失败：%v", err)
	}

	res, err := redemption.New(db).Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1})
	if err != nil {
		t.Fatalf("核销不该报错：%v", err)
	}
	if res.Result != "expired" {
		t.Fatalf("过期应该是 expired，实际 %s", res.Result)
	}
	if res.Reason != "past_valid_to" {
		t.Fatalf("原因应该是 past_valid_to，实际 %s", res.Reason)
	}
	invariantsGreen(t, db)
}

func TestRedeemRefundedVoucherIsRevoked(t *testing.T) {
	db := seeded(t)
	o, vouchers := ticketedOrder(t, db, "rd-revoked-001", "ALI-RD-REV")
	openWindow(t, db, vouchers[0])

	// 走真的退款流程把券退掉（手工改状态会跟明细状态分叉）。
	rs := refund.New(db)
	res0, err := rs.RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-RD-REVOKED",
	})
	if err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}
	if _, err := rs.ApproveRefund(res0.RefundID, "boss@test"); err != nil {
		t.Fatalf("放行退款失败：%v", err)
	}
	if _, err := rs.CompleteRefund(refund.CompleteRequest{RefundID: res0.RefundID, Success: true}); err != nil {
		t.Fatalf("落退款结果失败：%v", err)
	}

	res, err := redemption.New(db).Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1})
	if err != nil {
		t.Fatalf("核销不该报错：%v", err)
	}
	if res.Result != "revoked" {
		t.Fatalf("已退款的券应该是 revoked，实际 %s", res.Result)
	}
	if res.Reason != "voucher_refunded" {
		t.Fatalf("原因应该是 voucher_refunded，实际 %s", res.Reason)
	}
	invariantsGreen(t, db)
}

func TestRedeemOnRefundingOrderIsFailed(t *testing.T) {
	db := seeded(t)
	o, vouchers := ticketedOrder(t, db, "rd-refund-001", "ALI-RD-RF")
	openWindow(t, db, vouchers[0])

	// 先发起退款：订单进入 refunding。
	if _, err := refund.New(db).RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-RD-001",
	}); err != nil {
		t.Fatalf("发起退款失败：%v", err)
	}

	res, err := redemption.New(db).Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1})
	if err != nil {
		t.Fatalf("核销不该报错：%v", err)
	}
	if res.Result != "failed" {
		t.Fatalf("订单在退款中应该是 failed，实际 %s", res.Result)
	}
	if res.Reason != "order_refunding" {
		t.Fatalf("原因应该是 order_refunding，实际 %s", res.Reason)
	}
	invariantsGreen(t, db)
}

func TestRedeemUnknownCodeIsRejected(t *testing.T) {
	db := seeded(t)

	// 票码不存在是调用方的问题，不是扫票的结果 —— 报错，不留记录。
	_, err := redemption.New(db).Redeem(redemption.Request{Code: "NO-SUCH-CODE", GateID: 1})
	if err == nil {
		t.Fatal("票码不存在不该放行")
	}
	if !strings.Contains(err.Error(), "不存在") {
		t.Fatalf("报错要说清是票码不存在，实际：%v", err)
	}
	invariantsGreen(t, db)
}

// collideCode 造一个票码撞车：两个不同源的券用同一个票码。
func collideCode(t *testing.T, db *store.DB, code string) {
	t.Helper()
	// 券 1 属于票付通（supplier 5），券 7 属于另一个源 —— 不同源可以用同一个票码。
	if err := db.Exec(`UPDATE voucher SET code = ` + store.Quote(code) + ` WHERE id = 7;`); err != nil {
		t.Fatalf("造票码撞车失败：%v", err)
	}
}

func TestRedeemAmbiguousCodeIsRejectedWithoutGate(t *testing.T) {
	db := seeded(t)
	collideCode(t, db, "PFT90001")

	// 两个源各发一张票，票码一样 —— 闸机没给的时候不能猜是哪一张。
	_, err := redemption.New(db).Redeem(redemption.Request{Code: "PFT90001"})
	if err == nil {
		t.Fatal("票码不唯一不该放行")
	}
	if !strings.Contains(err.Error(), "不唯一") {
		t.Fatalf("报错要说清是票码不唯一，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRedeemAmbiguousCodeIsNarrowedByGate(t *testing.T) {
	db := seeded(t)
	collideCode(t, db, "PFT90001")
	openWindow(t, db, 1)

	// 闸机 1 属于票付通 —— 票码撞车时按闸机所属的源收窄。
	res, err := redemption.New(db).Redeem(redemption.Request{Code: "PFT90001", GateID: 1})
	if err != nil {
		t.Fatalf("按闸机收窄后不该报错：%v", err)
	}
	if res.Result != "success" {
		t.Fatalf("核销结果应该是 success，实际 %s（%s）", res.Result, res.Reason)
	}
	if res.VoucherID != 1 {
		t.Fatalf("应该核销票付通那张券（id 1），实际 %d", res.VoucherID)
	}
	invariantsGreen(t, db)
}

func TestRedeemRequiresVoucherIDOrCode(t *testing.T) {
	db := seeded(t)

	_, err := redemption.New(db).Redeem(redemption.Request{})
	if err == nil {
		t.Fatal("既没有券 id 也没有票码不该放行")
	}
	if !strings.Contains(err.Error(), "凭证 id 或票码") {
		t.Fatalf("报错要说清缺什么，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestSecondSuccessRedemptionIsBlockedByIndex(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-idx-001", "ALI-RD-IDX")
	openWindow(t, db, vouchers[0])
	if _, err := redemption.New(db).Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1}); err != nil {
		t.Fatalf("核销失败：%v", err)
	}

	// 绕过函数直接插第二条成功核销 —— 唯一索引要挡住它。
	// 「重复入场」不能靠约定防，得靠机制。
	err := db.Exec(`INSERT INTO voucher_redemption (voucher_id, result, consumed_quantity)
                    VALUES (` + store.Quote(vouchers[0]) + `, 'success', 1);`)
	if err == nil {
		t.Fatal("一张券不该能被核销两次")
	}
	if !strings.Contains(err.Error(), "ux_redemption_single_success") {
		t.Fatalf("报错要说清是唯一索引挡住的，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestRedeemThenRefundIsRejected(t *testing.T) {
	db := seeded(t)
	o, vouchers := ticketedOrder(t, db, "rd-then-rf-001", "ALI-RD-THENRF")
	openWindow(t, db, vouchers[0])

	if _, err := redemption.New(db).Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1}); err != nil {
		t.Fatalf("核销失败：%v", err)
	}

	// 票已经用了，整单退款必须被挡下 —— 这条分支现在是真的能走到的了。
	_, err := refund.New(db).RequestRefund(refund.Request{
		OrderID:        o.ID,
		Amount:         payableAmount(t, db, o.ID),
		IdempotencyKey: "RF-RD-AFTER-REDEMPT",
	})
	if err == nil {
		t.Fatal("有已核销的票不该能整单退款")
	}
	if !strings.Contains(err.Error(), "已核销") {
		t.Fatalf("报错要说清是票已核销，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestShowReturnsVoucherAndItsAttempts(t *testing.T) {
	db := seeded(t)
	_, vouchers := ticketedOrder(t, db, "rd-show-001", "ALI-RD-SHOW")
	openWindow(t, db, vouchers[0])
	svc := redemption.New(db)

	if _, err := svc.Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1, DeviceID: "POS-1"}); err != nil {
		t.Fatalf("核销失败：%v", err)
	}
	if _, err := svc.Redeem(redemption.Request{VoucherID: vouchers[0], GateID: 1, DeviceID: "POS-1"}); err != nil {
		t.Fatalf("第二次核销失败：%v", err)
	}

	st, err := svc.Show(vouchers[0])
	if err != nil {
		t.Fatalf("读凭证失败：%v", err)
	}
	if st.Status != "used" {
		t.Fatalf("凭证状态应该是 used，实际 %s", st.Status)
	}
	if st.UsedAt == "" {
		t.Fatal("核销过就该有核销时间")
	}
	if st.UsedChannel == "" {
		t.Fatal("核销过就该记下销售渠道")
	}
	if len(st.Attempts) != 2 {
		t.Fatalf("应该有两条核销记录，实际 %d 条", len(st.Attempts))
	}
	// 从新到旧。
	if st.Attempts[0].Result != "duplicate" {
		t.Fatalf("最新一条应该是 duplicate，实际 %s", st.Attempts[0].Result)
	}
	if st.Attempts[1].Result != "success" {
		t.Fatalf("次新一条应该是 success，实际 %s", st.Attempts[1].Result)
	}
	if st.Attempts[0].DeviceID != "POS-1" {
		t.Fatalf("核销记录应该带设备编号，实际 %q", st.Attempts[0].DeviceID)
	}
	invariantsGreen(t, db)
}
