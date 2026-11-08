// Package compose 是「组合映射」的写侧：把源侧的一条组合表达式
// （一个可售单元由多个源 SKU 按数量组成）解成一张配方，
// 并核上规范侧的组件声明。
//
// 为什么要有这个包：
//
//	异构融合有两个方向。
//	  方向 A：一个源 SKU 覆盖多个规范变体 —— 由 supplier_variant_mapping
//	          + fn_variant_covered 表达（010 建的），读法在 internal/coverage。
//	  方向 B：一个规范变体由多个源 SKU 按数量组成 —— 就是这个包。
//	到 011 为止只有方向 A，于是 GlobalTix 官方示例里的「家庭套餐」
//	（2 份成人门票 + 2 份成人快速通行证 + 1 份儿童门票 + 1 份儿童快速通行证）
//	只能被判成「当前模型表达不了的源侧结构」—— 报告里写着，系统没法卖。
//
// 这个包只做三件事：
//  1. 把表达式里的每一段（源 SKU + 数量）配到规范侧声明的一个组件上；
//  2. 核数量：源侧要几份，规范侧就声明几份，不一致当场报错；
//  3. 把配方写进 supplier_variant_composition（可重复执行，幂等）。
//
// **覆盖判定不在这里重写**：能不能覆盖住，走 internal/coverage →
// 库里的 fn_variant_covered（唯一实现）。
package compose

import (
	"fmt"
	"math/big"
	"strconv"
	"strings"

	"ticket-center/internal/coverage"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
)

// SourceVariant 是一个源 SKU。
type SourceVariant struct {
	// ID 是 supplier_variant.id。
	ID int64
	// ExternalID 是源侧 SKU id。
	ExternalID string
	// Coverage 是这个源 SKU 的覆盖声明，判定时喂给 fn_variant_covered。
	Coverage normalize.Coverage
}

// Part 是组合表达式里的一段。
type Part struct {
	// Variant 是这一段指向的源 SKU。
	Variant SourceVariant
	// Quantity 是要订几份（源侧表达式里的 |2 就是它）。
	Quantity int
}

// Component 是规范侧声明的一个组件。
type Component struct {
	// VariantID 是 product_variant.id。
	VariantID int64
	// Key 是组件的 variant_key。
	Key string
	// Title 是组件名（报错时要说清是哪个组件）。
	Title string
	// Quantity 是这个组件要几份（NUMERIC 原文，不做浮点）。
	Quantity string
}

// Resolved 是配方里的一行：某个源 SKU 顶某个组件、订几份。
type Resolved struct {
	Component
	// SupplierVariantID 是顶这个组件的源 SKU。
	SupplierVariantID int64
	// ExternalID 是源 SKU id（报错与报告用）。
	ExternalID string
	// SourceQuantity 是源侧表达式里的数量（NUMERIC 原文）。
	SourceQuantity string
}

// Plan 是一个组合的完整配方。
type Plan struct {
	// ComboVariantID 是组合（规范侧）的 product_variant.id。
	ComboVariantID int64
	// ComboKey 是组合的 variant_key。
	ComboKey string
	// Components 是规范侧声明的组件（按声明顺序）。
	Components []Component
	// Resolved 是解出来的配方，一行一个成分。
	Resolved []Resolved
	// Parts 是源侧表达式的原始分段（配对用）。
	Parts []Part
	// Union 是各成分覆盖声明的并集 —— 整张配方「合起来」能覆盖什么。
	Union normalize.Coverage
	// CoveredByUnion 说的是：整张配方合起来，覆盖得住组合自己吗。
	// 覆盖不住就说明我们声明的组件比源侧给的还多 —— 这张配方不该卖。
	CoveredByUnion bool
	// UnionGaps 是覆盖不住时差在哪。
	UnionGaps []string
}

// FindCombo 按 variant_key 找组合变体。
//
// variant_key 在库里是「每个商品内唯一」，跨商品可能重名 ——
// 所以这里必须唯一命中，命中多个就报错，不猜。
func FindCombo(db *store.DB, key string) (int64, error) {
	rows, err := db.Rows(`SELECT id, variant_key, variant_role
	                         FROM product_variant
	                        WHERE variant_key = ` + store.Quote(key) + `
	                          AND status = 'active';`)
	if err != nil {
		return 0, err
	}
	switch len(rows) {
	case 0:
		return 0, fmt.Errorf("规范变体 %s 不在库里", key)
	case 1:
		id, _ := strconv.ParseInt(rows[0]["id"], 10, 64)
		return id, nil
	default:
		return 0, fmt.Errorf("规范变体 %s 有 %d 条，key 跨商品不唯一，不能猜", key, len(rows))
	}
}

