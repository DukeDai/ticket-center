// 库存与预占：查源场次还剩几张票，购物车占住票，放掉到期预占。
//
// 这一组命令只是把库里的 fn_available_qty / fn_reserve_qty / fn_hold_inventory
// 调起来 —— 还剩几张、够不够、要不要拦，全在库里。
package main

import (
	"flag"
	"fmt"

	"ticket-center/internal/inventory"
	"ticket-center/internal/store"
)

func init() {
	register("stock", "库存：源场次还剩几张票，由库里的唯一实现说了算", usageStock, cmdStock, 120)
	register("hold", "预占：购物车占住票，够不够由库里的唯一实现说了算", usageHold, cmdHold, 130)
}

// cmdStock 是库存子命令。show 看这个源场次还剩多少。
//
// 这一组命令只是把库里的 fn_available_qty 调起来 —— 还剩几张、是不是「不知道」，
// 全在库里。
func cmdStock(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("stock 需要子命令：show")
	}
	switch args[0] {
	case "show":
		return cmdStockShow(args[1:])
	default:
		return fmt.Errorf("stock 未知子命令：%s（可用：show）", args[0])
	}
}

func cmdStockShow(args []string) error {
	fs := flag.NewFlagSet("stock show", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	supplierSessionID := fs.Int64("supplier-session", 0, "源场次 id")
	ticketTypeID := fs.Int64("ticket-type", 0, "源票种 id（0 = 不筛）")
	sourceTicketTypeID := fs.Int64("source-ticket-type", 0, "源票种 id（套装的池子；0 = 不筛）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *supplierSessionID == 0 {
		return fmt.Errorf("stock show 需要 --supplier-session")
	}
	svc := inventory.New(store.New(fulfillDB(*dbName)))
	var av *inventory.Availability
	var err error
	if *sourceTicketTypeID != 0 {
		av, err = svc.AvailableBySourceTicketType(*supplierSessionID, *sourceTicketTypeID)
	} else {
		av, err = svc.Available(*supplierSessionID, *ticketTypeID)
	}
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, av); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if !av.Known {
		fmt.Printf("源场次 %d：源侧没有库存数据 —— 不知道还剩几张（放行但不保护）\n", *supplierSessionID)
		return nil
	}
	fmt.Printf("源场次 %d：源侧可售 %d · 已承诺 %d · 还剩 %d（源侧状态 %s，快照 %s）\n",
		*supplierSessionID, av.AvailableQty, av.CommittedQty, av.RemainingQty, av.SourceStatus, av.SnapshotAt)
	return nil
}

// cmdHold 是预占子命令。create 建预占，release 放掉，expire 放掉到期的，show 看现状。
//
// 这一组命令只是把库里的 fn_hold_inventory 调起来 —— 够不够、预占多久、该不该放，
// 全在库里。
func cmdHold(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("hold 需要子命令：create | release | expire | show")
	}
	switch args[0] {
	case "create":
		return cmdHoldCreate(args[1:])
	case "release":
		return cmdHoldRelease(args[1:])
	case "expire":
		return cmdHoldExpire(args[1:])
	case "show":
		return cmdHoldShow(args[1:])
	default:
		return fmt.Errorf("hold 未知子命令：%s（可用：create | release | expire | show）", args[0])
	}
}

func cmdHoldCreate(args []string) error {
	fs := flag.NewFlagSet("hold create", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	holdNo := fs.String("no", "", "预占单号（幂等键）")
	channelID := fs.Int64("channel", 0, "渠道 id")
	variantID := fs.Int64("variant", 0, "可售单元 id")
	qty := fs.Int64("qty", 0, "预占张数")
	visitDate := fs.String("date", "", "访客日 YYYY-MM-DD")
	cartID := fs.Int64("cart", 0, "购物车 id")
	ttl := fs.Int64("ttl", 0, "预占时长（秒；0 = 用库里默认的 900）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *holdNo == "" {
		return fmt.Errorf("hold create 需要 --no")
	}
	svc := inventory.New(store.New(fulfillDB(*dbName)))
	res, err := svc.Hold(inventory.HoldRequest{
		HoldNo:     *holdNo,
		ChannelID:  *channelID,
		VariantID:  *variantID,
		Quantity:   *qty,
		VisitDate:  *visitDate,
		CartID:     *cartID,
		TTLSeconds: *ttl,
	})
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, res); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	verb := "已预占"
	if !res.Created {
		verb = "已存在（幂等命中）"
	}
	if !res.Known {
		fmt.Printf("%s：预占 %s（id %d）· 数量 %d · 不知道还剩几张（放行但不保护）\n",
			verb, res.HoldNo, res.HoldID, *qty)
		return nil
	}
	fmt.Printf("%s：预占 %s（id %d）· 数量 %d · 还剩 %d\n",
		verb, res.HoldNo, res.HoldID, *qty, res.RemainingQty)
	return nil
}

