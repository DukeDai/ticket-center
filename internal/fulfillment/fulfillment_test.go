package fulfillment_test

import (
	"strconv"
	"strings"
	"testing"

	"ticket-center/internal/fulfillment"
	"ticket-center/internal/order"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 履约的行为约定：
//   - 支付金额必须等于订单应付，币种必须一致（差一分钱要当场拦下）；
//   - 渠道流水是支付入账的幂等键，同一笔流水不能记到两张单上；
//   - 预订的源场次来自绑定，不按日期猜；
//   - 票码与持票人一一对应，码数不对就报错；
//   - 订单的履约状态由库里的唯一实现推导，调用方不写；
//   - 全流程走完，全库不变量仍然全绿。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

// priceDate 找一个该变体确实有售价的日期。
//
// 种子数据用 current_date+N 写日期，测试里不能写死日期 —— 隔一天就会挂。
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

// holdersFor 给一个变体凑够实名信息。
func holdersFor(variantID int64, qty int, fields []string) []order.Holder {
	out := make([]order.Holder, 0, qty*len(fields))
	for seq := 1; seq <= qty; seq++ {
		for _, f := range fields {
			out = append(out, order.Holder{
				VariantID: variantID,
				Sequence:  seq,
				FieldCode: f,
				Value:     holderValue(f),
			})
		}
	}
	return out
}

// holderValue 给一个字段编一个像样的值。
//
// dob 的值必须是日期 —— 库里会按 checkout_requirement 的 data_type 校验。
func holderValue(field string) string {
	if field == "dob" {
		return "2018-05-20"
	}
	return "测试值" + field
}

// requiredFields 查某个变体要哪些实名字段（口径在 checkout_requirement 里）。
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

func TestPaymentRecordsAmountAndMovesOrderToPaid(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-pay-001", 9, 2)
	svc := fulfillment.New(db)

	res, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        o.Total,
		Currency:      o.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-TEST-001",
	})
	if err != nil {
		t.Fatalf("支付入账失败：%v", err)
	}
	if !res.Paid {
		t.Fatal("第一次支付入账应该是新记")
	}
	if res.OrderStatus != "paid" {
		t.Fatalf("支付后订单状态应该是 paid，实际 %s", res.OrderStatus)
	}

	// 订单的 status 与 payment_status 必须一起变 —— 只改一个会留下一张
	// 「钱记上了、状态还挂在 awaiting_payment」的单，下一棒会卡住。
	payStatus, err := db.Scalar(`SELECT payment_status FROM sales_order WHERE id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读支付状态失败：%v", err)
	}
	if payStatus != "paid" {
		t.Fatalf("支付状态应该是 paid，实际 %s", payStatus)
	}
	invariantsGreen(t, db)
}

func TestPaymentReplayWithSameProviderTxnIsIdempotent(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-idem-001", 9, 2)
	svc := fulfillment.New(db)

	req := fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        o.Total,
		Currency:      o.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-TEST-IDEM",
	}
	first, err := svc.RecordPayment(req)
	if err != nil {
		t.Fatalf("第一次支付失败：%v", err)
	}
	second, err := svc.RecordPayment(req)
	if err != nil {
		t.Fatalf("重复支付失败：%v", err)
	}
	if second.Paid {
		t.Fatal("同一笔渠道流水重复入账不该再记一笔")
	}
	if second.PaymentID != first.PaymentID {
		t.Fatalf("重复入账应该返回同一条支付记录，实际 %d 与 %d", second.PaymentID, first.PaymentID)
	}

	n, err := db.Scalar(`SELECT count(*) FROM sales_payment WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("数支付记录失败：%v", err)
	}
	if n != "1" {
		t.Fatalf("同一笔流水只该有一条支付记录，实际 %s 条", n)
	}
	invariantsGreen(t, db)
}