// DeclaredComponents 读组合在规范侧声明的组件（relation_type='included'）。
func DeclaredComponents(db *store.DB, comboVariantID int64) ([]Component, error) {
	rows, err := db.Rows(`SELECT r.child_variant_id, cv.variant_key, cv.title, r.quantity
	                         FROM product_variant_relation r
	                         JOIN product_variant cv ON cv.id = r.child_variant_id
	                        WHERE r.parent_variant_id = ` + strconv.FormatInt(comboVariantID, 10) + `
	                          AND r.relation_type = 'included'
	                        ORDER BY r.sort_order, r.id;`)
	if err != nil {
		return nil, err
	}
	out := make([]Component, 0, len(rows))
	for _, r := range rows {
		id, _ := strconv.ParseInt(r["child_variant_id"], 10, 64)
		out = append(out, Component{
			VariantID: id,
			Key:       r["variant_key"],
			Title:     r["title"],
			Quantity:  r["quantity"],
		})
	}
	return out, nil
}

// Resolve 把组合表达式的每一段配到规范侧声明的组件上，并核数量。
//
// 配对靠覆盖判定（库里的 fn_variant_covered）：
//
//	一个源 SKU 必须**恰好**覆盖住一个声明的组件。
//	覆盖不住 → 报错（源侧给的这个 SKU 顶不了我们声明的任何组件）。
//	覆盖住多个 → 报错（猜不出来就不是猜，是不许卖错）。
//
// 数量必须一致：源侧 |2 就是 2，规范侧声明也得是 2。
func Resolve(db *store.DB, comboKey string, parts []Part) (*Plan, error) {
	comboID, err := FindCombo(db, comboKey)
	if err != nil {
		return nil, err
	}
	components, err := DeclaredComponents(db, comboID)
	if err != nil {
		return nil, err
	}
	if len(components) == 0 {
		return nil, fmt.Errorf("组合 %s 没有声明组件（relation_type='included'），无从配对", comboKey)
	}

	candidates := make([]coverage.Canonical, 0, len(components))
	for _, c := range components {
		candidates = append(candidates, coverage.Canonical{VariantID: c.VariantID, Key: c.Key})
	}

	plan := &Plan{ComboVariantID: comboID, ComboKey: comboKey, Components: components, Parts: parts}
	used := map[int64]string{} // 组件 id → 已配上的源 SKU

	for _, p := range parts {
		verdicts, err := coverage.Judge(db, coverage.JSON(p.Variant.Coverage), candidates)
		if err != nil {
			return nil, err
		}
		var hit []Component
		var gaps []string
		for _, v := range verdicts {
			if v.CanFulfil {
				hit = append(hit, componentOf(components, v.VariantID))
			} else if len(v.Gaps) > 0 {
				gaps = append(gaps, fmt.Sprintf("%s（缺 %s）", v.Key, strings.Join(v.Gaps, "，")))
			}
		}
		switch len(hit) {
		case 0:
			return nil, fmt.Errorf("源 SKU %s 覆盖不住 %s 声明的任何组件；各组件的缺口：%s",
				p.Variant.ExternalID, comboKey, strings.Join(gaps, "；"))
		case 1:
		default:
			keys := make([]string, 0, len(hit))
			for _, c := range hit {
				keys = append(keys, c.Key)
			}
			return nil, fmt.Errorf("源 SKU %s 同时覆盖住 %s 的多个组件（%s），配不出来，不许猜",
				p.Variant.ExternalID, comboKey, strings.Join(keys, "、"))
		}

		comp := hit[0]
		if prev, dup := used[comp.VariantID]; dup {
			return nil, fmt.Errorf("组件 %s 被两个源 SKU 同时顶上（%s 与 %s）",
				comp.Key, prev, p.Variant.ExternalID)
		}
		if err := checkQuantity(comp, p.Quantity); err != nil {
			return nil, err
		}
		used[comp.VariantID] = p.Variant.ExternalID
		plan.Resolved = append(plan.Resolved, Resolved{
			Component:         comp,
			SupplierVariantID: p.Variant.ID,
			ExternalID:        p.Variant.ExternalID,
			SourceQuantity:    strconv.Itoa(p.Quantity),
		})
	}

	// 声明了却没配上的组件 = 源侧少给了一份。
	for _, c := range components {
		if _, ok := used[c.VariantID]; !ok {
			return nil, fmt.Errorf("组件 %s 声明要 %s 份，源侧表达式里没有对应的 SKU", c.Key, c.Quantity)
		}
	}

	// 整张配方合起来（各成分覆盖声明的并集）覆盖得住组合自己吗。
	// 覆盖不住 = 我们声明的组件比源侧给的还多 —— 这张配方不该卖，当场说清差在哪。
	covs := make([]normalize.Coverage, 0, len(parts))
	for _, p := range parts {
		covs = append(covs, p.Variant.Coverage)
	}
	plan.Union = normalize.UnionCoverage(covs)
	verdict, err := coverage.JudgeOne(db, coverage.JSON(plan.Union),
		coverage.Canonical{VariantID: comboID, Key: comboKey})
	if err != nil {
		return nil, err
	}
	plan.CoveredByUnion = verdict.CanFulfil
	plan.UnionGaps = verdict.Gaps
	return plan, nil
}

