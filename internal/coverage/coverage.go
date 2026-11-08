// Package coverage 是「源变体能不能装出规范变体」这条规则的唯一读法。
//
// 规则住在库里（fn_variant_covered / fn_variant_coverage_gaps，010 建的）：
// 一个源变体的覆盖声明（哪些轴取值覆盖得了、哪些被排除）
// 与一个规范变体的要求（人群 + 各轴取值）比对，得出「覆盖得住 / 覆盖不住，缺什么」。
//
// 为什么不在 Go 里再写一遍：
//   这条规则是异构融合的核心 —— 它决定「我们的这个可售单元，源侧能不能出票」。
//   之前它有三份实现：库里的函数、internal/normalize 的 Covers、
//   scripts/mapping_dryrun.py 的 covers()。
//   三份各自自洽，改了一份另外两份不动 ——
//   分叉的后果是「源侧说覆盖得住、我们的门禁说覆盖不住」，
//   或者反过来：以为能供，最后源侧下不了单。
//
// 这个包只负责调用与结果结构化，不重写规则。
package coverage

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
)

// Canonical 是一个规范变体（匹配的另一侧）。
type Canonical struct {
	// VariantID 是 product_variant.id —— 库里的判定函数要的是 id，不是 key。
	VariantID int64  `json:"variant_id"`
	Key       string `json:"key"`
}

// Verdict 是一个规范变体对一个覆盖声明的判定结果。
type Verdict struct {
	Canonical
	CanFulfil bool     `json:"can_fulfil"`
	Gaps      []string `json:"gaps"`
}

// JSON 把归一化出来的覆盖声明序列化成判定函数要的 jsonb 文本。
//
// 归一化产出的是结构体，判定函数吃的是 jsonb —— 这一步只做搬运，不做判断。
func JSON(cov normalize.Coverage) string {
	b, err := json.Marshal(cov)
	if err != nil {
		return "{}"
	}
	return string(b)
}

// LoadCanonical 读出库里所有可用的规范变体。
func LoadCanonical(db *store.DB) ([]Canonical, error) {
	if db == nil {
		return nil, nil
	}
	rows, err := db.Rows(`SELECT product_variant_id, variant_key
	                        FROM v_product_variant_matrix
	                       WHERE status = 'active'
	                       ORDER BY sort_order;`)
	if err != nil {
		return nil, err
	}
	out := make([]Canonical, 0, len(rows))
	for _, r := range rows {
		id, _ := strconv.ParseInt(r["product_variant_id"], 10, 64)
		out = append(out, Canonical{VariantID: id, Key: r["variant_key"]})
	}
	return out, nil
}

// Judge 判定一个覆盖声明能装出哪些规范变体。
//
// covJSON 是覆盖声明（{"axes":{...},"excludes":[...]}），
// canon 是候选的规范变体。判定与缺口都在库里算，这里只负责搬结果。
func Judge(db *store.DB, covJSON string, canon []Canonical) ([]Verdict, error) {
	if db == nil || len(canon) == 0 {
		return nil, nil
	}
	ids := make([]string, 0, len(canon))
	for _, c := range canon {
		ids = append(ids, strconv.FormatInt(c.VariantID, 10))
	}
	sql := `SELECT pv.variant_key,
	               pv.id,
	               fn_variant_covered(` + store.Quote(covJSON) + `::jsonb, pv.id) AS can_fulfil,
	               COALESCE(array_to_string(fn_variant_coverage_gaps(` + store.Quote(covJSON) + `::jsonb, pv.id), ','), '') AS gaps
	          FROM unnest(ARRAY[` + strings.Join(ids, ",") + `]::bigint[]) AS u(variant_id)
	          JOIN product_variant pv ON pv.id = u.variant_id
	         ORDER BY pv.sort_order;`
	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	out := make([]Verdict, 0, len(rows))
	for _, r := range rows {
		id, _ := strconv.ParseInt(r["id"], 10, 64)
		v := Verdict{
			Canonical: Canonical{VariantID: id, Key: r["variant_key"]},
			CanFulfil: strings.EqualFold(r["can_fulfil"], "t") || strings.EqualFold(r["can_fulfil"], "true"),
		}
		if g := strings.TrimSpace(r["gaps"]); g != "" {
			v.Gaps = strings.Split(g, ",")
		}
		out = append(out, v)
	}
	return out, nil
}

// JudgeOne 判定一个覆盖声明能不能装出指定的规范变体。
func JudgeOne(db *store.DB, covJSON string, c Canonical) (Verdict, error) {
	vs, err := Judge(db, covJSON, []Canonical{c})
	if err != nil {
		return Verdict{}, err
	}
	if len(vs) == 0 {
		return Verdict{}, fmt.Errorf("规范变体 %s 不在库里", c.Key)
	}
	return vs[0], nil
}
