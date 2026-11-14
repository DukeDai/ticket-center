package sync

import (
	"context"
	"path/filepath"
	"testing"

	"ticket-center/internal/config"
	"ticket-center/internal/layertest"
	"ticket-center/internal/mock"
	"ticket-center/internal/normalize"
	"ticket-center/internal/testdb"
)

// TestSyncEndToEndAgainstMock 整条链对着本地 mock 跑通：抓 → 归一化 → 落库。
//
// 这条测试守的是**接线**：前面的测试各自钉一段（覆盖判定来自库、
// 幂等、不降级），这里钉的是它们接在一起还成立 ——
// 抓回来的报文真的能变成源层的行。
//
// 用 mock 不用真源：真源要商务凭证（硬约束 12），
// 而 mock 走的是**同一个适配器**（`registry.Build` + `EndpointOverride`），
// 所以这条测试验的是适配器到落库这一段，不是「凭证能不能拿到」。
func TestSyncEndToEndAgainstMock(t *testing.T) {
	db := testDB(t)
	root := testdb.RepoRoot()

	srv, err := mock.New(filepath.Join(root, "fixtures", "trip_com_catalog.json"))
	if err != nil {
		t.Fatalf("起 mock 失败：%v", err)
	}
	defer srv.Close()

	cfg, err := config.Load(filepath.Join(root, "configs", "api_config.json"))
	if err != nil {
		t.Fatalf("读配置失败：%v", err)
	}
	rules, err := normalize.LoadRules(filepath.Join(root, "configs", "mapping_rules.json"))
	if err != nil {
		t.Fatalf("读规则失败：%v", err)
	}

	// 端点指向本地 mock；凭证是 mock 模式专用的假值（只在内存里）。
	clone := cloneWithMockEndpoints(cfg, srv.Endpoints())

	ledger, err := Run(context.Background(), "trip_com", Options{
		DB:      db,
		Config:  clone,
		Rules:   rules,
		Env:     "sandbox",
		EnvVars: layertest.MockEnvVars,
		Timeout: 10 * 1000000000,
	})
	if err != nil {
		t.Fatalf("同步失败：%v", err)
	}
	if ledger.Status != "success" {
		t.Fatalf("台账状态 = %q，期望 success（error=%v）", ledger.Status, ledger.Error)
	}

	// 源层落了东西。
	n, err := db.Scalar("SELECT count(*) FROM supplier_product WHERE external_id <> '' AND supplier_id = 7;")
	if err != nil {
		t.Fatalf("数源商品失败：%v", err)
	}
	if n == "0" {
		t.Fatal("同步完了，一个源商品都没落")
	}

	// 台账上的四个数自洽：scanned = created + updated + skipped。
	s := ledger.Stats
	if s.Created+s.Updated+s.Skipped != s.Scanned {
		t.Errorf("台账计数不自洽：%+v（scanned 应等于其余三个之和）", s)
	}
	if s.Created == 0 {
		t.Errorf("第一次同步新建了 0 条：%+v", s)
	}

	// 原始报文归档了（硬约束 8）。
	payloads, err := db.Scalar("SELECT count(*) FROM supplier_raw_payload WHERE supplier_id = 7;")
	if err != nil {
		t.Fatalf("数归档报文失败：%v", err)
	}
	if payloads == "0" {
		t.Error("同步完了，一条原始报文都没归档")
	}
}

// cloneWithMockEndpoints 复制一份配置，把沙箱端点指向本地 mock。
//
// 复制而不是改原对象：配置是进程内共享的，
// 改了它，后面的测试就跟着跑到 mock 上去（而它们不知道自己跑在 mock 上）。
func cloneWithMockEndpoints(cfg *config.File, endpoints map[string]string) *config.File {
	clone := *cfg
	clone.Sources = map[string]*config.Source{}
	for k, v := range cfg.Sources {
		c := *v
		clone.Sources[k] = &c
	}
	src := clone.Sources["trip_com"]
	sandbox := map[string]string{}
	for k, v := range src.Endpoints.Sandbox {
		sandbox[k] = v
	}
	for k, v := range endpoints {
		sandbox[k] = v
	}
	src.Endpoints.Sandbox = sandbox
	return &clone
}
