package order_test

import (
	"strconv"
	"strings"
	"testing"

	"ticket-center/internal/order"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 下单的行为约定：
//   - 金额与采纳源都来自定价函数的唯一实现（fn_price_variant），Go 侧不另算；
//   - 幂等键必填：同一请求重复提交只产生一张单；同一个键配不同内容要报错；
//   - 实名信息按 checkout_requirement 收齐，收不齐不许下单；
//   - 落库之后全库不变量仍然全绿。

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

// holdersFor 给一个变体凑够实名信息（两个必填字段 × 数量份）。
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

func TestPlaceOrderUsesPricingFunctionOutput(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)

	o, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-place-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 2, VisitDate: date}},
		Holders:        holdersFor(9, 2, []string{"holder_name", "id_number"}),
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}
	if !o.Created {
		t.Fatal("第一次下单应该是新单")
	}
	if o.Status != "awaiting_payment" {
		t.Fatalf("下单后状态应该是 awaiting_payment，实际 %s", o.Status)
	}
	if o.No == "" {
		t.Fatal("订单号不该为空")
	}

	// 单价必须等于定价函数在同一天的输出 —— 不是 Go 侧算的。
	want, err := db.Scalar(`SELECT sell_price::text FROM fn_price_variant(9, ` +
		store.Quote(date) + `::date, 1, 1);`)
	if err != nil {
		t.Fatalf("取定价结果失败：%v", err)
	}
	got, err := db.Scalar(`SELECT unit_price::text FROM sales_order_item WHERE order_id = ` +
		store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读明细失败：%v", err)
	}
	if got != want {
		t.Fatalf("明细单价 %s 与定价函数输出 %s 不一致", got, want)
	}

	// 订单合计 = 单价 × 数量（变体 9 是单人计价）。
	total, err := db.Scalar(`SELECT total::text FROM sales_order WHERE id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读订单失败：%v", err)
	}
	if total != o.Total {
		t.Fatalf("返回的合计 %s 与库里写的 %s 不一致", o.Total, total)
	}
	rows, err := db.Query(`SELECT total_price::text, unit_price::text FROM sales_order_item WHERE order_id = ` +
		store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读明细失败：%v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("应该只有一行明细，实际 %d 行", len(rows))
	}
	if rows[0][1] != want {
		t.Fatalf("明细单价 %s 与定价函数输出 %s 不一致", rows[0][1], want)
	}
	if rows[0][0] != o.Total {
		t.Fatalf("明细合计 %s 与订单合计 %s 不一致", rows[0][0], o.Total)
	}

	// 持票人落库：2 名 × 2 个字段。
	n, err := db.Scalar(`SELECT count(*) FROM order_holder WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读持票人失败：%v", err)
	}
	if n != "4" {
		t.Fatalf("应该落 4 条持票人字段，实际 %s 条", n)
	}
}

func TestRepeatWithSameKeyReturnsSameOrder(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)

	req := order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-idem-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 2, VisitDate: date}},
		Holders:        holdersFor(9, 2, []string{"holder_name", "id_number"}),
	}
	first, err := svc.Place(req)
	if err != nil {
		t.Fatalf("第一次下单失败：%v", err)
	}
	second, err := svc.Place(req)
	if err != nil {
		t.Fatalf("重复下单失败：%v", err)
	}
	if second.Created {
		t.Fatal("重复下单不该产生新单")
	}
	if second.ID != first.ID || second.No != first.No {
		t.Fatalf("重复下单应该返回同一张单，实际 %s / %d 与 %s / %d",
			first.No, first.ID, second.No, second.ID)
	}

	n, err := db.Scalar(`SELECT count(*) FROM sales_order
                          WHERE channel_id = 1 AND idempotency_key = 'test-idem-001';`)
	if err != nil {
		t.Fatalf("数订单失败：%v", err)
	}
	if n != "1" {
		t.Fatalf("同一幂等键只该有一张单，实际 %s 张", n)
	}
}

func TestSameKeyWithDifferentPayloadIsRejected(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)

	first := order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-conflict-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 2, VisitDate: date}},
		Holders:        holdersFor(9, 2, []string{"holder_name", "id_number"}),
	}
	if _, err := svc.Place(first); err != nil {
		t.Fatalf("第一次下单失败：%v", err)
	}

	// 同一个幂等键，换了内容 —— 必须被拒，不能悄悄返回上一张单。
	conflict := first
	conflict.Items = []order.Item{{VariantID: 9, Quantity: 3, VisitDate: date}}
	conflict.Holders = holdersFor(9, 3, []string{"holder_name", "id_number"})
	_, err := svc.Place(conflict)
	if err == nil {
		t.Fatal("同一个幂等键配不同内容应该被拒")
	}
	if !strings.Contains(err.Error(), "幂等键") {
		t.Fatalf("报错要说清是幂等键冲突，实际：%v", err)
	}
}

