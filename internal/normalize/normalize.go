// Package normalize 是归一化核心：源报文 → 源变体 + 覆盖语义声明。
//
// 全部规则来自 configs/mapping_rules.json，本包不出现任何按源分支的代码。
// 演练器（Python）与适配器层（Go）共用同一份规则数据。
//
// 覆盖语义（与数据库函数 fn_variant_covered 保持一致）：
//
//	coverage = {"axes": {"<轴码>": ["<取值>", ...]}, "excludes": ["<取值>", ...]}
//
//	源变体能覆盖规范变体 ⟺ 规范变体要求的每一项能力都落在 coverage 内，且不在 excludes 里。
package normalize

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Rules 是映射规则配置。
type Rules struct {
	BaseDate string                  `json:"base_date"`
	Sources  map[string]*SourceRules `json:"sources"`
}

// SourceRules 单个源的归一化规则。
type SourceRules struct {
	SupplierCode       string      `json:"supplier_code"`
	SupplierName       string      `json:"supplier_name"`
	Currency           string      `json:"currency"`
	DefaultDate        string      `json:"default_date"`
	Fixture            string      `json:"fixture"`
	Documents          Documents   `json:"documents"`
	Product            ProductRef  `json:"product"`
	Packages           *Packages   `json:"packages"`
	Products           *Products   `json:"products"`
	Skus               *Skus       `json:"skus"`
	MappingExpression  *Expression `json:"mapping_expression"`
}

// Documents 报文文档在 payload 里的位置。
type Documents struct {
	CatalogPath string `json:"catalog_path"`
	PricesPath  string `json:"prices_path"`
}

// ProductRef 商品 id / 名的取值路径。
type ProductRef struct {
	IDPath   string `json:"id_path"`
	NamePath string `json:"name_path"`
}

// AxisRule 轴取值规则：value_path 取原值，value_map 把源取值映射到我们的轴取值。
type AxisRule struct {
	AxisCode  string            `json:"axis_code"`
	ValuePath string            `json:"value_path"`
	ValueMap  map[string]string `json:"value_map"`
}

// FlagRule 布尔标志规则。
type FlagRule struct {
	Path   string `json:"path"`
	Equals *bool  `json:"equals"`
}

// Packages 「产品 → 套餐 → 资源」形态（形态 A）。
type Packages struct {
	Path      string     `json:"path"`
	IDPath    string     `json:"id_path"`
	NamePath  string     `json:"name_path"`
	Axes      []AxisRule `json:"axes"`
	Resources Resources  `json:"resources"`
}

// Resources 套餐下的资源（= 源侧可售单元）。
type Resources struct {
	Path         string            `json:"path"`
	IDPath       string            `json:"id_path"`
	NamePath     string            `json:"name_path"`
	AudiencePath string            `json:"audience_path"`
	AudienceMap  map[string]string `json:"audience_map"`
	Axes         []AxisRule        `json:"axes"`
	Flags        map[string]FlagRule `json:"flags"`
}

// Products 「产品 → 商品列表」形态。
type Products struct {
	Path     string `json:"path"`
	IDPath   string `json:"id_path"`
	NamePath string `json:"name_path"`
}

// Skus 「文档即产品 → SKU」形态（形态 B）。
type Skus struct {
	Path         string              `json:"path"`
	IDPath       string              `json:"id_path"`
	NamePath     string              `json:"name_path"`
	AudiencePath string              `json:"audience_path"`
	AudienceMap  map[string]string   `json:"audience_map"`
	Axes         []AxisRule          `json:"axes"`
	Flags        map[string]FlagRule `json:"flags"`
}

// Expression 组合映射表达式规则（GlobalTix 的 A|2+B|1）。
type Expression struct {
	Path          string `json:"path"`
	OurVariantPath string `json:"our_variant_path"`
	MappingIDPath string `json:"mapping_id_path"`
}

// Coverage 覆盖语义声明。
type Coverage struct {
	Axes     map[string][]string `json:"axes"`
	Excludes []string            `json:"excludes"`
}

