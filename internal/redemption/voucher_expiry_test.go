package redemption_test

import (
	"testing"

	"ticket-center/internal/redemption"
	"ticket-center/internal/store"
)

// 凭证过期作业的行为约定：
//   - 只动 status='issued' 且 valid_to 已过的券（别的状态是另外几条事实）；
//   - 幂等：跑第二遍是 0，不报错、不重复改；
//   - 状态一变，领域事件由触发器自动落一条（不变量 120 / 121）；
//   - 作业漏跑不挡门禁，由 v_voucher_expiry_overdue 看得见。

// backdateWindow 把券的有效期整段前移（fixture）。
//
// 整段前移而不是只改 valid_to：只改 valid_to 会把窗口截短，
// 撞上不变量 74「已发出的券不得短于该可售单元承诺的有效期」——
// 那是测试自己造出来的违规，不是过期作业造出来的。
func backdateWindow(t *testing.T, db *store.DB, voucherID int64) {
	t.Helper()
	if err := db.Exec(`UPDATE voucher
                         SET valid_from = valid_from - interval '400 day',
                             valid_to   = valid_to   - interval '400 day'
                       WHERE id = ` + store.Quote(voucherID) + `;`); err != nil {
		t.Fatalf("调整券有效期失败：%v", err)
	}
}

// 过期作业把到期的 issued 券推进到 expired，第二次跑是 0。
func TestExpireOverdueAdvancesIssuedVouchersAndIsIdempotent(t *testing.T) {
	db := seeded(t)
	svc := redemption.New(db)

	// 种子里没有到期的券（种子的日期在未来），所以先造一张。
	_, voucherIDs := ticketedOrder(t, db, "EXP-T1", "EXP-TXN-1")
	if len(voucherIDs) == 0 {
		t.Fatalf("没有券可测")
	}
	backdateWindow(t, db, voucherIDs[0])

	// 作业漏跑时的现状：能数出来。
	overdue, err := svc.ShowOverdue()
	if err != nil {
		t.Fatalf("读过期现状失败：%v", err)
	}
	if overdue.OverdueCount != 1 {
		t.Fatalf("到期却还是 issued 的券应该正好 1 张，实际 %d", overdue.OverdueCount)
	}
	if overdue.AffectedOrders != 1 {
		t.Fatalf("这批券应该分散在 1 张订单上，实际 %d", overdue.AffectedOrders)
	}

	n, err := svc.ExpireOverdue(0)
	if err != nil {
		t.Fatalf("跑过期作业失败：%v", err)
	}
	if n != 1 {
		t.Fatalf("应该过期 1 张券，实际 %d", n)
	}

	// 券状态推进了。
	st, err := svc.Show(voucherIDs[0])
	if err != nil {
		t.Fatalf("读券失败：%v", err)
	}
	if st.Status != "expired" {
		t.Fatalf("券状态不对：期望 expired，实际 %s", st.Status)
	}

	// 幂等：再跑一遍是 0。
	n2, err := svc.ExpireOverdue(0)
	if err != nil {
		t.Fatalf("重跑过期作业失败：%v", err)
	}
	if n2 != 0 {
		t.Fatalf("重跑不该再过期任何券，实际 %d", n2)
	}

	// 作业跑完之后现状归零。
	overdue2, err := svc.ShowOverdue()
	if err != nil {
		t.Fatalf("读过期现状失败：%v", err)
	}
	if overdue2.OverdueCount != 0 {
		t.Fatalf("作业跑完还有 %d 张券到期却停在 issued", overdue2.OverdueCount)
	}

	invariantsGreen(t, db)
}

// 状态一变，领域事件由触发器自动落 —— 不许在作业里手插事件。
func TestExpireOverdueEmitsVoucherExpiredEvent(t *testing.T) {
	db := seeded(t)
	svc := redemption.New(db)

	_, voucherIDs := ticketedOrder(t, db, "EXP-T2", "EXP-TXN-2")
	backdateWindow(t, db, voucherIDs[0])

	if _, err := svc.ExpireOverdue(0); err != nil {
		t.Fatalf("跑过期作业失败：%v", err)
	}

	rows, err := db.Rows(`SELECT e.event_type,
                                 e.payload->>'from_status' AS from_status,
                                 e.payload->>'to_status'   AS to_status
                            FROM event_outbox e
                           WHERE e.aggregate_type = 'voucher'
                             AND e.aggregate_id   = ` + store.Quote(voucherIDs[0]) + `
                             AND e.event_type = 'VoucherExpired';`)
	if err != nil {
		t.Fatalf("查领域事件失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatalf("过期作业没有落 VoucherExpired 事件")
	}
	r := rows[0]
	if r["from_status"] != "issued" || r["to_status"] != "expired" {
		t.Fatalf("事件里的状态迁移不对：%s → %s", r["from_status"], r["to_status"])
	}
}

// 别的状态不动：已核销的券过期与否不影响「被用过」这个事实，
// 作废的 / 已退款的是另外两条事实，都不许被作业推成 expired。
func TestExpireOverdueLeavesOtherStatusesAlone(t *testing.T) {
	db := seeded(t)
	svc := redemption.New(db)

	_, voucherIDs := ticketedOrder(t, db, "EXP-T3", "EXP-TXN-3")
	for _, id := range voucherIDs {
		backdateWindow(t, db, id)
	}

	// 把一张券改成已核销，另一张改成作废。
	if err := db.Exec(`UPDATE voucher SET status = 'used', used_at = now()
                       WHERE id = ` + store.Quote(voucherIDs[0]) + `;`); err != nil {
		t.Fatalf("改券状态失败：%v", err)
	}
	if err := db.Exec(`UPDATE voucher SET status = 'void'
                       WHERE id = ` + store.Quote(voucherIDs[1]) + `;`); err != nil {
		t.Fatalf("改券状态失败：%v", err)
	}

	n, err := svc.ExpireOverdue(0)
	if err != nil {
		t.Fatalf("跑过期作业失败：%v", err)
	}
	if n != 0 {
		t.Fatalf("used 与 void 的券不该被过期作业推进，实际过期 %d 张", n)
	}

	for _, id := range voucherIDs {
		st, err := svc.Show(id)
		if err != nil {
			t.Fatalf("读券失败：%v", err)
		}
		if st.Status == "expired" {
			t.Fatalf("券 %d 的状态被作业改成了 expired", id)
		}
	}
}
