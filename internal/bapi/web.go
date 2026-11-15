package bapi

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// webFS 是运营台的静态资源与模板。
//
// go:embed 把它们编译进二进制：部署时不用带一堆文件，
// 也不会出现「模板改了没生效」这种版本错位。
//
//go:embed web/static web/templates
var webFS embed.FS

// webTemplates 是渲染用的模板集。
var webTemplates = template.Must(template.New("web").Funcs(webFuncs()).ParseFS(webFS, "web/templates/*.html"))

// webFuncs 是模板里能用到的函数。
//
// 它们都是**展示层**的辅助：状态对应什么颜色、时间怎么截短。
// 不放任何业务判断 —— 业务口径在库与读模型里，
// 模板里再判一次就是第二份实现。
func webFuncs() template.FuncMap {
	return template.FuncMap{
		"statusPill":      statusPill,
		"paymentPill":     statusPill,
		"voucherPill":     voucherPill,
		"refundPill":      statusPill,
		"redemptionPill":  redemptionPill,
		"supplierPill":    statusPill,
		"shortTime":       shortTime,
		"statusClass":     statusPill,
		"evidenceSignals": evidenceSignals,
	}
}

// evidenceSignals 把匹配依据里的信号列出来。
//
// 依据存的是 jsonb（`{"signals": [...], "decided_by": "..."}`）。
// 整段 JSON 摊在表格里没人看 —— 运营要扫的是「凭什么说它匹配」，
// 所以把 signals 拼成一行，判定人单独一列。
//
// **这是展示层，不改口径。** 拼不出来就原样返回那段 JSON：
// 依据的形状是机器写进来的，运营台不替它猜结构。
func evidenceSignals(evidence string) string {
	evidence = strings.TrimSpace(evidence)
	if evidence == "" {
		return "—"
	}
	var doc struct {
		Signals []string `json:"signals"`
	}
	if err := json.Unmarshal([]byte(evidence), &doc); err != nil || len(doc.Signals) == 0 {
		return evidence
	}
	return strings.Join(doc.Signals, " · ")
}

// statusPill 把状态词映射到徽标样式。
//
// 绿色的那几个是「事情成了」，红色的是「事情卡住了」。
// 判据是状态的**语义**而不是它的字母 ——
// 「paid」与「issued」在字母上毫无关系，在语义上都是「成了」。
func statusPill(status string) string {
	switch status {
	case "paid", "succeeded", "issued", "used", "confirmed", "ticketed", "online", "active", "completed":
		return "ok"
	case "failed", "cancelled", "void", "expired", "refunded", "discontinued", "inactive", "sold_out":
		return "bad"
	case "pending", "requested", "processing", "draft", "reserved", "partial_refund",
		"pending_review", "unpaid", "awaiting_payment", "refunding", "partially_cancelled":
		return "warn"
	case "offline":
		// 下架不是故障 —— 灰色的空徽标，比红色更贴近事实。
		return ""
	default:
		return ""
	}
}

// voucherPill 是券状态专用映射。
//
// 「expired」在券上是正常终态（票过期了），不是故障 ——
// 所以它是灰的，不是红的。红色留给「这张券出问题了」。
func voucherPill(status string) string {
	switch status {
	case "issued":
		return "ok"
	case "used":
		return "info"
	case "void", "refunded":
		return "bad"
	case "expired":
		return ""
	default:
		return "warn"
	}
}

// redemptionPill 是核销结果专用映射。
//
// 「duplicate」是坏消息：有人在重复扫票，票务欺诈的入口。
func redemptionPill(result string) string {
	switch result {
	case "success":
		return "ok"
	case "duplicate":
		return "bad"
	default:
		return "warn"
	}
}

// shortTime 把数据库的时间戳截到分钟。
//
// 时间戳是 Postgres 的 timestamptz 文本，带时区偏移与小数秒 ——
// 表格里显示那一长串，谁也读不出来。
func shortTime(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "—"
	}
	// Postgres 的 timestamptz 文本形如 2024-05-01 10:20:30.123456+08
	if i := strings.IndexByte(s, '+'); i > 0 {
		s = s[:i]
	} else if i := strings.LastIndexByte(s, '-'); i > 10 {
		// UTC 的结尾是 -00 或 -05 这种负偏移；日期里的 '-' 在更前面，
		// 所以 LastIndex 拿到的一定是偏移。
		s = s[:i]
	}
	s = strings.TrimSuffix(s, "Z")
	if t, err := time.Parse("2006-01-02 15:04:05.999999", s); err == nil {
		return t.Format("01-02 15:04")
	}
	if t, err := time.Parse("2006-01-02 15:04:05", s); err == nil {
		return t.Format("01-02 15:04")
	}
	if len(s) > 16 {
		return s[:16]
	}
	return s
}

// -------------------------------------------------------------------------------------
// 页面
// -------------------------------------------------------------------------------------

