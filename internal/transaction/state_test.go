package transaction_test

import (
	"strings"
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
	"ticket-center/internal/transaction"
)

// 状态机的行为约定：
//   - 非法流转写不进去（守卫触发器当场报错）；
//   - 合法流转写进去了，而且一定留下领域事件（outbox 里能查到）；
//   - 库里不存在「凭空出现」的状态（不变量 46-49）。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

func TestIllegalTransitionIsRejected(t *testing.T) {
	db := seeded(t)

	// 订单 4 是 expired：expired → confirmed 在状态机里没有这条边。
	err := db.Exec(`UPDATE sales_order SET status = 'confirmed' WHERE id = 4;`)
	if err == nil {
		t.Fatal("expired 的订单不该能被改成 confirmed")
	}
	if !strings.Contains(err.Error(), "非法状态流转") {
		t.Fatalf("报错要说清是状态流转的问题，实际：%v", err)
	}

	// 数据没被改。
	status, err := db.Scalar(`SELECT status FROM sales_order WHERE id = 4;`)
	if err != nil {
		t.Fatalf("读订单失败：%v", err)
	}
	if status != "expired" {
		t.Fatalf("被拒绝的流转不该改到数据，实际状态 %s", status)
	}
}

func TestLegalTransitionEmitsDomainEvent(t *testing.T) {
	db := seeded(t)

	// 预订 3 是 failed（源侧 STOCK_LOCKED）：failed → pending 是合法的重报。
	if err := db.Exec(`UPDATE booking SET status = 'pending', next_retry_at = now() WHERE id = 3;`); err != nil {
		t.Fatalf("合法流转被拒：%v", err)
	}

	events, err := transaction.Events(db, "booking", 3)
	if err != nil {
		t.Fatalf("查事件失败：%v", err)
	}
	found := false
	for _, e := range events {
		if e.EventType == "BookingRetryScheduled" {
			found = true
			if !strings.Contains(e.Payload, "BK202610280003") {
				t.Fatalf("事件载荷里没有预订号：%s", e.Payload)
			}
		}
	}
	if !found {
		t.Fatalf("状态变了却没有领域事件：%+v", events)
	}
}

func TestAllowedMatchesTheGuard(t *testing.T) {
	db := seeded(t)

	cases := []struct {
		aggregate string
		from, to  string
		want      bool
	}{
		{"order", "created", "awaiting_payment", true},
		{"order", "expired", "confirmed", false},
		{"order", "paid", "fulfilled", false},
		{"booking", "pending", "requested", true},
		{"booking", "confirmed", "pending", false},
		{"voucher", "pending", "issued", true},
		{"voucher", "used", "issued", false},
	}
	for _, c := range cases {
		got, err := transaction.Allowed(db, c.aggregate, c.from, c.to)
		if err != nil {
			t.Fatalf("判定流转失败：%v", err)
		}
		if got != c.want {
			t.Fatalf("%s %s→%s 判定为 %v，期望 %v", c.aggregate, c.from, c.to, got, c.want)
		}
	}
}

func TestSeededStatusesAreReachable(t *testing.T) {
	db := seeded(t)

	rows, err := db.Rows(`SELECT seq, check_name, actual FROM v_invariant_checks_tx WHERE NOT passed;`)
	if err != nil {
		t.Fatalf("查交易侧不变量失败：%v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("种子数据不该有交易侧违规：%v", rows)
	}
}
