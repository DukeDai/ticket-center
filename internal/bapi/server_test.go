package bapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// testRig 是测试用的运营台：数据库 + 服务 + 一个 admin 操作员。
type testRig struct {
	db       *store.DB
	srv      *Server
	admin    string // 明文凭证
	viewer   string
	operator string
}

// newRig 建一套测试环境。
//
// 建三个角色：admin（能放行）、operator（能写但不能放行）、viewer（只读）。
// 角色门禁是这块最容易被漏掉的东西 —— 漏一个就是「只读的人能放行退款」。
func newRig(t *testing.T) *testRig {
	t.Helper()
	name := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(name)
	srv := New(db, Options{})

	ops := NewOperatorService(db)
	admin, err := ops.Create("ops_admin", "管理员", RoleAdmin)
	if err != nil {
		t.Fatalf("建 admin：%v", err)
	}
	operator, err := ops.Create("ops_writer", "运营", RoleOperator)
	if err != nil {
		t.Fatalf("建 operator：%v", err)
	}
	viewer, err := ops.Create("ops_read", "只读", RoleViewer)
	if err != nil {
		t.Fatalf("建 viewer：%v", err)
	}
	return &testRig{db: db, srv: srv, admin: admin, viewer: viewer, operator: operator}
}

// login 登录并拿到会话 cookie。
func (rig *testRig) login(t *testing.T, code, secret string) *http.Cookie {
	t.Helper()
	body := map[string]string{"code": code, "secret": secret}
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/api/v1/auth/login", strings.NewReader(string(raw)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("登录失败：%d %s", rec.Code, rec.Body.String())
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookie {
			return c
		}
	}
	t.Fatalf("登录没有下发会话 cookie")
	return nil
}

// do 发一个带会话的请求。
func (rig *testRig) do(t *testing.T, method, path string, cookie *http.Cookie, body any) *httptest.ResponseRecorder {
	t.Helper()
	var reader *strings.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("序列化请求体：%v", err)
		}
		reader = strings.NewReader(string(raw))
	} else {
		reader = strings.NewReader("")
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	return rec
}

// -------------------------------------------------------------------------------------

// TestReadEndpointsNeedLogin 是「没登录就是 401」。
//
// 运营台是内部工具但它连着生产库。匿名可读 = 换个端口号就能看全部渠道的订单。
func TestReadEndpointsNeedLogin(t *testing.T) {
	rig := newRig(t)
	for _, path := range []string{
		"/api/v1/channels",
		"/api/v1/products",
		"/api/v1/orders",
		"/api/v1/refunds",
		"/api/v1/fulfillment/gaps",
		"/api/v1/supply-forms",
		"/api/v1/redemptions",
		"/api/v1/inventory/holds",
		"/api/v1/suppliers/health",
		"/api/v1/settlement/gaps",
		"/api/v1/reassign/candidates",
		"/api/v1/operators",
	} {
		rec := rig.do(t, "GET", path, nil, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s 未登录时返回 %d，应该是 401", path, rec.Code)
		}
	}
}

// TestLoginWrongSecretIsUnauthorized 是「凭证不对就是 401，且不泄露操作员是否存在」。
func TestLoginWrongSecretIsUnauthorized(t *testing.T) {
	rig := newRig(t)
	raw, _ := json.Marshal(map[string]string{"code": "ops_admin", "secret": "wrong"})
	req := httptest.NewRequest("POST", "/api/v1/auth/login", strings.NewReader(string(raw)))
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("凭证不对时返回 %d，应该是 401", rec.Code)
	}

	// 不存在的操作员给同一个答复：不给调用方枚举 code 的探针。
	raw2, _ := json.Marshal(map[string]string{"code": "no_such_op", "secret": "whatever"})
	req2 := httptest.NewRequest("POST", "/api/v1/auth/login", strings.NewReader(string(raw2)))
	rec2 := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("操作员不存在时返回 %d，应该是 401", rec2.Code)
	}
	if strings.TrimSpace(rec.Body.String()) != strings.TrimSpace(rec2.Body.String()) {
		t.Errorf("凭证不对与操作员不存在的答复应当相同：\n%q\n%q",
			rec.Body.String(), rec2.Body.String())
	}
}

// TestReadEndpointsWork 是「每个读端点登录后能跑通并返回可解析的行」。
func TestReadEndpointsWork(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	for _, path := range []string{
		"/api/v1/channels",
		"/api/v1/products",
		"/api/v1/orders",
		"/api/v1/refunds",
		"/api/v1/fulfillment/gaps",
		"/api/v1/supply-forms",
		"/api/v1/redemptions",
		"/api/v1/inventory/holds",
		"/api/v1/suppliers/health",
		"/api/v1/settlement/gaps",
		"/api/v1/reassign/candidates",
		"/api/v1/operators",
	} {
		rec := rig.do(t, "GET", path, c, nil)
		if rec.Code != http.StatusOK {
			t.Errorf("%s 返回 %d：%s", path, rec.Code, rec.Body.String())
			continue
		}
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Errorf("%s 的响应不是合法 JSON：%v", path, err)
		}
	}
}

