package sync

import (
	"testing"

	"ticket-center/internal/store"
)

// TestSyncInvariantsCatchViolations 门禁要真的能挡住违规。
//
// 一条从来没红过的门禁等于没有门禁（它看起来在工作）。
func TestSyncInvariantsCatchViolations(t *testing.T) {
	db := testDB(t)
	sid := supplierIDOf(t, db, "trip_com")

	plan, err := buildPlan(db, sid, "trip_com", sampleCatalog(adultCoverage()))
	if err != nil {
		t.Fatal(err)
	}
	if err := apply(db, plan); err != nil {
		t.Fatal(err)
	}

	// 干净状态：全绿。
	if bad := failingSyncInvariants(t, db); len(bad) != 0 {
		t.Fatalf("干净状态下就有门禁红了：%v", bad)
	}

	// 造一个违规：把源商品降成 pending_review，但留着 active 的商品映射。
	// 这正是「待审核的事实漏进了可用路径」。
	if err := db.Exec("UPDATE supplier_product SET status='pending_review' WHERE external_id='21081935';"); err != nil {
		t.Fatal(err)
	}
	bad := failingSyncInvariants(t, db)
	if len(bad) == 0 {
		t.Fatal("造了违规（pending_review 的源商品挂着 active 的商品映射），门禁却没报")
	}
	t.Logf("门禁抓到了：%v", bad)
}

func failingSyncInvariants(t *testing.T, db *store.DB) []string {
	t.Helper()
	rows, err := db.Rows("SELECT seq, check_name FROM v_invariant_checks_sync WHERE actual > 0 ORDER BY seq;")
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, r := range rows {
		out = append(out, r["seq"]+": "+r["check_name"])
	}
	return out
}
