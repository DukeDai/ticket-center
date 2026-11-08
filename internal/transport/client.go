// Package transport 是 HTTP 传输层：超时、指数退避重试、错误四分类。
//
// 零第三方依赖，只用标准库 net/http。
package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"ticket-center/internal/apperr"
)

// Response 一次 HTTP 调用的结果。
type Response struct {
	Status  int
	Header  http.Header
	Body    []byte
	Latency time.Duration
	URL     string
}

// JSON 把响应体解析到 v。
func (r *Response) JSON(v any) error { return decodeJSON(r.Body, v) }

// JSONMap 把响应体解析成 map。
func (r *Response) JSONMap() (map[string]any, error) {
	m := map[string]any{}
	if err := r.JSON(&m); err != nil {
		return nil, err
	}
	return m, nil
}

// RetryAfterSeconds 解析 Retry-After（仅支持秒数形式）。
func (r *Response) RetryAfterSeconds() (float64, bool) {
	v := r.Header.Get("Retry-After")
	if v == "" {
		return 0, false
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, false
	}
	return math.Max(0, f), true
}

// Classifier 判断一次响应是否出错。返回 nil 表示成功。
// 分类规则由源侧配置驱动（见 configs/api_config.json），不在传输层写死。
type Classifier func(resp *Response) *apperr.Error

// Request 一次请求的描述。
type Request struct {
	Method   string
	URL      string
	Query    url.Values
	Body     any
	Headers  map[string]string
	Classify Classifier
	// SupplierCode 写进错误，便于定位是哪个源。
	SupplierCode string
	// TraceID 请求追踪位（uuid 之类），写进归档。
	TraceID string
}

// Client 带重试与退避的 HTTP 客户端。
type Client struct {
	HTTP        *http.Client
	MaxAttempts int
	BackoffBase time.Duration
	BackoffCap  time.Duration
	UserAgent   string
	// Sleep 可注入，便于测试断言退避行为。
	Sleep func(time.Duration)
	// Rand 用于抖动，避免多实例同时重试。
	Rand *rand.Rand
}

// NewClient 构造默认客户端。
func NewClient() *Client {
	return &Client{
		HTTP:        &http.Client{Timeout: 20 * time.Second},
		MaxAttempts: 3,
		BackoffBase: time.Second,
		BackoffCap:  30 * time.Second,
		UserAgent:   "ticket-center-adapter/1.0",
		Sleep:       time.Sleep,
		Rand:        rand.New(rand.NewSource(time.Now().UnixNano())),
	}
}

// ProbeResult 连通性探测结果。
type ProbeResult struct {
	OK     bool   `json:"ok"`
	Host   string `json:"host"`
	Port   int    `json:"port"`
	Detail string `json:"detail"`
}

// Probe TCP 连通性探测（不需要凭证）。
func (c *Client) Probe(host string, port int, timeout time.Duration) ProbeResult {
	start := time.Now()
	addr := fmt.Sprintf("%s:%d", host, port)
	conn, err := netDialTimeout(addr, timeout)
	if err != nil {
		return ProbeResult{OK: false, Host: host, Port: port,
			Detail: fmt.Sprintf("TCP %s 失败：%v", addr, err)}
	}
	_ = conn.Close()
	return ProbeResult{OK: true, Host: host, Port: port,
		Detail: fmt.Sprintf("TCP %s 可连接（%dms）", addr, time.Since(start).Milliseconds())}
}

