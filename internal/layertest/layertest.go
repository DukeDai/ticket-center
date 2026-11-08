// Package layertest 实现分层连通性测试：
// 连通 → 认证 → 目录 → 详情 → 价格 → 映射 → 路由。
//
// 设计：
//   - **凭证只从环境变量读**（其次 supplier.auth_config）。缺哪个环境变量，报告会明确写出来。
//   - 没有凭证时**不外呼业务接口**，但仍然跑 L0 TCP 连通性（不需要凭证）与离线自检。
//   - 原始报文归档到独立库（默认 ticket_center_integration），**不污染主库**。
package layertest

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"ticket-center/internal/apperr"
	"ticket-center/internal/config"
	"ticket-center/internal/coverage"
	"ticket-center/internal/normalize"
	"ticket-center/internal/registry"
	"ticket-center/internal/store"
	"ticket-center/internal/supplier"
)

// Status 是分层结果状态。
type Status string

const (
	StatusPass Status = "PASS"
	StatusFail Status = "FAIL"
	StatusSkip Status = "SKIP"
)

// LayerNames 分层顺序与中文名。
var LayerNames = []struct{ Key, Label string }{
	{"connect", "L0 连通"},
	{"auth", "L1 认证"},
	{"catalog", "L2 目录"},
	{"detail", "L3 详情"},
	{"price", "L4 价格"},
	{"mapping", "L5 映射"},
	{"routing", "L6 路由"},
}

// LayerResult 一层的结果。
type LayerResult struct {
	Layer  string         `json:"layer"`
	Label  string         `json:"label"`
	Status Status         `json:"status"`
	Detail string         `json:"detail"`
	Data   map[string]any `json:"data,omitempty"`
}

// SupplierRun 一个源的分层结果。
type SupplierRun struct {
	Supplier string        `json:"supplier"`
	Fatal    string        `json:"fatal,omitempty"`
	Layers   []LayerResult `json:"layers"`
}

// Layer 取某一层的结果。
func (r *SupplierRun) Layer(key string) *LayerResult {
	for i := range r.Layers {
		if r.Layers[i].Layer == key {
			return &r.Layers[i]
		}
	}
	return nil
}

// Options 一次测试的可选项。
type Options struct {
	Config       *config.File
	Rules        *normalize.Rules
	Env          string
	ArchiveDB    *store.DB
	CanonicalDB  *store.DB
	Timeout      time.Duration
	EnvVars      map[string]string
	RequireCreds bool
}