// Variant 源侧可售单元。
type Variant struct {
	ExternalID  string         `json:"external_id"`
	Title       string         `json:"title"`
	Coverage    Coverage       `json:"coverage"`
	Attrs       map[string]any `json:"attrs"`
	PriceLocked bool           `json:"price_locked"`
	Raw         map[string]any `json:"raw"`
}

// PriceRow 一条源报价行。
type PriceRow struct {
	ResourceID string   `json:"resource_id"`
	Date       string   `json:"date"`
	SalePrice  *float64 `json:"sale_price"`
	NetPrice   *float64 `json:"net_price"`
	Currency   string   `json:"currency"`
	Stock      *int     `json:"stock"`
}

// Product 一个源商品的归一化结果。
type Product struct {
	ExternalID string               `json:"external_id"`
	Name       string               `json:"name"`
	Raw        map[string]any       `json:"raw"`
	Variants   []Variant            `json:"variants"`
	Prices     map[string][]PriceRow `json:"prices"`
}

// CompositeExpression 组合映射表达式（一个可售单元由多个源 SKU 组成）。
type CompositeExpression struct {
	OurVariant  string          `json:"our_variant"`
	MappingID   string          `json:"mapping_id"`
	Parts       []ExpressionPart `json:"parts"`
	IsComposite bool            `json:"is_composite"`
}

// ExpressionPart 组合表达式的一段。
type ExpressionPart struct {
	SKU  string `json:"sku_id"`
	Qty  int    `json:"qty"`
}

// Result 一个源的整体归一化结果。
type Result struct {
	SupplierCode        string                `json:"supplier_code"`
	Products            []Product             `json:"products"`
	Variants            []Variant             `json:"variants"`
	Prices              []PriceRow            `json:"prices"`
	CompositeExpressions []CompositeExpression `json:"composite_expressions"`
}

// Canonical 规范变体（匹配的另一侧）。
type Canonical struct {
	Key      string            `json:"key"`
	Audience string            `json:"audience"`
	Axes     map[string]string `json:"axes"`
}

// LoadRules 读取规则文件。
func LoadRules(path string) (*Rules, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Rules
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("解析映射规则失败 %s: %w", path, err)
	}
	if len(r.Sources) == 0 {
		return nil, fmt.Errorf("映射规则 %s 没有任何源", path)
	}
	return &r, nil
}

// Dig 按 'a.b.c' 取值，任一层缺失返回 nil。
func Dig(obj map[string]any, path string) any {
	if path == "" {
		return nil
	}
	var cur any = obj
	for _, part := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur, ok = m[part]
		if !ok || cur == nil {
			return nil
		}
	}
	return cur
}

// Covers 判断源变体的覆盖声明是否覆盖规范变体。
func Covers(cov Coverage, c Canonical) bool {
	for _, req := range requiredAxes(c) {
		if !contains(cov.Axes[req.Axis], req.Opt) {
			return false
		}
		if contains(cov.Excludes, req.Opt) {
			return false
		}
	}
	return true
}

// CoverageGaps 列出覆盖缺口（诊断用，不用于判定）。
func CoverageGaps(cov Coverage, c Canonical) []string {
	var gaps []string
	for _, req := range requiredAxes(c) {
		if !contains(cov.Axes[req.Axis], req.Opt) {
			gaps = append(gaps, req.Axis+":"+req.Opt)
		} else if contains(cov.Excludes, req.Opt) {
			gaps = append(gaps, req.Axis+":"+req.Opt+"(excluded)")
		}
	}
	sort.Strings(gaps)
	return gaps
}

type axisReq struct {
	Axis string
	Opt  string
}

func requiredAxes(c Canonical) []axisReq {
	var out []axisReq
	if c.Audience != "" {
		out = append(out, axisReq{"audience", c.Audience})
	}
	axes := make([]string, 0, len(c.Axes))
	for a := range c.Axes {
		axes = append(axes, a)
	}
	sort.Strings(axes)
	for _, a := range axes {
		out = append(out, axisReq{a, c.Axes[a]})
	}
	return out
}

