package tripcom

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"

	"ticket-center/internal/apperr"
	"ticket-center/internal/config"
	"ticket-center/internal/credential"
	"ticket-center/internal/mock"
	"ticket-center/internal/store"
	"ticket-center/internal/supplier"
	"ticket-center/internal/testdb"
	"ticket-center/internal/transport"
)

// newAdapterAgainstMock 起一个协议 mock，返回指向它的适配器。
func newAdapterAgainstMock(t *testing.T) (*Adapter, *mock.Server) {
	t.Helper()
	cfgPath := filepath.Join("..", "..", "..", "configs", "api_config.json")
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("读配置失败：%v", err)
	}
	src, err := cfg.Get("trip_com")
	if err != nil {
		t.Fatal(err)
	}
	fixture := filepath.Join("..", "..", "..", "fixtures", "trip_com_catalog.json")
	srv, err := mock.New(fixture)
	if err != nil {
		t.Fatalf("起 mock 失败：%v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })

	// 端点指向 mock
	clone := *src
	clone.Endpoints = config.Endpoints{
		Prod:    map[string]string{},
		Sandbox: srv.Endpoints(),
		Extra:   map[string]map[string]string{},
	}
	// 加测试专用接口
	clone.Interfaces = map[string]config.Interface{}
	for k, v := range src.Interfaces {
		clone.Interfaces[k] = v
	}
	for name, icode := range map[string]string{
		"testRetry": "TESTRETRY01",
		"testFatal": "TESTFATAL01",
		"testIdem":  "TESTIDEM01",
		"testAuth":  "TESTAUTH01",
	} {
		clone.Interfaces[name] = config.Interface{ICodeSandbox: icode, ICodeProd: icode}
	}

	creds, err := credential.NewResolver("trip_com", clone.Credentials, nil).Resolve(false)
	if err != nil {
		t.Fatal(err)
	}
	credsResolver := credential.NewResolver("trip_com", clone.Credentials, nil)
	credsResolver.Lookup = func(k string) (string, bool) {
		switch k {
		case "TRIPCOM_AID":
			return "12345", true
		case "TRIPCOM_SID":
			return "45678", true
		case "TRIPCOM_KEY":
			return "MOCK-SECRET-KEY", true
		}
		return "", false
	}
	creds, err = credsResolver.Resolve(false)
	if err != nil {
		t.Fatal(err)
	}

	base := &supplier.Base{
		Code: "trip_com", Cfg: &clone, Creds: creds,
		Client: transport.NewClient(), Env: "sandbox",
	}
	return New(base), srv
}

func TestAuthenticateGetsToken(t *testing.T) {
	a, srv := newAdapterAgainstMock(t)
	detail, err := a.Authenticate(context.Background())
	if err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	if detail == "" {
		t.Error("认证应返回说明")
	}
	_, _, tokenReqs, _ := srv.State().Snapshot()
	if tokenReqs != 1 {
		t.Errorf("authorize 调用 %d 次，期望 1", tokenReqs)
	}
}

func TestCallSendsRequiredQueryParams(t *testing.T) {
	a, srv := newAdapterAgainstMock(t)
	if _, err := a.GetCategories(context.Background()); err != nil {
		t.Fatalf("调用失败：%v", err)
	}
	_, requests, _, _ := srv.State().Snapshot()
	var found bool
	for _, r := range requests {
		if r.Path != "/openservice/serviceproxy.ashx" {
			continue
		}
		if r.Query["icode"] == "" {
			t.Error("query 缺 icode")
		}
		for _, k := range []string{"aid", "sid", "uuid", "token"} {
			if r.Query[k] == "" {
				t.Errorf("query 缺 %s", k)
			}
		}
		found = true
	}
	if !found {
		t.Fatal("没有收到业务请求")
	}
}

func TestUUIDIsUniquePerRequest(t *testing.T) {
	a, srv := newAdapterAgainstMock(t)
	for i := 0; i < 3; i++ {
		if _, err := a.GetCategories(context.Background()); err != nil {
			t.Fatalf("调用失败：%v", err)
		}
	}
	_, requests, _, _ := srv.State().Snapshot()
	seen := map[string]bool{}
	n := 0
	for _, r := range requests {
		if r.Path != "/openservice/serviceproxy.ashx" {
			continue
		}
		n++
		if seen[r.Query["uuid"]] {
			t.Errorf("uuid 重复：%s", r.Query["uuid"])
		}
		seen[r.Query["uuid"]] = true
	}
	if n != 3 {
		t.Errorf("业务请求 %d 次，期望 3", n)
	}
}

func TestFatalErrorIsNotRetried(t *testing.T) {
	a, srv := newAdapterAgainstMock(t)
	srv.State().ResetCalls("TESTFATAL01")
	_, err := a.Call(context.Background(), "testFatal", map[string]any{}, "")
	ae, ok := err.(*apperr.Error)
	if !ok {
		t.Fatalf("期望适配器错误，得到 %T：%v", err, err)
	}
	if ae.Class != apperr.ClassFatal {
		t.Errorf("分类 = %s，期望 fatal", ae.Class)
	}
	if n := srv.State().Calls("TESTFATAL01"); n != 1 {
		t.Errorf("fatal 调了 %d 次，期望 1（不重试）", n)
	}
}

func TestIdempotentHitIsNotFailure(t *testing.T) {
	a, _ := newAdapterAgainstMock(t)
	res, err := a.Call(context.Background(), "testIdem", map[string]any{}, "")
	if err != nil {
		t.Fatalf("幂等命中不该报错：%v", err)
	}
	if !res.IdempotentHit {
		t.Error("B0010 应被识别为幂等命中")
	}
}

func TestMissingICodeReportsUnconfirmed(t *testing.T) {
	a, _ := newAdapterAgainstMock(t)
	// 找一个没有 ICODE 的接口：listAllProducts 在沙箱有、生产没有，这里直接构造
	a.Cfg.Interfaces["noCode"] = config.Interface{}
	_, err := a.Call(context.Background(), "noCode", map[string]any{}, "")
	u, ok := apperr.AsUnconfirmed(err)
	if !ok {
		t.Fatalf("期望 EndpointUnconfirmed，得到 %T：%v", err, err)
	}
	if u.Need == "" {
		t.Error("应说明需要什么")
	}
}

func TestArchiveRedactsCredentials(t *testing.T) {
	// 以前这里连的是开发机上的 ticket_center_mock —— 一台机器上没这个库就跳过，
	// 有这个库但没 seed 就插入失败。改成一次性库，每次都是干净状态。
	dbName := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(dbName)

	// 归档要挂在真正的 trip_com 源下面（supplier_raw_payload.supplier_id 是外键）。
	supplierID, err := db.Scalar("SELECT id FROM supplier WHERE code='trip_com';")
	if err != nil {
		t.Fatalf("查 supplier 失败：%v", err)
	}
	if supplierID == "" {
		t.Fatal("种子数据里没有 trip_com 这个源")
	}
	var sid int64
	if _, err := fmt.Sscanf(supplierID, "%d", &sid); err != nil {
		t.Fatalf("supplier id 不是整数：%q", supplierID)
	}

	a, _ := newAdapterAgainstMock(t)
	archiver := store.NewArchiver(db, sid, true)
	a.Archiver = archiver
	if _, err := a.GetCategories(context.Background()); err != nil {
		t.Fatalf("调用失败：%v", err)
	}
	rows, err := db.Rows("SELECT request::text, response::text FROM supplier_raw_payload ORDER BY id DESC LIMIT 5;")
	if err != nil {
		t.Fatalf("查归档失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("没有归档记录")
	}
	for _, r := range rows {
		blob := r["request"] + r["response"]
		if containsSubstr(blob, "MOCK-SECRET-KEY") || containsSubstr(blob, "MOCK-ACCESS-TOKEN") {
			t.Fatalf("归档泄露凭证：%s", blob)
		}
	}
}

func containsSubstr(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
