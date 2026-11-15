// Package bapi 的 HTTP 服务：内部运营台的后端。
//
// 定位与纪律见 operator.go 的包注释。这里说三件具体的事：
//
// ① 边界画在**身份**上，不是渠道上。
//    C 端公开接口没有调用方身份，边界只能画在渠道（requireChannel）。
//    运营台有身份（b2b_operator + 会话 cookie），所以它可以跨渠道看 ——
//    这正是运营台存在的意义（哪个渠道在堆积、哪个源在掉链子）。
//    但跨渠道不等于匿名可读：每个端点都要过 requireOperator。
//
// ② 写端点必须做**渠道归属校验**。
//    internal/order、internal/fulfillment、internal/refund、internal/reassign
//    这几个包都只按 id 定位记录，不带渠道过滤 —— 它们是库函数的薄封装，
//    故意不做权限判断（那是调用方的责任）。
//    这里就是那个调用方。所以每个写端点都要先确认「这个资源属于哪个渠道」，
//    确认不了就拒绝，而不是放行。
//
// ③ 写路径一律走库里的唯一实现。
//    Go 侧只拼参数、只读结果：不重算金额、不重排源、不自己算状态、
//    不自己判退款资格、不自己判能不能进场。
package bapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"ticket-center/internal/store"
)

// Server 是运营台 API 的服务句柄。
type Server struct {
	db       *store.DB
	ops      *OperatorService
	write    *writeHandlers
	mux      *http.ServeMux
	nowFn    func() time.Time
	secure   bool
	basePath string
}

// Options 是建服务时的选项。
type Options struct {
	// Secure 为 true 时会话 cookie 带 Secure 标记（生产走 HTTPS 时开）。
	Secure bool
	// Now 覆盖「现在」，测试用。nil 时用 time.Now。
	Now func() time.Time
}

// New 建一个运营台 API 服务。
func New(db *store.DB, opts Options) *Server {
	s := &Server{
		db:     db,
		ops:    NewOperatorService(db),
		write:  newWriteHandlers(db),
		mux:    http.NewServeMux(),
		nowFn:  time.Now,
		secure: opts.Secure,
	}
	if opts.Now != nil {
		s.nowFn = opts.Now
	}

	// 身份。
	s.mux.HandleFunc("POST /api/v1/auth/login", s.handleLogin)
	s.mux.HandleFunc("POST /api/v1/auth/logout", s.handleLogout)
	s.mux.HandleFunc("GET /api/v1/auth/me", s.handleOperatorInfo)

	// 读侧：跨渠道运营视图。
	s.mux.HandleFunc("GET /api/v1/channels", s.handleChannels)
	s.mux.HandleFunc("GET /api/v1/products", s.handleProducts)
	s.mux.HandleFunc("GET /api/v1/products/{product_id}", s.handleProductDetail)
	s.mux.HandleFunc("GET /api/v1/orders", s.handleOrders)
	s.mux.HandleFunc("GET /api/v1/orders/{order_id}", s.handleOrderDetail)
	s.mux.HandleFunc("GET /api/v1/fulfillment/gaps", s.handleFulfillmentGaps)
	s.mux.HandleFunc("GET /api/v1/supply-forms", s.handleSupplyForms)
	s.mux.HandleFunc("GET /api/v1/refunds", s.handleRefunds)
	s.mux.HandleFunc("GET /api/v1/redemptions", s.handleRedemptions)
	s.mux.HandleFunc("GET /api/v1/inventory/holds", s.handleHolds)
	s.mux.HandleFunc("GET /api/v1/suppliers/health", s.handleSupplierHealth)
	s.mux.HandleFunc("GET /api/v1/settlement/gaps", s.handleSettlementGaps)
	s.mux.HandleFunc("GET /api/v1/reassign/candidates", s.handleReassignCandidates)
	s.mux.HandleFunc("GET /api/v1/operators", s.handleOperators)

	// 写侧：复用已有的写路径（库里的唯一实现），只拼参数。
	s.mux.HandleFunc("POST /api/v1/orders", s.handlePlaceOrder)
	s.mux.HandleFunc("POST /api/v1/orders/{order_id}/payments", s.handleRecordPayment)
	s.mux.HandleFunc("POST /api/v1/bookings/{booking_id}/vouchers", s.handleIssueVoucher)
	s.mux.HandleFunc("POST /api/v1/refunds", s.handleRequestRefund)
	s.mux.HandleFunc("POST /api/v1/refunds/{refund_id}/approval", s.handleApproveRefund)
	s.mux.HandleFunc("POST /api/v1/orders/{order_id}/items/{order_item_id}/reassign", s.handleReassign)

	// 健康检查不要求身份：探针不该带凭证。
	s.mux.HandleFunc("GET /healthz", s.handleHealth)

	// 运营台的网页界面。页面与 API 是同一套身份（同一个会话 cookie）——
	// 两套身份就意味着「网页上看不到的东西，API 能改」。
	s.mux.HandleFunc("GET /static/", s.handleStatic)
	s.mux.HandleFunc("GET /login", s.handleLoginPage)
	s.mux.HandleFunc("POST /login", s.handleLoginSubmit)
	s.mux.HandleFunc("POST /logout", s.handleLogoutSubmit)
	s.mux.HandleFunc("GET /console", s.handleConsole)
	s.mux.HandleFunc("GET /", s.handleRoot)

	// 兜底：路径不认识时也回 JSON。
	s.mux.HandleFunc("/", s.handleNotFound)
	return s
}