func TestPaymentWithWrongAmountIsRejected(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-badamt-001", 9, 2)
	svc := fulfillment.New(db)

	// 少付一分 —— 结算阶段才爆就晚了。
	_, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        "0.01",
		Currency:      o.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-TEST-BAD",
	})
	if err == nil {
		t.Fatal("金额不符不该放行")
	}
	if !strings.Contains(err.Error(), "金额") {
		t.Fatalf("报错要说清是金额不符，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestPaymentWithWrongCurrencyIsRejected(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-badcur-001", 9, 2)
	svc := fulfillment.New(db)

	_, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        o.Total,
		Currency:      "USD",
		Provider:      "alipay",
		ProviderTxnID: "ALI-TEST-CUR",
	})
	if err == nil {
		t.Fatal("币种不符不该放行")
	}
	if !strings.Contains(err.Error(), "币种") {
		t.Fatalf("报错要说清是币种不符，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestConfirmedBookingRequiresSourceBookingId(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-extid-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-EXTID-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if _, err := svc.RequestBooking(bookings[0].BookingID, nil); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}

	// 确认却没给源侧预订号 = 回头找源对账时连「找哪一笔」都做不到。
	_, err = svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:    bookings[0].BookingID,
		Status:       "confirmed",
		IssueVoucher: true,
	})
	if err == nil {
		t.Fatal("确认预订时不给源侧预订号不该放行")
	}
	if !strings.Contains(err.Error(), "源侧预订号") {
		t.Fatalf("报错要说清是缺源侧预订号，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestFulfillmentQuantitiesAreReportedAfterOrderIsFulfilled(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-qty-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-QTY-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if _, err := svc.RequestBooking(bookings[0].BookingID, nil); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}
	if _, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         bookings[0].BookingID,
		Status:            "confirmed",
		ExternalBookingID: "EXT-BK-QTY-001",
		Codes:             []string{"QTY-1", "QTY-2"},
		IssueVoucher:      true,
	}); err != nil {
		t.Fatalf("落预订结果失败：%v", err)
	}

	// 订单已经 fulfilled —— 不再归履约推导管，但「出到第几份」照样要报。
	f, err := svc.ApplyFulfillment(o.ID)
	if err != nil {
		t.Fatalf("推导履约状态失败：%v", err)
	}
	if f.OrderStatus != "fulfilled" {
		t.Fatalf("订单状态应该是 fulfilled，实际 %s", f.OrderStatus)
	}
	if f.DeliveredQty != 2 || f.RequestedQty != 2 {
		t.Fatalf("已出 %d 份 / 应出 %d 份，实际应为 2 / 2", f.DeliveredQty, f.RequestedQty)
	}
}

