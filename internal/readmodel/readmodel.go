// Package readmodel 是 C 端读模型的刷新与漂移检查。
//
// 刷新的口径写在库里的 fn_refresh_read_models()（db/migrations/002_read_model_refresh.sql，
// 015 整体替换过一次），这个包只负责调用与报告 —— 读模型的口径不该在 Go 侧再写一遍，
// 否则两边各改各的，刷新完还会被判成漂移。
//
// 组合（异构融合方向 B）的售价行与日历格子也在这个包里同步：
// 组合源侧没有商品条目，目录同步作业看不见它 —— 它的日历得自己推。
package readmodel

import (
	"fmt"
	"strconv"

	"ticket-center/internal/store"
)

// Counts 是一次刷新的结果。
type Counts struct {
	CardsUpdated        int
	VariantCellsUpdated int
	VariantFactsUpdated int
}

// ComboCounts 是一次组合同步的结果。
type ComboCounts struct {
	PriceRows int
	Cells     int
}

// Drift 是一张漂移了的卡片。
type Drift struct {
	ChannelID     int64
	ProductID     int64
	CardFromPrice string
	TruthMinPrice string
	SyncedAt      string
}

// Refresh 刷新读模型。
func Refresh(db *store.DB) (Counts, error) {
	var c Counts
	rows, err := db.Query("SELECT cards_updated, variant_cells_updated, variant_facts_updated FROM fn_refresh_read_models();")
	if err != nil {
		return c, err
	}
	if len(rows) == 0 || len(rows[0]) < 3 {
		return c, fmt.Errorf("刷新读模型没有返回结果")
	}
	c.CardsUpdated, _ = strconv.Atoi(rows[0][0])
	c.VariantCellsUpdated, _ = strconv.Atoi(rows[0][1])
	c.VariantFactsUpdated, _ = strconv.Atoi(rows[0][2])
	return c, nil
}

// SyncCombos 把组合（异构融合方向 B）推成售价行与日历格子。
//
// 组合是自己的配方 —— 源侧没有对应的商品条目，目录同步作业看不见它。
// 所以它的售价行与日历格子只能由配方推出来：成本取自定价函数的组合分支
// （Σ 成分单价 × 份数），日期取自成分共同的场次。
//
// 口径在库里的 fn_sync_combo_calendar()，这个包只调用与报告。
// 幂等：重复跑不会多出价格行，也不会多出格子。
func SyncCombos(db *store.DB) (ComboCounts, error) {
	var c ComboCounts
	rows, err := db.Query("SELECT price_rows, cells FROM fn_sync_combo_calendar();")
	if err != nil {
		return c, err
	}
	if len(rows) == 0 || len(rows[0]) < 2 {
		return c, fmt.Errorf("组合同步没有返回结果")
	}
	c.PriceRows, _ = strconv.Atoi(rows[0][0])
	c.Cells, _ = strconv.Atoi(rows[0][1])
	return c, nil
}

// DriftRows 列出漂移的卡片。
//
// 漂移 = 卡片上的起价与价格日历算出来的真值不一致，
// 说明刷新作业漏跑了（或者口径被改过）。
func DriftRows(db *store.DB) ([]Drift, error) {
	rows, err := db.Rows(`SELECT channel_id, product_id,
                                 COALESCE(card_from_price::text, '-')      AS card_from_price,
                                 COALESCE(truth_min_price::text, '-')     AS truth_min_price,
                                 synced_at::text
                            FROM v_c_readmodel_drift
                           WHERE drifted
                           ORDER BY channel_id, product_id;`)
	if err != nil {
		return nil, err
	}
	out := make([]Drift, 0, len(rows))
	for _, r := range rows {
		ch, _ := strconv.ParseInt(r["channel_id"], 10, 64)
		pr, _ := strconv.ParseInt(r["product_id"], 10, 64)
		out = append(out, Drift{
			ChannelID:     ch,
			ProductID:     pr,
			CardFromPrice: r["card_from_price"],
			TruthMinPrice: r["truth_min_price"],
			SyncedAt:      r["synced_at"],
		})
	}
	return out, nil
}
