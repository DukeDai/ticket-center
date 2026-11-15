package bapi

import (
	"net/http"
	"strings"
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// TestProductQueriesRun 是「每个商品详情查询都能跑」的冒烟测试。
//
// 与 TestOpsQueriesRun 同一个理由：视图建对了、查询列名写错了，
// 页面打开就是 500，而错误只在运行时出现。列名写错当场红。
func TestProductQueriesRun(t *testing.T) {
	name := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(name)

	head, err := ProductHeadByID(db, 1)
	if err != nil {
		t.Fatalf("商品头：%v", err)
	}
	if head.ProductID != 1 {
		t.Errorf("商品头 id 应该是 1，实际是 %d", head.ProductID)
	}
	if _, err := ProductSources(db, head.ProductID); err != nil {
		t.Fatalf("源绑定：%v", err)
	}
	if _, err := ProductVariants(db, head.ProductID); err != nil {
		t.Fatalf("可售单元：%v", err)
	}
	if _, err := ProductListings(db, head.ProductID); err != nil {
		t.Fatalf("上架配置：%v", err)
	}
	if _, err := ProductPrices(db, head.ProductID); err != nil {
		t.Fatalf("售价行：%v", err)
	}
	if _, err := ProductContents(db, head.ProductID); err != nil {
		t.Fatalf("展示文案：%v", err)
	}
	if _, err := ProductDetailByID(db, head.ProductID); err != nil {
		t.Fatalf("商品详情：%v", err)
	}
}

// TestProductHeadNotFound 是「商品不存在就明确报不存在」。
//
// 这一条不许返回「一个空的详情」——
// 详情页分不清「商品不存在」与「商品存在但什么都没绑定」，
// 运营会以为商品还在，只是没数据。
func TestProductHeadNotFound(t *testing.T) {
	name := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(name)

	if _, err := ProductHeadByID(db, 999999); err == nil {
		t.Errorf("不存在的商品应该报错，实际返回了详情")
	}
	if _, err := ProductDetailByID(db, 999999); err == nil {
		t.Errorf("不存在的商品应该报错，实际返回了详情")
	}
	if _, err := ProductHeadByID(db, 0); err == nil {
		t.Errorf("product_id 应该是正整数，0 应该报错")
	}
}

// TestProductDetailHasRealData 是「详情页拿到的是真东西」。
//
// 这里是防「视图建出来了但查出来是空表」——
// 页面一片空白，运营以为这个商品没货，其实库里什么都有。
func TestProductDetailHasRealData(t *testing.T) {
	name := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(name)

	// 商品头里就带着家底计数 —— 详情页拿到的五块该与它对得上。
	head, err := ProductHeadByID(db, 1)
	if err != nil {
		t.Fatalf("商品头：%v", err)
	}
	d, err := ProductDetailByID(db, head.ProductID)
	if err != nil {
		t.Fatalf("商品详情：%v", err)
	}
	if len(d.Variants) == 0 {
		t.Errorf("商品 %s 没有可售单元", d.ProductCode)
	}
	if len(d.Listings) == 0 {
		t.Errorf("商品 %s 没有上架配置", d.ProductCode)
	}
	if len(d.Prices) == 0 {
		t.Errorf("商品 %s 没有售价行", d.ProductCode)
	}
}

// TestProductDetailAPI 是「商品详情端点能取到详情」。
func TestProductDetailAPI(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	head, err := ProductHeadByID(rig.db, 1)
	if err != nil {
		t.Fatalf("商品头：%v", err)
	}
	rec := rig.do(t, "GET", "/api/v1/products/"+itoa(head.ProductID), c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("商品详情返回 %d：%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	for _, want := range []string{head.ProductCode, "variants", "sources", "prices"} {
		if !strings.Contains(body, want) {
			t.Errorf("详情响应里没有 %q：%s", want, body)
		}
	}
}

// TestProductDetailAPINeedsLogin 是「没登录取不到商品详情」。
func TestProductDetailAPINeedsLogin(t *testing.T) {
	rig := newRig(t)
	rec := rig.do(t, "GET", "/api/v1/products/1", nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("未登录取商品详情返回 %d，应该是 401", rec.Code)
	}
}

// TestProductDetailAPIRejectsBadID 是「id 不是正整数就报错」。
func TestProductDetailAPIRejectsBadID(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)
	rec := rig.do(t, "GET", "/api/v1/products/abc", c, nil)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("id 不是数字时返回 %d，应该是 400", rec.Code)
	}
}