func TestSecondDistinctChargeOnPaidOrderIsRejected(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-dup-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-DUP-001",
	}); err != nil {
		t.Fatalf("第一次支付失败：%v", err)
	}

	// 又来一笔**不同**的流水 = 重复收款：钱收了两次，库里只记一笔，
	// 这笔钱在对账时凭空消失。幂等只该覆盖「重放同一笔」。
	_, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-DUP-002",
	})
	if err == nil {
		t.Fatal("重复收款不该被当成幂等命中放行")
	}
	if !strings.Contains(err.Error(), "重复收款") {
		t.Fatalf("报错要说清是重复收款，实际：%v", err)
	}

	// 库里仍然只有一笔支付记录。
	n, err := db.Scalar(`SELECT count(*) FROM sales_payment WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("数支付记录失败：%v", err)
	}
	if n != "1" {
		t.Fatalf("应该只有 1 笔支付记录，实际 %s 笔", n)
	}
	invariantsGreen(t, db)
}

func TestSameProviderTxnOnAnotherOrderIsRejected(t *testing.T) {
	db := seeded(t)
	first := placeOrder(t, db, "ff-txn-a", 9, 2)
	second := placeOrder(t, db, "ff-txn-b", 9, 2)
	svc := fulfillment.New(db)

	_, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       first.ID,
		Method:        "alipay",
		Amount:        first.Total,
		Currency:      first.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-SHARED-001",
	})
	if err != nil {
		t.Fatalf("第一张单支付失败：%v", err)
	}

	// 同一笔流水记到另一张单上：对账时两笔对不上，必须当场拦下。
	_, err = svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       second.ID,
		Method:        "alipay",
		Amount:        second.Total,
		Currency:      second.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-SHARED-001",
	})
	if err == nil {
		t.Fatal("同一笔流水记到另一张单上不该放行")
	}
	if !strings.Contains(err.Error(), "渠道流水") {
		t.Fatalf("报错要说清是渠道流水冲突，实际：%v", err)
	}
}

func TestBookingUsesBoundSupplierSession(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-book-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       o.ID,
		Method:        "alipay",
		Amount:        o.Total,
		Currency:      o.Currency,
		Provider:      "alipay",
		ProviderTxnID: "ALI-BOOK-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}

	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if len(bookings) != 1 {
		t.Fatalf("一张单一条明细应该建一条预订，实际 %d 条", len(bookings))
	}
	if !bookings[0].Created {
		t.Fatal("第一次建预订应该是新建")
	}

	// 源场次必须来自 product_session_source 的绑定，不按日期猜。
	supplierSession, err := db.Scalar(`SELECT supplier_session_id::text FROM booking WHERE id = ` +
		store.Quote(bookings[0].BookingID) + `;`)
	if err != nil {
		t.Fatalf("读预订失败：%v", err)
	}
	if supplierSession == "" {
		t.Fatal("预订必须绑到源场次")
	}
	bound, err := db.Scalar(`SELECT count(*) FROM product_session_source
                              WHERE product_session_id = (SELECT session_id FROM sales_order_item
                                                         WHERE order_id = ` + store.Quote(o.ID) + `)
                                AND supplier_product_id = (SELECT supplier_product_id FROM sales_order_item
                                                         WHERE order_id = ` + store.Quote(o.ID) + `)
                                AND supplier_session_id::text = ` + store.Quote(supplierSession) + `;`)
	if err != nil {
		t.Fatalf("查绑定失败：%v", err)
	}
	if bound != "1" {
		t.Fatal("预订的源场次必须绑在该明细的规范场次上")
	}

	// 幂等：再跑一次不重复建。
	again, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("重复建预订失败：%v", err)
	}
	if len(again) != 1 || again[0].Created {
		t.Fatal("重复建预订不该产生新预订")
	}
	invariantsGreen(t, db)
}

func TestIssueVoucherRejectsWrongCodeCount(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-code-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-CODE-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	b := bookings[0].BookingID

	if _, err := svc.RequestBooking(b, map[string]any{"x": 1}); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}

	// 要 2 张券只给 1 个票码 —— 不拿一张券顶两个人的票。
	_, err = svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         b,
		Status:            "confirmed",
		ExternalBookingID: "EXT-BK-CODE-001",
		Codes:             []string{"ONLY-ONE"},
		IssueVoucher:      true,
	})
	if err == nil {
		t.Fatal("票码数与持票人数不符不该放行")
	}
	if !strings.Contains(err.Error(), "票码") {
		t.Fatalf("报错要说清是票码数不对，实际：%v", err)
	}
	invariantsGreen(t, db)
}

func TestFullFulfillmentPathReachesFulfilled(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-full-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-FULL-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	b := bookings[0].BookingID

	req, err := svc.RequestBooking(b, map[string]any{"resource": "x"})
	if err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}
	if req.AttemptNo != 1 {
		t.Fatalf("第一次尝试的编号应该是 1，实际 %d", req.AttemptNo)
	}

	// 归档一次尝试（硬约束 8：原始报文必须归档）。
	if _, err := svc.RecordAttempt(fulfillment.AttemptRequest{
		BookingID:  b,
		Request:    map[string]any{"resource": "x"},
		Response:   map[string]any{"status": "OK"},
		HTTPStatus: 200,
		LatencyMS:  120,
	}); err != nil {
		t.Fatalf("归档尝试失败：%v", err)
	}

	// 源侧确认 → 出券（票码与持票人一一对应）。
	done, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         b,
		Status:            "confirmed",
		ExternalBookingID: "EXT-BK-001",
		Response:          map[string]any{"bookingRef": "EXT-BK-001"},
		Codes:             []string{"EXT-CODE-001", "EXT-CODE-002"},
		IssueVoucher:      true,
	})
	if err != nil {
		t.Fatalf("落预订结果失败：%v", err)
	}
	if done.Status != "confirmed" {
		t.Fatalf("预订状态应该是 confirmed，实际 %s", done.Status)
	}
	if done.VoucherCount != 2 {
		t.Fatalf("2 人应该发 2 张券，实际 %d 张", done.VoucherCount)
	}
	if done.OrderStatus != "fulfilled" {
		t.Fatalf("订单状态应该是 fulfilled，实际 %s", done.OrderStatus)
	}

	// 出券幂等：再来一次不重复发。
	vouchers, err := svc.IssueVoucher(b, []string{"EXT-CODE-001", "EXT-CODE-002"}, nil)
	if err != nil {
		t.Fatalf("重复出券失败：%v", err)
	}
	if len(vouchers) != 2 {
		t.Fatalf("应该还是 2 张券，实际 %d 张", len(vouchers))
	}
	for _, v := range vouchers {
		if v.Created {
			t.Fatal("重复出券不该新发")
		}
	}

	// 明细状态必须是 ticketed，券的权益一人一份。
	itemStatus, err := db.Scalar(`SELECT status FROM sales_order_item WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读明细状态失败：%v", err)
	}
	if itemStatus != "ticketed" {
		t.Fatalf("明细状态应该是 ticketed，实际 %s", itemStatus)
	}
	ent, err := db.Scalar(`SELECT count(*) FROM voucher_entitlement ve
                            JOIN voucher v ON v.id = ve.voucher_id
                           WHERE v.order_id = ` + store.Quote(o.ID) + `
                             AND ve.entitlement_type = 'admission'
                             AND ve.quantity = 1;`)
	if err != nil {
		t.Fatalf("读权益失败：%v", err)
	}
	if ent != "2" {
		t.Fatalf("按人计价应该 2 份一人一份的权益，实际 %s 条", ent)
	}
	invariantsGreen(t, db)
}

