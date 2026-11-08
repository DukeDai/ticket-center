// Package pricing 是定价的 Go 入口。
//
// 定价逻辑不在 Go 里，也不在 Python 里 —— 唯一实现在数据库的 fn_price_variant。
// 两条理由：
//   - 钱必须是 NUMERIC（AGENTS.md 硬约束 5），Go 标准库没有十进制类型，
//     float64 接住金额迟早差一分钱；
//   - 视图、接入层、演练器、种子数据必须给出同一个价格，
//     唯一能同时被这四方够到的地方就是数据库本身。
//
// 所以这个包只负责把定价函数的结果读出来，不做任何价格计算。
package pricing

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Quote 是一次定价的结果。
//
// 金额一律是字符串：这些字段在库里是 NUMERIC，用 float64 接住就是丢精度。
//
// 组合（异构融合方向 B）没有单一的采纳源 —— 它的成本是 Σ 成分成本 × 份数，
// 逐成分的明细在 Rule 的 "combo" 数组里。所以组合的
// SupplierProductID 是 nil，SourceCurrency / NetPrice / FxRate / FxAsOf 是空的：
// 那是「这里没有单一的值」，不是「同币种、汇率 1」。
type Quote struct {
	ProductID        int64  `json:"product_id"`
	ProductVariantID int64  `json:"product_variant_id"`
	Date             string `json:"date"`
	Currency         string `json:"currency"`
	// SupplierProductID 是采纳的源商品；组合为 nil（成本来自配方，不是来自一个源）。
	SupplierProductID *int64          `json:"supplier_product_id"`
	SourceCurrency    string          `json:"source_currency"`
	NetPrice          string          `json:"net_price"`
	FxRate            string          `json:"fx_rate"`
	FxAsOf            string          `json:"fx_as_of"`
	CostPrice         string          `json:"cost_price"`
	SellPrice         string          `json:"sell_price"`
	ListPrice         string          `json:"list_price"`
	DiscountPct       string          `json:"discount_pct"`
	PriceLocked       bool            `json:"price_locked"`
	MinMargin         string          `json:"min_margin"`
	Rule              json.RawMessage `json:"rule"`
	// IsCombo 表示这是一张组合套餐（定价函数在 rule 里给了 combo 分解）。
	IsCombo bool `json:"is_combo"`
}

// Calculator 调库里的定价函数。
type Calculator struct {
	db *store.DB
}

// New 构造定价器。db 为 nil 时无法定价（调用方应直接报错，不要静默返回零价）。
func New(db *store.DB) *Calculator { return &Calculator{db: db} }

const quoteColumns = `product_id, product_variant_id, date, currency, supplier_product_id,
	source_currency, net_price, fx_rate, fx_as_of, cost_price, sell_price, list_price,
	discount_pct, price_locked, min_margin, rule`

// Quote 算一个变体在某天、某个渠道上下文下的对客价。
//
// contextChannelID：规则与可选源来自哪个渠道的上架关系；传 0 表示用默认自营渠道
// （fn_default_context_channel），也就是「默认售价行」的归属。
// priceChannelID：售价行写给哪个渠道；nil 表示默认行（基准币种）。
//
// 没有候选源（当天没报价 / 没上架 / 币种折不出来）时返回 nil，不是零价 ——
// 零价会被当成「免费」，这是最危险的一种错。
func (c *Calculator) Quote(variantID int64, date string, contextChannelID int64, priceChannelID *int64) (*Quote, error) {
	if c.db == nil {
		return nil, fmt.Errorf("定价需要数据库连接")
	}
	if date == "" {
		return nil, fmt.Errorf("定价需要日期")
	}
	var priceChannel any
	if priceChannelID != nil {
		priceChannel = *priceChannelID
	}
	sql := fmt.Sprintf(
		`SELECT %s FROM fn_price_variant(%s, %s::date,
		                              CASE WHEN %s = 0 THEN fn_default_context_channel() ELSE %s END,
		                              %s);`,
		quoteColumns,
		store.Quote(variantID), store.Quote(date),
		store.Quote(contextChannelID), store.Quote(contextChannelID),
		store.Quote(priceChannel))
	rows, err := c.db.Rows(sql)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	q, err := quoteFromRow(rows[0])
	if err != nil {
		return nil, err
	}
	return &q, nil
}