// consoleData 是页面数据。
type consoleData struct {
	Operator *Operator
	Tab      string
	Tabs     []tabDef
	Error    string

	Overview  overviewData
	Orders    []OrderRow
	OrderDetail *OrderDetail
	Catalog   []CatalogRow
	ProductDetail *ProductDetail
	Gaps      []FulfillmentGapRow
	SupplyForms []SupplyFormRow
	Refunds   []RefundRow
	Redemptions []RedemptionRow
	Holds     []HoldRow
	Suppliers []SupplierHealthRow
	SettlementGaps []SettlementGapRow
	ReassignCandidates []ReassignCandidateRow

	Filter filterState
}

// tabDef 是一个页签。
type tabDef struct {
	Key   string
	Label string
	Count int
}

// overviewData 是总览的汇总。
type overviewData struct {
	Channels       []ChannelOverview
	TotalChannels  int
	TotalListings  int
	TotalOrders    int
	PaidOrders     int
	UnpaidOrders   int
	SuspectedLost  int
	RefundsOpen    int
}

// filterState 是筛选条件的回显。
type filterState struct {
	OrderKeyword    string
	OrderStatus     string
	OrderPayment    string
	OrderStatuses   []string
	PaymentStatuses []string
	RefundStatus    string
	RefundStatuses  []string
	SupplyDate      string
	SupplyGapsOnly  bool
	CatalogKeyword  string
	ListingStatus   string
	ListingStatuses []string
}

// webHandlers 是页面渲染这一层。
type webHandlers struct {
	srv *Server
}

// handleLoginPage 渲染登录页。
func (s *Server) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	data := struct {
		Error string
	}{}
	if raw := strings.TrimSpace(r.URL.Query().Get("error")); raw != "" {
		data.Error = raw
	}
	render(w, "login", data)
}

// handleLoginSubmit 处理登录表单。
func (s *Server) handleLoginSubmit(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Redirect(w, r, "/login?error="+url.QueryEscape("表单解析失败"), http.StatusSeeOther)
		return
	}
	code := strings.TrimSpace(r.PostFormValue("code"))
	secret := r.PostFormValue("secret")
	op, err := s.ops.Login(code, secret)
	if err != nil {
		http.Redirect(w, r, "/login?error="+url.QueryEscape(err.Error()), http.StatusSeeOther)
		return
	}
	rec, err := s.ops.Lookup(op.Code)
	if err != nil {
		http.Redirect(w, r, "/login?error="+url.QueryEscape("签发会话失败"), http.StatusSeeOther)
		return
	}
	now := s.nowFn()
	token, err := IssueSession(rec, now)
	if err != nil {
		http.Redirect(w, r, "/login?error="+url.QueryEscape("签发会话失败"), http.StatusSeeOther)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   s.secure,
		SameSite: http.SameSiteLaxMode,
		Expires:  now.Add(sessionTTL),
	})
	http.Redirect(w, r, "/console", http.StatusSeeOther)
}

// handleLogoutSubmit 处理登出表单。
func (s *Server) handleLogoutSubmit(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   s.secure,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// handleConsole 渲染运营台主页面。
//
// 一次请求把当前页签需要的数据全查出来 —— 运营台是内部工具，
// 数据量是几千行量级，一次查完比来回查十次快，
// 也省掉「页签切换时上一屏的数据还在不在」这类问题。
func (s *Server) handleConsole(w http.ResponseWriter, r *http.Request) {
	// 页面与 API 的未登录处理不一样：API 回 401 + JSON，
	// 页面把人送去登录页。浏览器收到 401 的 JSON 会显示一坨裸文本，
	// 而不是让人去登录 —— 那台子就等于废了。
	op, ok := s.currentOperator(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	tab := strings.TrimSpace(r.URL.Query().Get("tab"))
	if tab == "" {
		tab = "overview"
	}
	q := r.URL.Query()

	data := consoleData{
		Operator: op,
		Tab:      tab,
		Filter: filterState{
			OrderKeyword: strings.TrimSpace(q.Get("q")),
			OrderStatus:  strings.TrimSpace(q.Get("status")),
			OrderPayment: strings.TrimSpace(q.Get("payment_status")),
			RefundStatus: strings.TrimSpace(q.Get("refund_status")),
			SupplyDate:   strings.TrimSpace(q.Get("date")),
			SupplyGapsOnly: strings.EqualFold(strings.TrimSpace(q.Get("gaps_only")), "true"),
			CatalogKeyword: strings.TrimSpace(q.Get("q")),
			ListingStatus:  strings.TrimSpace(q.Get("listing_status")),
			OrderStatuses:   []string{"pending", "confirmed", "partially_refunded", "refunded", "cancelled"},
			PaymentStatuses: []string{"unpaid", "paid", "partially_refunded", "refunded"},
			RefundStatuses:  []string{"requested", "approved", "completed", "failed", "rejected"},
			ListingStatuses: []string{"online", "draft", "offline", "sold_out", "expired"},
		},
	}

	switch tab {
	case "overview":
		if err := s.loadOverview(&data); err != nil {
			data.Error = err.Error()
		}
	case "orders":
		if err := s.loadOrders(&data); err != nil {
			data.Error = err.Error()
		}
	case "catalog":
		if err := s.loadCatalog(&data); err != nil {
			data.Error = err.Error()
		}
	case "product_detail":
		id, err := queryID(r, "product_id")
		if err != nil {
			data.Error = err.Error()
		} else {
			d, err := ProductDetailByID(s.db, id)
			if err != nil {
				data.Error = err.Error()
			} else {
				data.ProductDetail = d
			}
		}
	case "order_detail":
		id, err := queryID(r, "order_id")
		if err != nil {
			data.Error = err.Error()
		} else {
			d, err := OrderDetailByID(s.db, id)
			if err != nil {
				data.Error = err.Error()
			} else {
				data.OrderDetail = d
			}
		}
	case "gaps":
		rows, err := FulfillmentGaps(s.db, 0, false)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.Gaps = rows
		}
	case "supply":
		rows, err := SupplyForms(s.db, 0, 0, data.Filter.SupplyDate, data.Filter.SupplyGapsOnly)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.SupplyForms = rows
		}
	case "refunds":
		rows, err := Refunds(s.db, 0, data.Filter.RefundStatus)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.Refunds = rows
		}
	case "redemptions":
		rows, err := Redemptions(s.db, 0, "", 200)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.Redemptions = rows
		}
	case "sources":
		sup, err := SupplierHealth(s.db)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.Suppliers = sup
		}
		sg, err := SettlementGaps(s.db)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.SettlementGaps = sg
		}
	case "holds":
		rows, err := Holds(s.db, 0, "", 200)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.Holds = rows
		}
	case "reassign":
		rows, err := ReassignCandidates(s.db, 0)
		if err != nil {
			data.Error = err.Error()
		} else {
			data.ReassignCandidates = rows
		}
	default:
		data.Error = fmt.Sprintf("没有这个页签：%s", tab)
	}

	data.Tabs = s.buildTabs(&data)
	render(w, "console", data)
}