// Run 跑一个源的全部分层。
func Run(ctx context.Context, code string, opts Options) *SupplierRun {
	run := &SupplierRun{Supplier: code}
	if opts.Env == "" {
		opts.Env = "sandbox"
	}
	if opts.Timeout == 0 {
		opts.Timeout = 20 * time.Second
	}

	port, err := registry.Build(code, opts.Config, registry.Options{
		Env: opts.Env, DB: opts.ArchiveDB, EnvVars: opts.EnvVars,
		RequireCredentials: false, Archive: true, Idempotency: true,
	})
	if err != nil {
		run.Fatal = err.Error()
		for _, l := range LayerNames {
			run.Layers = append(run.Layers, LayerResult{Layer: l.Key, Label: l.Label,
				Status: StatusSkip, Detail: err.Error()})
		}
		return run
	}

	// ---- L0 连通（不需要凭证）
	if res, err := port.Connectivity(ctx); err != nil {
		run.add("connect", StatusSkip, err.Error(), nil)
	} else if res.OK {
		run.add("connect", StatusPass, res.Detail, nil)
	} else {
		run.add("connect", StatusFail, res.Detail, nil)
	}

	// ---- L1 认证
	missing := missingCredentials(port)
	if len(missing) > 0 {
		parts := make([]string, 0, len(missing))
		for _, m := range missing {
			parts = append(parts, fmt.Sprintf("%s（环境变量 %s）", m.Name, m.Env))
		}
		detail := "缺少凭证：" + strings.Join(parts, "；")
		run.add("auth", StatusSkip, detail, map[string]any{"missing": missing})
		for _, l := range LayerNames[2:] {
			run.add(l.Key, StatusSkip, "凭证缺失（见 L1）", nil)
		}
		return run
	}
	if _, err := port.Authenticate(ctx); err != nil {
		status := StatusFail
		if u, ok := apperr.AsUnconfirmed(err); ok {
			status = StatusSkip
			_ = u
		}
		run.add("auth", status, err.Error(), nil)
		for _, l := range LayerNames[2:] {
			run.add(l.Key, StatusSkip, "认证未通过（L1），后续层不外呼", nil)
		}
		return run
	}
	run.add("auth", StatusPass, "认证通过", nil)

	// ---- L2 目录
	search, err := port.ListProducts(ctx, nil)
	if err != nil {
		run.add("catalog", StatusFail, err.Error(), nil)
		for _, l := range LayerNames[3:] {
			run.add(l.Key, StatusSkip, "目录层失败，后续层不执行", nil)
		}
		return run
	}
	productIDs := ExtractProductIDs(search)
	run.add("catalog", statusFor(len(productIDs) > 0),
		fmt.Sprintf("搜索到 %d 个产品", len(productIDs)),
		map[string]any{"product_ids": productIDs})

	if len(productIDs) == 0 {
		for _, l := range LayerNames[3:] {
			run.add(l.Key, StatusSkip, "目录层未返回产品 id", nil)
		}
		return run
	}
	pid := fmt.Sprintf("%v", productIDs[0])

	// ---- L3 详情
	detailData, err := port.GetProduct(ctx, pid)
	if err != nil {
		run.add("detail", StatusFail, err.Error(), nil)
		for _, l := range LayerNames[4:] {
			run.add(l.Key, StatusSkip, "详情层失败，后续层不执行", nil)
		}
		return run
	}
	resIDs := ExtractResourceIDs(detailData)
	run.add("detail", statusFor(len(resIDs) > 0),
		fmt.Sprintf("产品 %s 详情：%d 个 package 资源", pid, len(resIDs)),
		map[string]any{"product_id": pid, "resource_ids": resIDs})

	// ---- L4 价格
	start := DefaultStartDate()
	end := DefaultEndDate(start)
	priceData, err := port.GetPriceCalendar(ctx, pid, start, end)
	if err != nil {
		run.add("price", StatusFail, err.Error(), nil)
		for _, l := range LayerNames[5:] {
			run.add(l.Key, StatusSkip, "价格层失败，后续层不执行", nil)
		}
		return run
	}
	rows := CountPriceRows(priceData)
	run.add("price", statusFor(rows > 0),
		fmt.Sprintf("产品 %s 价格日历：%d 条报价", pid, rows),
		map[string]any{"product_id": pid, "start": start, "rows": rows})

	// ---- L5 映射
	payload := BuildNormalizePayload(detailData, priceData)
	result, err := opts.Rules.Normalize(code, payload)
	if err != nil {
		run.add("mapping", StatusFail, "归一化失败: "+err.Error(), nil)
		run.add("routing", StatusSkip, "映射层失败", nil)
		return run
	}
	canonical, cerr := coverage.LoadCanonical(opts.CanonicalDB)
	if cerr != nil {
		run.add("mapping", StatusFail, "读规范库失败: "+cerr.Error(), nil)
		run.add("routing", StatusSkip, "映射层失败", nil)
		return run
	}
	matched := map[string][]string{}
	gaps := []any{}
	for _, sv := range result.Variants {
		// 覆盖判定走库里的 fn_variant_covered —— 这条规则只有一份实现。
		verdicts, verr := coverage.Judge(opts.CanonicalDB, coverage.JSON(sv.Coverage), canonical)
		if verr != nil {
			run.add("mapping", StatusFail, "判定覆盖失败: "+verr.Error(), nil)
			run.add("routing", StatusSkip, "映射层失败", nil)
			return run
		}
		var hits []string
		for _, v := range verdicts {
			if v.CanFulfil {
				hits = append(hits, v.Key)
			}
		}
		matched[sv.ExternalID] = hits
		if len(hits) == 0 {
			near := []string{}
			for _, v := range verdicts {
				if len(v.Gaps) == 1 {
					near = append(near, fmt.Sprintf("%s(%s)", v.Key, v.Gaps[0]))
				}
				if len(near) >= 3 {
					break
				}
			}
			gaps = append(gaps, map[string]any{"source_variant": sv.ExternalID, "near_miss": near})
		}
	}
	totalHits := 0
	for _, v := range matched {
		totalHits += len(v)
	}
	run.add("mapping", statusFor(len(result.Variants) > 0),
		fmt.Sprintf("源变体 %d 个，命中规范变体 %d 个（近失配 %d）", len(result.Variants), totalHits, len(gaps)),
		map[string]any{"source_variants": len(result.Variants), "gaps": gaps})

	// ---- L6 路由
	hitKeys := []string{}
	for _, hits := range matched {
		hitKeys = append(hitKeys, hits...)
	}
	hitKeys = dedupSorted(hitKeys)
	cands, cerr := RoutingCandidates(opts.CanonicalDB, hitKeys)
	if cerr != nil {
		run.add("routing", StatusFail, "读路由候选失败: "+cerr.Error(), nil)
		return run
	}
	withRoute := 0
	for _, k := range hitKeys {
		if len(cands[k]) > 0 {
			withRoute++
		}
	}
	detail := fmt.Sprintf("命中 %d 个规范变体，其中 %d 个有路由候选", len(hitKeys), withRoute)
	if len(hitKeys) > 0 && withRoute == 0 {
		detail += "（规范库无对应路由，需先跑演练器建映射）"
	}
	run.add("routing", statusFor(len(hitKeys) > 0 && withRoute > 0), detail,
		map[string]any{"variants": hitKeys})
	return run
}

