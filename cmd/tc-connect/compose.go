// 组合映射（异构融合的第二个方向）。
//
//	tc-connect compose plan  --source key --fixture path --db name
//	tc-connect compose apply --source key --fixture path --db name
//
// 源侧的一条组合表达式（一个可售单元由多个源 SKU 按数量组成）
// 解成一张配方，核上规范侧的组件声明。
//
// 解析与核数在 internal/compose；「能不能覆盖住」由库里的
// fn_variant_covered 判定（唯一实现，internal/coverage 是读法）。
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"ticket-center/internal/compose"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
)

// cmdCompose 组合映射的入口。
func cmdCompose(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("compose 需要子命令：plan | apply")
	}
	switch args[0] {
	case "plan":
		return cmdComposeRun(args[1:], false)
	case "apply":
		return cmdComposeRun(args[1:], true)
	default:
		return fmt.Errorf("compose 未知子命令：%s（可用：plan | apply）", args[0])
	}
}

func cmdComposeRun(args []string, apply bool) error {
	fs := flag.NewFlagSet("compose", flag.ExitOnError)
	// 这里不用 commonFlags：它的 --db 是「报文归档库」，而 compose 要的是规范库。
	// 自己声明一套，避免两个 --db 撞在一起。
	source := fs.String("source", "", "映射规则里的源 key")
	fixture := fs.String("fixture", "", "源报文 JSON 路径")
	dbName := fs.String("db", "", "规范库（默认取 PGDATABASE，再默认 ticket_center）")
	rulesPath := fs.String("rules", filepath.Join(findRoot(), "configs", "mapping_rules.json"), "映射规则配置文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *source == "" || *fixture == "" {
		return fmt.Errorf("compose 需要 --source 与 --fixture")
	}
	rules, err := normalize.LoadRules(*rulesPath)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(*fixture)
	if err != nil {
		return err
	}
	result, err := rules.Normalize(*source, raw)
	if err != nil {
		return err
	}
	rule, ok := rules.Sources[*source]
	if !ok {
		return fmt.Errorf("映射规则里没有源 %s", *source)
	}

	db := store.New(fulfillDB(*dbName))
	plans, err := resolveComposites(db, rule.SupplierCode, result)
	if err != nil {
		return err
	}
	if apply {
		for _, p := range plans {
			if err := compose.Apply(db, p); err != nil {
				return err
			}
		}
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, plans); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(plans) == 0 {
		fmt.Println("这份报文里没有组合表达式。")
		return nil
	}
	for _, p := range plans {
		fmt.Printf("组合 %s（规范变体 %d）\n", p.ComboKey, p.ComboVariantID)
		for _, r := range p.Resolved {
			fmt.Printf("  %-24s × %-4s ← 源 SKU %s\n",
				r.Key, r.SourceQuantity, r.ExternalID)
		}
		if p.CoveredByUnion {
			fmt.Println("  整张配方合起来覆盖得住这个组合")
		} else {
			fmt.Printf("  整张配方合起来覆盖不住这个组合，缺：%s\n", strings.Join(p.UnionGaps, "，"))
		}
		if apply {
			fmt.Println("  已写入 supplier_variant_composition")
		}
	}
	return nil
}

// resolveComposites 把报文里的组合表达式逐条解成配方。
//
// 三步：
//  1. 表达式每一段指向哪个源 SKU —— 按 supplier_variant.external_variant_id 查库；
//  2. 这个源 SKU 的覆盖声明 —— 来自归一化结果（internal/normalize 是唯一实现）；
//  3. 配对与核数 —— internal/compose（覆盖判定走库里的 fn_variant_covered）。
func resolveComposites(db *store.DB, supplierCode string, result *normalize.Result) ([]*compose.Plan, error) {
	exprs := make([]normalize.CompositeExpression, 0, len(result.CompositeExpressions))
	for _, e := range result.CompositeExpressions {
		if e.IsComposite {
			exprs = append(exprs, e)
		}
	}
	if len(exprs) == 0 {
		return nil, nil
	}

	// 归一化结果里的源变体：external_id → 覆盖声明
	covByExternal := map[string]normalize.Coverage{}
	for _, v := range result.Variants {
		covByExternal[v.ExternalID] = v.Coverage
	}

	// 库里这个源的源变体：external_id → id
	externalIDs := make([]string, 0, len(covByExternal))
	for id := range covByExternal {
		externalIDs = append(externalIDs, id)
	}
	idByExternal, err := loadSourceVariantIDs(db, supplierCode, externalIDs)
	if err != nil {
		return nil, err
	}

	plans := make([]*compose.Plan, 0, len(exprs))
	for _, e := range exprs {
		parts := make([]compose.Part, 0, len(e.Parts))
		for _, part := range e.Parts {
			cov, ok := covByExternal[part.SKU]
			if !ok {
				return nil, fmt.Errorf("组合表达式里的源 SKU %s 不在归一化结果里", part.SKU)
			}
			id, ok := idByExternal[part.SKU]
			if !ok {
				return nil, fmt.Errorf("组合表达式里的源 SKU %s 不在库里（%s 的 supplier_variant）", part.SKU, supplierCode)
			}
			parts = append(parts, compose.Part{
				Variant: compose.SourceVariant{
					ID:         id,
					ExternalID: part.SKU,
					Coverage:   cov,
				},
				Quantity: part.Qty,
			})
		}
		plan, err := compose.Resolve(db, e.OurVariant, parts)
		if err != nil {
			return nil, fmt.Errorf("组合表达式 %s：%w", e.MappingID, err)
		}
		plans = append(plans, plan)
	}
	return plans, nil
}

// loadSourceVariantIDs 查一个源下若干 external_variant_id 对应的 supplier_variant.id。
func loadSourceVariantIDs(db *store.DB, supplierCode string, externalIDs []string) (map[string]int64, error) {
	out := map[string]int64{}
	if len(externalIDs) == 0 {
		return out, nil
	}
	quoted := make([]string, 0, len(externalIDs))
	for _, id := range externalIDs {
		quoted = append(quoted, store.Quote(id))
	}
	rows, err := db.Rows(`SELECT sv.external_variant_id, sv.id
	                         FROM supplier_variant sv
	                         JOIN supplier_product sp ON sp.id = sv.supplier_product_id
	                         JOIN supplier sup ON sup.id = sp.supplier_id
	                        WHERE sup.code = ` + store.Quote(supplierCode) + `
	                          AND sv.external_variant_id IN (` + strings.Join(quoted, ",") + `);`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		id, _ := strconv.ParseInt(r["id"], 10, 64)
		out[r["external_variant_id"]] = id
	}
	return out, nil
}

func init() {
	register("compose", "组合映射：源侧组合表达式解成配方，核上规范侧的组件声明", usageCompose, cmdCompose, 150)
}

const usageCompose = `  tc-connect compose    plan     --source key --fixture path --db name [--json out.json]
  tc-connect compose    apply    --source key --fixture path --db name [--json out.json]
`
