// Package capi 是 C 端的只读 HTTP API。
//
// 它只读 C 端读模型（c_product_card / v_c_listing_feed / v_c_variant_feed /
// v_c_variant_composition / c_variant_calendar），**不在请求链路里 join 主数据**，
// 也不重算任何事实 —— 有效天数、成分份数、可履约源数都由库里的读模型算好，
// 这里只把它们带出来（硬约束 10 / 24）。
//
// 覆盖的是 C 端购买链路的读侧四步（docs/c-end-model.md §3）：
//
//	① 浏览    GET /api/v1/products                          → v_c_listing_feed
//	③ 选变体  GET /api/v1/products/{id}/variants            → v_c_variant_feed
//	   构成    GET /api/v1/variants/{id}/composition          → v_c_variant_composition
//	④ 看日历  GET /api/v1/variants/{id}/calendar             → c_variant_calendar
//
// 写侧（下单 / 支付 / 出券）暂时不开成 HTTP 接口：那些口径各有唯一实现
// （fn_place_order / fn_record_payment / fn_issue_voucher），
// 但系统里**还没有调用方身份**——没有顾客账号体系，
// 把下单开成匿名接口等于把订单入口暴露给任何人。
// 读侧不需要身份，可以先落地。
//
// 读侧没有身份可依，边界就画在渠道上：所有收 channel_id 的接口
// 只服务**在营的自营 C 端**（requireChannel）。B 端分销、企业客户、
// 供应商直销各有自己的商务口径，读模型也在同一个库里 ——
// 不拦一道就等于换个渠道号就能读到别家的目录与报价。
package capi

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

// Server 是 C 端只读 API 的服务句柄。
type Server struct {
	db  *store.DB
	mux *http.ServeMux
}

// New 建一个 API 服务。
func New(db *store.DB) *Server {
	s := &Server{db: db, mux: http.NewServeMux()}
	s.mux.HandleFunc("GET /healthz", s.handleHealth)
	s.mux.HandleFunc("GET /api/v1/products", s.handleProducts)
	s.mux.HandleFunc("GET /api/v1/products/{product_id}/variants", s.handleVariants)
	s.mux.HandleFunc("GET /api/v1/variants/{variant_id}/composition", s.handleComposition)
	s.mux.HandleFunc("GET /api/v1/variants/{variant_id}/calendar", s.handleCalendar)
	// 兜底：路径不认识时也回 JSON —— 客户端解析错误体时不该遇到一段纯文本。
	s.mux.HandleFunc("/", s.handleNotFound)
	return s
}

// handleNotFound 兜底的 404。
func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeErr(w, http.StatusNotFound, "not_found",
		fmt.Sprintf("没有这个接口：%s %s", r.Method, r.URL.Path))
}

// ServeHTTP 让 Server 直接当 http.Handler 用。
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

// defaultLocale 是没传 locale 时的默认语言。
const defaultLocale = "zh-CN"

// localeRe 是 locale 的白名单：字母、数字、下划线、短横。
//
// locale 是拼进 SQL 的（psql 子进程没有占位符），所以先把它关进一个
// 只可能由这些字符组成的集合再拼 —— 校验不过就报错，不猜、不糊过去。
var localeRe = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)

// channelID 取必答的渠道维度。
//
// 渠道是必答的那一半：C 端读模型是**按渠道**建的，
// 一个套餐上了两个渠道就有两份成分明细 —— 不按渠道过滤，
// 「2 份成人 + 1 份儿童」会被数成两遍（SPEC §5.14）。
func channelID(r *http.Request) (int64, error) {
	raw := strings.TrimSpace(r.URL.Query().Get("channel_id"))
	if raw == "" {
		return 0, fmt.Errorf("channel_id 必填（C 端读模型按渠道建，不按渠道过滤会把份数数成两遍）")
	}
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("channel_id 必须是正整数，收到 %q", raw)
	}
	return id, nil
}

// publicChannelType 是公开读接口唯一服务的渠道类型。
//
// channel 表里还有 B 端分销、企业客户、供应商直销、内部运营这些类型：
// 它们的读模型有各自的商务口径（价格、币种、税费、结算），
// 对外的 C 端接口只服务自营门店 —— 换个渠道号就能读到别家的目录与报价，
// 那是跨渠道的数据泄露，不是「参数没校验」的小问题。
const publicChannelType = "b2c_own"

// requireChannel 取必答的渠道维度，并确认它是对外服务的渠道。
//
// 匿名接口没有调用方身份，边界只能画在渠道上：只服务**在营的自营 C 端**。
// 渠道不存在与渠道不对外服务给同一个答复 —— 不给调用方一个能枚举渠道的探针。
//
// 每个收 channel_id 的处理器都必须走这里，不许自己再解析一遍。
func (s *Server) requireChannel(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := channelID(r)
	if err != nil {
		badRequest(w, err)
		return 0, false
	}
	ok, err := s.channelIsPublic(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "读渠道失败："+err.Error())
		return 0, false
	}
	if !ok {
		writeErr(w, http.StatusForbidden, "forbidden",
			fmt.Sprintf("channel_id=%d 不是对外服务的渠道（这个接口只服务在营的自营 C 端渠道）", id))
		return 0, false
	}
	return id, true
}

// channelIsPublic 判断这个渠道是不是对外服务的自营 C 端门店。
func (s *Server) channelIsPublic(id int64) (bool, error) {
	sql := fmt.Sprintf(
		"SELECT count(*) FROM channel WHERE id = %d AND channel_type = '%s' AND status = 'active'",
		id, publicChannelType)
	n, err := s.db.Scalar(sql)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(n) == "1", nil
}

// locale 取展示语言。
func locale(r *http.Request) (string, error) {
	raw := strings.TrimSpace(r.URL.Query().Get("locale"))
	if raw == "" {
		return defaultLocale, nil
	}
	if !localeRe.MatchString(raw) {
		return "", fmt.Errorf("locale 只能由字母、数字、下划线、短横组成（不超过 32 个字符），收到 %q", raw)
	}
	return raw, nil
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
		if convErr != nil || n < 1 || n > 200 {
			return 0, 0, fmt.Errorf("limit 必须是 1 到 200 之间的整数，收到 %q", raw)
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

// badRequest 报参数错。
func badRequest(w http.ResponseWriter, err error) {
	writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
}

// rawJSON 把 jsonb 列的文本变成可序列化的 JSON 值。
//
// 空值（NULL）与坏值一律变成 null —— 这些列都是 jsonb，
// 库里出来的文本一定是合法 JSON；万一不是，宁可少给一个字段，
// 也不要让整个响应序列化失败。
func rawJSON(s string) json.RawMessage {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" || !json.Valid([]byte(trimmed)) {
		return json.RawMessage("null")
	}
	return json.RawMessage(trimmed)
}
