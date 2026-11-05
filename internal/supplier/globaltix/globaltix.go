// Package globaltix 实现 GlobalTix Supply API 适配器（我们从 GlobalTix 采购 = 我们是分销商）。
//
// **诚实边界（重要）**：
// GlobalTix 的 Supply API **接口端点与请求体没有公开文档**。目前只核实了两件事：
//
//  1. 凭证口径：Reseller ID (x-agent ID) + Reseller Name + Username + API Key，
//     并且需要把出站 IP 加入白名单。
//  2. SKU 映射是**组合表达式**：`SKU` / `SKU|2` / `A|2+B|1`
//     （官方示例正是「环球影城日本入园票 + 快速通行证家庭套餐（2 成人 + 1 儿童）」
//     = 4 个源 SKU 组成一个可售单元）。
//
// 另外核实到的商业事实：Settlement Cost Price ≠ Recommended Selling Price；
// 价格受限商品要遵守销售政策；库存以 GlobalTix 实时库存为准。
//
// → 因此本适配器**不编造端点**。端点、请求体、字段名都留在 configs/api_config.json 里等商务文档，
// 拿到后填上即可启用；在此之前只跑「凭证齐备性 + 组合表达式解析 + 归一化」三件事。
package globaltix

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"ticket-center/internal/apperr"
	"ticket-center/internal/normalize"
	"ticket-center/internal/supplier"
	"ticket-center/internal/transport"
)

// MappingExpressionForms 已核实的组合表达式语法。
var MappingExpressionForms = []string{"SKU", "SKU|2", "A|2+B|1"}

// Adapter 是 GlobalTix 适配器。
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
func (a *Adapter) Confirmed() bool { return a.Base.Cfg.Confirmed }

// Describe 自述。
func (a *Adapter) Describe() map[string]any {
	return map[string]any{
		"supplier_code":           a.Code(),
		"protocol":                a.Protocol(),
		"confirmed":               a.Confirmed(),
		"env":                     a.Env,
		"confirmed_facts":         a.Cfg.ConfirmedFacts,
		"need_from_business":      a.Cfg.NeedFromBusiness,
		"mapping_expression_forms": MappingExpressionForms,
		"credentials":             a.Creds.Describe(),
		"missing_credentials":     a.Base.MissingCredentials(),
	}
}

// Connectivity 端点未确认 → 不编造主机名，直接报「待商务确认」。
func (a *Adapter) Connectivity(ctx context.Context) (transport.ProbeResult, error) {
	probeHost := a.Base.Endpoints()["probe_host"]
	if probeHost == "" {
		return transport.ProbeResult{OK: false, Detail: "未配置端点主机（GlobalTix 未公开 API 域名）"},
			&apperr.EndpointUnconfirmed{
				SupplierCode: a.Code(), What: "连通性探测",
				Detail: "未配置端点主机（GlobalTix 未公开 API 域名）",
				Need:   "商务提供 base URL 后填入 configs/api_config.json 的 endpoints.<env>.probe_host",
			}
	}
	host, port := probeHost, 443
	if h, p, found := strings.Cut(probeHost, ":"); found {
		host = h
		if n, err := strconv.Atoi(p); err == nil {
			port = n
		}
	}
	res := a.Client.Probe(host, port, 5*time.Second)
	return res, nil
}

// Authenticate 认证方式未确认，只能校验凭证齐备性。
func (a *Adapter) Authenticate(ctx context.Context) (string, error) {
	if err := a.Base.RequireCredentials(); err != nil {
		return "", err
	}
	if !a.Cfg.Auth.Confirmed {
		return "", &apperr.EndpointUnconfirmed{
			SupplierCode: a.Code(), What: "认证方式",
			Detail: "凭证四项齐备，但请求头的确切形态未确认（" + a.Cfg.Auth.Scheme + "）",
			Need:   "商务确认后把 auth.confirmed 置 true 并补 auth.scheme 实现细节",
		}
	}
	return "", &apperr.EndpointUnconfirmed{
		SupplierCode: a.Code(), What: "认证方式",
		Detail: "auth.confirmed 为 true 但未实现", Need: "补齐认证请求头拼装",
	}
}

// ListProducts 端点未确认 → 明确失败，不猜。
func (a *Adapter) ListProducts(ctx context.Context, opts map[string]any) (json.RawMessage, error) {
	return nil, a.unconfirmed("目录接口")
}

// GetProduct 端点未确认 → 明确失败，不猜。
func (a *Adapter) GetProduct(ctx context.Context, externalID string) (json.RawMessage, error) {
	return nil, a.unconfirmed("详情接口")
}

// GetPriceCalendar 端点未确认 → 明确失败，不猜。
func (a *Adapter) GetPriceCalendar(ctx context.Context, externalID, start, end string) (json.RawMessage, error) {
	return nil, a.unconfirmed("价格接口")
}

func (a *Adapter) unconfirmed(what string) error {
	return &apperr.EndpointUnconfirmed{
		SupplierCode: a.Code(), What: what,
		Detail: a.Cfg.ProtocolNote, Need: "商务提供接口文档后按文档实现请求体",
	}
}

// ParseMappingExpression 解析组合表达式：'A|2+B|1' → [{SKU:"A", Qty:2},{SKU:"B", Qty:1}]。
//
// 语法已核实（官方文档三种形态）。**单个 supplier_variant 表达不了组合**，
// 组合履约需要 supplier_variant_bundle（已知模型缺口，见 SPEC §5.8）。
func ParseMappingExpression(expression string) []normalize.ExpressionPart {
	var parts []normalize.ExpressionPart
	for _, seg := range strings.Split(expression, "+") {
		sku, qty, found := strings.Cut(seg, "|")
		sku = strings.TrimSpace(sku)
		if sku == "" {
			continue
		}
		n := 1
		if found {
			if v, err := strconv.Atoi(strings.TrimSpace(qty)); err == nil {
				n = v
			}
		}
		parts = append(parts, normalize.ExpressionPart{SKU: sku, Qty: n})
	}
	return parts
}

// CompositeCoverage 组合表达式的并集覆盖（= 这个可售单元实际能覆盖哪些轴取值）。
func CompositeCoverage(expression string, coverageBySKU map[string]normalize.Coverage) normalize.Coverage {
	var covs []normalize.Coverage
	for _, part := range ParseMappingExpression(expression) {
		if cov, ok := coverageBySKU[part.SKU]; ok {
			covs = append(covs, cov)
		}
	}
	return normalize.UnionCoverage(covs)
}