func cmdHoldRelease(args []string) error {
	fs := flag.NewFlagSet("hold release", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	holdNo := fs.String("no", "", "预占单号")
	reason := fs.String("reason", "", "释放原因")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *holdNo == "" {
		return fmt.Errorf("hold release 需要 --no")
	}
	svc := inventory.New(store.New(fulfillDB(*dbName)))
	res, err := svc.Release(*holdNo, *reason)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, res); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if res.Released {
		fmt.Printf("预占 %s 已释放（id %d）\n", res.HoldNo, res.HoldID)
	} else {
		fmt.Printf("预占 %s 未释放（id %d）· 状态 %s\n", res.HoldNo, res.HoldID, res.Status)
	}
	return nil
}

func cmdHoldExpire(args []string) error {
	fs := flag.NewFlagSet("hold expire", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	limit := fs.Int64("limit", 0, "单次最多放掉几张（0 表示用默认 500）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	svc := inventory.New(store.New(fulfillDB(*dbName)))
	n, err := svc.Expire(*limit)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, map[string]int64{"expired_count": n}); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	fmt.Printf("放掉到期预占 %d 张\n", n)
	return nil
}

func cmdHoldShow(args []string) error {
	fs := flag.NewFlagSet("hold show", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	holdNo := fs.String("no", "", "预占单号")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *holdNo == "" {
		return fmt.Errorf("hold show 需要 --no")
	}
	svc := inventory.New(store.New(fulfillDB(*dbName)))
	st, err := svc.Show(*holdNo)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, st); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	fmt.Printf("预占 %s（id %d）· 状态 %s · 数量 %d · 已兑现 %d\n",
		st.HoldNo, st.HoldID, st.Status, st.Quantity, st.Consumed)
	fmt.Printf("  渠道 %d · 变体 %d · 规范场次 %d · 源场次 %d\n",
		st.ChannelID, st.VariantID, st.SessionID, st.SupSession)
	if st.OrderID != 0 {
		fmt.Printf("  已兑现给订单 %d\n", st.OrderID)
	}
	if st.CartID != 0 || st.ExpiresAt != "" {
		fmt.Printf("  购物车 %d · 到期 %s\n", st.CartID, st.ExpiresAt)
	}
	if st.ReleasedAt != "" {
		line := fmt.Sprintf("  释放于 %s", st.ReleasedAt)
		if st.ReleaseWhy != "" {
			line += " · 原因 " + st.ReleaseWhy
		}
		fmt.Println(line)
	}
	return nil
}

const usageStock = `  tc-connect stock      show     --db name --supplier-session 5 [--ticket-type 1]
                                  [--source-ticket-type 15]
                                  [--json out.json]
`

const usageHold = `  tc-connect hold       create   --db name --no HOLD001 --channel 1 --variant 11
                                  --qty 2 --date YYYY-MM-DD [--cart 3] [--ttl 900]
                                  [--json out.json]
                                  （--date 取「当天有售价」的日期：先跑 variant feed 看；
                                    种子的日期是 current_date+N，写死的日期会失效）
  tc-connect hold       release  --db name --no HOLD001 [--reason cart_abandoned]
                                  [--json out.json]
  tc-connect hold       expire   --db name [--limit 500] [--json out.json]
  tc-connect hold       show     --db name --no HOLD001 [--json out.json]
`
