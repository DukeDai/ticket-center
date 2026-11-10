package reassign_test

import (
	"strings"
	"testing"

	"ticket-center/internal/order"
	"ticket-center/internal/reassign"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 改派的行为约定：
//   - 改派 = 重新选源 + 重新定价，源与价都来自定价函数的唯一实现；
//   - 只发生在未收款、还没预订过的单张形态上，其余情况当场报错；
//   - 改一处必须三处一起改：明细、成分行（履约按它建预订）、库存预占；
//   - 重复改派不产生第二笔留痕（幂等）；
//   - 改派走完之后全库不变量仍然全绿。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

// adultVariant 是那个有两个候选源的可售单元（改派要有地方可换）。
const adultVariant = 1

// placeAdult 下单一张成人票，返回订单号与明细行号。
func placeAdult(t *testing.T, db *store.DB, idem, date string) (int64, int64) {
	t.Helper()
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: idem,
		Items:          []order.Item{{VariantID: adultVariant, Quantity: 1, VisitDate: date}},
		Holders: []order.Holder{
			{VariantID: adultVariant, Sequence: 1, FieldCode: "holder_name", Value: "改派测试"},
			{VariantID: adultVariant, Sequence: 1, FieldCode: "id_number", Value: "110101199005055678"},
		},
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}
	itemID, err := db.Scalar(`SELECT id::text FROM sales_order_item WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读明细失败：%v", err)
	}
	return o.ID, atoi(t, itemID)
}

// cheaperAlternative 把第二名候选源的报价砍一半，让它变成第一名。
//
// 换到哪个源不是测试自己定的：是选源的唯一实现（fn_route_candidates）
// 排出来的第二名。这里只改世界，不改结论。
func cheaperAlternative(t *testing.T, db *store.DB, date string) {
	t.Helper()
	err := db.Exec(`UPDATE supplier_price_calendar
                      SET net_price      = round(net_price / 2, 2),
                          supplier_price = round(supplier_price / 2, 2)
                    WHERE supplier_variant_id = (
                            SELECT rc.supplier_variant_id
                              FROM fn_route_candidates(` + store.Quote(adultVariant) + `, ` +
                            store.Quote(date) + `::date, 1, fn_price_row_currency(1)) rc
                             WHERE rc.route_rank = 2)
                      AND product_variant_id = ` + store.Quote(adultVariant) + `
                      AND date = ` + store.Quote(date) + `::date;`)
	if err != nil {
		t.Fatalf("改源价失败：%v", err)
	}
	if _, err := db.Scalar(`SELECT fn_reprice_rows()::text;`); err != nil {
		t.Fatalf("重算售价行失败：%v", err)
	}
	if _, err := db.Scalar(`SELECT fn_refresh_read_models()::text;`); err != nil {
		t.Fatalf("刷新读模型失败：%v", err)
	}
}

func scalar(t *testing.T, db *store.DB, sql string) string {
	t.Helper()
	v, err := db.Scalar(sql)
	if err != nil {
		t.Fatalf("查询失败：%v", err)
	}
	return v
}

func atoi(t *testing.T, s string) int64 {
	t.Helper()
	var n int64
	for _, c := range s {
		if c < '0' || c > '9' {
			t.Fatalf("不是整数：%q", s)
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

func TestReassignSwitchesSourceAndReprices(t *testing.T) {
	db := seeded(t)
	date := scalar(t, db, `SELECT date::text FROM price_calendar
	                         WHERE product_variant_id = `+store.Quote(adultVariant)+`
	                           AND status = 'active'
	                         ORDER BY date LIMIT 1;`)
	orderID, itemID := placeAdult(t, db, "test-reassign-001", date)

	beforeSP := scalar(t, db, `SELECT supplier_product_id::text FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	beforePrice := scalar(t, db, `SELECT unit_price::text FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	beforeTotal := scalar(t, db, `SELECT total::text FROM sales_order WHERE id = `+store.Quote(orderID)+`;`)

	// 读侧先看见「这条明细跟世界对不上了」。
	cheaperAlternative(t, db, date)

	cands, err := reassign.New(db).Candidates()
	if err != nil {
		t.Fatalf("读待改派清单失败：%v", err)
	}
	found := false
	for _, c := range cands {
		if c.OrderItemID == itemID {
			found = true
			if c.StaleReason == "" {
				t.Fatal("待改派明细必须说清差在哪")
			}
			if c.NewSupplierProductID == c.CurrentSupplierProductID &&
				c.NewUnitPrice == c.CurrentUnitPrice {
				t.Fatal("世界已经变了，待改派清单却说不出差在哪")
			}
		}
	}
	if !found {
		t.Fatalf("明细 %d 应该出现在待改派清单里", itemID)
	}

	res, err := reassign.New(db).Reassign(orderID, itemID, "源侧降价了")
	if err != nil {
		t.Fatalf("改派失败：%v", err)
	}
	if res.Outcome != "reassigned" {
		t.Fatalf("改派结果应该是 reassigned，实际 %s", res.Outcome)
	}
	if res.NewSupplierProductID == res.PreviousSupplierProductID {
		t.Fatalf("改派应该换源，实际还是源商品 %d", res.PreviousSupplierProductID)
	}
	if res.NewUnitPrice == res.PreviousUnitPrice {
		t.Fatalf("改派应该重新定价，单价没动（%s）", res.PreviousUnitPrice)
	}

	// 明细：单价换成新的那一份。
	gotPrice := scalar(t, db, `SELECT unit_price::text FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	if gotPrice != res.NewUnitPrice {
		t.Fatalf("明细单价 %s 与改派结果 %s 不一致", gotPrice, res.NewUnitPrice)
	}

	// 成分行：履约按它建预订，它必须跟明细说同一个源。
	srcSP := scalar(t, db, `SELECT supplier_product_id::text FROM sales_order_item_source WHERE order_item_id = `+store.Quote(itemID)+`;`)
	if atoi(t, srcSP) != res.NewSupplierProductID {
		t.Fatalf("成分行源商品 %s 与明细 %d 不一致（按 A 源的价格卖、按 B 源出票）", srcSP, res.NewSupplierProductID)
	}

	// 库存预占：钉在旧源上就是「按新源卖、按旧源占库存」。
	holdSP := scalar(t, db, `SELECT supplier_id::text FROM inventory_hold WHERE order_id = `+store.Quote(orderID)+`;`)
	itemSID := scalar(t, db, `SELECT supplier_id::text FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	if holdSP != itemSID {
		t.Fatalf("库存预占的供应商 %s 与明细 %s 不一致（预占必须跟着源走）", holdSP, itemSID)
	}

	// 订单的钱跟着明细走。
	afterTotal := scalar(t, db, `SELECT total::text FROM sales_order WHERE id = `+store.Quote(orderID)+`;`)
	if afterTotal == beforeTotal {
		t.Fatalf("改派后订单合计应该变（原来 %s）", beforeTotal)
	}
	if afterTotal != res.NewTotalPrice {
		t.Fatalf("订单合计 %s 与改派结果 %s 不一致", afterTotal, res.NewTotalPrice)
	}

	// 留痕：一笔一档，旧值在里面。
	trail := scalar(t, db, `SELECT jsonb_array_length(detail_snapshot -> 'reassignments')::text
	                         FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	if trail != "1" {
		t.Fatalf("改派一次应该留一条痕，实际 %s 条", trail)
	}
	fromSP := scalar(t, db, `SELECT (detail_snapshot -> 'reassignments' -> 0 ->> 'from_supplier_product_id')
	                         FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	if fromSP != beforeSP {
		t.Fatalf("留痕里的原源 %s 与改派前的源 %s 不一致", fromSP, beforeSP)
	}

	if res.NewUnitPrice == beforePrice {
		t.Fatalf("改派后的单价 %s 与改派前 %s 一样（源价变了却没重新定价）", res.NewUnitPrice, beforePrice)
	}

	// 不变量必须仍然全绿。
	bad := scalar(t, db, `SELECT count(*)::text FROM v_invariant_checks WHERE NOT passed;`)
	if bad != "0" {
		names := scalar(t, db, `SELECT string_agg(check_name || '（' || actual || '）', '；')
		                         FROM v_invariant_checks WHERE NOT passed;`)
		t.Fatalf("改派之后不变量必须全绿：%s", names)
	}
}

func TestReassignTwiceIsIdempotent(t *testing.T) {
	db := seeded(t)
	date := scalar(t, db, `SELECT date::text FROM price_calendar
	                         WHERE product_variant_id = `+store.Quote(adultVariant)+`
	                           AND status = 'active'
	                         ORDER BY date LIMIT 1;`)
	orderID, itemID := placeAdult(t, db, "test-reassign-idem-001", date)

	cheaperAlternative(t, db, date)

	svc := reassign.New(db)
	if _, err := svc.Reassign(orderID, itemID, "第一次"); err != nil {
		t.Fatalf("第一次改派失败：%v", err)
	}
	res, err := svc.Reassign(orderID, itemID, "第二次")
	if err != nil {
		t.Fatalf("第二次改派失败：%v", err)
	}
	if res.Outcome != "no_change" {
		t.Fatalf("重复改派应该是 no_change，实际 %s", res.Outcome)
	}
	trail := scalar(t, db, `SELECT jsonb_array_length(detail_snapshot -> 'reassignments')::text
	                         FROM sales_order_item WHERE id = `+store.Quote(itemID)+`;`)
	if trail != "1" {
		t.Fatalf("重复改派不该再记一笔留痕，实际 %s 条", trail)
	}
}

func TestReassignRefusesPaidOrder(t *testing.T) {
	db := seeded(t)
	date := scalar(t, db, `SELECT date::text FROM price_calendar
	                         WHERE product_variant_id = `+store.Quote(adultVariant)+`
	                           AND status = 'active'
	                         ORDER BY date LIMIT 1;`)
	orderID, itemID := placeAdult(t, db, "test-reassign-paid-001", date)

	total := scalar(t, db, `SELECT total::text FROM sales_order WHERE id = `+store.Quote(orderID)+`;`)
	if _, err := db.Scalar(`SELECT fn_record_payment(` + store.Quote(orderID) +
		`, 'alipay', ` + store.Quote(total) + `::numeric, 'CNY', 'alipay', 'REASSIGN-PAID-001')::text;`); err != nil {
		t.Fatalf("支付失败：%v", err)
	}

	_, err := reassign.New(db).Reassign(orderID, itemID, "收了钱还想换源")
	if err == nil {
		t.Fatal("已收款的订单不许改派")
	}
	if !strings.Contains(err.Error(), "支付") {
		t.Fatalf("报错要说清是支付的问题，实际：%v", err)
	}
}

func TestReassignRefusesBookedLine(t *testing.T) {
	db := seeded(t)
	date := scalar(t, db, `SELECT date::text FROM price_calendar
	                         WHERE product_variant_id = `+store.Quote(adultVariant)+`
	                           AND status = 'active'
	                         ORDER BY date LIMIT 1;`)
	orderID, itemID := placeAdult(t, db, "test-reassign-booked-001", date)

	// 已经发到源侧的预订是事实：改派不能靠换源把它抹掉。
	//
	// 预订按成分行的源建（不变量 88 的双向对齐），
	// 所以这一行必须与成分行的源变体 / 源场次完全一致 ——
	// 对不上就是「订了没人要的东西」，那是另一条错。
	if err := db.Exec(`INSERT INTO booking (booking_no, order_id, order_item_id, supplier_id,
	                                supplier_product_id, supplier_session_id, supplier_variant_id,
	                                status, idempotency_key)
	                      SELECT 'BK-REASSIGN-TEST', ` + store.Quote(orderID) + `, s.order_item_id,
	                             s.supplier_id, s.supplier_product_id, s.supplier_session_id,
	                             s.supplier_variant_id, 'pending', 'idem-reassign-booked-test'
	                        FROM sales_order_item_source s
	                       WHERE s.order_item_id = ` + store.Quote(itemID) + `;`); err != nil {
		t.Fatalf("造预订失败：%v", err)
	}

	_, err := reassign.New(db).Reassign(orderID, itemID, "预订之后还想换源")
	if err == nil {
		t.Fatal("已经预订过的明细不许改派")
	}
	if !strings.Contains(err.Error(), "预订") {
		t.Fatalf("报错要说清是预订的问题，实际：%v", err)
	}
}

func TestReassignRefusesComboLine(t *testing.T) {
	db := seeded(t)
	// 组合套餐的源是声明的（配方），不是选出来的 —— 换源要重新声明。
	comboID := scalar(t, db, `SELECT id::text FROM product_variant WHERE variant_role = 'combo' LIMIT 1;`)
	date := scalar(t, db, `SELECT date::text FROM price_calendar
	                         WHERE product_variant_id = `+store.Quote(comboID)+`
	                           AND status = 'active'
	                         ORDER BY date LIMIT 1;`)

	combo := atoi(t, comboID)
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-reassign-combo-001",
		Items:          []order.Item{{VariantID: combo, Quantity: 1, VisitDate: date}},
		Holders: []order.Holder{
			{VariantID: 9, Sequence: 1, FieldCode: "holder_name", Value: "成人甲"},
			{VariantID: 9, Sequence: 1, FieldCode: "id_number", Value: "110101199001011234"},
			{VariantID: 9, Sequence: 2, FieldCode: "holder_name", Value: "成人乙"},
			{VariantID: 9, Sequence: 2, FieldCode: "id_number", Value: "110101199001011235"},
			{VariantID: 10, Sequence: 1, FieldCode: "holder_name", Value: "儿童丙"},
			{VariantID: 10, Sequence: 1, FieldCode: "dob", Value: "2018-05-20"},
		},
	})
	if err != nil {
		t.Fatalf("组合下单失败：%v", err)
	}
	itemID := atoi(t, scalar(t, db, `SELECT id::text FROM sales_order_item WHERE order_id = `+store.Quote(o.ID)+`;`))

	_, err = reassign.New(db).Reassign(o.ID, itemID, "组合也想换源")
	if err == nil {
		t.Fatal("组合形态不许改派")
	}
	if !strings.Contains(err.Error(), "组合") {
		t.Fatalf("报错要说清是形态的问题，实际：%v", err)
	}
}