// loadOverview 填总览。
func (s *Server) loadOverview(data *consoleData) error {
	channels, err := ChannelOverviews(s.db, 0)
	if err != nil {
		return fmt.Errorf("读渠道总览失败：%w", err)
	}
	data.Overview.Channels = channels
	data.Overview.TotalChannels = len(channels)
	for _, ch := range channels {
		data.Overview.TotalListings += int(ch.OnlineListings)
		data.Overview.TotalOrders += int(ch.OrderCount)
		data.Overview.PaidOrders += int(ch.PaidOrderCount)
		data.Overview.UnpaidOrders += int(ch.UnpaidOrderCount)
		data.Overview.SuspectedLost += int(ch.SuspectedLostCnt)
	}
	refunds, err := Refunds(s.db, 0, "")
	if err != nil {
		return fmt.Errorf("读退款台账失败：%w", err)
	}
	for _, rf := range refunds {
		switch rf.RefundStatus {
		case "requested", "approved":
			data.Overview.RefundsOpen++
		}
	}
	return nil
}

// loadOrders 填订单列表。
func (s *Server) loadOrders(data *consoleData) error {
	rows, err := Orders(s.db, OrderFilter{
		Status:  data.Filter.OrderStatus,
		Payment: data.Filter.OrderPayment,
		Keyword: data.Filter.OrderKeyword,
		Limit:   200,
	})
	if err != nil {
		return fmt.Errorf("读订单列表失败：%w", err)
	}
	data.Orders = rows
	return nil
}

// loadCatalog 填商品目录。
//
// 目录是「商品 × 渠道」一行 —— 同一个商品在两个渠道上架就有两行，
// 这是**口径**（运营要看每个渠道各自挂了什么），不是重复。
func (s *Server) loadCatalog(data *consoleData) error {
	rows, err := Catalog(s.db, 0, data.Filter.CatalogKeyword, data.Filter.ListingStatus)
	if err != nil {
		return fmt.Errorf("读商品目录失败：%w", err)
	}
	data.Catalog = rows
	return nil
}

// buildTabs 造页签（带条数）。
func (s *Server) buildTabs(data *consoleData) []tabDef {
	return []tabDef{
		{Key: "overview", Label: "总览"},
		{Key: "catalog", Label: "商品", Count: len(data.Catalog)},
		{Key: "orders", Label: "订单", Count: len(data.Orders)},
		{Key: "gaps", Label: "履约缺口"},
		{Key: "supply", Label: "供给形态", Count: len(data.SupplyForms)},
		{Key: "refunds", Label: "退款", Count: len(data.Refunds)},
		{Key: "redemptions", Label: "核销"},
		{Key: "sources", Label: "源与结算"},
		{Key: "holds", Label: "库存预占"},
		{Key: "reassign", Label: "待改派"},
	}
}

// render 渲染一个模板。
func render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := webTemplates.ExecuteTemplate(w, name, data); err != nil {
		// 模板已经写了一部分响应体，这时改不了状态码 ——
		// 只能把错误写进流里，让看页面的人知道它没渲染完。
		fmt.Fprintf(w, "\n<!-- 渲染失败：%s -->\n", err)
	}
}