func TestMissingHoldersIsRejected(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)

	// 变体 9 要求持票人姓名 + 证件号码（checkout_requirement）。
	_, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-noholder-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 2, VisitDate: date}},
	})
	if err == nil {
		t.Fatal("缺实名信息不该放行")
	}
	if !strings.Contains(err.Error(), "实名") {
		t.Fatalf("报错要说清是实名信息不够，实际：%v", err)
	}
}

func TestVariantWithoutPriceIsRejected(t *testing.T) {
	db := seeded(t)
	svc := order.New(db)

	// 变体 9 有售价的日期是 current_date+12；current_date+400 上没有报价。
	_, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-noprice-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 1, VisitDate: "2030-01-01"}},
		Holders:        holdersFor(9, 1, []string{"holder_name", "id_number"}),
	})
	if err == nil {
		t.Fatal("没有售价的日子不该下得出单")
	}
	if !strings.Contains(err.Error(), "没有可售价格") {
		t.Fatalf("报错要说清是当天没有可售价格，实际：%v", err)
	}
}

func TestPerGroupOrderKeepsGroupTotal(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 17)
	svc := order.New(db)

	// 变体 17 是按团报价：团总价 1200.00，7 人人均只是分摊。
	o, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-group-001",
		Items:          []order.Item{{VariantID: 17, Quantity: 7, VisitDate: date}},
	})
	if err != nil {
		t.Fatalf("按团下单失败：%v", err)
	}
	if o.Total != "1200.00" {
		t.Fatalf("按团报价的合计应是团总价 1200.00，实际 %s", o.Total)
	}
	basis, err := db.Scalar(`SELECT pricing_basis FROM sales_order_item WHERE order_id = ` +
		store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读计价口径失败：%v", err)
	}
	if basis != "per_group" {
		t.Fatalf("计价口径应该是 per_group，实际 %s", basis)
	}
}

func TestPlacedOrderKeepsInvariantsGreen(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)

	if _, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-invariant-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 2, VisitDate: date}},
		Holders:        holdersFor(9, 2, []string{"holder_name", "id_number"}),
	}); err != nil {
		t.Fatalf("下单失败：%v", err)
	}

	rows, err := db.Rows(`SELECT seq, check_name, actual FROM v_invariant_checks WHERE NOT passed;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("下单之后不该出现不变量违规：%v", rows)
	}
}

// comboVariant 找出家庭套餐那个组合变体。
//
// 变体 id 是种子按顺序生成的，写死 id 的话种子一改测试就跟着错。
func comboVariant(t *testing.T, db *store.DB) int64 {
	t.Helper()
	s, err := db.Scalar(`SELECT id::text FROM product_variant
	                      WHERE variant_key = 'family:2adult:1child:studio_only';`)
	if err != nil {
		t.Fatalf("查组合变体失败：%v", err)
	}
	if s == "" {
		t.Fatal("种子里没有家庭套餐这个组合变体")
	}
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		t.Fatalf("组合变体 id 不是整数：%v", err)
	}
	return id
}

// comboHolders 家庭套餐的实名：成人成分 2 人（姓名 + 证件），儿童成分 1 人（姓名 + 生日）。
func comboHolders() []order.Holder {
	out := []order.Holder{
		{VariantID: 9, Sequence: 1, FieldCode: "holder_name", Value: "测试成人一"},
		{VariantID: 9, Sequence: 1, FieldCode: "id_number", Value: "110101199001011234"},
		{VariantID: 9, Sequence: 2, FieldCode: "holder_name", Value: "测试成人二"},
		{VariantID: 9, Sequence: 2, FieldCode: "id_number", Value: "110101199001011235"},
		{VariantID: 10, Sequence: 1, FieldCode: "holder_name", Value: "测试儿童"},
		{VariantID: 10, Sequence: 1, FieldCode: "dob", Value: "2018-05-20"},
	}
	return out
}

func TestComboOrderIsOneItemWithComponentSources(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)
	combo := comboVariant(t, db)

	o, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-combo-001",
		Items:          []order.Item{{VariantID: combo, Quantity: 1, VisitDate: date}},
		Holders:        comboHolders(),
	})
	if err != nil {
		t.Fatalf("组合套餐下单失败：%v", err)
	}

	// 客户买的是一份套餐 → 一行明细。
	items, err := db.Scalar(`SELECT count(*)::text FROM sales_order_item WHERE order_id = ` +
		store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("读明细数失败：%v", err)
	}
	if items != "1" {
		t.Fatalf("一份套餐应该只有 1 行明细，实际 %s 行", items)
	}

	// 但源侧要收两次单 → 两行成分（成人 2 份、儿童 1 份）。
	sources, err := db.Scalar(`SELECT count(*)::text FROM sales_order_item_source
	                            WHERE order_item_id IN (SELECT id FROM sales_order_item WHERE order_id = ` +
		store.Quote(o.ID) + `);`)
	if err != nil {
		t.Fatalf("读成分数失败：%v", err)
	}
	if sources != "2" {
		t.Fatalf("家庭套餐应该落 2 行成分，实际 %s 行", sources)
	}

	// 金额 = 定价函数的输出：2×505 + 1×418 = 1428 成本，售价 1656.48。
	if o.Total != "1656.48" {
		t.Fatalf("组合套餐售价应是 1656.48，实际 %s", o.Total)
	}

	rows, err := db.Rows(`SELECT seq, check_name, actual FROM v_invariant_checks WHERE NOT passed;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("组合下单之后不该出现不变量违规：%v", rows)
	}
}

