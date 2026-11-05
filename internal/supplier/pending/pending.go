// Package pending 是接口细节尚未核实的源的占位适配器。
//
// 这些源不是「不做」，而是**卡在商务/文档**上：
//   - Ingresso       文档不公开，需 mutual NDA + ticketing agreement 后索取 URL+密码（OCTO XML）
//   - Goodfellows JTB hostConnect（OTA XML 2010A），技术规格需权限凭据
//   - Zowoyoo        需申请生产 API Key
//   - FonTicket      未找到公开 API 文档
//   - 票付通          未找到公开 API 文档
//
// 占位适配器能做的事（不编造任何东西）：
//   - 校验凭证齐备性，明确报出缺哪个环境变量
//   - 若端点已配置，做 TCP 连通性探测
//   - 其余一律报「接口细节待确认」，并说明卡在哪、需要什么
package pending

import (
	"context"
	"encoding/json"
	"time"

	"ticket-center/internal/apperr"
	"ticket-center/internal/supplier"
	"ticket-center/internal/transport"
)

// Adapter 是占位适配器。
type Adapter struct {
	*supplier.Base
}

// New 构造适配器。
func New(base *supplier.Base) *Adapter { return &Adapter{Base: base} }

// Code 供应源编码。
func (a *Adapter) Code() string { return a.Base.Code }

// Protocol 协议形态。
func (a *Adapter) Protocol() string { return a.Base.Cfg.Protocol }

// Confirmed 接口细节是否已核实。
func (a *Adapter) Confirmed() bool { return false }

// Describe 自述。
func (a *Adapter) Describe() map[string]any {
	return map[string]any{
		"supplier_code":       a.Code(),
		"protocol":            a.Protocol(),
		"confirmed":           a.Confirmed(),
		"env":                 a.Env,
		"protocol_note":       a.Cfg.ProtocolNote,
		"credentials":         a.Creds.Describe(),
		"missing_credentials": a.Base.MissingCredentials(),
	}
}

// Connectivity 若端点已配置则探测，否则报「待确认」。
func (a *Adapter) Connectivity(ctx context.Context) (transport.ProbeResult, error) {
	eps := a.Base.Endpoints()
	endpoint := eps["catalog"]
	if endpoint == "" {
		endpoint = eps["service"]
	}
	if endpoint == "" {
		return transport.ProbeResult{OK: false, Detail: a.Cfg.ProtocolNote},
			&apperr.EndpointUnconfirmed{
				SupplierCode: a.Code(), What: "端点",
				Detail: a.Cfg.ProtocolNote, Need: "商务提供接口文档 / URL 后填入 configs/api_config.json",
			}
	}
	res, err := a.Base.Probe(endpoint, 5*time.Second)
	return res, err
}

// Authenticate 凭证齐备性校验；认证方式未确认则明确报待确认。
func (a *Adapter) Authenticate(ctx context.Context) (string, error) {
	if err := a.Base.RequireCredentials(); err != nil {
		return "", err
	}
	return "", a.unconfirmed("认证方式")
}

// ListProducts 待确认。
func (a *Adapter) ListProducts(ctx context.Context, opts map[string]any) (json.RawMessage, error) {
	return nil, a.unconfirmed("目录接口")
}

// GetProduct 待确认。
func (a *Adapter) GetProduct(ctx context.Context, externalID string) (json.RawMessage, error) {
	return nil, a.unconfirmed("详情接口")
}

// GetPriceCalendar 待确认。
func (a *Adapter) GetPriceCalendar(ctx context.Context, externalID, start, end string) (json.RawMessage, error) {
	return nil, a.unconfirmed("价格接口")
}

func (a *Adapter) unconfirmed(what string) error {
	return &apperr.EndpointUnconfirmed{
		SupplierCode: a.Code(), What: what,
		Detail: a.Cfg.ProtocolNote, Need: "商务提供接口文档后实现",
	}
}
