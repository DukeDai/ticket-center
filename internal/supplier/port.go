// Package supplier 定义供应源接入端口（Port）与其公共基类。
//
// 端口是领域层与外部系统之间**唯一**的接触面（见 docs/connector-contract.md §1）。
// 具体源的实现放在 supplier/<源名> 子包里。
package supplier

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"time"

	"ticket-center/internal/apperr"
	"ticket-center/internal/config"
	"ticket-center/internal/credential"
	"ticket-center/internal/store"
	"ticket-center/internal/transport"
)

// Port 是所有供应源适配器实现的端口。
type Port interface {
	// Code 供应源编码（= supplier.code）。
	Code() string
	// Protocol 协议形态。
	Protocol() string
	// Confirmed 接口细节是否已核实（false → 端点不可用，只跑凭证与配置校验）。
	Confirmed() bool
	// Describe 自述（不含凭证明文）。
	Describe() map[string]any

	// Connectivity L0 连通性探测（不需要凭证）。
	Connectivity(ctx context.Context) (transport.ProbeResult, error)
	// Authenticate L1 认证。
	Authenticate(ctx context.Context) (string, error)

	// ListProducts L2 目录。
	ListProducts(ctx context.Context, opts map[string]any) (json.RawMessage, error)
	// GetProduct L3 详情。
	GetProduct(ctx context.Context, externalID string) (json.RawMessage, error)
	// GetPriceCalendar L4 价格。
	GetPriceCalendar(ctx context.Context, externalID, start, end string) (json.RawMessage, error)
}

// Base 是适配器公共基类：凭证、HTTP 客户端、归档、幂等。
type Base struct {
	Code     string
	Cfg      *config.Source
	Creds    *credential.Credentials
	Client   *transport.Client
	Archiver *store.Archiver
	Idem     *store.Idempotency
	Env      string
}

// MissingCredentials 列出还缺哪些凭证（含环境变量名）。
func (b *Base) MissingCredentials() []apperr.MissingCredential {
	var out []apperr.MissingCredential
	for name, spec := range b.Cfg.Credentials {
		if !spec.Required {
			continue
		}
		if _, ok := b.Creds.Get(name); !ok {
			out = append(out, apperr.MissingCredential{
				Name: name, Env: spec.Env, AuthConfigKey: spec.AuthConfigKey,
			})
		}
	}
	return out
}

// RequireCredentials 缺任何必填凭证就报错（明确列出环境变量名）。
func (b *Base) RequireCredentials() error {
	missing := b.MissingCredentials()
	if len(missing) == 0 {
		return nil
	}
	return &apperr.MissingCredentials{SupplierCode: b.Code, Missing: missing}
}

// Endpoints 取当前环境的端点表。
func (b *Base) Endpoints() map[string]string { return b.Cfg.Endpoints.ForEnv(b.Env) }

// Endpoint 取一个端点（缺失时报 EndpointUnconfirmed，不编造）。
func (b *Base) Endpoint(key, what string) (string, error) {
	url := b.Endpoints()[key]
	if url == "" {
		return "", &apperr.EndpointUnconfirmed{
			SupplierCode: b.Code,
			What:         what,
			Detail:       fmt.Sprintf("api_config.json 未配置 %s（环境 %s）", key, b.Env),
			Need:         "商务提供端点后填入 configs/api_config.json",
		}
	}
	return url, nil
}

// Probe 探测一个端点主机的 TCP 连通性。
func (b *Base) Probe(endpointURL string, timeout time.Duration) (transport.ProbeResult, error) {
	u, err := url.Parse(endpointURL)
	if err != nil {
		return transport.ProbeResult{}, &apperr.Error{Class: apperr.ClassFatal, Code: "BAD_URL",
			Message: fmt.Sprintf("端点 URL 解析失败: %v", err), SupplierCode: b.Code}
	}
	port := 443
	if u.Scheme == "http" {
		port = 80
	}
	if u.Port() != "" {
		fmt.Sscanf(u.Port(), "%d", &port)
	}
	return b.Client.Probe(u.Hostname(), port, timeout), nil
}