func TestSameComponentInTwoLinesNeedsItemIndex(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)
	combo := comboVariant(t, db)

	// 一单里既有家庭套餐（成人成分 9），又有单买的成人票（也是变体 9）。
	// 两行都要实名，但「这份姓名属于哪一行」光看 variant_id 分不出来。
	items := []order.Item{
		{VariantID: combo, Quantity: 1, VisitDate: date},
		{VariantID: 9, Quantity: 1, VisitDate: date},
	}

	_, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-combo-ambiguous-001",
		Items:          items,
		Holders:        comboHolders(),
	})
	if err == nil {
		t.Fatal("同一个成分变体出现在多行明细里，不该猜该把实名绑哪一行")
	}
	if !strings.Contains(err.Error(), "item_index") {
		t.Fatalf("报错要说清要带 item_index，实际：%v", err)
	}
}

func TestItemIndexAssignsHoldersToTheRightLine(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)
	combo := comboVariant(t, db)

	holders := comboHolders()
	for i := range holders {
		holders[i].ItemIndex = 1 // 家庭套餐那一行
	}
	holders = append(holders,
		order.Holder{VariantID: 9, Sequence: 1, FieldCode: "holder_name", Value: "单买成人", ItemIndex: 2},
		order.Holder{VariantID: 9, Sequence: 1, FieldCode: "id_number", Value: "110101199003033456", ItemIndex: 2},
	)

	o, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-combo-itemindex-001",
		Items: []order.Item{
			{VariantID: combo, Quantity: 1, VisitDate: date},
			{VariantID: 9, Quantity: 1, VisitDate: date},
		},
		Holders: holders,
	})
	if err != nil {
		t.Fatalf("带 item_index 的组合下单失败：%v", err)
	}

	// 第二行的实名只能绑在第二行上。
	leaked, err := db.Scalar(`SELECT count(*)::text FROM order_holder oh
	                           JOIN sales_order_item oi ON oi.id = oh.order_item_id
	                          WHERE oi.order_id = ` + store.Quote(o.ID) + `
	                            AND oi.product_variant_id = 9
	                            AND oh.value LIKE '测试成人%';`)
	if err != nil {
		t.Fatalf("查实名归属失败：%v", err)
	}
	if leaked != "0" {
		t.Fatalf("家庭套餐行的实名串到了单买那一行，实际串了 %s 条", leaked)
	}
}

func TestHolderItemIndexMustBeAllOrNothing(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)

	holders := holdersFor(9, 2, []string{"holder_name", "id_number"})
	holders[0].ItemIndex = 1 // 只带一条

	_, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-holder-mixed-001",
		Items:          []order.Item{{VariantID: 9, Quantity: 2, VisitDate: date}},
		Holders:        holders,
	})
	if err == nil {
		t.Fatal("实名里混着带与不带 item_index 的，应该当场拒")
	}
	if !strings.Contains(err.Error(), "item_index") {
		t.Fatalf("报错要说清 item_index 的口径，实际：%v", err)
	}
}

func TestComboCannotOversellOneSharedSourcePool(t *testing.T) {
	db := seeded(t)
	date := priceDate(t, db, 9)
	svc := order.New(db)
	combo := comboVariant(t, db)

	// 家庭套餐的两个成分落在同一个源场次（源侧那个人群参数化的 SKU），
	// 也就是说它们抢的是**同一个池子**：成人 2 份 + 儿童 1 份 = 3 份。
	//
	// 这个池子还剩 2 份（可用 8 减掉种子那几笔订单已经占掉的 6 份）。
	// 逐成分各查各的话：
	//   成人查「还剩 2」→ 要 2，过；
	//   儿童查「还剩 2」→ 要 1，也过；
	// 两个都过，加起来要 3 份 —— 超卖一张。
	// 按场次加总才看得见：3 > 2，当场拦住。
	if err := db.Exec(`INSERT INTO inventory_snapshot
	                     (supplier_session_id, supplier_ticket_type_id, session_date,
	                      available_qty, sold_qty, status, captured_at)
	                   VALUES (12, NULL, ` + store.Quote(date) + `, 8, 0, 'available', now());`); err != nil {
		t.Fatalf("铺库存快照失败：%v", err)
	}

	_, err := svc.Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "test-combo-oversell-001",
		Items:          []order.Item{{VariantID: combo, Quantity: 1, VisitDate: date}},
		Holders:        comboHolders(),
	})
	if err == nil {
		t.Fatal("两个成分抢同一个池子，加起来超了就不该放行")
	}
	if !strings.Contains(err.Error(), "库存不足") {
		t.Fatalf("报错要说清是库存不足，实际：%v", err)
	}
}
