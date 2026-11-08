// Package tripcom 实现 Trip.com 分销侧适配器（我们从携程拿库存 = 我们是分销商）。
//
// 已核对来源：《门票活动全球分销接口文档》V2.0.25（2026-10-28）OpenAPI 规格。
//
// 访问形态（**URL query 传参**，不是 header、不是 body）：
//
//	POST {service}?aid=..&sid=..&icode=..&uuid=..&token=..
//	body = JSON
//
// 三个必须分清的概念：
//   - uuid               请求级唯一（每次调用都新的），用途是日志追踪，**不是幂等键**
//   - distributorOrderID 业务幂等键（重复下单返回 B0010）
//   - icode              每个接口一个且固定，取自规格 description 的「沙箱测试ICODE / 生产ICODE」
//
// ⚠ 供应商侧那套（accountId + AES-128-CBC + MD5 + sequenceId）是**反方向**的，
// 只在「我们把货推给携程卖」时才用，本适配器不涉及。
package tripcom

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"ticket-center/internal/apperr"
	"ticket-center/internal/config"
	"ticket-center/internal/credential"
	"ticket-center/internal/idgen"
	"ticket-center/internal/supplier"
	"ticket-center/internal/transport"
)

// 接口名（与 configs/api_config.json 的 interfaces 键一一对应）。
const (
	OpListProducts     = "listProducts"
	OpGetProduct       = "getProduct"
	OpGetPriceCalendar = "getPriceCalendar"
	OpGetPoi           = "getPoi"
	OpListAllProducts  = "listAllProducts"
	OpListAllPois      = "listAllPois"
	OpBookingVerify    = "bookingVerify"
	OpBookingReqInfo   = "bookingRequiredInfo"
	OpCreateBooking    = "createBooking"
	OpBookingStatus    = "getBookingStatus"
	OpBookingDetail    = "getBookingDetail"
	OpCancelBooking    = "cancelBooking"
	OpGetVoucher       = "getVoucher"
	OpGetLogistics     = "getLogistics"
	OpGetRefundDetail  = "getRefundDetail"
	OpCancelVerify     = "cancelVerify"
	OpGetCategories    = "getCategories"
	OpGetLocations     = "getLocations"
	OpGetCurrencies    = "getCurrencies"
	OpGetLocales       = "getLocales"
)

// entityTypes：接口 → 归档实体类型（supplier_raw_payload.entity_type 词表）。
var entityTypes = map[string]string{
	OpListProducts: "product", OpGetProduct: "product", OpGetPoi: "product",
	OpListAllProducts: "product", OpListAllPois: "product",
	OpGetPriceCalendar: "price",
	OpGetCategories:    "product", OpGetLocations: "product",
	OpGetCurrencies: "product", OpGetLocales: "product",
	OpBookingVerify: "booking", OpBookingReqInfo: "booking",
	OpCreateBooking: "booking", OpBookingStatus: "booking",
	OpBookingDetail: "booking", OpCancelBooking: "cancel",
	OpGetVoucher: "booking", OpGetLogistics: "booking",
	OpGetRefundDetail: "refund", OpCancelVerify: "refund",
}

// Envelope 是源侧业务信封：{success, errcode, errmsg, data}。
type Envelope struct {
	Success bool            `json:"success"`
	ErrCode string          `json:"errcode"`
	ErrMsg  string          `json:"errmsg"`
	Data    json.RawMessage `json:"data"`
}

// Result 一次业务调用的结果。
type Result struct {
	Data          json.RawMessage
	ErrCode       string
	ErrMsg        string
	IdempotentHit bool
}

// Adapter 是 Trip.com 适配器。
type Adapter struct {
	*supplier.Base

	mu           sync.Mutex
	accessToken  string
	refreshToken string
	expiresAt    time.Time
}

// New 构造适配器。
func New(base *supplier.Base) *Adapter {
	return &Adapter{Base: base}
}

