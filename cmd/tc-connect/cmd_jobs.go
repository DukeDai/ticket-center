// 作业调度：一次跑完库里那几个批处理作业。
//
// 为什么要有这条命令：作业在库里（fn_expire_vouchers / fn_expire_holds /
// fn_refresh_read_models），但没有人调它，作业就只是库里一个没人跑函数 ——
// 「券过期了由作业统一改」这句话就落空了。所以这里给作业一个入口。
//
// 这条命令是一次性的，跑完就退出，不常驻、不自己排期。
// 多久跑一次是运维的决定，代码里不写死 —— 写死就成了第二份口径，
// 改的时候要改两处，而且改漏一处没人知道。
// 把它交给系统 cron 或 k8s CronJob：
//
//	*/5 * * * * cd /srv/ticket-center && ./bin/tc-connect jobs --db ticket_center
//
// 失败重试也交给调度器：命令失败时非零退出，调度器按自己的策略重试。
// 作业本身是幂等的，重跑一遍不会多改什么 —— 幂等靠的是
// 「UPDATE ... WHERE status = 'issued'」这个形状，不是靠调度器的自觉。
//
// 这条命令不重算任何业务结论：判据全在库里，Go 侧只拼参数、只读结果。
//
// **目录同步是它的一个分支**（`--sync`）：同步作业要连外部源、要凭证，
// 纯库内维护的作业不该依赖它。两者分开走各自的 cron 行，
// 但入口只有这一条命令（spec §5.27）。
package main

import (
	"flag"
	"fmt"
	"time"

	"ticket-center/internal/inventory"
	"ticket-center/internal/readmodel"
	"ticket-center/internal/redemption"
	"ticket-center/internal/store"
)

// cmdJobs 跑一遍批处理作业，并做读侧自检。
//
// 失败分两种，处理方式不一样：
//
//   - 作业报错 / 读模型漂移 → 非零退出。漂移是硬事实：我们刚刷新过，
//     刷新完还对不上，说明有东西不对，必须让人看见。
//   - 仍有券停在 issued（到期却没改）→ 只报告，不失败。
//     这可能是本批的余量（到期券比 --limit 多），也可能是漏跑；
//     漏跑是运行状态，不是数据违规 —— 硬约束 38 说的是
//     「看得见但不挡门禁」。让这一项挡住调度，会把一条告警变成一个死循环。
func cmdJobs(args []string) error {
	fs := flag.NewFlagSet("jobs", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	limit := fs.Int64("limit", 500, "每个批处理作业的单批上限")
	doSync := fs.Bool("sync", false, "顺带跑目录同步作业（要连外部源、要凭证）")
	syncSupplier := fs.String("sync-supplier", "", "只同步某个源（默认同步配置里已确认的源）")
	syncEnv := fs.String("sync-env", "sandbox", "同步的源侧环境：sandbox | prod")
	syncTimeout := fs.Duration("sync-timeout", 20*time.Second, "同步作业里单次请求的超时")
	syncStart := fs.String("sync-start", "", "同步的价格日历起始日期（默认今天）")
	syncEnd := fs.String("sync-end", "", "同步的价格日历结束日期（默认起始日 +7 天）")
	if err := fs.Parse(args); err != nil {
		return err
	}
	db := store.New(fulfillDB(*dbName))

	// 目录同步先跑：它落的是源层事实（源商品 / 源变体 / 源报价行 / 映射），
	// 而读模型刷新读的就是这些表（fn_refresh_read_models 走
	// supplier_price_calendar ⋈ supplier_variant_mapping）。
	// 同步排在刷新之后的话，本次落下的事实要等到下一轮 cron 才出现在 C 端卡片上 ——
	// 看着像「同步了但没生效」。
	if *doSync {
		if err := runSyncBranch(db, syncFlags{
			supplier: *syncSupplier,
			env:      *syncEnv,
			timeout:  *syncTimeout,
			start:    *syncStart,
			end:      *syncEnd,
		}); err != nil {
			return err
		}
	}

	expired, err := redemption.New(db).ExpireOverdue(*limit)
	if err != nil {
		return fmt.Errorf("凭证过期作业失败：%w", err)
	}
	fmt.Printf("凭证过期作业：%d 张券改成 expired。\n", expired)

	holds, err := inventory.New(db).Expire(*limit)
	if err != nil {
		return fmt.Errorf("预占过期作业失败：%w", err)
	}
	fmt.Printf("预占过期作业：%d 条预占放掉。\n", holds)

	// 组合先同步再刷新：组合同源侧没有商品条目，目录同步作业看不见它，
	// 它的售价行与日历格子得自己推（与 cmdRefresh 同一口径、同一顺序）。
	combos, err := readmodel.SyncCombos(db)
	if err != nil {
		return fmt.Errorf("组合同步失败：%w", err)
	}
	counts, err := readmodel.Refresh(db)
	if err != nil {
		return fmt.Errorf("读模型刷新失败：%w", err)
	}
	fmt.Printf("读模型已刷新：卡片 %d 张，变体日历格子 %d 个，变体差异事实 %d 条。\n",
		counts.CardsUpdated, counts.VariantCellsUpdated, counts.VariantFactsUpdated)
	fmt.Printf("组合同步：售价行 %d 行，日历格子 %d 个。\n", combos.PriceRows, combos.Cells)

	drifts, err := readmodel.DriftRows(db)
	if err != nil {
		return fmt.Errorf("漂移检查失败：%w", err)
	}
	if len(drifts) > 0 {
		fmt.Printf("漂移检查：%d 张卡片与价格日历对不上：\n", len(drifts))
		for _, d := range drifts {
			fmt.Printf("  渠道 %d 商品 %d：卡片起价 %s，真值 %s（卡片刷新于 %s）\n",
				d.ChannelID, d.ProductID, d.CardFromPrice, d.TruthMinPrice, d.SyncedAt)
		}
		return fmt.Errorf("%d 张卡片漂移", len(drifts))
	}
	fmt.Println("漂移检查：无漂移。")

	overdue, err := redemption.New(db).ShowOverdue()
	if err != nil {
		return fmt.Errorf("读过期现状失败：%w", err)
	}
	if overdue.OverdueCount > 0 {
		fmt.Printf("仍有 %d 张券到期却还停在 issued（涉及 %d 张订单，最早 %s）：",
			overdue.OverdueCount, overdue.AffectedOrders, overdue.OldestValidTo)
		fmt.Println("本批上限到了就是余量，下一轮会接着改；一直不变就是作业没跑。")
	}
	return nil
}

func init() {
	register("jobs", "跑一遍批处理作业（过期 / 预占 / 读模型；--sync 顺带跑目录同步），交给外部调度器按 cron 调",
		usageJobs, cmdJobs, 160)
}

const usageJobs = `  tc-connect jobs       [--db name] [--limit n] [--sync] [--sync-supplier code]
`