func (r *SupplierRun) add(layer string, status Status, detail string, data map[string]any) {
	label := layer
	for _, l := range LayerNames {
		if l.Key == layer {
			label = l.Label
		}
	}
	r.Layers = append(r.Layers, LayerResult{Layer: layer, Label: label,
		Status: status, Detail: detail, Data: data})
}

func statusFor(ok bool) Status {
	if ok {
		return StatusPass
	}
	return StatusFail
}

func missingCredentials(port supplier.Port) []apperr.MissingCredential {
	d, ok := port.Describe()["missing_credentials"]
	if !ok {
		return nil
	}
	raw, err := json.Marshal(d)
	if err != nil {
		return nil
	}
	var out []apperr.MissingCredential
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil
	}
	return out
}

// ---------------------------------------------------------------- 报文提取

// ExtractProductIDs 从目录响应里取产品 id（不写死具体值）。
func ExtractProductIDs(data []byte) []any {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return nil
	}
	// 兼容带 data 包裹的信封
	if inner, ok := m["data"].(map[string]any); ok && len(inner) > 0 {
		m = inner
	}
	var items []any
	for _, key := range []string{"productList", "productlist", "products", "list"} {
		if v, ok := m[key].([]any); ok {
			items = v
			break
		}
	}
	if items == nil {
		if _, ok := m["productID"]; ok {
			items = []any{m}
		}
	}
	var out []any
	for _, it := range items {
		im, ok := it.(map[string]any)
		if !ok {
			continue
		}
		for _, key := range []string{"productID", "productId", "productid", "id"} {
			if v, ok := im[key]; ok && v != nil {
				out = append(out, v)
				break
			}
		}
	}
	return out
}

// ExtractResourceIDs 从详情响应里取资源 id（package → resourceList）。
func ExtractResourceIDs(data []byte) []any {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return nil
	}
	products := []any{}
	if v, ok := m["productList"].([]any); ok {
		products = v
	} else {
		products = []any{m}
	}
	var out []any
	for _, p := range products {
		pm, ok := p.(map[string]any)
		if !ok {
			continue
		}
		for _, pkg := range asList(pm["packageList"]) {
			pkgm, ok := pkg.(map[string]any)
			if !ok {
				continue
			}
			for _, res := range asList(pkgm["resourceList"]) {
				rm, ok := res.(map[string]any)
				if !ok {
					continue
				}
				if v, ok := rm["resourceID"]; ok && v != nil {
					out = append(out, v)
				}
			}
		}
	}
	return out
}