// Code 供应源编码。
func (a *Adapter) Code() string { return a.Base.Code }

// Protocol 协议形态。
func (a *Adapter) Protocol() string { return a.Base.Cfg.Protocol }

// Confirmed 接口细节是否已核实。
func (a *Adapter) Confirmed() bool { return a.Base.Cfg.Confirmed }

// Describe 自述（不含凭证明文）。
func (a *Adapter) Describe() map[string]any {
	missing := a.Base.MissingCredentials()
	return map[string]any{
		"supplier_code":            a.Code(),
		"protocol":                 a.Protocol(),
		"confirmed":                a.Confirmed(),
		"env":                      a.Env,
		"interfaces_total":         len(a.Cfg.Interfaces),
		"interfaces_missing_icode": a.Cfg.MissingICode(a.Env),
		"endpoints":                a.Base.Endpoints(),
		"credentials":              a.Creds.Describe(),
		"missing_credentials":      missing,
	}
}

// ---------------------------------------------------------------- L0 连通

// Connectivity 探测业务与认证两个主机（不涉及凭证）。
func (a *Adapter) Connectivity(ctx context.Context) (transport.ProbeResult, error) {
	var details []string
	ok := true
	for _, item := range []struct{ label, key string }{{"业务", "service"}, {"认证", "authorize"}} {
		endpoint, err := a.Base.Endpoint(item.key, "端点 "+item.key)
		if err != nil {
			return transport.ProbeResult{OK: false, Detail: err.Error()}, err
		}
		res, err := a.Base.Probe(endpoint, 5*time.Second)
		if err != nil {
			return res, err
		}
		details = append(details, item.label+"："+res.Detail)
		if !res.OK {
			ok = false
		}
	}
	return transport.ProbeResult{OK: ok, Detail: strings.Join(details, "；")}, nil
}

// ---------------------------------------------------------------- L1 认证

// Authenticate 取 access_token / refresh_token。token 只在内存里，不落库。
func (a *Adapter) Authenticate(ctx context.Context) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.accessToken != "" && time.Now().Before(a.expiresAt) {
		return fmt.Sprintf("token 缓存有效（剩余 %ds）", int(time.Until(a.expiresAt).Seconds())), nil
	}
	return a.authenticateLocked(ctx, true)
}

func (a *Adapter) authenticateLocked(ctx context.Context, force bool) (string, error) {
	tc := a.Cfg.Token
	endpoint, err := a.Base.Endpoint("authorize", "认证端点 authorize")
	if err != nil {
		return "", err
	}
	aid, err := a.Creds.Require("aid")
	if err != nil {
		return "", err
	}
	sid, err := a.Creds.Require("sid")
	if err != nil {
		return "", err
	}
	key, err := a.Creds.Require("key")
	if err != nil {
		return "", err
	}

	query := url.Values{}
	query.Set("aid", aid)
	query.Set("sid", sid)
	query.Set("key", key)

	resp, err := a.Client.Do(ctx, transport.Request{
		Method: "POST", URL: endpoint, Query: query,
		SupplierCode: a.Code(),
		Classify:     a.classifyAuth,
	})
	if err != nil {
		return "", err
	}
	var body map[string]any
	if err := resp.JSON(&body); err != nil {
		return "", &apperr.Error{Class: apperr.ClassFatal, Code: "BAD_AUTH_RESPONSE",
			Message: "认证响应不是 JSON 对象", SupplierCode: a.Code()}
	}
	access := asString(body[tc.AccessField])
	if access == "" {
		code := asString(body[tc.ErrCodeField])
		msg := asString(body[tc.ErrMsgField])
		return "", &apperr.Error{Class: apperr.ClassAuth, Code: orDefault(code, "NO_TOKEN"),
			Message: "未取到 Access_Token：" + orDefault(msg, string(resp.Body)), SupplierCode: a.Code()}
	}
	a.accessToken = access
	a.refreshToken = asString(body[tc.RefreshField])
	expires := int(toFloat(body[tc.ExpiresField]))
	if expires <= 0 {
		expires = 600
	}
	skew := time.Duration(tc.SkewSeconds) * time.Second
	a.expiresAt = time.Now().Add(time.Duration(expires) * time.Second).Add(-skew)
	a.archive("auth", "", "outbound", map[string]any{"endpoint": "authorize"}, body, resp)
	return fmt.Sprintf("已取到 token（有效期 %ds，剩余有效期 %.0fs）", expires, time.Until(a.expiresAt).Seconds()), nil
}