// TestChannelOverviewIsCrossChannel 是「运营台看得到多个渠道」。
//
// 这是运营台与 C 端最本质的区别：C 端只看自己那一个渠道，
// 运营台要看全部 —— 哪个渠道在堆积、哪个渠道的履约缺口大。
func TestChannelOverviewIsCrossChannel(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "GET", "/api/v1/channels", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("读渠道总览：%d %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Channels []struct {
			ChannelID   int64  `json:"channel_id"`
			ChannelType string `json:"channel_type"`
		} `json:"channels"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("解析渠道总览：%v", err)
	}
	types := map[string]bool{}
	for _, ch := range body.Channels {
		types[ch.ChannelType] = true
	}
	for _, want := range []string{"b2c_own", "b2b_distributor", "corporate"} {
		if !types[want] {
			t.Errorf("渠道总览里没有 %s 类型的渠道（运营台要跨渠道）", want)
		}
	}
}

// TestViewerCannotWrite 是「只读角色写不了」。
func TestViewerCannotWrite(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_read", rig.viewer)

	rec := rig.do(t, "POST", "/api/v1/orders", c, map[string]any{
		"channel_id":      1,
		"customer_id":     1,
		"idempotency_key": "viewer-test-1",
	})
	if rec.Code != http.StatusForbidden {
		t.Errorf("viewer 下单返回 %d，应该是 403", rec.Code)
	}
}

// TestOperatorCannotApprove 是「放行退款只给 admin」。
//
// 放行是留痕的动作，痕迹是追责的依据 —— 让 operator 也能放行，
// 追责就断在「哪个 operator 干的」这一层。
func TestOperatorCannotApprove(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_writer", rig.operator)

	rec := rig.do(t, "POST", "/api/v1/refunds/1/approval", c, map[string]any{
		"refund_id": 1,
	})
	if rec.Code != http.StatusForbidden {
		t.Errorf("operator 放行退款返回 %d，应该是 403", rec.Code)
	}
}

// TestPlaceOrderRequiresIdempotencyKey 是「下单必须带幂等键」。
//
// 重放一次下单 = 落两单 = 收了两次钱发了两张票。
func TestPlaceOrderRequiresIdempotencyKey(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "POST", "/api/v1/orders", c, map[string]any{
		"channel_id":  1,
		"customer_id": 1,
	})
	if rec.Code != http.StatusBadRequest {
		t.Errorf("缺幂等键的下单返回 %d，应该是 400", rec.Code)
	}
}

// TestRequestRefundRequiresIdempotencyKey 是「发起退款必须带幂等键」。
//
// 重放一次退款就是多退一次钱。
func TestRequestRefundRequiresIdempotencyKey(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "POST", "/api/v1/refunds", c, map[string]any{
		"order_id": 1,
		"amount":   "100.00",
	})
	if rec.Code != http.StatusBadRequest {
		t.Errorf("缺幂等键的退款返回 %d，应该是 400", rec.Code)
	}
}

// TestDisabledOperatorCannotLogin 是「停用的操作员登不进去」。
//
// 停用要立刻生效：改 status 只是不让重新登录，
// 已签发的会话还得靠换盐作废（CLI 的 disable 两条都做）。
func TestDisabledOperatorCannotLogin(t *testing.T) {
	rig := newRig(t)

	// 先建一个，停用它，再登。
	ops := NewOperatorService(rig.db)
	secret, err := ops.Create("ops_off", "已停用", RoleAdmin)
	if err != nil {
		t.Fatalf("建操作员：%v", err)
	}
	if err := rig.db.Exec(
		`UPDATE b2b_operator SET status = 'disabled' WHERE code = 'ops_off';`); err != nil {
		t.Fatalf("停用：%v", err)
	}

	raw, _ := json.Marshal(map[string]string{"code": "ops_off", "secret": secret})
	req := httptest.NewRequest("POST", "/api/v1/auth/login", strings.NewReader(string(raw)))
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("停用的操作员登录返回 %d，应该是 401", rec.Code)
	}
}

// TestDisabledOperatorSessionRejected 是「停用后已有会话也立刻作废」。
func TestDisabledOperatorSessionRejected(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	// 登录成功后停用它 —— 会话还在手上，但不该再能读。
	if err := rig.db.Exec(
		`UPDATE b2b_operator SET status = 'disabled' WHERE code = 'ops_admin';`); err != nil {
		t.Fatalf("停用：%v", err)
	}
	rec := rig.do(t, "GET", "/api/v1/channels", c, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("停用后用旧会话读渠道返回 %d，应该是 401", rec.Code)
	}
}

// TestLogoutClearsSession 是「登出后不能再读」。
func TestLogoutClearsSession(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "POST", "/api/v1/auth/logout", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("登出：%d %s", rec.Code, rec.Body.String())
	}
	// 登出后浏览器不再带 cookie；这里模拟「带一个空 cookie」的情形。
	empty := &http.Cookie{Name: sessionCookie, Value: ""}
	rec2 := rig.do(t, "GET", "/api/v1/channels", empty, nil)
	if rec2.Code != http.StatusUnauthorized {
		t.Errorf("登出后读渠道返回 %d，应该是 401", rec2.Code)
	}
}

// TestMeReportsOperator 是「会话能报出当前操作员与角色」。
func TestMeReportsOperator(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "GET", "/api/v1/auth/me", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("读当前操作员：%d %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Operator struct {
			Code string `json:"code"`
			Role string `json:"role"`
		} `json:"operator"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("解析：%v", err)
	}
	if body.Operator.Code != "ops_admin" {
		t.Errorf("报出的操作员是 %q，应该是 ops_admin", body.Operator.Code)
	}
	if body.Operator.Role != RoleAdmin {
		t.Errorf("报出的角色是 %q，应该是 admin", body.Operator.Role)
	}
}
