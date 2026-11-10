package capi_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"ticket-center/internal/capi"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// C 端只读 API 的行为约定：
//   - 读模型是唯一的出处：请求链路不 join 主数据、不重算事实；
//   - 渠道是必答的那一半：成分明细按渠道建，不按渠道过滤会把份数数成两遍；
//   - 有效期终点由库算好，前端不自己加一天；
//   - 参数不合法就报错，不猜、不糊过去。

func seeded(t *testing.T) (*store.DB, http.Handler) {
	t.Helper()
	db := store.New(testdb.New(t, testdb.Options{Seed: true}))
	return db, capi.New(db)
}

// get 发一个请求，返回状态码与解码后的响应体。
func get(t *testing.T, h http.Handler, path string) (int, map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	body := map[string]any{}
	if rec.Body.Len() > 0 {
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("响应不是合法 JSON：%v（原文 %s）", err, rec.Body.String())
		}
	}
	return rec.Code, body
}

func items(t *testing.T, body map[string]any) []map[string]any {
	t.Helper()
	raw, ok := body["items"].([]any)
	if !ok {
		t.Fatalf("响应里没有 items：%v", body)
	}
	out := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		m, ok := r.(map[string]any)
		if !ok {
			t.Fatalf("items 里不是对象：%v", r)
		}
		out = append(out, m)
	}
	return out
}

func TestProductListIsScopedByChannelAndLocale(t *testing.T) {
	_, h := seeded(t)

	code, body := get(t, h, "/api/v1/products?channel_id=1&locale=zh-CN")
	if code != http.StatusOK {
		t.Fatalf("列表应返回 200，实际 %d", code)
	}
	list := items(t, body)
	if len(list) == 0 {
		t.Fatal("列表不该是空的")
	}
	for _, c := range list {
		if c["channel_id"].(float64) != 1 {
			t.Fatalf("列表里混进了别的渠道：%v", c["channel_id"])
		}
		if c["locale"] != "zh-CN" {
			t.Fatalf("列表里混进了别的语言：%v", c["locale"])
		}
		if c["title"] == "" {
			t.Fatal("卡片没有标题")
		}
		// 价格是 NUMERIC，以字符串出（Go 没有十进制类型）。
		if c["from_price"] == "" {
			t.Fatal("卡片没有起价")
		}
		if c["currency"] == "" {
			t.Fatal("卡片没有币种")
		}
	}
	if int(body["total"].(float64)) != len(list) {
		t.Fatalf("总数 %v 与返回条数 %d 对不上", body["total"], len(list))
	}

	// 换个语言，卡片就不一样（读模型是按 locale 建的）。
	_, en := get(t, h, "/api/v1/products?channel_id=1&locale=en-HK")
	enList := items(t, en)
	if len(enList) == 0 {
		t.Fatal("英文版列表不该是空的")
	}
	for _, c := range enList {
		if c["locale"] != "en-HK" {
			t.Fatalf("英文版里混进了别的语言：%v", c["locale"])
		}
	}
}

func TestProductListRejectsBadParams(t *testing.T) {
	_, h := seeded(t)

	for _, path := range []string{
		"/api/v1/products",                           // 渠道必答
		"/api/v1/products?channel_id=abc",            // 不是数字
		"/api/v1/products?channel_id=0",              // 不是正整数
		"/api/v1/products?channel_id=1&locale=a%20b", // locale 不该有空格
		"/api/v1/products?channel_id=1&limit=0",      // limit 越界
	} {
		code, body := get(t, h, path)
		if code != http.StatusBadRequest {
			t.Fatalf("%s 应返回 400，实际 %d", path, code)
		}
		errObj, ok := body["error"].(map[string]any)
		if !ok || errObj["code"] != "bad_request" {
			t.Fatalf("%s 的错误体不对：%v", path, body)
		}
		if msg, _ := errObj["message"].(string); msg == "" {
			t.Fatalf("%s 的错误没有说清楚：%v", path, body)
		}
	}
}

func TestOfflineCardIsNotListed(t *testing.T) {
	db, h := seeded(t)

	if err := db.Exec("UPDATE c_product_card SET status = 'offline' WHERE product_id = 3;"); err != nil {
		t.Fatalf("下架卡片失败：%v", err)
	}
	_, body := get(t, h, "/api/v1/products?channel_id=1&locale=zh-CN")
	for _, c := range items(t, body) {
		if c["product_id"].(float64) == 3 {
			t.Fatal("下架的卡片不该出现在列表里")
		}
	}
}