// classifyAuth 认证端点的错误分类（ErrCode 1001-1006）。
func (a *Adapter) classifyAuth(resp *transport.Response) *apperr.Error {
	if resp.Status >= 400 {
		return apperr.DefaultFromStatus(resp.Status)
	}
	var body map[string]any
	if err := resp.JSON(&body); err != nil {
		return &apperr.Error{Class: apperr.ClassFatal, Code: "BAD_AUTH_RESPONSE",
			Message: "认证响应不是 JSON 对象"}
	}
	code := asString(body[a.Cfg.Token.ErrCodeField])
	if code == "" || code == "0" {
		return nil
	}
	cls := apperr.ClassAuth
	if c, ok := a.Cfg.ErrorCodes[code]; ok && apperr.Class(c).Valid() {
		cls = apperr.Class(c)
	}
	return &apperr.Error{Class: cls, Code: code,
		Message: fmt.Sprintf("%s：%s", code, asString(body[a.Cfg.Token.ErrMsgField]))}
}

// refresh 刷新 token（2.2）。
func (a *Adapter) refresh(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.refreshToken == "" {
		_, err := a.authenticateLocked(ctx, true)
		return err
	}
	tc := a.Cfg.Token
	endpoint, err := a.Base.Endpoint("refresh", "认证端点 refresh")
	if err != nil {
		return err
	}
	aid, _ := a.Creds.Require("aid")
	sid, _ := a.Creds.Require("sid")
	query := url.Values{}
	query.Set("aid", aid)
	query.Set("sid", sid)
	query.Set("refresh_token", a.refreshToken)

	resp, err := a.Client.Do(ctx, transport.Request{
		Method: "POST", URL: endpoint, Query: query,
		SupplierCode: a.Code(), Classify: a.classifyAuth,
	})
	if err != nil {
		return err
	}
	var body map[string]any
	if err := resp.JSON(&body); err != nil {
		return &apperr.Error{Class: apperr.ClassFatal, Code: "BAD_AUTH_RESPONSE",
			Message: "刷新响应不是 JSON 对象", SupplierCode: a.Code()}
	}
	access := asString(body[tc.AccessField])
	if access == "" {
		return &apperr.Error{Class: apperr.ClassAuth, Code: orDefault(asString(body[tc.ErrCodeField]), "NO_TOKEN"),
			Message: "刷新 token 失败：" + asString(body[tc.ErrMsgField]), SupplierCode: a.Code()}
	}
	a.accessToken = access
	if rt := asString(body[tc.RefreshField]); rt != "" {
		a.refreshToken = rt
	}
	expires := int(toFloat(body[tc.ExpiresField]))
	if expires <= 0 {
		expires = 600
	}
	skew := time.Duration(tc.SkewSeconds) * time.Second
	a.expiresAt = time.Now().Add(time.Duration(expires) * time.Second).Add(-skew)
	a.archive("auth", "", "outbound", map[string]any{"endpoint": "refresh"}, body, resp)
	return nil
}

// ensureToken 保证有可用 token。
//
// 注意锁的用法：authenticateLocked 假定调用方已持锁，这里**只加一次锁**，
// 否则会出现自锁（token 过期时必然触发）。
func (a *Adapter) ensureToken(ctx context.Context) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.accessToken == "" || !time.Now().Before(a.expiresAt) {
		if _, err := a.authenticateLocked(ctx, true); err != nil {
			return "", err
		}
	}
	return a.accessToken, nil
}