// UnionCoverage 求多个覆盖声明的并集（组合履约用）。
func UnionCoverage(covs []Coverage) Coverage {
	out := Coverage{Axes: map[string][]string{}}
	for _, cov := range covs {
		for axis, opts := range cov.Axes {
			for _, o := range opts {
				if !contains(out.Axes[axis], o) {
					out.Axes[axis] = append(out.Axes[axis], o)
				}
			}
		}
		for _, e := range cov.Excludes {
			if !contains(out.Excludes, e) {
				out.Excludes = append(out.Excludes, e)
			}
		}
	}
	return out
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// ResolveAxes 按规则解析轴取值。
func ResolveAxes(raw map[string]any, rules []AxisRule) map[string]string {
	out := map[string]string{}
	for _, rule := range rules {
		v := Dig(raw, rule.ValuePath)
		if v == nil {
			continue
		}
		var key string
		switch t := v.(type) {
		case []any:
			parts := make([]string, 0, len(t))
			for _, item := range t {
				parts = append(parts, toString(item))
			}
			key = strings.Join(parts, ",")
		case bool:
			key = strconv.FormatBool(t)
		default:
			key = toString(v)
		}
		if mapped, ok := rule.ValueMap[key]; ok {
			out[rule.AxisCode] = mapped
			continue
		}
		for k, mapped := range rule.ValueMap {
			if strings.EqualFold(k, key) {
				out[rule.AxisCode] = mapped
				break
			}
		}
	}
	return out
}

// ResolveAudience 解析人群码。
func ResolveAudience(raw map[string]any, path string, audienceMap map[string]string) string {
	v := Dig(raw, path)
	if v == nil {
		return ""
	}
	key := toString(v)
	if mapped, ok := audienceMap[key]; ok {
		return mapped
	}
	return key
}

// ResolveFlags 解析布尔标志。
func ResolveFlags(raw map[string]any, rules map[string]FlagRule) map[string]bool {
	out := map[string]bool{}
	for name, rule := range rules {
		v := Dig(raw, rule.Path)
		if v == nil {
			out[name] = false
			continue
		}
		if rule.Equals != nil {
			out[name] = toString(v) == strconv.FormatBool(*rule.Equals)
			continue
		}
		out[name] = truthy(v)
	}
	return out
}

func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case string:
		return t != ""
	case float64:
		return t != 0
	case []any:
		return len(t) > 0
	case map[string]any:
		return len(t) > 0
	}
	return true
}

func toString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case bool:
		return strconv.FormatBool(t)
	case float64:
		if t == float64(int64(t)) {
			return strconv.FormatInt(int64(t), 10)
		}
		return strconv.FormatFloat(t, 'f', -1, 64)
	}
	return fmt.Sprintf("%v", v)
}

