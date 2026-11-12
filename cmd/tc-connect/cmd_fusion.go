// 异构融合的只读子命令：可售单元之间的差异、源覆盖、读模型行、组合构成。
//
// 三个子命令都只读视图，不算任何东西：
// 轴取值、有效天数、覆盖判定都有唯一实现，Go 侧再写一遍就是第二份实现。
package main

import (
	"flag"
	"fmt"
	"strings"

	"ticket-center/internal/store"
	"ticket-center/internal/variant"
)

// cmdVariant 是差异模型的只读子命令。
//
// compare  —— 可售单元之间差在哪（人群 / 轴 / 有效期 / 退款口径 / 有几个源能供）
// coverage —— 每个可售单元有哪些源能供、缺什么（缺什么就是覆盖缺口）
// feed     —— C 端读模型里的变体行（请求链路不许 join 主数据，差异靠它带出去）
// supply   —— 三种供给形态（单张 / 配方 / 套装）在同一张表上对齐
//
// 这些子命令都只读视图，不算任何东西：
// 轴取值、有效天数、覆盖判定都有唯一实现，Go 侧再写一遍就是第二份实现。
func cmdVariant(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("variant 需要子命令：compare | coverage | feed | composition | bundle | supply")
	}
	switch args[0] {
	case "compare":
		return cmdVariantCompare(args[1:])
	case "coverage":
		return cmdVariantCoverage(args[1:])
	case "feed":
		return cmdVariantFeed(args[1:])
	case "composition":
		return cmdVariantComposition(args[1:])
	case "bundle":
		return cmdVariantBundle(args[1:])
	case "supply":
		return cmdVariantSupply(args[1:])
	default:
		return fmt.Errorf("variant 未知子命令：%s（可用：compare | coverage | feed | composition | bundle | supply）", args[0])
	}
}

