package bapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestConsolePagesRender 是「每个页签都能渲染」。
//
// 模板里最常见的错是字段名写错 —— 那会让整页 500，
// 而运营台是拿来处理线上问题的：台子打不开的时候正是最需要它的时候。
func TestConsolePagesRender(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	for _, tab := range []string{
		"overview", "orders", "gaps", "supply", "refunds",
		"redemptions", "sources", "holds", "reassign",
	} {
		rec := rig.do(t, "GET", "/console?tab="+tab, c, nil)
		if rec.Code != http.StatusOK {
			t.Errorf("页签 %s 返回 %d：%s", tab, rec.Code, rec.Body.String())
			continue
		}
		body := rec.Body.String()
		if !strings.Contains(body, "运营台") {
			t.Errorf("页签 %s 的页面里没有标题", tab)
		}
		if strings.Contains(body, "渲染失败") {
			t.Errorf("页签 %s 渲染失败：%s", tab, body)
		}
	}
}

// TestConsoleOrderDetailRenders 是「订单详情页能渲染」。
func TestConsoleOrderDetailRenders(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "GET", "/console?tab=orders", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("读订单页：%d", rec.Code)
	}
	// 从页面里抠一个订单链接出来，再去点它。
	idx := strings.Index(rec.Body.String(), "/console?tab=order_detail&order_id=")
	if idx < 0 {
		t.Skip("库里没有订单，跳过详情页测试")
	}
	rest := rec.Body.String()[idx:]
	end := strings.IndexAny(rest, "\"'")
	if end < 0 {
		t.Fatalf("订单链接格式不对")
	}
	link := rest[:end]

	rec2 := rig.do(t, "GET", link, c, nil)
	if rec2.Code != http.StatusOK {
		t.Fatalf("订单详情页返回 %d：%s", rec2.Code, rec2.Body.String())
	}
	if strings.Contains(rec2.Body.String(), "渲染失败") {
		t.Errorf("订单详情页渲染失败")
	}
}

// TestConsoleNeedsLogin 是「没登录访问运营台被送去登录页」。
func TestConsoleNeedsLogin(t *testing.T) {
	rig := newRig(t)
	rec := rig.do(t, "GET", "/console", nil, nil)
	if rec.Code != http.StatusSeeOther {
		t.Errorf("未登录访问运营台返回 %d，应该是 303 跳转登录页", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/login" {
		t.Errorf("跳转到 %q，应该是 /login", loc)
	}
}

// TestLoginPageRenders 是「登录页能渲染」。
func TestLoginPageRenders(t *testing.T) {
	rig := newRig(t)
	rec := rig.do(t, "GET", "/login", nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("登录页返回 %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{"运营台登录", `name="code"`, `name="secret"`} {
		if !strings.Contains(body, want) {
			t.Errorf("登录页里没有 %q", want)
		}
	}
}

// TestStaticAssetServes 是「CSS 能取到」。
func TestStaticAssetServes(t *testing.T) {
	rig := newRig(t)
	req := httptest.NewRequest("GET", "/static/app.css", nil)
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("取 CSS 返回 %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/css") {
		t.Errorf("CSS 的 Content-Type 是 %q", ct)
	}
}

// TestStaticAssetRejectsTraversal 是「静态资源不许穿目录」。
func TestStaticAssetRejectsTraversal(t *testing.T) {
	rig := newRig(t)
	for _, path := range []string{
		"/static/../templates/console.html",
		"/static/..%2ftemplates%2fconsole.html",
	} {
		req := httptest.NewRequest("GET", path, nil)
		rec := httptest.NewRecorder()
		rig.srv.ServeHTTP(rec, req)
		if rec.Code == http.StatusOK {
			t.Errorf("%s 返回了 200，静态资源不该能被穿出去", path)
		}
	}
}

// TestLoginFormSetsSession 是「表单登录能拿到会话 cookie」。
func TestLoginFormSetsSession(t *testing.T) {
	rig := newRig(t)
	form := strings.NewReader("code=ops_admin&secret=" + rig.admin)
	req := httptest.NewRequest("POST", "/login", form)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("表单登录返回 %d，应该是 303", rec.Code)
	}
	found := false
	for _, ck := range rec.Result().Cookies() {
		if ck.Name == sessionCookie && ck.Value != "" {
			found = true
		}
	}
	if !found {
		t.Errorf("表单登录没有下发会话 cookie")
	}
}

// TestLoginFormWrongSecretRedirects 是「凭证不对回到登录页并带错误」。
func TestLoginFormWrongSecretRedirects(t *testing.T) {
	rig := newRig(t)
	form := strings.NewReader("code=ops_admin&secret=wrong")
	req := httptest.NewRequest("POST", "/login", form)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	rig.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("凭证不对时返回 %d，应该是 303", rec.Code)
	}
	if loc := rec.Header().Get("Location"); !strings.Contains(loc, "error=") {
		t.Errorf("跳转到 %q，应该带上错误说明", loc)
	}
}