// ---------------------------------------------------------------- 调用

// classify 业务信封分类：{success, errcode, errmsg, data}。
func (a *Adapter) classify(resp *transport.Response) *apperr.Error {
	if resp.Status >= 400 {
		return apperr.DefaultFromStatus(resp.Status)
	}
	var env Envelope
	if err := resp.JSON(&env); err != nil {
		return &apperr.Error{Class: apperr.ClassFatal, Code: "BAD_RESPONSE",
			Message: "响应不是 JSON 对象: " + truncate(resp.Body, 200)}
	}
	if env.Success {
		return nil
	}
	code := strings.TrimSpace(env.ErrCode)
	// 幂等命中（B0010 重复下单）不是失败：放行，交给调用方识别
	if contains(a.Cfg.IdempotentCodes, code) {
		return nil
	}
	cls := apperr.ClassFatal
	if c, ok := a.Cfg.ErrorCodes[code]; ok && apperr.Class(c).Valid() {
		cls = apperr.Class(c)
	}
	label := a.Cfg.ErrorLabels[code]
	msg := code
	if label != "" {
		msg += " " + label
	}
	if env.ErrMsg != "" {
		msg += "：" + env.ErrMsg
	}
	return &apperr.Error{Class: cls, Code: orDefault(code, "BUSINESS_ERROR"), Message: msg}
}

// ICode 取接口在当前环境的 ICODE，缺失时报 EndpointUnconfirmed（不猜）。
func (a *Adapter) ICode(op string) (string, error) {
	iface, ok := a.Cfg.Interfaces[op]
	if !ok {
		return "", &apperr.EndpointUnconfirmed{SupplierCode: a.Code(),
			What: "接口 " + op, Detail: "api_config.json 未定义该接口",
			Need: "在 configs/api_config.json 补该接口的 icode"}
	}
	icode := a.Cfg.ICode(op, a.Env)
	if icode == "" {
		detail := fmt.Sprintf("规格未给出%s ICODE", a.Env)
		if iface.Note != "" {
			detail += "（" + iface.Note + "）"
		}
		return "", &apperr.EndpointUnconfirmed{SupplierCode: a.Code(),
			What: "接口 " + op, Detail: detail, Need: "需携程商务提供该接口的 ICODE"}
	}
	return icode, nil
}

// Call 调用一个业务接口。
func (a *Adapter) Call(ctx context.Context, op string, body map[string]any, entityRef string) (*Result, error) {
	icode, err := a.ICode(op)
	if err != nil {
		return nil, err
	}
	service, err := a.Base.Endpoint("service", "业务端点 service")
	if err != nil {
		return nil, err
	}
	refreshable := a.Cfg.RefreshableCodes

	for outer := 0; outer < 2; outer++ {
		token, err := a.ensureToken(ctx)
		if err != nil {
			return nil, err
		}
		trace := idgen.UUID()
		query := url.Values{}
		query.Set("aid", mustGet(a.Creds, "aid"))
		query.Set("sid", mustGet(a.Creds, "sid"))
		query.Set("icode", icode)
		query.Set("uuid", trace)
		query.Set("token", token)

		resp, err := a.Client.Do(ctx, transport.Request{
			Method: "POST", URL: service, Query: query, Body: body,
			SupplierCode: a.Code(), TraceID: trace, Classify: a.classify,
		})
		if err != nil {
			ae, ok := err.(*apperr.Error)
			if ok && ae.Class == apperr.ClassAuth && contains(refreshable, ae.Code) && outer == 0 {
				if rerr := a.refresh(ctx); rerr != nil {
					return nil, rerr
				}
				continue
			}
			return nil, err
		}
		var env Envelope
		if err := resp.JSON(&env); err != nil {
			return nil, &apperr.Error{Class: apperr.ClassFatal, Code: "BAD_RESPONSE",
				Message: "响应不是 JSON 对象", SupplierCode: a.Code()}
		}
		code := strings.TrimSpace(env.ErrCode)
		hit := contains(a.Cfg.IdempotentCodes, code)
		a.archive(entityTypes[op], entityRef, "outbound",
			map[string]any{"interface": op, "icode": icode,
				"query": transport.RedactURL(resp.URL), "body": body},
			env, resp)
		return &Result{Data: env.Data, ErrCode: code, ErrMsg: env.ErrMsg, IdempotentHit: hit}, nil
	}
	return nil, &apperr.Error{Class: apperr.ClassRetriable, Code: "REFRESH_LOOP",
		Message: "刷新 token 后仍失败", SupplierCode: a.Code()}
}