// TestConsoleCatalogRenders 是「商品目录页能渲染」。
func TestConsoleCatalogRenders(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "GET", "/console?tab=catalog", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("商品目录页返回 %d：%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if strings.Contains(body, "渲染失败") {
		t.Errorf("商品目录页渲染失败：%s", body)
	}
	for _, bad := range []string{"必须是正整数", "读商品目录失败"} {
		if strings.Contains(body, bad) {
			t.Errorf("商品目录页报了错（%q）：%s", bad, body)
		}
	}
	// 目录页要能看到商品并能点进详情。
	if !strings.Contains(body, "/console?tab=product_detail&product_id=") {
		t.Errorf("商品目录页里没有详情链接：%s", body)
	}
}

// TestConsoleProductDetailRenders 是「商品详情页能渲染」。
//
// 与订单详情页那次同一个教训：错误页的 HTTP 状态也是 200，
// 所以断言的不只是状态码，还要断言「页面里没有它自己报出来的错」。
func TestConsoleProductDetailRenders(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "GET", "/console?tab=catalog", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("读商品目录页：%d", rec.Code)
	}
	idx := strings.Index(rec.Body.String(), "/console?tab=product_detail&product_id=")
	if idx < 0 {
		t.Skip("库里没有商品，跳过详情页测试")
	}
	rest := rec.Body.String()[idx:]
	end := strings.IndexAny(rest, "\"'")
	if end < 0 {
		t.Fatalf("商品详情链接格式不对")
	}
	link := rest[:end]

	rec2 := rig.do(t, "GET", link, c, nil)
	if rec2.Code != http.StatusOK {
		t.Fatalf("商品详情页返回 %d：%s", rec2.Code, rec2.Body.String())
	}
	body := rec2.Body.String()
	if strings.Contains(body, "渲染失败") {
		t.Errorf("商品详情页渲染失败")
	}
	for _, bad := range []string{"必须是正整数", "没有找到这个商品", "读源绑定失败", "读售价行失败"} {
		if strings.Contains(body, bad) {
			t.Errorf("商品详情页报了错（%q）：%s", bad, body)
		}
	}
	// 详情页要有五块：源绑定、可售单元、上架配置、展示文案、售价行。
	for _, want := range []string{"源绑定", "可售单元", "上架配置", "展示文案", "售价行"} {
		if !strings.Contains(body, want) {
			t.Errorf("商品详情页里没有 %q 这一块", want)
		}
	}
}

// TestConsoleProductDetailMissingProduct 是「商品不存在时页面说清楚」。
//
// 不许 500，也不许一个空页 ——
// 运营会以为台子坏了，而不是「那个 id 不存在」。
func TestConsoleProductDetailMissingProduct(t *testing.T) {
	rig := newRig(t)
	c := rig.login(t, "ops_admin", rig.admin)

	rec := rig.do(t, "GET", "/console?tab=product_detail&product_id=999999", c, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("商品不存在时返回 %d，应该是 200 加说明", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "没有找到这个商品") {
		t.Errorf("页面没有说「没有找到这个商品」：%s", body)
	}
}

// itoa 把 int64 变成字符串（测试里拼路径用）。
func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// TestEvidenceSignals 是「匹配依据把信号列出来」。
//
// 依据存的是 jsonb，整段摊在表格里没人扫 ——
// 运营要看的���「凭什么说它匹配」。拼不出来就原样返回那段 JSON：
// 依据的形状是机器写进来的，运营台不替它猜结构。
func TestEvidenceSignals(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "有信号就拼成一行",
			in:   `{"signals": ["title_exact", "same_venue", "same_city"], "decided_by": "ops@demo"}`,
			want: "title_exact · same_venue · same_city",
		},
		{
			name: "信号带值也照拼",
			in:   `{"signals": ["title_similarity:0.93", "same_venue"]}`,
			want: "title_similarity:0.93 · same_venue",
		},
		{
			name: "空依据给个破折号",
			in:   "",
			want: "—",
		},
		{
			name: "不是 json 就原样返回",
			in:   "人工看过，标题对得上",
			want: "人工看过，标题对得上",
		},
		{
			name: "没有 signals 字段就原样返回",
			in:   `{"decided_by": "ops@demo"}`,
			want: `{"decided_by": "ops@demo"}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := evidenceSignals(tc.in); got != tc.want {
				t.Errorf("evidenceSignals(%q) = %q，应该是 %q", tc.in, got, tc.want)
			}
		})
	}
}