func TestConfirmedWithoutTicketStaysConfirmedUntilTicketsArrive(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-late-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-LATE-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	b := bookings[0].BookingID

	if _, err := svc.RequestBooking(b, nil); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}

	// 源先确认、票后到。
	done, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         b,
		Status:            "confirmed",
		ExternalBookingID: "EXT-BK-LATE-001",
		IssueVoucher:      false,
	})
	if err != nil {
		t.Fatalf("落预订结果失败：%v", err)
	}
	if done.OrderStatus != "confirmed" {
		t.Fatalf("票还没到，订单状态应该是 confirmed，实际 %s", done.OrderStatus)
	}
	if done.VoucherCount != 0 {
		t.Fatalf("不出券时不该发券，实际发了 %d 张", done.VoucherCount)
	}

	// 票到了 → 出券 → fulfilled。
	if _, err := svc.IssueVoucher(b, []string{"LATE-1", "LATE-2"}, nil); err != nil {
		t.Fatalf("出券失败：%v", err)
	}
	f, err := svc.ApplyFulfillment(o.ID)
	if err != nil {
		t.Fatalf("推导履约状态失败：%v", err)
	}
	if f.OrderStatus != "fulfilled" {
		t.Fatalf("票到齐后订单状态应该是 fulfilled，实际 %s", f.OrderStatus)
	}
	if f.FulfillmentStatus != "fulfilled" {
		t.Fatalf("履约口径应该是 fulfilled，实际 %s", f.FulfillmentStatus)
	}
	if f.DeliveredQty != 2 || f.RequestedQty != 2 {
		t.Fatalf("已出 %d 份 / 应出 %d 份，实际应为 2 / 2", f.DeliveredQty, f.RequestedQty)
	}
	invariantsGreen(t, db)
}

