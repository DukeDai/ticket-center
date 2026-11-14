package sync

import (
	"context"
	"encoding/json"
	"fmt"

	"ticket-center/internal/layertest"
	"ticket-center/internal/normalize"
	"ticket-center/internal/registry"
	"ticket-center/internal/supplier"
)

// fetch 抓一个源的目录，归一化成 Catalog。
//
// 抓的形状：L2 目录 → 每个商品 id 各一次 L3 详情 + L4 价格。
// **每个 id 都抓** —— 只抓第一个会让台账说「成功」而目录里大部分商品根本没进来。
//
// 报文先归档再归一化：归档由适配器做（registry.Options.Archive），
// 归档表与规范库同库，归档开关是开的 —— 硬约束 8 要求原始报文必须归档。
func fetch(ctx context.Context, code string, opts Options) (Catalog, error) {
	if opts.Config == nil {
		return Catalog{}, fmt.Errorf("同步 %s 缺少接入层配置：没有配置就没有端点，没有端点就没有目录", code)
	}
	if opts.Rules == nil {
		return Catalog{}, fmt.Errorf("同步 %s 缺少归一化规则：没有规则就没有归一化", code)
	}

	port, err := registry.Build(code, opts.Config, registry.Options{
		Env: opts.Env, DB: opts.DB, EnvVars: opts.EnvVars,
		RequireCredentials: true, Archive: true, Idempotency: true,
	})
	if err != nil {
		return Catalog{}, err
	}

	start, end := priceWindow(opts)

	list, err := port.ListProducts(ctx, nil)
	if err != nil {
		return Catalog{}, fmt.Errorf("拉目录失败: %w", err)
	}

	ids := layertest.ExtractProductIDs(list)
	if len(ids) == 0 {
		return Catalog{}, fmt.Errorf("目录层没有返回任何商品 id：同步了零条，比同步失败更难查")
	}

	catalog := Catalog{SupplierCode: code}
	for _, raw := range ids {
		// 数字 id 不能用 `%v` 渲染：JSON 的数字解出来是 float64，
		// 渲染出来是 `2.1081935e+07` —— 那个字符串会当成源侧 id 落进库里，
		// 幂等锚点（supplier_id, external_id）就废了。
		pid := layertest.IDString(raw)
		product, err := fetchOne(ctx, port, pid, start, end, code, opts)
		if err != nil {
			return Catalog{}, fmt.Errorf("抓商品 %s 失败: %w", pid, err)
		}
		catalog.Products = append(catalog.Products, product)
	}
	return catalog, nil
}

// fetchOne 抓一个商品的详情与价格，归一化成 normalize.Product。
//
// 归一化在**逐商品**的粒度上做：报文的 catalog 段只放这一个商品，
// prices 段放这一个商品的价格。这样一个商品解析失败不影响别的商品，
// 而结果里也不掺别的商品（混在一起的话，落库时会把 A 商品的变体挂到 B 商品上）。
func fetchOne(ctx context.Context, port supplier.Port, pid, start, end, code string, opts Options) (normalize.Product, error) {
	detail, err := port.GetProduct(ctx, pid)
	if err != nil {
		return normalize.Product{}, err
	}
	prices, err := port.GetPriceCalendar(ctx, pid, start, end)
	if err != nil {
		return normalize.Product{}, err
	}

	payload := layertest.BuildNormalizePayload(detail, prices)
	result, err := opts.Rules.Normalize(code, payload)
	if err != nil {
		return normalize.Product{}, fmt.Errorf("归一化失败: %w", err)
	}

	for _, p := range result.Products {
		if p.ExternalID == pid {
			return p, nil
		}
	}
	return normalize.Product{}, fmt.Errorf("归一化结果里没有商品 %s", pid)
}

// priceWindow 这次同步要拉的价格日期区间。
//
// 空则用默认（今天 +7 天起 7 天）。区间是作业的范围，
// 落在台账的 scope 里 —— 读的人要知道「这次同步覆盖了哪几天」。
func priceWindow(opts Options) (string, string) {
	start := opts.Start
	if start == "" {
		start = layertest.DefaultStartDate()
	}
	end := opts.End
	if end == "" {
		end = layertest.DefaultEndDate(start)
	}
	return start, end
}

// rawToJSON 把归一化产物里的原始报文转成可落库的 jsonb。
//
// 报文是 map[string]any，存进 jsonb 列要走一次序列化。
// 序列化失败就报出来 —— 静默写空报文等于把「源侧报了什么」弄丢了。
func rawToJSON(raw map[string]any) ([]byte, error) {
	if len(raw) == 0 {
		return []byte("{}"), nil
	}
	b, err := json.Marshal(raw)
	if err != nil {
		return nil, fmt.Errorf("原始报文序列化失败: %w", err)
	}
	return b, nil
}