// ServeHTTP 让 Server 直接当 http.Handler 用。
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

// handleNotFound 兜底的 404。
func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeErr(w, http.StatusNotFound, "not_found",
		fmt.Sprintf("没有这个接口：%s %s", r.Method, r.URL.Path))
}

// handleHealth 健康检查。
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// -------------------------------------------------------------------------------------
// 身份
// -------------------------------------------------------------------------------------

// handleLogin 校验凭证并签发会话。
//
// 请求体：{"code":"ops_admin","secret":"tk_op_..."}。
// 响应体：{"operator":{...},"expires_at":"..."}。
//
// 会话放在 HttpOnly cookie 里，不放在响应体里给 JS 读 ——
// 运营台是内部工具，但 XSS 一样能把 cookie 偷走。
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code   string `json:"code"`
		Secret string `json:"secret"`
	}
	if err := decodeJSON(r, &req); err != nil {
		badRequest(w, err)
		return
	}
	op, err := s.ops.Login(req.Code, req.Secret)
	if err != nil {
		// 凭证不对与账号不存在给同一个答复，不给调用方枚举操作员 code 的探针。
		writeErr(w, http.StatusUnauthorized, "unauthorized", err.Error())
		return
	}
	rec, err := s.ops.Lookup(op.Code)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "签发会话失败："+err.Error())
		return
	}
	now := s.nowFn()
	token, err := IssueSession(rec, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "签发会话失败："+err.Error())
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
	writeJSON(w, http.StatusOK, map[string]any{
		"operator":   op,
		"expires_at": now.Add(sessionTTL).Format(time.RFC3339),
	})
}

// handleLogout 清掉会话 cookie。
//
// 服务端不维护会话表，所以「登出」就是让浏览器不再带这个 cookie。
// 换句话说：token 在过期前仍然有效 —— 这是无状态会话的固有性质。
// 真要立刻失效，靠改 session_salt（换盐让所有已签发的会话作废）。
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   s.secure,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleMe 报当前会话的操作员。
func (s *Server) handleOperatorInfo(w http.ResponseWriter, r *http.Request) {
	op, ok := s.requireOperator(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"operator": op})
}

// currentOperator 取当前会话的操作员，不写响应。
//
// 页面用它：未登录时页面要把人送去登录页（302/303），
// 而不是回一段 401 的 JSON —— 浏览器收到裸 JSON 会显示一坨文本，
// 那台子就等于废了。
func (s *Server) currentOperator(r *http.Request) (*Operator, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || strings.TrimSpace(c.Value) == "" {
		return nil, false
	}
	op, err := s.ops.VerifySession(c.Value, s.nowFn())
	if err != nil {
		return nil, false
	}
	return op, true
}

// requireOperator 取当前会话的操作员，没登录就拒绝。
//
// 每个端点都要过这里 —— 不许在某个处理器里另写一套「怎么判断登录了」。
func (s *Server) requireOperator(w http.ResponseWriter, r *http.Request) (*Operator, bool) {
	op, ok := s.currentOperator(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized", "需要先登录")
		return nil, false
	}
	return op, true
}

// requireWrite 取当前会话的操作员，并确认他能不能做写操作。
func (s *Server) requireWrite(w http.ResponseWriter, r *http.Request) (*Operator, bool) {
	op, ok := s.requireOperator(w, r)
	if !ok {
		return nil, false
	}
	if !op.CanWrite() {
		writeErr(w, http.StatusForbidden, "forbidden",
			fmt.Sprintf("角色 %s 不能做写操作（要 operator 或 admin）", op.Role))
		return nil, false
	}
	return op, true
}