func TestVariantFeedCarriesDifferenceFacts(t *testing.T) {
	_, h := seeded(t)

	code, body := get(t, h, "/api/v1/products/6/variants?channel_id=1")
	if code != http.StatusOK {
		t.Fatalf("变体行应返回 200，实际 %d", code)
	}
	rows := items(t, body)

	byCode := map[string]map[string]any{}
	for _, r := range rows {
		byCode[r["variant_code"].(string)] = r
	}

	// 两日票的有效天数是 2 —— 差异事实必须带出来。
	two, ok := byCode["USJ-ADULT-2D-STD"]
	if !ok {
		t.Fatal("没拿到两日成人票这一行")
	}
	if two["valid_days"].(float64) != 2 {
		t.Fatalf("两日票的有效天数应为 2，实际 %v", two["valid_days"])
	}

	// 套餐要带出构成摘要：这是 2 份成人 + 1 儿童。
	combo, ok := byCode["USJ-FAMILY-2A1C"]
	if !ok {
		t.Fatal("没拿到家庭套票这一行")
	}
	if combo["is_combo"] != true {
		t.Fatalf("家庭套票应标成组合，实际 %v", combo["is_combo"])
	}
	if combo["component_count"].(float64) != 2 {
		t.Fatalf("家庭套票的成分数应为 2，实际 %v", combo["component_count"])
	}
	if combo["composition"] == nil {
		t.Fatal("组合行必须带出构成摘要")
	}

	// 轴取值是结构化事实，不是文案。普通变体带自己的轴取值。
	one, ok := byCode["USJ-ADULT-1D-STD"]
	if !ok {
		t.Fatal("没拿到单日成人票这一行")
	}
	axes, ok := one["axes"].(map[string]any)
	if !ok || len(axes) == 0 {
		t.Fatalf("轴取值没带出来：%v", one["axes"])
	}
	if axes["pass_type"] != "1d" {
		t.Fatalf("轴取值读错了：%v", axes)
	}

	// 组合没有单一人群：人群是每个成分各自的编码（成人 + 儿童）。
	if combo["audience"] != "" {
		t.Fatalf("组合不该有单一人群，实际 %v", combo["audience"])
	}
	if !strings.Contains(combo["combo_audience"].(string), "adult") ||
		!strings.Contains(combo["combo_audience"].(string), "child") {
		t.Fatalf("组合的人群编码没带出来：%v", combo["combo_audience"])
	}
}

func TestCompositionIsScopedByChannel(t *testing.T) {
	_, h := seeded(t)

	// 20 号套餐上了两个渠道，两边各有一份成分明细。
	for _, channel := range []string{"1", "2"} {
		code, body := get(t, h, "/api/v1/variants/20/composition?channel_id="+channel)
		if code != http.StatusOK {
			t.Fatalf("成分清单应返回 200，实际 %d", code)
		}
		rows := items(t, body)
		if len(rows) != 2 {
			t.Fatalf("渠道 %s 的成分数应为 2，实际 %d（不按渠道过滤会把份数数成两遍）", channel, len(rows))
		}
		audiences := map[string]bool{}
		for _, r := range rows {
			audiences[r["audience_code"].(string)] = true
		}
		if !audiences["adult"] || !audiences["child"] {
			t.Fatalf("渠道 %s 的成分人群不对：%v", channel, audiences)
		}
	}

	// 份数是字符串（NUMERIC 不许用浮点）。
	_, body := get(t, h, "/api/v1/variants/20/composition?channel_id=1")
	for _, r := range items(t, body) {
		q, ok := r["quantity"].(string)
		if !ok {
			t.Fatalf("份数必须以字符串出：%T", r["quantity"])
		}
		if q != "1.00" && q != "2.00" {
			t.Fatalf("份数不对：%v", q)
		}
	}
}

func TestCalendarCarriesLibraryComputedValidTo(t *testing.T) {
	_, h := seeded(t)

	// 两日票：格子日期 2026-11-22，有效期终点是 11-24（库里算的，前端不自己加一天）。
	code, body := get(t, h, "/api/v1/variants/14/calendar?channel_id=1")
	if code != http.StatusOK {
		t.Fatalf("日历应返回 200，实际 %d", code)
	}
	rows := items(t, body)
	if len(rows) == 0 {
		t.Fatal("日历不该是空的")
	}
	for _, r := range rows {
		if r["date"] != "2026-11-22" {
			continue
		}
		if r["valid_to"] != "2026-11-24" {
			t.Fatalf("两日票的有效期终点应为 2026-11-24，实际 %v", r["valid_to"])
		}
	}

	// 单日票：终点是次日。
	_, one := get(t, h, "/api/v1/variants/9/calendar?channel_id=1")
	for _, r := range items(t, one) {
		if r["date"] == "2026-11-22" && r["valid_to"] != "2026-11-23" {
			t.Fatalf("单日票的有效期终点应为 2026-11-23，实际 %v", r["valid_to"])
		}
	}
}

func TestCalendarRejectsBadRange(t *testing.T) {
	_, h := seeded(t)

	for _, path := range []string{
		"/api/v1/variants/9/calendar?channel_id=1&from=2026-13-01",
		"/api/v1/variants/9/calendar?channel_id=1&from=2026-11-22&to=2026-11-01",
	} {
		code, body := get(t, h, path)
		if code != http.StatusBadRequest {
			t.Fatalf("%s 应返回 400，实际 %d", path, code)
		}
		if errObj, ok := body["error"].(map[string]any); !ok || errObj["code"] != "bad_request" {
			t.Fatalf("%s 的错误体不对：%v", path, body)
		}
	}
}

func TestUnknownPathIsNotFound(t *testing.T) {
	_, h := seeded(t)
	code, _ := get(t, h, "/api/v1/nope")
	if code != http.StatusNotFound {
		t.Fatalf("未知路径应返回 404，实际 %d", code)
	}
}

func TestHealthzReportsDatabase(t *testing.T) {
	_, h := seeded(t)
	code, body := get(t, h, "/healthz")
	if code != http.StatusOK {
		t.Fatalf("探活应返回 200，实际 %d", code)
	}
	if body["status"] != "ok" {
		t.Fatalf("探活应报 ok，实际 %v", body)
	}
	if !strings.Contains(body["database"].(string), "tc_test_") {
		t.Fatalf("探活没带上库名：%v", body)
	}
}
