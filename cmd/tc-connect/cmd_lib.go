// 库侧的子命令：定价、迁移、读模型刷新。
//
// 这三个命令都不自己算业务结论：定价走 fn_price_variant，
// 迁移走迁移引擎的账本，读模型刷新走 fn_refresh_read_models。
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"ticket-center/internal/migrate"
	"ticket-center/internal/pricing"
	"ticket-center/internal/readmodel"
	"ticket-center/internal/store"
)

// cmdPrice 调库里的定价实现（fn_price_variant）。
//
// Go 侧不做任何价格计算：钱必须是 NUMERIC，而标准库没有十进制类型。
// 这个子命令的价值是「所有入口给出同一个价格」——演练器、接入层、运维排查
// 走的都是这一条路。
func cmdPrice(args []string) error {
	fs := flag.NewFlagSet("price", flag.ExitOnError)
	var c commonFlags
	c.register(fs)
	variant := fs.Int64("variant", 0, "规范变体 id")
	date := fs.String("date", "", "日期 YYYY-MM-DD")
	channel := fs.Int64("channel", 0, "规则与可选源来自哪个渠道（0 = 默认自营渠道）")
	priceChannel := fs.Int64("price-channel", 0, "售价行写给哪个渠道（0 = 默认行，基准币种）")
	reprice := fs.Bool("reprice", false, "重算库里所有在售售价行")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if c.canonicalDB == "" {
		return fmt.Errorf("price 需要一个库（--canonical-db）")
	}
	calc := pricing.New(store.New(c.canonicalDB))

	if *reprice {
		n, err := calc.Reprice()
		if err != nil {
			return err
		}
		missing, err := calc.Unpriced()
		if err != nil {
			return err
		}
		result := map[string]any{"repriced_rows": n, "unpriced": missing}
		if c.jsonOut != "" {
			if err := writeJSON(c.jsonOut, result); err != nil {
				return err
			}
			fmt.Printf("JSON 已导出：%s\n", c.jsonOut)
			return nil
		}
		fmt.Printf("已重算 %d 行售价。\n", n)
		if len(missing) > 0 {
			fmt.Printf("以下售价行没有定价（缺源报价 / 缺上架关系 / 缺汇率快照）：\n")
			for _, m := range missing {
				fmt.Printf("  %s\n", m)
			}
			return fmt.Errorf("%d 行售价没定价", len(missing))
		}
		return nil
	}

	if *variant == 0 || *date == "" {
		return fmt.Errorf("price 需要 --variant 与 --date（或用 --reprice 重算全部）")
	}
	// 渠道专属价：上下文渠道（规则与可选源）与结算渠道是同一个渠道。
	// 只给 --price-channel 时上下文跟着走 —— 否则会拿自营渠道的源、标上别家的币种，
	// 算出一个谁也不会卖的价格。
	if *channel == 0 && *priceChannel != 0 {
		*channel = *priceChannel
	}
	var priceChannelID *int64
	if *priceChannel != 0 {
		priceChannelID = priceChannel
	}
	quote, err := calc.Quote(*variant, *date, *channel, priceChannelID)
	if err != nil {
		return err
	}
	if quote == nil {
		return fmt.Errorf("变体 %d 在 %s 没有可用的候选源（当天没报价 / 没上架 / 币种折不出来）", *variant, *date)
	}
	if c.jsonOut != "" {
		if err := writeJSON(c.jsonOut, quote); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", c.jsonOut)
		return nil
	}
	fmt.Printf("变体 %d · %s\n", quote.ProductVariantID, quote.Date)
	if quote.IsCombo {
		// 组合没有单一采纳源：成本是 Σ 成分成本 × 份数。
		// 打印「采纳源商品 0」等于说「这个商品没有供应商」。
		fmt.Printf("  组合套餐：成本 %s %s（Σ 成分单价 × 份数，逐成分明细见 rule.combo）\n",
			quote.CostPrice, quote.Currency)
	} else {
		source := "-"
		if quote.SupplierProductID != nil {
			source = strconv.FormatInt(*quote.SupplierProductID, 10)
		}
		fmt.Printf("  采纳源商品 %s（%s）\n", source, quote.SourceCurrency)
		fmt.Printf("  源净价 %s → 成本 %s %s（%s）\n",
			quote.NetPrice, quote.CostPrice, quote.Currency, fxDescription(quote))
	}
	fmt.Printf("  售价 %s%s   划线价 %s（折扣 %s%%）\n",
		quote.SellPrice, map[bool]string{true: "  [锁价]", false: ""}[quote.PriceLocked],
		quote.ListPrice, quote.DiscountPct)
	return nil
}