// requireApprove 取当前会话的操作员，并确认他能不能放行。
//
// 放行退款与改派要记操作人 —— 这两个动作的痕迹是追责的依据，
// 所以只给 admin。
func (s *Server) requireApprove(w http.ResponseWriter, r *http.Request) (*Operator, bool) {
	op, ok := s.requireOperator(w, r)
	if !ok {
		return nil, false
	}
	if !op.CanApprove() {
		writeErr(w, http.StatusForbidden, "forbidden",
			fmt.Sprintf("角色 %s 不能放行（要 admin）", op.Role))
		return nil, false
	}
	return op, true
}

// -------------------------------------------------------------------------------------
// 读端点
// -------------------------------------------------------------------------------------

// handleChannels 渠道总览。
func (s *Server) handleChannels(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	rows, err := ChannelOverviews(s.db, 0)
	if err != nil {
		internalErr(w, "读渠道总览失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"channels": rows})
}

// handleProducts 商品目录。
func (s *Server) handleProducts(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	channelID := optInt64(r, "channel_id")
	keyword := strings.TrimSpace(r.URL.Query().Get("q"))
	status := strings.TrimSpace(r.URL.Query().Get("listing_status"))
	rows, err := Catalog(s.db, channelID, keyword, status)
	if err != nil {
		internalErr(w, "读商品目录失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"products": rows})
}

// handleProductDetail 商品详情。
//
// 详情是**钻取**：源绑定、可售单元、上架配置、售价、文案五块。
// 每一块都来自 v_ops_product_* 读模型 —— 运营台不重算事实，
// 也不在请求链路里 join 主数据（硬约束 10 / 41）。
func (s *Server) handleProductDetail(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	id, err := pathID(r, "product_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	d, err := ProductDetailByID(s.db, id)
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// handleOrders 订单列表。
func (s *Server) handleOrders(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	limit, offset, err := paging(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	rows, err := Orders(s.db, OrderFilter{
		ChannelID: optInt64(r, "channel_id"),
		Status:    strings.TrimSpace(r.URL.Query().Get("status")),
		Payment:   strings.TrimSpace(r.URL.Query().Get("payment_status")),
		Keyword:   strings.TrimSpace(r.URL.Query().Get("q")),
		Limit:     limit,
		Offset:    offset,
	})
	if err != nil {
		internalErr(w, "读订单列表失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"orders": rows, "limit": limit, "offset": offset})
}

// handleOrderDetail 订单详情。
func (s *Server) handleOrderDetail(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	id, err := pathID(r, "order_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	d, err := OrderDetailByID(s.db, id)
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// handleFulfillmentGaps 履约漏斗。
func (s *Server) handleFulfillmentGaps(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	lostOnly := strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("lost_only")), "true")
	rows, err := FulfillmentGaps(s.db, optInt64(r, "channel_id"), lostOnly)
	if err != nil {
		internalErr(w, "读履约漏斗失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"gaps": rows})
}

// handleSupplyForms 供给形态对照。
func (s *Server) handleSupplyForms(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	date, err := dateParam(r, "date")
	if err != nil {
		badRequest(w, err)
		return
	}
	gapsOnly := strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("gaps_only")), "true")
	rows, err := SupplyForms(s.db,
		optInt64(r, "channel_id"), optInt64(r, "product_id"), date, gapsOnly)
	if err != nil {
		internalErr(w, "读供给形态失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"forms": rows})
}

// handleRefunds 退款台账。
func (s *Server) handleRefunds(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	rows, err := Refunds(s.db, optInt64(r, "channel_id"),
		strings.TrimSpace(r.URL.Query().Get("status")))
	if err != nil {
		internalErr(w, "读退款台账失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"refunds": rows})
}

// handleRedemptions 核销记录。
func (s *Server) handleRedemptions(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	limit, _, err := paging(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	rows, err := Redemptions(s.db, optInt64(r, "channel_id"),
		strings.TrimSpace(r.URL.Query().Get("result")), limit)
	if err != nil {
		internalErr(w, "读核销记录失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"redemptions": rows})
}

// handleHolds 库存预占。
func (s *Server) handleHolds(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	limit, _, err := paging(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	rows, err := Holds(s.db, optInt64(r, "channel_id"),
		strings.TrimSpace(r.URL.Query().Get("status")), limit)
	if err != nil {
		internalErr(w, "读库存预占失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"holds": rows})
}

// handleSupplierHealth 源健康度。
func (s *Server) handleSupplierHealth(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	rows, err := SupplierHealth(s.db)
	if err != nil {
		internalErr(w, "读源健康度失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"suppliers": rows})
}

// handleSettlementGaps 结算缺口。
func (s *Server) handleSettlementGaps(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	rows, err := SettlementGaps(s.db)
	if err != nil {
		internalErr(w, "读结算缺口失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"gaps": rows})
}

// handleReassignCandidates 待改派清单。
func (s *Server) handleReassignCandidates(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	rows, err := ReassignCandidates(s.db, optInt64(r, "channel_id"))
	if err != nil {
		internalErr(w, "读待改派清单失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"candidates": rows})
}

// handleOperators 列出操作员。
func (s *Server) handleOperators(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireOperator(w, r); !ok {
		return
	}
	rows, err := s.ops.List()
	if err != nil {
		internalErr(w, "读操作员失败："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"operators": rows})
}

// -------------------------------------------------------------------------------------
// 辅助
// -------------------------------------------------------------------------------------

// apiError 是错误响应的形状。
type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(body)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": apiError{Code: code, Message: msg}})
}

func badRequest(w http.ResponseWriter, err error) {
	writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
}

func internalErr(w http.ResponseWriter, msg string) {
	writeErr(w, http.StatusInternalServerError, "internal", msg)
}

// decodeJSON 读请求体。
//
// 限制体大小：运营台是内部工具，但「内部」不等于「可以被人塞一个 1GB 的体」，
// psql 子进程会把它整段拼进 SQL 之前先吃进内存。
func decodeJSON(r *http.Request, v any) error {
	defer func() { _ = r.Body.Close() }()
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	if err := dec.Decode(v); err != nil {
		return fmt.Errorf("请求体解析失败：%w", err)
	}
	return nil
}

// pathID 取路径里的正整数 id。
func pathID(r *http.Request, name string) (int64, error) {
	raw := strings.TrimSpace(r.PathValue(name))
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("%s 必须是正整数，收到 %q", name, raw)
	}
	return id, nil
}

// queryID 取查询参数里的正整数 id；没传或不是正整数都报错。
//
// 网页端的详情页用查询参数带 id（`?tab=order_detail&order_id=8`），
// API 端用路径参数（`/api/v1/orders/{order_id}`）—— 两处不能混用同一个读法：
// `pathID` 读的是路径里的值，拿它去读查询参数会读成空串，
// 于是详情页永远报「order_id 必须是正整数，收到 ""」。
func queryID(r *http.Request, name string) (int64, error) {
	raw := strings.TrimSpace(r.URL.Query().Get(name))
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("%s 必须是正整数，收到 %q", name, raw)
	}
	return id, nil
}

// optInt64 取可选的正整数查询参数；没传或传 0 返回 0。
//
// 0 的含义是「不过滤」而不是「id 为 0」—— 后者在库里不存在，
// 当成过滤条件会让调用方以为「查不到东西」。
func optInt64(r *http.Request, name string) int64 {
	raw := strings.TrimSpace(r.URL.Query().Get(name))
	if raw == "" {
		return 0
	}
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || id < 0 {
		return 0
	}
	return id
}

// dateParam 取 YYYY-MM-DD 的日期参数，没传返回空串。
func dateParam(r *http.Request, name string) (string, error) {
	raw := strings.TrimSpace(r.URL.Query().Get(name))
	if raw == "" {
		return "", nil
	}
	t, err := time.Parse("2006-01-02", raw)
	if err != nil {
		return "", fmt.Errorf("%s 的格式不对（要 YYYY-MM-DD）：%q", name, raw)
	}
	return t.Format("2006-01-02"), nil
}

// paging 取分页参数。
func paging(r *http.Request) (limit, offset int, err error) {
	limit, offset = 50, 0
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, convErr := strconv.Atoi(raw)
		if convErr != nil || n < 1 || n > 500 {
			return 0, 0, fmt.Errorf("limit 必须是 1 到 500 之间的整数，收到 %q", raw)
		}
		limit = n
	}
	if raw := strings.TrimSpace(r.URL.Query().Get("offset")); raw != "" {
		n, convErr := strconv.Atoi(raw)
		if convErr != nil || n < 0 {
			return 0, 0, fmt.Errorf("offset 不能是负数，收到 %q", raw)
		}
		offset = n
	}
	return limit, offset, nil
}

// stringRe 是查询参数里允许出现的字符集。
//
// 这些参数会被拼进 SQL（psql 子进程没有占位符），所以先关进一个
// 只可能由这些字符组成的集合再拼 —— 校验不过就报错，不猜、不糊过去。
var stringRe = regexp.MustCompile(`^[A-Za-z0-9_.:-]{0,64}$`)