func TestOneItemFailsOtherTicksOutIsPartiallyFulfilled(t *testing.T) {
	db := seeded(t)
	svc := fulfillment.New(db)
	date := priceDate(t, db, 12)

	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "ff-partial-001",
		Items: []order.Item{
			{VariantID: 12, Quantity: 1, VisitDate: date},
			{VariantID: 13, Quantity: 1, VisitDate: date},
		},
		Holders: append(
			holdersFor(12, 1, requiredFields(t, db, 12)),
			holdersFor(13, 1, requiredFields(t, db, 13))...),
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}
	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-PART-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if len(bookings) != 2 {
		t.Fatalf("两条明细应该建两条预订，实际 %d 条", len(bookings))
	}

	for _, b := range bookings {
		if _, err := svc.RequestBooking(b.BookingID, nil); err != nil {
			t.Fatalf("发起预订失败：%v", err)
		}
	}

	// 第一条确认出券，第二条失败。
	if _, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         bookings[0].BookingID,
		Status:            "confirmed",
		ExternalBookingID: "EXT-BK-PART-001",
		Codes:             []string{"PART-CODE-1"},
		IssueVoucher:      true,
	}); err != nil {
		t.Fatalf("第一条落结果失败：%v", err)
	}
	if _, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:    bookings[1].BookingID,
		Status:       "failed",
		ErrorCode:    "STOCK_LOCKED",
		ErrorMessage: "库存被占位",
	}); err != nil {
		t.Fatalf("第二条落结果失败：%v", err)
	}

	f, err := svc.ApplyFulfillment(o.ID)
	if err != nil {
		t.Fatalf("推导履约状态失败：%v", err)
	}
	if f.OrderStatus != "partially_fulfilled" {
		t.Fatalf("一条出票一条失败，订单状态应该是 partially_fulfilled，实际 %s", f.OrderStatus)
	}
	if f.FulfillmentStatus != "partial" {
		t.Fatalf("履约口径应该是 partial，实际 %s", f.FulfillmentStatus)
	}

	// 失败的那条重报：预订回 pending，订单保持 partially_fulfilled。
	retried, err := svc.RetryBooking(bookings[1].BookingID, nil)
	if err != nil {
		t.Fatalf("失败重报失败：%v", err)
	}
	if retried.Status != "pending" {
		t.Fatalf("重报后预订状态应该是 pending，实际 %s", retried.Status)
	}
	after, err := svc.ApplyFulfillment(o.ID)
	if err != nil {
		t.Fatalf("推导履约状态失败：%v", err)
	}
	if after.OrderStatus != "partially_fulfilled" {
		t.Fatalf("重报后订单状态应保持 partially_fulfilled，实际 %s", after.OrderStatus)
	}
	invariantsGreen(t, db)
}

func TestShowReportsFulfillmentState(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-show-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-SHOW-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if _, err := svc.RequestBooking(bookings[0].BookingID, nil); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}

	st, err := svc.Show(o.ID)
	if err != nil {
		t.Fatalf("读订单失败：%v", err)
	}
	if st.Status != "booking_pending" {
		t.Fatalf("建了预订后订单状态应该是 booking_pending，实际 %s", st.Status)
	}
	if st.PaymentStatus != "paid" {
		t.Fatalf("支付状态应该是 paid，实际 %s", st.PaymentStatus)
	}
	if len(st.Items) != 1 {
		t.Fatalf("应该有 1 条明细，实际 %d 条", len(st.Items))
	}
	if len(st.Bookings) != 1 {
		t.Fatalf("应该有 1 条预订，实际 %d 条", len(st.Bookings))
	}
	if st.Bookings[0].Status != "requested" {
		t.Fatalf("预订状态应该是 requested，实际 %s", st.Bookings[0].Status)
	}
	if st.Bookings[0].AttemptCount != 1 {
		t.Fatalf("应该尝试过 1 次，实际 %d 次", st.Bookings[0].AttemptCount)
	}
}

func TestRecordAttemptRequiresRequestFirst(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-attempt-001", 9, 2)
	svc := fulfillment.New(db)

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-ATT-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}

	// 没发起过请求就归档尝试 —— 说明调用顺序错了，当场报错。
	_, err = svc.RecordAttempt(fulfillment.AttemptRequest{BookingID: bookings[0].BookingID})
	if err == nil {
		t.Fatal("没发起请求就归档尝试不该放行")
	}
	if !strings.Contains(err.Error(), "发起") {
		t.Fatalf("报错要说清是还没发起请求，实际：%v", err)
	}
}

func TestNonDecimalAmountIsRejectedBeforeHittingDB(t *testing.T) {
	db := seeded(t)
	o := placeOrder(t, db, "ff-deci-001", 9, 2)
	svc := fulfillment.New(db)

	_, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: "一千二", Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-DECI-001",
	})
	if err == nil {
		t.Fatal("非十进制金额不该放行")
	}
	if !strings.Contains(err.Error(), "十进制") {
		t.Fatalf("报错要说清是十进制数，实际：%v", err)
	}
}