// CountPriceRows 数一个价格日历里的报价行数。
func CountPriceRows(data []byte) int {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return 0
	}
	n := 0
	for _, pkg := range asList(m["packageList"]) {
		pkgm, ok := pkg.(map[string]any)
		if !ok {
			continue
		}
		for _, res := range asList(pkgm["resourceList"]) {
			rm, ok := res.(map[string]any)
			if !ok {
				continue
			}
			if l, ok := rm["calendarDetailList"].([]any); ok {
				n += len(l)
				continue
			}
			if l, ok := rm["calendarDetail"].([]any); ok {
				n += len(l)
			}
		}
	}
	return n
}

// BuildNormalizePayload 把分层测试拿到的报文拼成归一化期望的形状。
func BuildNormalizePayload(detailData, priceData []byte) []byte {
	var detail map[string]any
	_ = json.Unmarshal(detailData, &detail)
	docs := []any{}
	if list, ok := detail["productList"].([]any); ok {
		docs = list
	} else if len(detail) > 0 {
		docs = []any{detail}
	}
	payload := map[string]any{"catalog": docs}
	if len(priceData) > 0 {
		var price map[string]any
		if err := json.Unmarshal(priceData, &price); err == nil {
			payload["prices"] = []any{price}
		}
	}
	raw, _ := json.Marshal(payload)
	return raw
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

// ---------------------------------------------------------------- 规范库

// LoadCanonicalVariants 读规范变体（audience + axes），供覆盖语义匹配使用。
// Route 是一个路由候选。
type Route struct {
	Supplier      string `json:"supplier"`
	SourceVariant string `json:"source_variant"`
	NetPrice      string `json:"net_price"`
	RouteRank     string `json:"route_rank"`
	PriceLocked   bool   `json:"price_locked"`
}

// RoutingCandidates 查变体的路由候选。
func RoutingCandidates(db *store.DB, variantKeys []string) (map[string][]Route, error) {
	out := map[string][]Route{}
	if db == nil || len(variantKeys) == 0 {
		return out, nil
	}
	quoted := make([]string, 0, len(variantKeys))
	for _, k := range variantKeys {
		quoted = append(quoted, store.Quote(k))
	}
	sql := "SELECT pv.variant_key, sup.code, sv.external_variant_id, vrc.net_price, vrc.route_rank, " +
		"coalesce(pc.price_locked,false) FROM v_variant_routing_candidates vrc " +
		"JOIN product_variant pv ON pv.id = vrc.product_variant_id " +
		"JOIN supplier_variant sv ON sv.id = vrc.supplier_variant_id " +
		"JOIN supplier_product sp ON sp.id = sv.supplier_product_id " +
		"JOIN supplier sup ON sup.id = sp.supplier_id " +
		"LEFT JOIN price_calendar pc ON pc.product_variant_id = pv.id AND pc.date = vrc.date " +
		"WHERE pv.variant_key IN (" + strings.Join(quoted, ", ") + ") ORDER BY pv.variant_key, vrc.route_rank;"
	rows, err := db.Rows(sql)
	if err != nil {
		return out, err
	}
	for _, r := range rows {
		out[r["variant_key"]] = append(out[r["variant_key"]], Route{
			Supplier: r["code"], SourceVariant: r["external_variant_id"],
			NetPrice: r["net_price"], RouteRank: r["route_rank"],
			PriceLocked: r["price_locked"] == "t" || r["price_locked"] == "true",
		})
	}
	return out, nil
}

func dedupSorted(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

// DefaultStartDate 默认价格查询起始日期（今天 + 7 天）。
func DefaultStartDate() string {
	return time.Now().AddDate(0, 0, 7).Format("2006-01-02")
}

// DefaultEndDate 默认价格查询结束日期（起始 + 7 天）。
func DefaultEndDate(start string) string {
	t, err := time.Parse("2006-01-02", start)
	if err != nil {
		return start
	}
	return t.AddDate(0, 0, 7).Format("2006-01-02")
}
