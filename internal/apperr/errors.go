// Package apperr 定义适配器层统一错误类型。
//
// 全平台只有四类错误（对应 docs/connector-contract.md §2）：
//
//	retriable  临时故障，重试有意义（网络超时、5xx、限流）
//	fatal      业务拒绝，重试无意义（库存不足、票种售罄）—— 立即失败并改派备源
//	auth       鉴权问题 —— 告警 + 暂停该源，绝不当成可重试错误
//	rate_limit 被限流 —— 尊重 Retry-After，降速全局
//
// 最关键的一条：fatal 不能重试。把「库存被占位」当超时重试，
// 是线上最容易犯的错（重试也拿不到票，还把源侧库存搅乱）。
package apperr

import (
	"fmt"
	"net/http"
)

// Class 是错误四分类。
type Class string

const (
	ClassRetriable Class = "retriable"
	ClassFatal     Class = "fatal"
	ClassAuth      Class = "auth"
	ClassRateLimit Class = "rate_limit"
)

// Valid 判断分类是否合法。
func (c Class) Valid() bool {
	switch c {
	case ClassRetriable, ClassFatal, ClassAuth, ClassRateLimit:
		return true
	}
	return false
}

// Retryable 只有 retriable 与 rate_limit 值得重试。
func (c Class) Retryable() bool {
	return c == ClassRetriable || c == ClassRateLimit
}

// Error 是适配器统一异常。
type Error struct {
	Class        Class  // 四分类
	Code         string // 源侧错误码（无则空）
	Message      string
	SupplierCode string
	HTTPStatus   int
	Raw          string // 源侧原始报文（截断）
	Hint         string // 处置建议
}

func (e *Error) Error() string {
	return fmt.Sprintf("[%s][%s] %s %s", e.SupplierCode, e.Class, e.Code, e.Message)
}

// Retryable 该错误是否值得重试。
func (e *Error) Retryable() bool { return e.Class.Retryable() }

// MissingCredential 描述一个缺失的凭证项。
type MissingCredential struct {
	Name          string `json:"name"`
	Env           string `json:"env"`
	AuthConfigKey string `json:"auth_config_key"`
}

// MissingCredentials 凭证缺失：明确报出缺哪个环境变量，不猜、不硬编码。
type MissingCredentials struct {
	SupplierCode string
	Missing      []MissingCredential
}

func (e *MissingCredentials) Error() string {
	parts := make([]string, 0, len(e.Missing))
	for _, m := range e.Missing {
		parts = append(parts, fmt.Sprintf("%s（环境变量 %s）", m.Name, m.Env))
	}
	return fmt.Sprintf("[%s][auth] 缺少凭证：%s", e.SupplierCode, join(parts, "；"))
}

// AsMissing 提取 MissingCredentials。
func AsMissing(err error) (*MissingCredentials, bool) {
	for err != nil {
		if m, ok := err.(*MissingCredentials); ok {
			return m, true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			break
		}
		err = u.Unwrap()
	}
	return nil, false
}

// EndpointUnconfirmed 源侧接口细节无公开文档 —— 禁止编造端点。
type EndpointUnconfirmed struct {
	SupplierCode string
	What         string // 哪个接口/端点没确认
	Detail       string // 已知的部分（凭证口径、协议形态……）
	Need         string // 需要什么才能实现
}

func (e *EndpointUnconfirmed) Error() string {
	return fmt.Sprintf("[%s][fatal] %s 未确认：%s（需要：%s）",
		e.SupplierCode, e.What, e.Detail, e.Need)
}

// AsUnconfirmed 提取 EndpointUnconfirmed。
func AsUnconfirmed(err error) (*EndpointUnconfirmed, bool) {
	for err != nil {
		if u, ok := err.(*EndpointUnconfirmed); ok {
			return u, true
		}
		w, ok := err.(interface{ Unwrap() error })
		if !ok {
			break
		}
		err = w.Unwrap()
	}
	return nil, false
}

// DefaultFromStatus 无源特定分类器时的兜底：按 HTTP 状态码归一。
func DefaultFromStatus(status int) *Error {
	switch {
	case status == http.StatusTooManyRequests:
		return &Error{Class: ClassRateLimit, Code: "HTTP_429", Message: "被限流（HTTP 429）", HTTPStatus: status}
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return &Error{Class: ClassAuth, Code: fmt.Sprintf("HTTP_%d", status),
			Message: fmt.Sprintf("鉴权被拒（HTTP %d）", status), HTTPStatus: status}
	case status >= 500:
		return &Error{Class: ClassRetriable, Code: fmt.Sprintf("HTTP_%d", status),
			Message: fmt.Sprintf("服务端错误（HTTP %d）", status), HTTPStatus: status}
	case status >= 400:
		return &Error{Class: ClassFatal, Code: fmt.Sprintf("HTTP_%d", status),
			Message: fmt.Sprintf("客户端错误（HTTP %d）", status), HTTPStatus: status}
	}
	return nil
}

func join(parts []string, sep string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += sep
		}
		out += p
	}
	return out
}
