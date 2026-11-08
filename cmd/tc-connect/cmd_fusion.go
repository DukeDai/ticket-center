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
//
// 三个子命令都只读视图，不算任何东西：
// 轴取值、有效天数、覆盖判定都有唯一实现，Go 侧再写一遍就是第二份实现。
func cmdVariant(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("variant 需要子命令：compare | coverage | feed | composition")
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
	default:
		return fmt.Errorf("variant 未知子命令：%s（可用：compare | coverage | feed | composition）", args[0])
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
	register("variant", "差异模型的只读视图：对照 / 覆盖 / 读模型行 / 组合构成", usageVariant, cmdVariant, 140)
}

const usageVariant = `  tc-connect variant    compare  --db name [--product 6] [--json out.json]
  tc-connect variant    coverage --db name [--variant 14] [--json out.json]
  tc-connect variant    feed     --db name [--channel 1] [--product 6] [--json out.json]
  tc-connect variant    composition --db name [--variant 18] [--channel 1] [--json out.json]
`