// comboHolders 家庭套餐的实名：成人成分 2 人（姓名 + 证件），儿童成分 1 人（姓名 + 生日）。
func comboHolders() []order.Holder {
	return []order.Holder{
		{VariantID: 9, Sequence: 1, FieldCode: "holder_name", Value: "测试成人一"},
		{VariantID: 9, Sequence: 1, FieldCode: "id_number", Value: "110101199001011234"},
		{VariantID: 9, Sequence: 2, FieldCode: "holder_name", Value: "测试成人二"},
		{VariantID: 9, Sequence: 2, FieldCode: "id_number", Value: "110101199001011235"},
		{VariantID: 10, Sequence: 1, FieldCode: "holder_name", Value: "测试儿童"},
		{VariantID: 10, Sequence: 1, FieldCode: "dob", Value: "2018-05-20"},
	}
}

// comboVariantID 取种子里那个家庭套餐组合变体的 id。
func comboVariantID(t *testing.T, db *store.DB) int64 {
	t.Helper()
	combo, err := db.Scalar(`SELECT id::text FROM product_variant
	                          WHERE variant_key = 'family:2adult:1child:studio_only';`)
	if err != nil {
		t.Fatalf("查组合变体失败：%v", err)
	}
	if combo == "" {
		t.Fatal("种子里没有家庭套餐这个组合变体")
	}
	id, err := strconv.ParseInt(combo, 10, 64)
	if err != nil {
		t.Fatalf("组合变体 id 不是整数：%v", err)
	}
	return id
}

// placeComboOrderWithBooking 下单 → 支付 → 建预订，返回订单 id 与那条预订 id。
//
// 组合套餐「一个源 SKU 一条预订」这件事本身有测试；
// 这里把它做成前置步骤，是为了让不变量 88 的反向测试能拿到
// 一个真实走到「订单已进预订阶段」的形状。
func placeComboOrderWithBooking(t *testing.T, db *store.DB, key string) (int64, int64) {
	t.Helper()
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: key,
		Items:          []order.Item{{VariantID: comboVariantID(t, db), Quantity: 1, VisitDate: priceDate(t, db, 9)}},
		Holders:        comboHolders(),
	})
	if err != nil {
		t.Fatalf("组合套餐下单失败：%v", err)
	}
	if _, err := fulfillment.New(db).RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-" + key,
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}
	bookings, err := fulfillment.New(db).CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if len(bookings) != 1 {
		t.Fatalf("组合套餐应该只有 1 条预订，实际 %d 条", len(bookings))
	}
	return o.ID, bookings[0].BookingID
}

