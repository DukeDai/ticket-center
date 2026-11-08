// Package mock 是 Trip.com 分销侧协议 mock 服务端（标准库 net/http，零第三方依赖）。
//
// 用途：**在拿到商务授权之前**先验证适配器链路本身是对的。
// 它按《门票活动全球分销接口文档》V2.0.25 的协议实现三个入口：
//
//	POST /openserviceauth/authorize.ashx?aid&sid&key        → 取 token
//	POST /openserviceauth/refresh.ashx?aid&sid&refresh_token → 刷 token
//	POST /openservice/serviceproxy.ashx?aid&sid&icode&uuid&token → 业务接口
//
// 业务响应复用 fixtures/trip_com_catalog.json 的**真实报文结构**，
// 所以归一化规则（configs/mapping_rules.json）不需要为 mock 改一行。
//
// 额外提供几个「测试专用 icode」，用来验证错误四分类与重试策略：
//
//	TESTRETRY01  前 N 次返回 S0001（retriable）→ 之后成功（验证退避重试）
//	TESTFATAL01  恒返回 B0005 库存不足（fatal）→ 不重试，立即失败
//	TESTIDEM01   恒返回 B0010 重复下单（幂等命中，不是失败）
//	TESTAUTH01   恒返回 V0003 权限不足（auth）→ 不当可重试错误
package mock

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// 沙箱 ICODE（取自分销侧 OpenAPI 规格的「沙箱测试ICODE」）。
const (
	ICodeSearch   = "17e414dba020473db7bc5c108f1c6826"
	ICodeDetail   = "f8c5e03752644552a8546ae445069c59"
	ICodePrice    = "2543fc84edf54c7186f6ae9ec8ee70d3"
	ICodeCategory = "fdc2b31b43b2460f943a4dec817e0f65"
	ICodeLocation = "63bc9b16f83e42d4aefa5200c1ee3326"
	ICodeCurrency = "a3bb8914625c45889667abdb017dc3bc"
	ICodeLocale   = "ad24bb7be681419295af1803dea3cc62"
	ICodeBook     = "a0fc8c6cf3524a31814f700490071f91"
)

const (
	accessToken  = "MOCK-ACCESS-TOKEN-0001"
	refreshToken = "MOCK-REFRESH-TOKEN-0001"
	expiresIn    = 600
)

// testICode 是测试专用 icode 的行为定义。
type testICode struct {
	FailTimes int
	ErrCode   string
	ErrMsg    string
}

var testICodes = map[string]testICode{
	"TESTRETRY01": {FailTimes: 2, ErrCode: "S0001", ErrMsg: "系统错误"},
	"TESTFATAL01": {FailTimes: 1 << 30, ErrCode: "B0005", ErrMsg: "库存不足"},
	"TESTIDEM01":  {FailTimes: 1 << 30, ErrCode: "B0010", ErrMsg: "重复的创建订单请求"},
	"TESTAUTH01":  {FailTimes: 1 << 30, ErrCode: "V0003", ErrMsg: "权限不足"},
}

// Request 是一次收到的请求（用于断言）。
type Request struct {
	Path  string            `json:"path"`
	Query map[string]string `json:"query"`
	Body  map[string]any    `json:"body"`
}

// State 是 mock 的可变状态。
type State struct {
	mu              sync.Mutex
	accessToken     string
	refreshToken    string
	calls           map[string]int
	requests        []Request
	tokenRequests   int
	refreshRequests int
	expireOnce      bool
}

// Snapshot 返回状态副本。
func (s *State) Snapshot() (calls map[string]int, requests []Request, tokenReqs, refreshReqs int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	calls = map[string]int{}
	for k, v := range s.calls {
		calls[k] = v
	}
	requests = append([]Request(nil), s.requests...)
	return calls, requests, s.tokenRequests, s.refreshRequests
}

// Calls 取某个 icode 的调用次数。
func (s *State) Calls(icode string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls[icode]
}

// ResetCalls 清零某个 icode 的调用计数。
func (s *State) ResetCalls(icode string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls[icode] = 0
}

// ExpireNextToken 让下一次业务调用返回 1004（模拟 token 过期）。
func (s *State) ExpireNextToken() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireOnce = true
}

// Server 是 mock 服务端。
type Server struct {
	state    *State
	fixture  map[string]any
	listener net.Listener
	server   *http.Server
	baseURL  string
}