// Normalize 把一个源报文归一化。
func (r *Rules) Normalize(sourceKey string, payload []byte) (*Result, error) {
	rule, ok := r.Sources[sourceKey]
	if !ok {
		return nil, fmt.Errorf("映射规则里没有源 %s", sourceKey)
	}
	var root map[string]any
	if err := json.Unmarshal(payload, &root); err != nil {
		return nil, fmt.Errorf("源报文不是 JSON 对象: %w", err)
	}

	res := &Result{SupplierCode: rule.SupplierCode, Products: []Product{}}

	docs := asList(Dig(root, rule.Documents.CatalogPath))
	priceDocs := asList(Dig(root, rule.Documents.PricesPath))

	// 独立价格日历文档 → 价格表
	prices := map[string][]PriceRow{}
	if rule.Packages != nil {
		for _, pdoc := range priceDocs {
			proot := unwrapData(pdoc)
			for _, pkg := range asList(Dig(proot, rule.Packages.Path)) {
				pkgMap, _ := pkg.(map[string]any)
				for _, resRaw := range asList(Dig(pkgMap, rule.Packages.Resources.Path)) {
					resMap, _ := resRaw.(map[string]any)
					rid := toString(Dig(resMap, rule.Packages.Resources.IDPath))
					rows := priceRows(resMap, rule)
					if len(rows) > 0 {
						prices[rid] = append(prices[rid], rows...)
					}
				}
			}
		}
	}

	for _, doc := range docs {
		docRoot := unwrapData(doc)
		product := Product{Prices: map[string][]PriceRow{}}

		switch {
		case rule.Packages != nil:
			pkgPath := rule.Packages.Path
			resPath := rule.Packages.Resources.Path
			product.ExternalID = toString(Dig(docRoot, rule.Product.IDPath))
			product.Name = toString(Dig(docRoot, rule.Product.NamePath))
			for _, pkgRaw := range asList(Dig(docRoot, pkgPath)) {
				pkgMap, _ := pkgRaw.(map[string]any)
				pkgAxes := ResolveAxes(pkgMap, rule.Packages.Axes)
				for _, resRaw := range asList(Dig(pkgMap, resPath)) {
					resMap, _ := resRaw.(map[string]any)
					axes := map[string]string{}
					for k, v := range pkgAxes {
						axes[k] = v
					}
					for k, v := range ResolveAxes(resMap, rule.Packages.Resources.Axes) {
						axes[k] = v
					}
					audience := ResolveAudience(resMap, rule.Packages.Resources.AudiencePath,
						rule.Packages.Resources.AudienceMap)
					flags := ResolveFlags(resMap, rule.Packages.Resources.Flags)
					extID := toString(Dig(resMap, rule.Packages.Resources.IDPath))
					v := Variant{
						ExternalID:  extID,
						Title:       toString(Dig(resMap, rule.Packages.Resources.NamePath)),
						Coverage:    coverageOf(axes, audience),
						Attrs:       map[string]any{"audience": audience, "axes": toAnyMap(axes)},
						PriceLocked: flags["is_price_locked"],
						Raw:         resMap,
					}
					product.Variants = append(product.Variants, v)
					if rows := priceRows(resMap, rule); len(rows) > 0 {
						product.Prices[extID] = append(product.Prices[extID], rows...)
					}
				}
			}
		case rule.Skus != nil:
			product.ExternalID = toString(Dig(docRoot, rule.Products.IDPath))
			product.Name = toString(Dig(docRoot, rule.Products.NamePath))
			for _, skuRaw := range asList(Dig(docRoot, rule.Skus.Path)) {
				skuMap, _ := skuRaw.(map[string]any)
				axes := ResolveAxes(skuMap, rule.Skus.Axes)
				audience := ResolveAudience(skuMap, rule.Skus.AudiencePath, rule.Skus.AudienceMap)
				flags := ResolveFlags(skuMap, rule.Skus.Flags)
				extID := toString(Dig(skuMap, rule.Skus.IDPath))
				v := Variant{
					ExternalID:  extID,
					Title:       toString(Dig(skuMap, rule.Skus.NamePath)),
					Coverage:    coverageOf(axes, audience),
					Attrs:       map[string]any{"audience": audience, "axes": toAnyMap(axes)},
					PriceLocked: flags["is_price_locked"],
					Raw:         skuMap,
				}
				product.Variants = append(product.Variants, v)
				if rows := priceRows(skuMap, rule); len(rows) > 0 {
					product.Prices[extID] = append(product.Prices[extID], rows...)
				}
			}
		default:
			continue
		}

		if len(product.Variants) == 0 {
			continue
		}
		if docMap, ok := doc.(map[string]any); ok {
			product.Raw = docMap
		} else {
			product.Raw = map[string]any{}
		}
		// 独立价格日历文档里的报价合并进来（只并到拥有该变体的商品上）
		variantIDs := map[string]bool{}
		for _, v := range product.Variants {
			variantIDs[v.ExternalID] = true
		}
		for vid, rows := range prices {
			if !variantIDs[vid] {
				continue
			}
			product.Prices[vid] = append(product.Prices[vid], rows...)
		}
		res.Products = append(res.Products, product)
		res.Variants = append(res.Variants, product.Variants...)
		for _, rows := range product.Prices {
			res.Prices = append(res.Prices, rows...)
		}
	}

	res.CompositeExpressions = parseComposite(rule, root)
	return res, nil
}