// TestComboBookingIsOnePerSourceSKU 组合套餐的预订单位是**源 SKU**，不是成分。
//
// 参数化源（自由行那种「一张通票、人群是购买时选的一档」）里，
// 成人票与儿童票是同一个源 SKU。按成分建预订就是同一个源 SKU 在同一个源场次上
// 订了两次：源侧看到两张订单单，我们这边一条客户订单对两个源单号，对账对不上。
//
// 所以这里断言的是：**一个源 SKU 一条预订**，成分的拆分留在预订里，
// 出券时再按成分把票码和持票人分下去。
func TestComboBookingIsOnePerSourceSKU(t *testing.T) {
	db := seeded(t)
	svc := fulfillment.New(db)

	comboID := comboVariantID(t, db)

	date := priceDate(t, db, 9)
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "ff-combo-001",
		Items:          []order.Item{{VariantID: comboID, Quantity: 1, VisitDate: date}},
		Holders:        comboHolders(),
	})
	if err != nil {
		t.Fatalf("组合套餐下单失败：%v", err)
	}

	if _, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID: o.ID, Method: "alipay", Amount: o.Total, Currency: o.Currency,
		Provider: "alipay", ProviderTxnID: "ALI-COMBO-001",
	}); err != nil {
		t.Fatalf("支付失败：%v", err)
	}

	bookings, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("建预订失败：%v", err)
	}
	if len(bookings) != 1 {
		t.Fatalf("组合套餐应该只有 1 条预订（同一个源 SKU 只订一次），实际 %d 条", len(bookings))
	}
	b := bookings[0].BookingID

	// 建预订是幂等的：重放一次还是那一条。
	again, err := svc.CreateBookings(o.ID)
	if err != nil {
		t.Fatalf("重放建预订失败：%v", err)
	}
	if len(again) != 1 || again[0].BookingID != b {
		t.Fatalf("重放建预订不该新建：期望还是 %d，实际 %d 条", b, len(again))
	}

	// 这一条预订覆盖两个成分、3 份入场（成人 2 份 + 儿童 1 份）。
	comps, err := db.Scalar(`SELECT count(*)::text FROM fn_booking_components(` +
		store.Quote(b) + `);`)
	if err != nil {
		t.Fatalf("读预订覆盖的成分失败：%v", err)
	}
	if comps != "2" {
		t.Fatalf("这条预订应该覆盖 2 个成分，实际 %s 个", comps)
	}
	adm, err := db.Scalar(`SELECT COALESCE(sum(c.admission_quantity), 0)::int::text
	                        FROM fn_booking_components(` + store.Quote(b) + `) c;`)
	if err != nil {
		t.Fatalf("读预订的入场份数失败：%v", err)
	}
	if adm != "3" {
		t.Fatalf("这条预订应该覆盖 3 份入场（2 成人 + 1 儿童），实际 %s 份", adm)
	}

	// 出券：票码与持票人一一对应 → 3 张
	if _, err := svc.RequestBooking(b, map[string]any{"resource": "combo"}); err != nil {
		t.Fatalf("发起预订失败：%v", err)
	}
	done, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         b,
		Status:            "confirmed",
		ExternalBookingID: "EXT-COMBO-001",
		Response:          map[string]any{"bookingRef": "EXT-COMBO-001"},
		Codes:             []string{"COMBO-CODE-001", "COMBO-CODE-002", "COMBO-CODE-003"},
		IssueVoucher:      true,
	})
	if err != nil {
		t.Fatalf("落预订结果失败：%v", err)
	}
	if done.VoucherCount != 3 {
		t.Fatalf("家庭套餐应该发 3 张券（2 成人 + 1 儿童），实际 %d 张", done.VoucherCount)
	}
	if done.OrderStatus != "fulfilled" {
		t.Fatalf("订单状态应该是 fulfilled，实际 %s", done.OrderStatus)
	}

	// 持票人按**成分**归位：儿童那张必须是儿童的名字。
	rows, err := db.Query(`SELECT pv.variant_key, v.holder_snapshot->>'holder_name'
	                         FROM voucher v
	                         JOIN product_variant pv ON pv.id = v.product_variant_id
	                        WHERE v.order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读券的持票人失败：%v", err)
	}
	holders := map[string]string{}
	for _, r := range rows {
		holders[r[0]] = r[1]
	}
	if len(holders) != 2 {
		t.Fatalf("三张券应该落在两个成分上，实际 %d 个：%v", len(holders), rows)
	}
	if holders["adult:1d:studio_only"] != "测试成人一" && holders["adult:1d:studio_only"] != "测试成人二" {
		t.Fatalf("成人券的持票人应该是成人的名字，实际 %q", holders["adult:1d:studio_only"])
	}
	if holders["child:1d:studio_only"] != "测试儿童" {
		t.Fatalf("儿童券的持票人应该是儿童的名字，实际 %q", holders["child:1d:studio_only"])
	}

	invariantsGreen(t, db)
}

// TestInvariant88CatchesUncoveredComponent 不变量 88 必须真的能抓到漏订。
//
// 门禁最怕的不是红，是「一直绿，但绿得没有意义」。
// 88 的第一半曾经写成「不存在一个被预订覆盖的成分」——
// 只要有一个成分被覆盖就放过：家庭套餐订了成人没订儿童，照样绿灯。
//
// 这种洞光读视图看不出来，只有反着验才知道它在不在。
// 两个场景都要盖：
//   - 部分漏订：成分有一个没被预订覆盖（老洞就在这里）；
//   - 悬空预订：订了个谁也不要的源 SKU。
func TestInvariant88CatchesUncoveredComponent(t *testing.T) {
	db := seeded(t)

	orderID, _ := placeComboOrderWithBooking(t, db, "ff-combo-gap-001")
	itemID, err := db.Scalar(`SELECT id::text FROM sales_order_item
	                           WHERE order_id = ` + store.Quote(orderID) + `;`)
	if err != nil {
		t.Fatalf("查明细失败：%v", err)
	}
	if itemID == "" {
		t.Fatalf("订单 %d 没有明细", orderID)
	}

	// 正常形状下 88 是绿的。
	if v := invariantActual(t, db, 88); v != 0 {
		t.Fatalf("订单刚建好预订时不该有违规，实际 %d", v)
	}

	// 场景一：某个成分没有对应的预订。
	// 加一条「这个源 SKU 没有预订覆盖」的成分行 —— 源 SKU 从数据里挑，
	// 不写死 id（种子的 id 会变）。
	if err := db.Exec(`INSERT INTO sales_order_item_source
	                     (order_item_id, component_variant_id, supplier_variant_id,
	                      supplier_product_id, supplier_id, product_session_id,
	                      supplier_session_id, ticket_type_id, quantity,
	                      admission_quantity, unit_cost, currency)
	                   SELECT s.order_item_id, s.component_variant_id, sv.id,
	                          s.supplier_product_id, s.supplier_id, s.product_session_id,
	                          s.supplier_session_id, s.ticket_type_id, 1,
	                          1, s.unit_cost, s.currency
	                     FROM sales_order_item_source s
	                     JOIN supplier_variant sv ON sv.supplier_product_id = s.supplier_product_id
	                    WHERE s.order_item_id = ` + store.Quote(itemID) + `
	                      AND NOT EXISTS (SELECT 1 FROM sales_order_item_source s2
	                                       WHERE s2.order_item_id = s.order_item_id
	                                         AND s2.supplier_variant_id = sv.id)
	                    LIMIT 1;`); err != nil {
		t.Fatalf("造漏订成分失败：%v", err)
	}

	if v := invariantActual(t, db, 88); v == 0 {
		t.Fatalf("漏订了一个成分，88 必须报 FAIL，实际还是 0")
	}
}

// TestInvariant88CatchesDanglingBooking 悬空预订也要被抓到。
//
// 订了个谁也不要的源 SKU = 白花源侧的钱。
// 这一半和上一半是两头：上一半看「成分有没有被覆盖」，这一半看「预订有没有被需要」。
func TestInvariant88CatchesDanglingBooking(t *testing.T) {
	db := seeded(t)

	orderID, _ := placeComboOrderWithBooking(t, db, "ff-combo-dangle-001")
	itemID, err := db.Scalar(`SELECT id::text FROM sales_order_item
	                           WHERE order_id = ` + store.Quote(orderID) + `;`)
	if err != nil {
		t.Fatalf("查明细失败：%v", err)
	}

	if v := invariantActual(t, db, 88); v != 0 {
		t.Fatalf("订单刚建好预订时不该有违规，实际 %d", v)
	}

	// 造一条没人要的预订：源 SKU 在这张明细的成分里根本没出现过。
	if err := db.Exec(`INSERT INTO booking
	                     (booking_no, order_id, order_item_id, supplier_id, supplier_product_id,
	                      supplier_variant_id, supplier_session_id, status, idempotency_key)
	                   SELECT 'PROBE-DANGLE-001', oi.order_id, oi.id, s.supplier_id, s.supplier_product_id,
	                          sv.id, s.supplier_session_id, 'pending', 'PROBE-DANGLE-001'
	                     FROM sales_order_item_source s
	                     JOIN sales_order_item oi ON oi.id = s.order_item_id
	                     JOIN sales_order o ON o.id = oi.order_id
	                     JOIN supplier_variant sv ON sv.supplier_product_id = s.supplier_product_id
	                    WHERE oi.id = ` + store.Quote(itemID) + `
	                      AND NOT EXISTS (SELECT 1 FROM sales_order_item_source s2
	                                       WHERE s2.order_item_id = oi.id
	                                         AND s2.supplier_variant_id = sv.id)
	                    LIMIT 1;`); err != nil {
		t.Fatalf("造悬空预订失败：%v", err)
	}

	if v := invariantActual(t, db, 88); v == 0 {
		t.Fatalf("悬空预订必须报 FAIL，实际还是 0")
	}
}

// invariantActual 读某条不变量的 actual（违规条数）。
func invariantActual(t *testing.T, db *store.DB, seq int) int {
	t.Helper()
	s, err := db.Scalar(`SELECT actual::text FROM v_invariant_checks WHERE seq = ` +
		strconv.Itoa(seq) + `;`)
	if err != nil {
		t.Fatalf("读不变量 %d 失败：%v", seq, err)
	}
	if s == "" {
		t.Fatalf("没有不变量 %d", seq)
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		t.Fatalf("不变量 %d 的 actual 不是整数：%q", seq, s)
	}
	return n
}
