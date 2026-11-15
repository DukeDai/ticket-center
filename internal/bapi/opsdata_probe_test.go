package bapi

import (
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// TestOpsQueriesRun 是「每个读查询都能跑」的冒烟测试。
//
// 运营台最贵的一种错是「视图建对了，查询列名写错了」——
// 页面打开就是 500，而错误只在运行时出现。所以这里把每个查询都跑一遍，
// 列名写错当场红。
func TestOpsQueriesRun(t *testing.T) {
	name := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(name)

	if _, err := ChannelOverviews(db, 0); err != nil {
		t.Fatalf("渠道总览：%v", err)
	}
	if _, err := Catalog(db, 0, "", ""); err != nil {
		t.Fatalf("商品目录：%v", err)
	}
	if _, err := Catalog(db, 1, "测试", "online"); err != nil {
		t.Fatalf("商品目录（带筛选）：%v", err)
	}
	if _, err := Orders(db, OrderFilter{Limit: 10, Offset: 0}); err != nil {
		t.Fatalf("订单列表：%v", err)
	}
	if _, err := Orders(db, OrderFilter{Limit: 10, Offset: 0, Keyword: "50%"}); err != nil {
		t.Fatalf("订单列表（关键词含通配符）：%v", err)
	}
	if _, err := FulfillmentGaps(db, 0, false); err != nil {
		t.Fatalf("履约漏斗：%v", err)
	}
	if _, err := SupplyForms(db, 0, 0, "", false); err != nil {
		t.Fatalf("供给形态：%v", err)
	}
	if _, err := Refunds(db, 0, ""); err != nil {
		t.Fatalf("退款台账：%v", err)
	}
	if _, err := Redemptions(db, 0, "", 10); err != nil {
		t.Fatalf("核销记录：%v", err)
	}
	if _, err := Holds(db, 0, "", 10); err != nil {
		t.Fatalf("库存预占：%v", err)
	}
	if _, err := SupplierHealth(db); err != nil {
		t.Fatalf("源健康度：%v", err)
	}
	if _, err := SettlementGaps(db); err != nil {
		t.Fatalf("结算缺口：%v", err)
	}
	if _, err := ReassignCandidates(db, 0); err != nil {
		t.Fatalf("待改派清单：%v", err)
	}
}