// Apply 把配方写进 supplier_variant_composition。
//
// 幂等：同一份配方重复执行，结果一样；
// 源侧表达式改过（少了某个 SKU）时，旧的那行退成 retired（不删 —— 卖过的事实不许改写）。
func Apply(db *store.DB, plan *Plan) error {
	if plan == nil || len(plan.Resolved) == 0 {
		return fmt.Errorf("配方是空的，不写")
	}
	sql := `INSERT INTO supplier_variant_composition
	                 (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
	         VALUES ` + valuesOf(plan) + `
	        ON CONFLICT (product_variant_id, component_variant_id, supplier_variant_id)
	        DO UPDATE SET quantity   = EXCLUDED.quantity,
	                      status     = 'active',
	                      updated_at = now();`
	if err := db.Exec(sql); err != nil {
		return err
	}
	// 表达式里已经没有的「成分 × 源 SKU」组合：退成 retired（留着，不删）。
	//
	// 按对退，不按源 SKU 退：
	//   参数化源（一个人群参数化的 SKU 顶成人/儿童/老年）里，
	//   同一个源 SKU 对应多个成分。表达式去掉其中一个成分但留着这个 SKU 时，
	//   按 SKU 退就漏掉了 —— 组合还带着已经不给的那一份继续卖。
	retire := `UPDATE supplier_variant_composition c
	              SET status = 'retired', updated_at = now()
	            WHERE c.product_variant_id = ` + strconv.FormatInt(plan.ComboVariantID, 10) + `
	              AND c.status = 'active'
	              AND NOT EXISTS (
	                    SELECT 1 FROM (VALUES ` + pairsOf(plan) + `) p(component_variant_id, supplier_variant_id)
	                     WHERE p.component_variant_id = c.component_variant_id
	                       AND p.supplier_variant_id = c.supplier_variant_id);`
	return db.Exec(retire)
}

// pairsOf 拼「成分 × 源 SKU」的值段，给退场判定用。
func pairsOf(plan *Plan) string {
	parts := make([]string, 0, len(plan.Resolved))
	for _, r := range plan.Resolved {
		parts = append(parts, fmt.Sprintf("(%d,%d)", r.VariantID, r.SupplierVariantID))
	}
	return strings.Join(parts, ",")
}

// valuesOf 拼 VALUES 段。
func valuesOf(plan *Plan) string {
	parts := make([]string, 0, len(plan.Resolved))
	for _, r := range plan.Resolved {
		parts = append(parts, fmt.Sprintf("(%d,%d,%d,%s,'active')",
			plan.ComboVariantID, r.VariantID, r.SupplierVariantID, r.Quantity))
	}
	return strings.Join(parts, ",")
}

// componentOf 按 id 取组件。
func componentOf(components []Component, id int64) Component {
	for _, c := range components {
		if c.VariantID == id {
			return c
		}
	}
	return Component{}
}

// checkQuantity 核数量：源侧要几份，规范侧就得声明几份。
//
// 用 big.Rat 比，不走浮点 —— 「2」和「2.00」是同一个数，
// 「2」和「2.5」不是，浮点比会在这里翻车。
func checkQuantity(c Component, sourceQty int) error {
	declared, ok := new(big.Rat).SetString(c.Quantity)
	if !ok {
		return fmt.Errorf("组件 %s 的声明数量 %q 不是数字", c.Key, c.Quantity)
	}
	want := new(big.Rat).SetInt64(int64(sourceQty))
	if declared.Cmp(want) != 0 {
		return fmt.Errorf("组件 %s 声明要 %s 份，源侧表达式要 %d 份，对不上",
			c.Key, c.Quantity, sourceQty)
	}
	return nil
}