// Do 发起请求并按分类器决定是否重试。
//
// 只有 retriable 与 rate_limit 会重试；fatal 立即失败（交由上层改派备源）；
// auth 不会在这里重试（由适配器决定是否刷新 token 后再试一次）。
func (c *Client) Do(ctx context.Context, req Request) (*Response, error) {
	full := req.URL
	if len(req.Query) > 0 {
		sep := "?"
		if u, err := url.Parse(req.URL); err == nil && u.RawQuery != "" {
			sep = "&"
		}
		full = req.URL + sep + req.Query.Encode()
	}

	var body []byte
	headers := map[string]string{
		"User-Agent": c.UserAgent,
		"Accept":     "application/json",
	}
	if req.Body != nil {
		b, err := json.Marshal(req.Body)
		if err != nil {
			return nil, &apperr.Error{Class: apperr.ClassFatal, Code: "ENCODE_BODY",
				Message: "请求体序列化失败: " + err.Error(), SupplierCode: req.SupplierCode}
		}
		body = b
		headers["Content-Type"] = "application/json; charset=utf-8"
	}
	for k, v := range req.Headers {
		headers[k] = v
	}

	method := req.Method
	if method == "" {
		method = http.MethodGet
	}

	var lastErr error
	attempts := c.MaxAttempts
	if attempts < 1 {
		attempts = 1
	}

	for attempt := 0; attempt < attempts; attempt++ {
		resp, err := c.doOnce(ctx, method, full, body, headers)
		if err != nil {
			lastErr = err
			if attempt < attempts-1 && isNetworkError(err) {
				c.backoff(attempt, nil)
				continue
			}
			return nil, lastErr
		}

		var verdict *apperr.Error
		if req.Classify != nil {
			verdict = req.Classify(resp)
		} else {
			verdict = apperr.DefaultFromStatus(resp.Status)
		}
		if verdict == nil {
			return resp, nil
		}
		verdict.SupplierCode = req.SupplierCode
		if verdict.HTTPStatus == 0 {
			verdict.HTTPStatus = resp.Status
		}
		if verdict.Raw == "" {
			verdict.Raw = truncate(string(resp.Body), 4000)
		}
		lastErr = verdict
		if verdict.Retryable() && attempt < attempts-1 {
			c.backoff(attempt, resp)
			continue
		}
		return nil, verdict
	}
	return nil, lastErr
}

func (c *Client) doOnce(ctx context.Context, method, full string, body []byte, headers map[string]string) (*Response, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	httpReq, err := http.NewRequestWithContext(ctx, method, full, rdr)
	if err != nil {
		return nil, &apperr.Error{Class: apperr.ClassFatal, Code: "BUILD_REQUEST",
			Message: "构造请求失败: " + err.Error()}
	}
	for k, v := range headers {
		httpReq.Header.Set(k, v)
	}
	start := time.Now()
	httpResp, err := c.HTTP.Do(httpReq)
	if err != nil {
		return nil, &apperr.Error{Class: apperr.ClassRetriable, Code: "NETWORK",
			Message: err.Error()}
	}
	defer httpResp.Body.Close()
	b, readErr := io.ReadAll(httpResp.Body)
	if readErr != nil {
		return nil, &apperr.Error{Class: apperr.ClassRetriable, Code: "READ_BODY",
			Message: readErr.Error()}
	}
	return &Response{
		Status:  httpResp.StatusCode,
		Header:  httpResp.Header,
		Body:    b,
		Latency: time.Since(start),
		URL:     full,
	}, nil
}

// backoff 计算并等待退避时长：base * 2^n，带抖动，上限 backoff_cap。
// 源侧给了 Retry-After 时取更大值（但不超过上限）。
func (c *Client) backoff(attempt int, resp *Response) {
	delay := c.BackoffBase * time.Duration(int64(math.Pow(2, float64(attempt))))
	if delay > c.BackoffCap {
		delay = c.BackoffCap
	}
	if c.Rand != nil {
		delay += time.Duration(c.Rand.Int63n(int64(delay/4) + 1))
	}
	if resp != nil {
		if ra, ok := resp.RetryAfterSeconds(); ok {
			d := time.Duration(ra * float64(time.Second))
			if d > delay {
				delay = d
			}
			if delay > c.BackoffCap {
				delay = c.BackoffCap
			}
		}
	}
	if c.Sleep != nil {
		c.Sleep(delay)
	}
}

func isNetworkError(err error) bool {
	ae, ok := err.(*apperr.Error)
	return ok && (ae.Code == "NETWORK" || ae.Code == "READ_BODY")
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
