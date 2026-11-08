package inventory_test

import (
	"fmt"
	"strings"
	"sync"
	"testing"

	"ticket-center/internal/inventory"
	"ticket-center/internal/order"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 库存的行为约定：
//   - 可售数只有一个实现（fn_available_qty）：Go 侧只报事实，不自己算；
//   - 明知不够当场报错（fn_reserve_qty），「不知道」放行但要标出来；
//   - 并发靠锁：两个并发预占抢最后一张，只能有一个成功；
//   - 预占是事实：每条订单明细都有一条预占记录，量对得上；
//   - 订单不成了（取消 / 超时 / 退款）预占要撤销，票要放回池子。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

func svc(t *testing.T, db *store.DB) *inventory.Service {
	t.Helper()
	return inventory.New(db)
}

// holdReq 造一个预占请求。
func holdReq(no string, variantID int64, qty int64, date string) inventory.HoldRequest {
	return inventory.HoldRequest{
		HoldNo:     no,
		ChannelID:  1,
		VariantID:  variantID,
		Quantity:   qty,
		VisitDate:  date,
		CartID:     1,
		TTLSeconds: 900,
	}
}

// 变体 5 → 规范场次 4 → 源场次 8（票种级快照：可售 10）。
const (
	knownVariant   = 5
	knownSession   = 8
	knownType      = 5
	knownAvailable = 10
)

// 变体 9 → 源场次 12：源侧没有库存数据 —— 不知道还剩几张。
const (
	unknownVariant = 9
	unknownSession = 12
)

// 变体 7 → 源场次 10：源侧 sold_out，可售 0。
const (
	soldOutVariant = 7
	soldOutSession = 10
)

// visitDate 取某个变体在种子里有报价的那一天。
//
// 为什么不把日期写死：种子的报价按 current_date 相对生成
// （今天跑是 11-16，明天跑就是 11-17）。
// 写死日期的测试会在第二天集体变红 —— 那是测试自己烂掉，不是产品坏掉，
// 但结果一样：门禁没人信。日期从数据里读，测试就跟数据一起走。
func visitDate(t *testing.T, db *store.DB, variantID int64) string {
	t.Helper()
	rows := testdb.Exec(t, db.Name, fmt.Sprintf(
		"SELECT pc.date FROM price_calendar pc "+
			"JOIN product_session ps ON ps.id = pc.session_id "+
			"WHERE pc.product_variant_id = %d AND pc.sell_price IS NOT NULL "+
			"AND pc.date = ps.session_date "+
			"ORDER BY pc.date LIMIT 1;", variantID))
	if len(rows) == 0 || len(rows[0]) == 0 {
		t.Fatalf("变体 %d 在种子里没有可售价格（种子的报价按 current_date 相对生成，日期要从数据里读）", variantID)
	}
	return rows[0][0]
}

func TestAvailableReportsSourceSideStock(t *testing.T) {
	db := seeded(t)
	av, err := svc(t, db).Available(knownSession, knownType)
	if err != nil {
		t.Fatalf("查库存失败：%v", err)
	}
	if !av.Known {
		t.Fatalf("源场次 %d 有票种级快照，应该知道可售数", knownSession)
	}
	if av.AvailableQty != knownAvailable {
		t.Fatalf("源侧可售数不对：期望 %d，实际 %d", knownAvailable, av.AvailableQty)
	}
	if av.RemainingQty != knownAvailable {
		t.Fatalf("还剩数不对：期望 %d，实际 %d", knownAvailable, av.RemainingQty)
	}
}

func TestAvailableSaysUnknownWhenSourceHasNoStockData(t *testing.T) {
	db := seeded(t)
	av, err := svc(t, db).Available(unknownSession, 9)
	if err != nil {
		t.Fatalf("查库存失败：%v", err)
	}
	if av.Known {
		t.Fatalf("源场次 %d 没有库存数据，应该说不知道", unknownSession)
	}
	if av.RemainingQty != 0 {
		t.Fatalf("不知道的时候不该报剩余数：实际 %d", av.RemainingQty)
	}
}

// 场次级池子（源侧只报整个场次的合计）不能让每个票种各花一遍。
//
// 源场次 12 的源侧只报场次合计：成人（票种 9）和儿童（票种 10）抢的是同一个池子。
// 如果按票种各算各的承诺，每个票种都能把整场次的可用量再花一遍 ——
// 卖 2 张成人再卖 2 张儿童，池子里明明只有 2 张。
//
// 所以场次级池子下，票种视角的剩余数必须和场次视角一致（都不许乐观）。
func TestSharedSessionPoolIsNotCreditedToEachTicketType(t *testing.T) {
	db := seeded(t)

	if err := db.Exec(`INSERT INTO inventory_snapshot
	                     (supplier_session_id, supplier_ticket_type_id, session_date,
	                      available_qty, sold_qty, status, captured_at)
	                   VALUES (12, NULL, '2026-11-19', 8, 0, 'available', now());`); err != nil {
		t.Fatalf("铺库存快照失败：%v", err)
	}

	// 场次视角。
	sessionView, err := svc(t, db).Available(12, 0)
	if err != nil {
		t.Fatalf("查库存失败：%v", err)
	}
	if !sessionView.Known {
		t.Fatal("刚铺了场次级快照，应该知道可售数")
	}

	// 票种视角：两个票种共用这个池子，看到的剩余数必须一样。
	for _, tt := range []int64{9, 10} {
		view, err := svc(t, db).Available(12, tt)
		if err != nil {
			t.Fatalf("查库存失败：%v", err)
		}
		if !view.Known {
			t.Fatalf("票种 %d 应该知道可售数（池子是场次级的）", tt)
		}
		if view.RemainingQty != sessionView.RemainingQty {
			t.Fatalf("票种 %d 的剩余数 %d 与场次视角的 %d 不一致：共用一个池子就不许各算各的",
				tt, view.RemainingQty, sessionView.RemainingQty)
		}
	}
}

func TestHoldReservesAndDeductsFromAvailability(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	res, err := s.Hold(holdReq("HOLD-T1", knownVariant, 2, visitDate(t, db, knownVariant)))
	if err != nil {
		t.Fatalf("预占失败：%v", err)
	}
	if !res.Created {
		t.Fatalf("第一次预占应该是新建的")
	}
	if !res.Known {
		t.Fatalf("源场次 %d 有库存数据，预占时应该知道", knownSession)
	}
	if res.RemainingQty != knownAvailable-2 {
		t.Fatalf("预占后可售数不对：期望 %d，实际 %d", knownAvailable-2, res.RemainingQty)
	}

	// 再查一次：预占占住的量要扣掉
	av, err := s.Available(knownSession, knownType)
	if err != nil {
		t.Fatalf("查库存失败：%v", err)
	}
	if av.RemainingQty != knownAvailable-2 {
		t.Fatalf("预占没扣进可售数：期望 %d，实际 %d", knownAvailable-2, av.RemainingQty)
	}
	if av.HeldQty != 2 {
		t.Fatalf("占用数不对：期望 2，实际 %d", av.HeldQty)
	}
}

func TestHoldIsIdempotent(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	first, err := s.Hold(holdReq("HOLD-T2", knownVariant, 1, visitDate(t, db, knownVariant)))
	if err != nil {
		t.Fatalf("预占失败：%v", err)
	}
	second, err := s.Hold(holdReq("HOLD-T2", knownVariant, 1, visitDate(t, db, knownVariant)))
	if err != nil {
		t.Fatalf("重放预占失败：%v", err)
	}
	if second.HoldID != first.HoldID {
		t.Fatalf("重放应该还是同一张预占：第一次 %d，第二次 %d", first.HoldID, second.HoldID)
	}
	if second.Created {
		t.Fatalf("重放不该新建预占")
	}
	if second.RemainingQty != first.RemainingQty {
		t.Fatalf("重放返回的可售数变了：第一次 %d，第二次 %d",
			first.RemainingQty, second.RemainingQty)
	}
}

func TestHoldSameKeyDifferentContentFails(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	if _, err := s.Hold(holdReq("HOLD-T3", knownVariant, 1, visitDate(t, db, knownVariant))); err != nil {
		t.Fatalf("预占失败：%v", err)
	}
	// 同一个预占号配另一份内容 = 两笔不同的预占，不能混成一张
	_, err := s.Hold(holdReq("HOLD-T3", knownVariant, 3, visitDate(t, db, knownVariant)))
	if err == nil {
		t.Fatalf("同键异内容应该报错")
	}
	if !strings.Contains(err.Error(), "幂等键") {
		t.Fatalf("报错要说清是幂等键冲突：%v", err)
	}
}

func TestHoldRejectsWhenSourceStockIsKnownToBeShort(t *testing.T) {
	db := seeded(t)

	_, err := svc(t, db).Hold(holdReq("HOLD-T4", soldOutVariant, 1, visitDate(t, db, soldOutVariant)))
	if err == nil {
		t.Fatalf("源侧已售罄，卖一张应该当场报错")
	}
	if !strings.Contains(err.Error(), "库存不足") {
		t.Fatalf("报错要说清是库存不足：%v", err)
	}
}

func TestHoldPassesThroughWhenSourceStockIsUnknown(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	res, err := s.Hold(holdReq("HOLD-T5", unknownVariant, 1, visitDate(t, db, unknownVariant)))
	if err != nil {
		t.Fatalf("不知道还剩几张不该拦住下单：%v", err)
	}
	if !res.Created {
		t.Fatalf("应该新建了一张预占")
	}
	if res.Known {
		t.Fatalf("源侧没有库存数据，这张预占不该说「知道」")
	}
}

func TestReleaseIsIdempotent(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	if _, err := s.Hold(holdReq("HOLD-T6", knownVariant, 1, visitDate(t, db, knownVariant))); err != nil {
		t.Fatalf("预占失败：%v", err)
	}

	first, err := s.Release("HOLD-T6", "cart_abandoned")
	if err != nil {
		t.Fatalf("释放失败：%v", err)
	}
	if !first.Released {
		t.Fatalf("第一次释放应该成功")
	}

	second, err := s.Release("HOLD-T6", "cart_abandoned")
	if err != nil {
		t.Fatalf("重复释放不该报错：%v", err)
	}
	if second.Released {
		t.Fatalf("重复释放不该再放一次")
	}
	if second.Status != "released" {
		t.Fatalf("状态不对：%s", second.Status)
	}

	// 放掉之后票要回到池子里
	av, err := s.Available(knownSession, knownType)
	if err != nil {
		t.Fatalf("查库存失败：%v", err)
	}
	if av.RemainingQty != knownAvailable {
		t.Fatalf("释放后还剩数不对：期望 %d，实际 %d", knownAvailable, av.RemainingQty)
	}
}

func TestExpireReleasesDueHolds(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	// 造一张已经到期的预占
	if _, err := s.Hold(holdReq("HOLD-T7", knownVariant, 1, visitDate(t, db, knownVariant))); err != nil {
		t.Fatalf("预占失败：%v", err)
	}
	if err := db.Exec(`UPDATE inventory_hold
	                        SET expires_at = now() - interval '1 minute'
	                      WHERE hold_no = 'HOLD-T7';`); err != nil {
		t.Fatalf("改过期时间失败：%v", err)
	}

	n, err := s.Expire(100)
	if err != nil {
		t.Fatalf("跑过期作业失败：%v", err)
	}
	if n != 1 {
		t.Fatalf("应该放掉 1 张，实际 %d", n)
	}

	st, err := s.Show("HOLD-T7")
	if err != nil {
		t.Fatalf("读预占失败：%v", err)
	}
	if st.Status != "expired" {
		t.Fatalf("到期预占状态不对：%s", st.Status)
	}

	// 作业可以反复跑，幂等
	n2, err := s.Expire(100)
	if err != nil {
		t.Fatalf("重跑过期作业失败：%v", err)
	}
	if n2 != 0 {
		t.Fatalf("重跑不该再放掉任何预占，实际 %d", n2)
	}
}

// 下单要写预占记录，明细快照里要留下「卖的时候还剩多少」。
func TestPlaceOrderRecordsHoldAndAvailability(t *testing.T) {
	db := seeded(t)

	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "INV-T8",
		Items:          []order.Item{{VariantID: knownVariant, Quantity: 2, VisitDate: visitDate(t, db, knownVariant)}},
		Holders: []order.Holder{
			{VariantID: knownVariant, Sequence: 1, FieldCode: "holder_name", Value: "张三"},
			{VariantID: knownVariant, Sequence: 2, FieldCode: "holder_name", Value: "李四"},
		},
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}

	// 每条明细都要有对应的预占（不变量 69）
	cnt, err := db.Scalar(`SELECT count(*) FROM inventory_hold
	                        WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("查预占失败：%v", err)
	}
	if cnt != "1" {
		t.Fatalf("订单应该有 1 张预占，实际 %s", cnt)
	}

	// 明细快照里要记下卖的时候看到的可售数（硬约束 7）
	avail, err := db.Scalar(`SELECT COALESCE((detail_snapshot->'availability'->>'known')::text, '')
	                          FROM sales_order_item WHERE order_id = ` + store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("查明细快照失败：%v", err)
	}
	if avail != "true" {
		t.Fatalf("明细快照应该记下「知道还剩多少」，实际 %q", avail)
	}
}

// 订单取消了，票要放回池子。
func TestCancelledOrderReleasesItsHold(t *testing.T) {
	db := seeded(t)

	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "INV-T9",
		Items:          []order.Item{{VariantID: knownVariant, Quantity: 1, VisitDate: visitDate(t, db, knownVariant)}},
		Holders: []order.Holder{
			{VariantID: knownVariant, Sequence: 1, FieldCode: "holder_name", Value: "张三"},
		},
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}

	if err := db.Exec(`UPDATE sales_order SET status = 'cancelled' WHERE id = ` +
		store.Quote(o.ID) + `;`); err != nil {
		t.Fatalf("取消订单失败：%v", err)
	}

	status, err := db.Scalar(`SELECT status FROM inventory_hold WHERE order_id = ` +
		store.Quote(o.ID) + `;`)
	if err != nil {
		t.Fatalf("查预占失败：%v", err)
	}
	if status != "voided" {
		t.Fatalf("订单取消后预占应该作废，实际 %s", status)
	}

	// 票要回到池子里
	av, err := svc(t, db).Available(knownSession, knownType)
	if err != nil {
		t.Fatalf("查库存失败：%v", err)
	}
	if av.RemainingQty != knownAvailable {
		t.Fatalf("订单取消后可售数不对：期望 %d，实际 %d", knownAvailable, av.RemainingQty)
	}
}

// 两个并发预占抢最后一张票，只能有一个成功。
// 这是防超卖的核心断言：不锁的话两边都会看到「还剩 1 张」。
func TestConcurrentHoldsOnLastTicketOnlyOneWins(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	// 把源场次的可售数压到 1
	if err := db.Exec(`UPDATE inventory_snapshot
	                        SET available_qty = 1, sold_qty = 0
	                      WHERE supplier_session_id = ` + store.Quote(knownSession) + `
	                        AND supplier_ticket_type_id = 1;`); err != nil {
		t.Fatalf("改库存快照失败：%v", err)
	}

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = s.Hold(holdReq("HOLD-RACE-"+string(rune('A'+i)), knownVariant, 1, visitDate(t, db, knownVariant)))
		}(i)
	}
	wg.Wait()

	ok, rejected := 0, 0
	for _, err := range errs {
		switch {
		case err == nil:
			ok++
		case strings.Contains(err.Error(), "库存不足"):
			rejected++
		default:
			t.Fatalf("并发预占报了不该有的错：%v", err)
		}
	}
	if ok != 1 || rejected != 1 {
		t.Fatalf("最后一张票只能卖出去一张：成功 %d，被拒 %d", ok, rejected)
	}
}

// 跑完这些动作之后，库存侧不变量必须还是全绿。
func TestInventoryInvariantsStayGreen(t *testing.T) {
	db := seeded(t)
	s := svc(t, db)

	if _, err := s.Hold(holdReq("HOLD-T10", knownVariant, 1, visitDate(t, db, knownVariant))); err != nil {
		t.Fatalf("预占失败：%v", err)
	}
	o, err := order.New(db).Place(order.Request{
		ChannelID:      1,
		CustomerID:     3,
		IdempotencyKey: "INV-T10",
		Items:          []order.Item{{VariantID: knownVariant, Quantity: 1, VisitDate: visitDate(t, db, knownVariant)}},
		Holders: []order.Holder{
			{VariantID: knownVariant, Sequence: 1, FieldCode: "holder_name", Value: "张三"},
		},
	})
	if err != nil {
		t.Fatalf("下单失败：%v", err)
	}
	if err := db.Exec(`UPDATE sales_order SET status = 'cancelled' WHERE id = ` +
		store.Quote(o.ID) + `;`); err != nil {
		t.Fatalf("取消订单失败：%v", err)
	}

	bad, err := db.Scalar(`SELECT count(*) FROM v_invariant_checks WHERE NOT passed;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if bad != "0" {
		t.Fatalf("不变量有 %s 条没通过", bad)
	}
}