// cmdMigrate 执行库结构迁移。
//
// 这一条命令是「DDL 只增不改」的执行者：迁移文件应用过就不能再改，
// 改了引擎会拒绝继续跑。要改结构就加一个新的迁移文件。
func cmdMigrate(args []string) error {
	fs := flag.NewFlagSet("migrate", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	dir := fs.String("dir", "", "迁移目录（默认 <仓库根>/db/migrations）")
	statusOnly := fs.Bool("status", false, "只列状态，不执行")
	baseline := fs.String("baseline", "", "接管存量库：把该版本及之前的迁移标记为已应用")
	dryRun := fs.Bool("dry-run", false, "只算计划，不执行")
	if err := fs.Parse(args); err != nil {
		return err
	}
	name := *dbName
	if name == "" {
		name = os.Getenv("PGDATABASE")
	}
	if name == "" {
		name = "ticket_center"
	}
	migDir := *dir
	if migDir == "" {
		migDir = filepath.Join(findRoot(), "db", "migrations")
	}
	db := store.New(name)

	if *statusOnly {
		list, err := migrate.List(db, migDir)
		if err != nil {
			return err
		}
		fmt.Printf("迁移目录 %s\n账本 %s（目标库 %s）\n\n", migDir, migrate.LedgerTable, name)
		for _, s := range list {
			switch {
			case s.Drift:
				fmt.Printf("  ✗ %-28s 内容漂移：账本记的校验和与文件不一致\n", s.File.Label())
			case s.Applied:
				fmt.Printf("  ✓ %-28s 已应用 %s\n", s.File.Label(), s.AppliedAt)
			default:
				fmt.Printf("  – %-28s 待应用\n", s.File.Label())
			}
		}
		return nil
	}

	res, err := migrate.Apply(db, migrate.Options{Dir: migDir, Baseline: *baseline, DryRun: *dryRun})
	if err != nil {
		return err
	}
	for _, b := range res.Baselined {
		fmt.Printf("基线：%s（标记为已应用，未执行）\n", b)
	}
	if *dryRun {
		fmt.Println("试运行：没有改动任何东西。")
	}
	fmt.Printf("应用 %d 个，跳过 %d 个。\n", len(res.Applied), len(res.Skipped))
	return nil
}

// cmdRefresh 刷新 C 端读模型（--check 只查漂移不刷新）。
//
// 读模型的口径在库里的 fn_refresh_read_models()，这里只负责调用与报告。
func cmdRefresh(args []string) error {
	fs := flag.NewFlagSet("refresh", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	check := fs.Bool("check", false, "只查漂移，不刷新")
	if err := fs.Parse(args); err != nil {
		return err
	}
	name := *dbName
	if name == "" {
		name = os.Getenv("PGDATABASE")
	}
	if name == "" {
		name = "ticket_center"
	}
	db := store.New(name)

	if !*check {
		// 组合先同步再刷新：组合同源侧没有商品条目，目录同步作业看不见它，
		// 它的售价行与日历格子得自己推。不先推，刷新出来的 C 端就没有套餐。
		combos, err := readmodel.SyncCombos(db)
		if err != nil {
			return err
		}
		counts, err := readmodel.Refresh(db)
		if err != nil {
			return err
		}
		fmt.Printf("读模型已刷新：卡片 %d 张，变体日历格子 %d 个，变体差异事实 %d 条。\n",
			counts.CardsUpdated, counts.VariantCellsUpdated, counts.VariantFactsUpdated)
		fmt.Printf("组合同步：售价行 %d 行，日历格子 %d 个。\n", combos.PriceRows, combos.Cells)
	}

	drifts, err := readmodel.DriftRows(db)
	if err != nil {
		return err
	}
	if len(drifts) == 0 {
		fmt.Println("漂移检查：无漂移。")
		return nil
	}
	fmt.Printf("漂移检查：%d 张卡片与价格日历对不上（刷新作业漏跑了）：\n", len(drifts))
	for _, d := range drifts {
		fmt.Printf("  渠道 %d 商品 %d：卡片起价 %s，真值 %s（卡片刷新于 %s）\n",
			d.ChannelID, d.ProductID, d.CardFromPrice, d.TruthMinPrice, d.SyncedAt)
	}
	return fmt.Errorf("%d 张卡片漂移", len(drifts))
}

// fxDescription 说清这次折算用的汇率。
// 同币种时没有快照（基准币种不需要快照），说明「汇率 1（同币种）」比留个空日期清楚。
func fxDescription(q *pricing.Quote) string {
	if q.FxAsOf == "" {
		return "汇率 1（同币种）"
	}
	return "汇率 " + q.FxRate + " @ " + q.FxAsOf
}

func init() {
	register("price", "定价：调库里的唯一实现 fn_price_variant", usagePrice, cmdPrice, 50)
	register("migrate", "库结构迁移：已发布的迁移不许改", usageMigrate, cmdMigrate, 60)
	register("refresh", "刷新 C 端读模型并查漂移", usageRefresh, cmdRefresh, 70)
}

const usagePrice = `  tc-connect price      --variant id --date YYYY-MM-DD [--channel id]
                        [--price-channel id] [--canonical-db name] [--json out.json]
  tc-connect price      --reprice [--canonical-db name] [--json out.json]
`

const usageMigrate = `  tc-connect migrate    [--db name] [--dir path] [--status] [--baseline NNN] [--dry-run]
`

const usageRefresh = `  tc-connect refresh    [--db name] [--check]
`