// priceRows 取一个资源的报价行。
//
// 真实 API（Trip.com priceCalendar）的报价**嵌套在 resource.calendarDetailList[]** 里，
// 一天一条；同时兼容「单日平铺」形态（部分源只给当天价）。
func priceRows(res map[string]any, rule *SourceRules) []PriceRow {
	var out []PriceRow
	details := asList(res["calendarDetailList"])
	if len(details) == 0 {
		details = asList(res["calendarDetail"])
	}
	if len(details) > 0 {
		for _, dRaw := range details {
			d, ok := dRaw.(map[string]any)
			if !ok {
				continue
			}
			out = append(out, PriceRow{
				Date:       firstNonEmpty(toString(d["date"]), rule.DefaultDate),
				SalePrice:  toFloat(d["salePrice"]),
				NetPrice:   toFloat(d["netPrice"]),
				Currency:   firstNonEmpty(toString(d["currency"]), toString(res["currency"]), rule.Currency),
				Stock:      toInt(d["stock"]),
			})
		}
		return out
	}
	if res["salePrice"] != nil || res["netPrice"] != nil {
		out = append(out, PriceRow{
			Date:       firstNonEmpty(toString(res["date"]), rule.DefaultDate),
			SalePrice:  toFloat(res["salePrice"]),
			NetPrice:   toFloat(res["netPrice"]),
			Currency:   firstNonEmpty(toString(res["currency"]), rule.Currency),
			Stock:      toInt(res["stock"]),
		})
	}
	return out
}

func parseComposite(rule *SourceRules, root map[string]any) []CompositeExpression {
	var out []CompositeExpression
	if rule.MappingExpression == nil {
		return out
	}
	for _, itemRaw := range asList(Dig(root, rule.MappingExpression.Path)) {
		item, ok := itemRaw.(map[string]any)
		if !ok {
			continue
		}
		mid := toString(Dig(item, rule.MappingExpression.MappingIDPath))
		var parts []ExpressionPart
		for _, seg := range strings.Split(mid, "+") {
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
			parts = append(parts, ExpressionPart{SKU: sku, Qty: n})
		}
		out = append(out, CompositeExpression{
			OurVariant:  toString(Dig(item, rule.MappingExpression.OurVariantPath)),
			MappingID:   mid,
			Parts:       parts,
			IsComposite: len(parts) > 1,
		})
	}
	return out
}

func coverageOf(axes map[string]string, audience string) Coverage {
	cov := Coverage{Axes: map[string][]string{}, Excludes: []string{}}
	if audience != "" {
		cov.Axes["audience"] = []string{audience}
	}
	keys := make([]string, 0, len(axes))
	for k := range axes {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		cov.Axes[k] = []string{axes[k]}
	}
	return cov
}

func unwrapData(doc any) map[string]any {
	m, ok := doc.(map[string]any)
	if !ok {
		return map[string]any{}
	}
	if inner, ok := m["data"]; ok {
		if im, ok := inner.(map[string]any); ok {
			return im
		}
	}
	return m
}

func asList(v any) []any {
	l, ok := v.([]any)
	if !ok {
		return nil
	}
	return l
}

func toFloat(v any) *float64 {
	switch t := v.(type) {
	case float64:
		return &t
	case int:
		f := float64(t)
		return &f
	case string:
		f, err := strconv.ParseFloat(t, 64)
		if err != nil {
			return nil
		}
		return &f
	}
	return nil
}

func toInt(v any) *int {
	switch t := v.(type) {
	case float64:
		i := int(t)
		return &i
	case int:
		return &t
	}
	return nil
}

func toAnyMap(m map[string]string) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		out[k] = v
	}
	return out
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