func (a *Adapter) archive(entityType, entityRef, direction string, request, response any, resp *transport.Response) {
	if a.Archiver == nil || !a.Archiver.Enabled() {
		return
	}
	status, latency := 0, 0
	if resp != nil {
		status = resp.Status
		latency = int(resp.Latency.Milliseconds())
	}
	_ = a.Archiver.Record(entityType, entityRef, direction, request, response, status, latency, "")
}

// ---------------------------------------------------------------- 端口

// ListProducts L2 目录。
func (a *Adapter) ListProducts(ctx context.Context, opts map[string]any) (json.RawMessage, error) {
	body := map[string]any{}
	for k, v := range a.Cfg.Probes[OpListProducts] {
		body[k] = v
	}
	for k, v := range opts {
		body[k] = v
	}
	res, err := a.Call(ctx, OpListProducts, body, "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetProduct L3 详情。
func (a *Adapter) GetProduct(ctx context.Context, externalID string) (json.RawMessage, error) {
	body := map[string]any{}
	for k, v := range a.Cfg.Probes[OpGetProduct] {
		body[k] = v
	}
	body["productIDList"] = []any{externalID}
	res, err := a.Call(ctx, OpGetProduct, body, externalID)
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetPriceCalendar L4 价格。
func (a *Adapter) GetPriceCalendar(ctx context.Context, externalID, start, end string) (json.RawMessage, error) {
	body := map[string]any{}
	for k, v := range a.Cfg.Probes[OpGetPriceCalendar] {
		body[k] = v
	}
	body["productID"] = externalID
	body["startDate"] = start
	body["endDate"] = end
	res, err := a.Call(ctx, OpGetPriceCalendar, body, externalID)
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetCategories 品类字典。
func (a *Adapter) GetCategories(ctx context.Context) (json.RawMessage, error) {
	res, err := a.Call(ctx, OpGetCategories, probeBody(a.Cfg, OpGetCategories), "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetLocations 位置树。
func (a *Adapter) GetLocations(ctx context.Context) (json.RawMessage, error) {
	res, err := a.Call(ctx, OpGetLocations, probeBody(a.Cfg, OpGetLocations), "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetCurrencies 币种清单。
func (a *Adapter) GetCurrencies(ctx context.Context) (json.RawMessage, error) {
	res, err := a.Call(ctx, OpGetCurrencies, probeBody(a.Cfg, OpGetCurrencies), "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetLocales 语言清单。
func (a *Adapter) GetLocales(ctx context.Context) (json.RawMessage, error) {
	res, err := a.Call(ctx, OpGetLocales, probeBody(a.Cfg, OpGetLocales), "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// ListAllProducts 全量增量（游标 lastMaxId）。
func (a *Adapter) ListAllProducts(ctx context.Context, lastMaxID string, limit int) (json.RawMessage, error) {
	body := map[string]any{"lastMaxId": lastMaxID, "limit": limit}
	res, err := a.Call(ctx, OpListAllProducts, body, "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// CreateBooking 创建订单。业务幂等键 = distributorOrderID。
//
// 返回 IdempotentHit=true 表示源侧识别为重复请求（不是失败），调用方应改查已有订单。
func (a *Adapter) CreateBooking(ctx context.Context, request map[string]any, idempotencyKey string) (*Result, error) {
	body := map[string]any{}
	for k, v := range request {
		body[k] = v
	}
	if idempotencyKey == "" {
		idempotencyKey = asString(body["distributorOrderID"])
	}
	if idempotencyKey == "" {
		return nil, &apperr.Error{Class: apperr.ClassFatal, Code: "NO_IDEMPOTENCY_KEY",
			Message:      "创建订单必须提供 distributorOrderID（= 我们的 booking.idempotency_key）",
			SupplierCode: a.Code()}
	}
	body["distributorOrderID"] = idempotencyKey

	scope := a.Code() + ":book"
	if a.Idem != nil && a.Idem.Enabled() {
		state, cached, err := a.Idem.Begin(scope, idempotencyKey, body)
		if err != nil {
			return nil, err
		}
		if state == "replay" {
			raw, _ := json.Marshal(cached)
			return &Result{Data: raw}, nil
		}
	}
	res, err := a.Call(ctx, OpCreateBooking, body, idempotencyKey)
	if err != nil {
		if a.Idem != nil && a.Idem.Enabled() {
			_ = a.Idem.Fail(scope, idempotencyKey)
		}
		return nil, err
	}
	if a.Idem != nil && a.Idem.Enabled() {
		_ = a.Idem.Complete(scope, idempotencyKey, res.Data)
	}
	return res, nil
}

// CancelBooking 订单退订。
func (a *Adapter) CancelBooking(ctx context.Context, orderID, reason string, items []any) (json.RawMessage, error) {
	body := map[string]any{"orderId": orderID, "reason": reason}
	if len(items) > 0 {
		body["cancelOrderItems"] = items
	}
	res, err := a.Call(ctx, OpCancelBooking, body, orderID)
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetBookingStatus 订单状态。
func (a *Adapter) GetBookingStatus(ctx context.Context, orderIDs, distributorOrderIDs []any) (json.RawMessage, error) {
	body := map[string]any{}
	if len(orderIDs) > 0 {
		body["orderIDList"] = orderIDs
	}
	if len(distributorOrderIDs) > 0 {
		body["distributorOrderIDList"] = distributorOrderIDs
	}
	res, err := a.Call(ctx, OpBookingStatus, body, "")
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetBookingDetail 订单详情。
func (a *Adapter) GetBookingDetail(ctx context.Context, orderID, distributorOrderID string) (json.RawMessage, error) {
	body := map[string]any{}
	if orderID != "" {
		body["orderID"] = orderID
	}
	if distributorOrderID != "" {
		body["distributorOrderID"] = distributorOrderID
	}
	res, err := a.Call(ctx, OpBookingDetail, body, distributorOrderID)
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// GetVoucher 凭证信息。
func (a *Adapter) GetVoucher(ctx context.Context, orderID string) (json.RawMessage, error) {
	res, err := a.Call(ctx, OpGetVoucher, map[string]any{"orderID": orderID}, orderID)
	if err != nil {
		return nil, err
	}
	return res.Data, nil
}

// ---------------------------------------------------------------- 工具

func probeBody(cfg *config.Source, op string) map[string]any {
	return cfg.Probe(op)
}

func mustGet(c *credential.Credentials, name string) string {
	v, _ := c.Get(name)
	return v
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func asString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		if t == float64(int64(t)) {
			return fmt.Sprintf("%d", int64(t))
		}
		return fmt.Sprintf("%v", t)
	}
	return fmt.Sprintf("%v", v)
}

func toFloat(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case string:
		var f float64
		fmt.Sscanf(t, "%g", &f)
		return f
	}
	return 0
}

func truncate(s []byte, n int) string {
	if len(s) <= n {
		return string(s)
	}
	return string(s[:n]) + "..."
}