// QuoteAll 算一批变体。变体之间互不影响，所以逐个调用 Quote 即可。
func (c *Calculator) QuoteAll(variantIDs []int64, date string, contextChannelID int64, priceChannelID *int64) ([]Quote, error) {
	out := make([]Quote, 0, len(variantIDs))
	for _, id := range variantIDs {
		q, err := c.Quote(id, date, contextChannelID, priceChannelID)
		if err != nil {
			return nil, err
		}
		if q == nil {
			continue
		}
		out = append(out, *q)
	}
	return out, nil
}

// Reprice 重算库里所有在售售价行。返回被更新的行数。
//
// 这就是「源成本变了怎么办」的答案：不用各写各的补丁，统一重算。
func (c *Calculator) Reprice() (int, error) {
	if c.db == nil {
		return 0, fmt.Errorf("重算定价需要数据库连接")
	}
	v, err := c.db.Scalar("SELECT fn_reprice_rows();")
	if err != nil {
		return 0, err
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 0, fmt.Errorf("重算定价返回了非数字结果：%q", v)
	}
	return n, nil
}

// Unpriced 列出没有被定价的售价行（缺源报价 / 缺上架关系 / 缺汇率快照）。
func (c *Calculator) Unpriced() ([]string, error) {
	if c.db == nil {
		return nil, fmt.Errorf("查询需要数据库连接")
	}
	rows, err := c.db.Rows(
		`SELECT format('变体%s@%s', product_variant_id, date) AS missing
		   FROM price_calendar
		  WHERE status = 'active'
		    AND product_variant_id IS NOT NULL
		    AND (sell_price IS NULL OR cost_price IS NULL)
		  ORDER BY id;`)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r["missing"])
	}
	return out, nil
}

func quoteFromRow(row map[string]string) (Quote, error) {
	q := Quote{
		Date:           row["date"],
		Currency:       row["currency"],
		SourceCurrency: row["source_currency"],
		NetPrice:       row["net_price"],
		FxRate:         row["fx_rate"],
		FxAsOf:         row["fx_as_of"],
		CostPrice:      row["cost_price"],
		SellPrice:      row["sell_price"],
		ListPrice:      row["list_price"],
		DiscountPct:    row["discount_pct"],
		MinMargin:      row["min_margin"],
		PriceLocked:    row["price_locked"] == "t" || row["price_locked"] == "true",
	}
	var err error
	if q.ProductID, err = strconv.ParseInt(row["product_id"], 10, 64); err != nil {
		return q, fmt.Errorf("product_id 不是整数：%q", row["product_id"])
	}
	if q.ProductVariantID, err = strconv.ParseInt(row["product_variant_id"], 10, 64); err != nil {
		return q, fmt.Errorf("product_variant_id 不是整数：%q", row["product_variant_id"])
	}
	if raw := strings.TrimSpace(row["supplier_product_id"]); raw != "" {
		id, perr := strconv.ParseInt(raw, 10, 64)
		if perr != nil {
			return q, fmt.Errorf("supplier_product_id 不是整数：%q", raw)
		}
		q.SupplierProductID = &id
	}
	if raw := row["rule"]; raw != "" {
		q.Rule = json.RawMessage(raw)
		// 组合的分解在 rule->'combo' 里（库里给出的形状，这里不重判「是不是组合」）。
		var probe map[string]json.RawMessage
		if err := json.Unmarshal(q.Rule, &probe); err != nil {
			return q, fmt.Errorf("rule 不是合法的 JSON 对象：%v", err)
		}
		_, q.IsCombo = probe["combo"]
	}
	return q, nil
}