// New 启动一个 mock 服务端。fixturePath 为空时用默认的 fixtures/trip_com_catalog.json。
func New(fixturePath string) (*Server, error) {
	if fixturePath == "" {
		fixturePath = DefaultFixturePath()
	}
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		return nil, fmt.Errorf("读取样例报文失败 %s: %w", fixturePath, err)
	}
	var fx map[string]any
	if err := json.Unmarshal(raw, &fx); err != nil {
		return nil, fmt.Errorf("解析样例报文失败 %s: %w", fixturePath, err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	s := &Server{
		state:    &State{accessToken: accessToken, refreshToken: refreshToken, calls: map[string]int{}},
		fixture:  fx,
		listener: ln,
	}
	s.server = &http.Server{Handler: http.HandlerFunc(s.handle)}
	go func() { _ = s.server.Serve(ln) }()
	s.baseURL = "http://" + ln.Addr().String()
	return s, nil
}

// DefaultFixturePath 默认样例报文路径。
func DefaultFixturePath() string {
	return filepath.Join("fixtures", "trip_com_catalog.json")
}

// BaseURL mock 的根地址。
func (s *Server) BaseURL() string { return s.baseURL }

// State 暴露内部状态（供断言）。
func (s *Server) State() *State { return s.state }

// Endpoints 可直接塞进 api_config 的端点表。
func (s *Server) Endpoints() map[string]string {
	return map[string]string{
		"authorize": s.baseURL + "/openserviceauth/authorize.ashx",
		"refresh":   s.baseURL + "/openserviceauth/refresh.ashx",
		"service":   s.baseURL + "/openservice/serviceproxy.ashx",
	}
}

// Close 停止服务。
func (s *Server) Close() error {
	if s.server == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return s.server.Shutdown(ctx)
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	query := map[string]string{}
	for k, v := range r.URL.Query() {
		if len(v) > 0 {
			query[k] = v[0]
		}
	}
	var body map[string]any
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

	st := s.state
	st.mu.Lock()
	st.requests = append(st.requests, Request{Path: r.URL.Path, Query: query, Body: body})
	st.mu.Unlock()

	switch {
	case hasSuffix(r.URL.Path, "authorize.ashx"):
		s.handleAuthorize(w, query)
	case hasSuffix(r.URL.Path, "refresh.ashx"):
		s.handleRefresh(w, query)
	case hasSuffix(r.URL.Path, "serviceproxy.ashx"):
		s.handleService(w, query, body)
	default:
		writeJSON(w, map[string]any{"success": false, "errcode": "V0006",
			"errmsg": "未知接口 " + r.URL.Path}, http.StatusNotFound)
	}
}

func (s *Server) handleAuthorize(w http.ResponseWriter, query map[string]string) {
	st := s.state
	st.mu.Lock()
	st.tokenRequests++
	st.accessToken = accessToken
	st.refreshToken = refreshToken
	st.mu.Unlock()
	if query["aid"] == "" || query["sid"] == "" || query["key"] == "" {
		writeJSON(w, map[string]any{"ErrCode": 1001, "ErrMsg": "INVALID_AID_OR_SID"}, http.StatusOK)
		return
	}
	writeJSON(w, map[string]any{
		"AID": numOrString(query["aid"]), "SID": numOrString(query["sid"]),
		"Access_Token": accessToken, "Expires_In": expiresIn, "Refresh_Token": refreshToken,
	}, http.StatusOK)
}

func (s *Server) handleRefresh(w http.ResponseWriter, query map[string]string) {
	st := s.state
	st.mu.Lock()
	st.refreshRequests++
	ok := query["refresh_token"] == st.refreshToken
	current := st.accessToken
	refresh := st.refreshToken
	st.mu.Unlock()
	if !ok {
		writeJSON(w, map[string]any{"ErrCode": 1005, "ErrMsg": "INVALID_REFRESH_TOKEN"}, http.StatusOK)
		return
	}
	writeJSON(w, map[string]any{
		"AID": numOrString(query["aid"]), "SID": numOrString(query["sid"]),
		"Access_Token": current, "Expires_In": expiresIn, "Refresh_Token": refresh,
	}, http.StatusOK)
}

func (s *Server) handleService(w http.ResponseWriter, query map[string]string, body map[string]any) {
	st := s.state
	icode := query["icode"]
	st.mu.Lock()
	st.calls[icode]++
	calls := st.calls[icode]
	tokenOK := query["token"] == st.accessToken
	expire := st.expireOnce
	if expire {
		st.expireOnce = false
		st.accessToken = "ROTATED-BY-MOCK"
	}
	st.mu.Unlock()

	if !tokenOK {
		writeErr(w, "V0003", "权限不足（token 无效）")
		return
	}
	if spec, ok := testICodes[icode]; ok {
		if calls <= spec.FailTimes {
			writeErr(w, spec.ErrCode, spec.ErrMsg)
			return
		}
		writeOK(w, map[string]any{"ok": true, "attempts": calls})
		return
	}
	if expire {
		writeErr(w, "1004", "Token已过期")
		return
	}

	switch icode {
	case ICodeSearch:
		products := []any{}
		for _, doc := range asList(s.fixture["catalog"]) {
			d, _ := doc.(map[string]any)["data"].(map[string]any)
			products = append(products, map[string]any{
				"productID": d["productID"], "name": d["name"], "business": d["business"],
				"category": d["category"], "duration": d["duration"],
				"currency": d["currency"], "locale": d["locale"],
			})
		}
		var lastID any
		if len(products) > 0 {
			lastID = products[0].(map[string]any)["productID"]
		}
		writeOK(w, map[string]any{"productList": products,
			"totalCount": len(products), "lastUpdateProductID": lastID})
		return

	case ICodeDetail:
		want := map[string]bool{}
		for _, v := range asList(body["productIDList"]) {
			want[fmt.Sprintf("%v", v)] = true
		}
		out := []any{}
		for _, doc := range asList(s.fixture["catalog"]) {
			d, _ := doc.(map[string]any)["data"].(map[string]any)
			id := fmt.Sprintf("%v", d["productID"])
			if len(want) == 0 || want[id] {
				out = append(out, d)
			}
		}
		writeOK(w, map[string]any{"productList": out})
		return

	case ICodePrice:
		pid := fmt.Sprintf("%v", body["productID"])
		for _, doc := range asList(s.fixture["prices"]) {
			d, _ := doc.(map[string]any)["data"].(map[string]any)
			if fmt.Sprintf("%v", d["productID"]) == pid {
				writeOK(w, d)
				return
			}
		}
		writeOK(w, map[string]any{"productID": body["productID"], "packageList": []any{}})
		return

	case ICodeCategory:
		writeOK(w, map[string]any{"categories": []any{
			map[string]any{"categoryID": 3, "categoryName": "门票", "business": "ACTIVITY",
				"subcategoryList": []any{map[string]any{"categoryID": 3001, "categoryName": "主题乐园", "business": "ACTIVITY"}}},
			map[string]any{"categoryID": 12, "categoryName": "一日游", "business": "TOUR", "subcategoryList": []any{}},
		}})
		return

	case ICodeLocation:
		writeOK(w, map[string]any{"locations": []any{
			map[string]any{"locationID": 1, "type": "COUNTRY", "name": "中国", "children": []any{
				map[string]any{"locationID": 2, "type": "PROVINCE", "name": "北京市", "children": []any{
					map[string]any{"locationID": 3, "type": "CITY", "name": "北京市", "children": []any{}}}}}},
		}})
		return

	case ICodeCurrency:
		writeOK(w, map[string]any{"currencyList": []any{"CNY", "HKD", "USD"}})
		return

	case ICodeLocale:
		writeOK(w, map[string]any{"localeList": []any{"zh-CN", "en-US"}})
		return

	case ICodeBook:
		writeOK(w, map[string]any{"orderID": 99000001,
			"distributorOrderID": body["distributorOrderID"], "status": "CONFIRMED"})
		return
	}
	writeErr(w, "V0001", "mock 未实现的接口 icode="+icode)
}

func writeOK(w http.ResponseWriter, data any) {
	writeJSON(w, map[string]any{"success": true, "errcode": "", "errmsg": "", "data": data}, http.StatusOK)
}

func writeErr(w http.ResponseWriter, code, msg string) {
	writeJSON(w, map[string]any{"success": false, "errcode": code, "errmsg": msg, "data": nil}, http.StatusOK)
}

func writeJSON(w http.ResponseWriter, payload any, status int) {
	blob, _ := json.Marshal(payload)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(blob)
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func numOrString(s string) any {
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		return n
	}
	return s
}

func hasSuffix(s, suffix string) bool {
	return len(s) >= len(suffix) && s[len(s)-len(suffix):] == suffix
}