func cmdVariantCompare(args []string) error {
	fs := flag.NewFlagSet("variant compare", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	productID := fs.Int64("product", 0, "商品 id（0 表示不按商品过滤）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rows, err := variant.Compare(store.New(fulfillDB(*dbName)), *productID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, rows); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(rows) == 0 {
		fmt.Println("没有可售单元。")
		return nil
	}
	fmt.Printf("共 %d 个可售单元：\n", len(rows))
	for _, r := range rows {
		fmt.Printf("  %-22s %-12s 人群 %-8s 有效 %d 天 %s\n",
			r.VariantCode, r.ProductCode, orDash(r.Audience), r.ValidDays, r.Axes)
		fmt.Printf("      可退 %s%s · 有源 %d / 能供 %d%s\n",
			boolText(r.Refundable), feeText(r.RefundFeePercent),
			r.SourceCount, r.FulfilableSourceCount, supplierText(r.Suppliers))
	}
	return nil
}

func cmdVariantCoverage(args []string) error {
	fs := flag.NewFlagSet("variant coverage", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	variantID := fs.Int64("variant", 0, "变体 id（0 表示全部）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rows, err := variant.SourceCoverage(store.New(fulfillDB(*dbName)), *variantID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, rows); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(rows) == 0 {
		fmt.Println("没有源覆盖记录。")
		return nil
	}
	for _, r := range rows {
		mark := "✓"
		note := ""
		if !r.CanFulfil {
			mark = "✗"
			note = "  缺 " + r.Gaps
		}
		fmt.Printf("  %s %-22s ← %-12s %-18s%s\n",
			mark, r.VariantCode, r.SupplierCode, r.ExternalVariantID, note)
	}
	return nil
}

func cmdVariantFeed(args []string) error {
	fs := flag.NewFlagSet("variant feed", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	channelID := fs.Int64("channel", 0, "渠道 id（0 表示全部）")
	productID := fs.Int64("product", 0, "商品 id（0 表示不按商品过滤）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rows, err := variant.FeedRows(store.New(fulfillDB(*dbName)), *channelID, *productID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, rows); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(rows) == 0 {
		fmt.Println("读模型里没有变体行（刷新作业漏跑了？先跑 tc-connect refresh）。")
		return nil
	}
	fmt.Printf("共 %d 行：\n", len(rows))
	for _, r := range rows {
		mark := ""
		if r.IsCombo {
			mark = fmt.Sprintf(" [套餐 %d 成分：%s]", r.ComponentCount, orDash(r.ComboAudience))
		}
		fmt.Printf("  渠道 %d · %-22s 人群 %-8s 有效 %d 天 · %s ~ %s · %s ~ %s%s\n",
			r.ChannelID, r.VariantCode, orDash(r.Audience), r.ValidDays,
			orDash(r.FirstDate), orDash(r.LastDate),
			orDash(r.PriceMin), orDash(r.PriceMax), mark)
	}
	return nil
}

// cmdVariantComposition 列出组合的成分明细（一份套餐由谁组成）。
func cmdVariantComposition(args []string) error {
	fs := flag.NewFlagSet("variant composition", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	variantID := fs.Int64("variant", 0, "变体 id（0 表示全部组合）")
	channelID := fs.Int64("channel", 0, "渠道 id（0 表示全部渠道）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rows, err := variant.CompositionRows(store.New(fulfillDB(*dbName)), *channelID, *variantID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, rows); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(rows) == 0 {
		fmt.Println("没有组合成分记录（先跑 tc-connect refresh 把组合推上读模型）。")
		return nil
	}
	// 读模型是按渠道建的：同一个套餐上了两个渠道就有两份明细。
	// 不分组就会把「2 份成人」印成两行 —— 看着像 4 份成人。
	var lastChannel, lastVariant int64
	for i, r := range rows {
		if r.ChannelID != lastChannel || r.ProductVariantID != lastVariant {
			if i > 0 {
				fmt.Println()
			}
			fmt.Printf("套餐 %s（渠道 %d）：\n", r.VariantKey, r.ChannelID)
			lastChannel, lastVariant = r.ChannelID, r.ProductVariantID
		}
		fmt.Printf("    %s 份 × %-20s 人群 %-8s 各自管 %d 天\n",
			orDash(r.Quantity), r.VariantCode, orDash(r.AudienceCode), r.ValidDays)
	}
	return nil
}

// cmdVariantBundle 列出套装（源侧把整套当一个 SKU 卖）的构成与缺口。
//
// 套装与配方型组合的区别：配方是我们把几个源 SKU 按份数拼起来，
// 套装是源侧自己把整套当一个 SKU 卖 —— 从 coverage 看不出是哪种，
// 所以必须单独声明，否则「一套三张票」会被当成「三张单票」。
func cmdVariantBundle(args []string) error {
	fs := flag.NewFlagSet("variant bundle", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	variantID := fs.Int64("variant", 0, "变体 id（0 表示全部）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	db := store.New(fulfillDB(*dbName))
	rows, err := variant.BundleRows(db, *variantID)
	if err != nil {
		return err
	}
	parts, err := variant.BundlePartRows(db, *variantID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, rows); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(rows) == 0 {
		fmt.Println("没有套装记录（套装要单独声明：源侧把整套当一个 SKU 卖）。")
		return nil
	}
	byBundle := map[int64][]variant.BundlePart{}
	for _, p := range parts {
		byBundle[p.BundleID] = append(byBundle[p.BundleID], p)
	}
	for _, r := range rows {
		window := "盖得住"
		if !r.CoversWindow {
			window = "盖不住（源侧整套有效期比成分窗口短）"
		}
		fmt.Printf("套装 %s ← %s / %s\n", r.VariantCode, r.SourceSetSKU, r.SupplierCode)
		fmt.Printf("    一套 %s 份入场 · 源侧整套有效 %s 天 · 成分窗口 %d 天（%s）\n",
			orDash(r.AdmissionsPerSet), orDash(r.SetValidDays), r.UnionDays, window)
		for _, p := range byBundle[r.BundleID] {
			fmt.Printf("      %s 份 × %-20s 人群 %-8s 各自管 %d 天\n",
				orDash(p.Quantity), p.VariantCode, orDash(p.AudienceCode), p.ValidDays)
		}
		if r.GapDays > 0 {
			fmt.Printf("    有 %d 天卖不掉：%s\n", r.GapDays, jsonListText(r.GapReasons))
		}
	}
	return nil
}

// cmdVariantSupply 把三种供给形态放在同一张表上对照。
//
// 形态不同、供给方式不同、成本口径也不同：
// 单张是一个源 SKU 顶住这个可售单元，配方是多个源 SKU 按份数组成，
// 套装是源侧自己把整套当一个 SKU 卖。
// 放在一张表上，才能一眼看出「同一份交付，不同的供给方式、不同的成本、不同的缺口」。
func cmdVariantSupply(args []string) error {
	fs := flag.NewFlagSet("variant supply", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	variantID := fs.Int64("variant", 0, "变体 id（0 表示全部）")
	date := fs.String("date", "", "日期 YYYY-MM-DD（空表示全部）")
	channelID := fs.Int64("channel", 0, "渠道 id（0 表示全部渠道）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rows, err := variant.SupplyFormRows(store.New(fulfillDB(*dbName)), *variantID, *date, *channelID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, rows); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if len(rows) == 0 {
		fmt.Println("没有供给形态记录（可卖日来自 price_calendar，渠道来自上架行）。")
		return nil
	}
	var lastVariant, lastChannel int64
	var lastDate string
	for i, r := range rows {
		if r.ProductVariantID != lastVariant || r.ChannelID != lastChannel || r.Date != lastDate {
			if i > 0 {
				fmt.Println()
			}
			fmt.Printf("%s（%s · 渠道 %d · %s）：\n",
				r.VariantCode, orDash(r.ProductTitle), r.ChannelID, r.Date)
			lastVariant, lastChannel, lastDate = r.ProductVariantID, r.ChannelID, r.Date
		}
		mark := "✗"
		if r.CanFulfil {
			mark = "✓"
		}
		fmt.Printf("    %s %-7s 源 %-16s 成本 %s %s · 入场 %s 份 · 有效 %d 天\n",
			mark, r.SupplyForm, pgArrayText(r.SupplierCodes),
			orDash(r.CostInTarget), r.Currency,
			orDash(r.AdmissionQuantity), r.ValidDays)
		if gaps := pgArrayText(r.Gaps); gaps != "" {
			fmt.Printf("        缺口：%s\n", gaps)
		}
	}
	return nil
}

// pgArrayText 把 PostgreSQL 的数组字面量（{a,b}）压成一行可读文本。
// 空数组与空串都读成空串。
func pgArrayText(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || s == "{}" {
		return ""
	}
	s = strings.TrimPrefix(s, "{")
	s = strings.TrimSuffix(s, "}")
	s = strings.ReplaceAll(s, "\"", "")
	return strings.TrimSpace(s)
}

// jsonListText 把 jsonb 字符串数组压成一行可读文本（去掉括号与引号）。
func jsonListText(s string) string {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	s = strings.ReplaceAll(s, "\"", "")
	return strings.TrimSpace(s)
}

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "-"
	}
	return s
}

func boolText(b bool) string {
	if b {
		return "是"
	}
	return "否"
}

func feeText(pct string) string {
	if pct == "" || pct == "0" || pct == "0.00" {
		return ""
	}
	return "（手续费 " + pct + "%）"
}

func supplierText(list string) string {
	if list == "" || list == "{}" {
		return ""
	}
	return " · " + list
}

func init() {
	register("variant", "差异模型的只读视图：对照 / 覆盖 / 读模型行 / 组合构成 / 套装构成 / 供给形态对照", usageVariant, cmdVariant, 140)
}

const usageVariant = `  tc-connect variant    compare  --db name [--product 6] [--json out.json]
  tc-connect variant    coverage --db name [--variant 14] [--json out.json]
  tc-connect variant    feed     --db name [--channel 1] [--product 6] [--json out.json]
  tc-connect variant    composition --db name [--variant 18] [--channel 1] [--json out.json]
  tc-connect variant    bundle   --db name [--variant 21] [--json out.json]
  tc-connect variant    supply   --db name [--variant 18] [--date <日期>] [--channel 1] [--json out.json]
`
