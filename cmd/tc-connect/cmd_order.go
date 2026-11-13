// 下单与查单：place 下单，show 查单，reassign 改派，stale 看该改派的明细。
//
// 这一组命令只拼参数、只读结果：
// 金额与选源全在库里的 fn_place_order / fn_reassign_order_item 里，
// 这里不重算钱、不重排源。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"ticket-center/internal/order"
	"ticket-center/internal/reassign"
	"ticket-center/internal/store"
)

func init() {
	register("order", "下单与查单：金额与选源都走库里的唯一实现", usageOrder, cmdOrder, 80)
}

// cmdOrder 是下单子命令。place 下单，show 查单，reassign 改派，stale 看该改派的明细。
//
// 请求走文件（--request）：下单的入参结构本身是领域对象（明细 + 实名 + 联系信息），
// 摊成一排命令行参数反而更容易拼错。文件格式见 usage。
func cmdOrder(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("order 需要子命令：place | show | reassign | stale")
	}
	switch args[0] {
	case "place":
		return cmdOrderPlace(args[1:])
	case "show":
		return cmdOrderShow(args[1:])
	case "reassign":
		return cmdOrderReassign(args[1:])
	case "stale":
		return cmdOrderStale(args[1:])
	default:
		return fmt.Errorf("order 未知子命令：%s（可用：place | show | reassign | stale）", args[0])
	}
}

func cmdOrderPlace(args []string) error {
	fs := flag.NewFlagSet("order place", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	reqPath := fs.String("request", "", "下单请求 JSON 文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *reqPath == "" {
		return fmt.Errorf("order place 需要 --request <req.json>")
	}
	name := *dbName
	if name == "" {
		name = os.Getenv("PGDATABASE")
	}
	if name == "" {
		name = "ticket_center"
	}

	blob, err := os.ReadFile(*reqPath)
	if err != nil {
		return fmt.Errorf("读请求文件失败：%w", err)
	}
	var req order.Request
	if err := json.Unmarshal(blob, &req); err != nil {
		return fmt.Errorf("请求文件不是合法的下单请求：%w", err)
	}

	svc := order.New(store.New(name))
	o, err := svc.Place(req)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, o); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	if o.Created {
		fmt.Printf("已下单：%s（订单 %d），状态 %s，金额 %s %s\n",
			o.No, o.ID, o.Status, o.Total, o.Currency)
	} else {
		fmt.Printf("幂等命中：返回已存在的订单 %s（订单 %d），状态 %s，金额 %s %s\n",
			o.No, o.ID, o.Status, o.Total, o.Currency)
	}
	return nil
}

func cmdOrderShow(args []string) error {
	fs := flag.NewFlagSet("order show", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	id := fs.Int64("id", 0, "订单 id")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *id == 0 {
		return fmt.Errorf("order show 需要 --id")
	}
	name := *dbName
	if name == "" {
		name = os.Getenv("PGDATABASE")
	}
	if name == "" {
		name = "ticket_center"
	}

	svc := order.New(store.New(name))
	d, err := svc.Show(*id)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, d); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	fmt.Printf("订单 %s（id %d）· 状态 %s · 合计 %s %s · 小计 %s\n",
		d.Order.No, d.Order.ID, d.Order.Status, d.Order.Total, d.Order.Currency, d.Order.Subtotal)
	for _, it := range d.Items {
		fmt.Printf("  %s ×%d  单价 %s  小计 %s %s  源商品 %d  访客日 %s  %s\n",
			it.Title, it.Quantity, it.UnitPrice, it.TotalPrice, it.Currency,
			it.CostSourceProdID, it.VisitDate, it.PricingBasis)
	}
	return nil
}

// cmdOrderReassign 改派一条明细：重新选源 + 重新定价。
//
// 能不能改派、改成什么，全由库里的 fn_reassign_order_item 说了算 ——
// 这里只把订单号、明细行号和理由送进去。
func cmdOrderReassign(args []string) error {
	fs := flag.NewFlagSet("order reassign", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	orderID := fs.Int64("order", 0, "订单 id")
	itemID := fs.Int64("item", 0, "明细行 id")
	reason := fs.String("reason", "", "改派理由（写进留痕）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *orderID == 0 {
		return fmt.Errorf("order reassign 需要 --order")
	}
	if *itemID == 0 {
		return fmt.Errorf("order reassign 需要 --item")
	}
	name := *dbName
	if name == "" {
		name = os.Getenv("PGDATABASE")
	}
	if name == "" {
		name = "ticket_center"
	}

	svc := reassign.New(store.New(name))
	res, err := svc.Reassign(*orderID, *itemID, *reason)
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
	if res.Outcome == "no_change" {
		fmt.Printf("明细 %d 不用改：当前的源与价已经是对的那个（源商品 %d，单价 %s %s）\n",
			res.OrderItemID, res.NewSupplierProductID, res.NewUnitPrice, res.Currency)
		return nil
	}
	fmt.Printf("已改派明细 %d：源商品 %d → %d，单价 %s → %s，小计 %s → %s %s\n",
		res.OrderItemID,
		res.PreviousSupplierProductID, res.NewSupplierProductID,
		res.PreviousUnitPrice, res.NewUnitPrice,
		res.PreviousTotalPrice, res.NewTotalPrice, res.Currency)
	return nil
}

// cmdOrderStale 列出待改派的明细：跟当前的世界对不上的那些行。
func cmdOrderStale(args []string) error {
	fs := flag.NewFlagSet("order stale", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库（默认取 PGDATABASE，再默认 ticket_center）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
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

	svc := reassign.New(store.New(name))
	rows, err := svc.Candidates()
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
		fmt.Println("没有待改派的明细")
		return nil
	}
	for _, c := range rows {
		fmt.Printf("订单 %s（%d）明细 %d · 访客日 %s · 源 %s(%d) → %s(%d) · 单价 %s → %s · %s\n",
			c.OrderNo, c.OrderID, c.OrderItemID, c.VisitDate,
			c.CurrentSupplier, c.CurrentSupplierProductID,
			c.NewSupplier, c.NewSupplierProductID,
			c.CurrentUnitPrice, c.NewUnitPrice, c.StaleReason)
	}
	return nil
}

const usageOrder = `  tc-connect order      place --db name --request req.json [--json out.json]
  tc-connect order      show  --db name --id 7 [--json out.json]
  tc-connect order      reassign --db name --order 7 --item 3 [--reason "源侧下架"] [--json out.json]
  tc-connect order      stale --db name [--json out.json]
`
