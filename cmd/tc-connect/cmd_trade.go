// 交易侧的子命令：下单、履约、退款、核销、库存与预占。
//
// 这一组命令只拼参数、只读结果：
// 状态往哪走、金额是多少、能不能进场，全在库里的唯一实现里。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"ticket-center/internal/fulfillment"
	"ticket-center/internal/inventory"
	"ticket-center/internal/order"
	"ticket-center/internal/reassign"
	"ticket-center/internal/redemption"
	"ticket-center/internal/refund"
	"ticket-center/internal/store"
)

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

// ---------------------------------------------------------------- 履约

// cmdFulfill 是履约子命令。pay 支付入账，book 建预订，request 发起预订，
// attempt 归档尝试，complete 落源侧结果，issue 出券，retry 失败重报，show 看全景。
//
// 这一组命令只是把库里的 fn_record_payment / fn_create_bookings / …
// 调起来 —— 状态往哪走、订单履约状态怎么算，全在库里。
func cmdFulfill(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("fulfill 需要子命令：pay | book | request | attempt | complete | issue | retry | show")
	}
	switch args[0] {
	case "pay":
		return cmdFulfillPay(args[1:])
	case "book":
		return cmdFulfillBook(args[1:])
	case "request":
		return cmdFulfillRequest(args[1:])
	case "attempt":
		return cmdFulfillAttempt(args[1:])
	case "complete":
		return cmdFulfillComplete(args[1:])
	case "issue":
		return cmdFulfillIssue(args[1:])
	case "retry":
		return cmdFulfillRetry(args[1:])
	case "show":
		return cmdFulfillShow(args[1:])
	default:
		return fmt.Errorf("fulfill 未知子命令：%s（可用：pay | book | request | attempt | complete | issue | retry | show）", args[0])
	}
}

func cmdFulfillPay(args []string) error {
	fs := flag.NewFlagSet("fulfill pay", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	orderID := fs.Int64("order", 0, "订单 id")
	method := fs.String("method", "", "支付方式（alipay / wechat / card …）")
	amount := fs.String("amount", "", "实付金额（十进制文本，必须等于订单应付）")
	currency := fs.String("currency", "", "支付币种（必须等于订单币种）")
	provider := fs.String("provider", "", "支付渠道（与 --txn 一起构成幂等键）")
	txn := fs.String("txn", "", "渠道流水号（幂等键）")
	payload := fs.String("payload", "", "渠道回调原文 JSON 文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *orderID == 0 {
		return fmt.Errorf("fulfill pay 需要 --order")
	}
	raw, err := readJSONFile(*payload)
	if err != nil {
		return err
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	res, err := svc.RecordPayment(fulfillment.PaymentRequest{
		OrderID:       *orderID,
		Method:        *method,
		Amount:        *amount,
		Currency:      *currency,
		Provider:      *provider,
		ProviderTxnID: *txn,
		RawPayload:    raw,
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
	if res.Paid {
		fmt.Printf("已记账：订单 %d 状态 %s（支付记录 %d）\n", res.OrderID, res.OrderStatus, res.PaymentID)
	} else {
		fmt.Printf("幂等命中：订单 %d 状态 %s（支付记录 %d，本次未新记）\n",
			res.OrderID, res.OrderStatus, res.PaymentID)
	}
	return nil
}

func cmdFulfillBook(args []string) error {
	fs := flag.NewFlagSet("fulfill book", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	orderID := fs.Int64("order", 0, "订单 id")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *orderID == 0 {
		return fmt.Errorf("fulfill book 需要 --order")
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	bookings, err := svc.CreateBookings(*orderID)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, bookings); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	for _, b := range bookings {
		mark := "新建"
		if !b.Created {
			mark = "已存在"
		}
		fmt.Printf("预订 %s（id %d）· 明细 %d · %s\n", b.BookingNo, b.BookingID, b.OrderItemID, mark)
	}
	if len(bookings) == 0 {
		fmt.Printf("订单 %d 没有需要建预订的明细。\n", *orderID)
	}
	return nil
}

func cmdFulfillRequest(args []string) error {
	fs := flag.NewFlagSet("fulfill request", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	bookingID := fs.Int64("booking", 0, "预订 id")
	payload := fs.String("request", "", "发往源侧的请求体 JSON 文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bookingID == 0 {
		return fmt.Errorf("fulfill request 需要 --booking")
	}
	raw, err := readJSONFile(*payload)
	if err != nil {
		return err
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	res, err := svc.RequestBooking(*bookingID, raw)
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
	fmt.Printf("已发起：预订 %s（id %d）状态 %s，第 %d 次尝试\n",
		res.BookingNo, res.BookingID, res.Status, res.AttemptNo)
	return nil
}

func cmdFulfillAttempt(args []string) error {
	fs := flag.NewFlagSet("fulfill attempt", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	bookingID := fs.Int64("booking", 0, "预订 id")
	reqFile := fs.String("request", "", "请求体 JSON 文件")
	respFile := fs.String("response", "", "响应体 JSON 文件")
	httpStatus := fs.Int("http-status", 0, "源侧 HTTP 状态码")
	latencyMS := fs.Int("latency-ms", 0, "本次调用耗时（毫秒）")
	errType := fs.String("error-type", "", "错误分类：retriable / fatal / auth / rate_limit / timeout")
	errMessage := fs.String("error-message", "", "错误信息")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bookingID == 0 {
		return fmt.Errorf("fulfill attempt 需要 --booking")
	}
	req, err := readJSONFile(*reqFile)
	if err != nil {
		return err
	}
	resp, err := readJSONFile(*respFile)
	if err != nil {
		return err
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	res, err := svc.RecordAttempt(fulfillment.AttemptRequest{
		BookingID:    *bookingID,
		Request:      req,
		Response:     resp,
		HTTPStatus:   *httpStatus,
		LatencyMS:    *latencyMS,
		ErrorType:    *errType,
		ErrorMessage: *errMessage,
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
	fmt.Printf("已归档：预订 %d 第 %d 次尝试（记录 %d）\n", *bookingID, res.AttemptNo, res.AttemptID)
	return nil
}

func cmdFulfillComplete(args []string) error {
	fs := flag.NewFlagSet("fulfill complete", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	bookingID := fs.Int64("booking", 0, "预订 id")
	status := fs.String("status", "", "源侧结果：confirmed / failed / cancelled")
	externalID := fs.String("external-booking-id", "", "源侧预订号")
	respFile := fs.String("response", "", "源侧响应 JSON 文件")
	errCode := fs.String("error-code", "", "源侧错误码")
	errMessage := fs.String("error-message", "", "源侧错误信息")
	var codes stringList
	fs.Var(&codes, "code", "票码（可重复；按持票人序号升序）")
	noVoucher := fs.Bool("no-voucher", false, "只落确认不出券（源先确认、票后到）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bookingID == 0 {
		return fmt.Errorf("fulfill complete 需要 --booking")
	}
	resp, err := readJSONFile(*respFile)
	if err != nil {
		return err
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	res, err := svc.CompleteBooking(fulfillment.CompleteRequest{
		BookingID:         *bookingID,
		Status:            *status,
		ExternalBookingID: *externalID,
		Response:          resp,
		ErrorCode:         *errCode,
		ErrorMessage:      *errMessage,
		Codes:             codes,
		IssueVoucher:      !*noVoucher,
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
	fmt.Printf("预订 %s（id %d）→ %s，发券 %d 张，订单状态 %s\n",
		res.BookingNo, res.BookingID, res.Status, res.VoucherCount, res.OrderStatus)
	return nil
}

func cmdFulfillIssue(args []string) error {
	fs := flag.NewFlagSet("fulfill issue", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	bookingID := fs.Int64("booking", 0, "预订 id")
	var codes stringList
	fs.Var(&codes, "code", "票码（可重复；按持票人序号升序）")
	payload := fs.String("payload", "", "出券原文 JSON 文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bookingID == 0 {
		return fmt.Errorf("fulfill issue 需要 --booking")
	}
	raw, err := readJSONFile(*payload)
	if err != nil {
		return err
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	vouchers, err := svc.IssueVoucher(*bookingID, codes, raw)
	if err != nil {
		return err
	}
	if *jsonOut != "" {
		if err := writeJSON(*jsonOut, vouchers); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", *jsonOut)
		return nil
	}
	for _, v := range vouchers {
		mark := "新发"
		if !v.Created {
			mark = "已存在"
		}
		fmt.Printf("券 %s（id %d）· 票码 %s · 持票人序号 %d · %s\n",
			v.VoucherNo, v.VoucherID, v.Code, v.HolderSequence, mark)
	}
	return nil
}

func cmdFulfillRetry(args []string) error {
	fs := flag.NewFlagSet("fulfill retry", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	bookingID := fs.Int64("booking", 0, "预订 id")
	nextAt := fs.String("next-retry-at", "", "下次重试时间（RFC3339，留空 = 立即可重试）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bookingID == 0 {
		return fmt.Errorf("fulfill retry 需要 --booking")
	}
	var at *time.Time
	if *nextAt != "" {
		t, err := time.Parse(time.RFC3339, *nextAt)
		if err != nil {
			return fmt.Errorf("下次重试时间不是 RFC3339：%w", err)
		}
		at = &t
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	res, err := svc.RetryBooking(*bookingID, at)
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
	fmt.Printf("预订 %s（id %d）已回到 %s\n", res.BookingNo, res.BookingID, res.Status)
	return nil
}

func cmdFulfillShow(args []string) error {
	fs := flag.NewFlagSet("fulfill show", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	orderID := fs.Int64("order", 0, "订单 id")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *orderID == 0 {
		return fmt.Errorf("fulfill show 需要 --order")
	}
	svc := fulfillment.New(store.New(fulfillDB(*dbName)))
	st, err := svc.Show(*orderID)
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
	fmt.Printf("订单 %s（id %d）· 状态 %s · 支付 %s · 履约 %s · 合计 %s %s\n",
		st.OrderNo, st.OrderID, st.Status, st.PaymentStatus, st.FulfillmentStatus, st.Total, st.Currency)
	for _, it := range st.Items {
		fmt.Printf("  明细 %d · %s ×%d · 状态 %s · 已出 %d 份\n",
			it.ItemID, it.Title, it.Quantity, it.Status, it.DeliveredQty)
	}
	for _, b := range st.Bookings {
		fmt.Printf("  预订 %s（id %d）· 状态 %s · 尝试 %d 次%s\n",
			b.BookingNo, b.BookingID, b.Status, b.AttemptCount, errorSuffix(b))
	}
	for _, v := range st.Vouchers {
		fmt.Printf("  券 %s · 票码 %s · 状态 %s\n", v.VoucherNo, v.Code, v.Status)
	}
	return nil
}

// errorSuffix 拼上失败原因（有才拼）。
func errorSuffix(b fulfillment.BookingState) string {
	if b.ErrorCode == "" && b.ErrorMessage == "" {
		return ""
	}
	if b.ErrorMessage == "" {
		return " · " + b.ErrorCode
	}
	if b.ErrorCode == "" {
		return " · " + b.ErrorMessage
	}
	return " · " + b.ErrorCode + " " + b.ErrorMessage
}

// ---------------------------------------------------------------- 退款

// cmdRefund 是退款子命令。request 发起，approve 放行，complete 落结果，show 看现状。
//
// 这一组命令只是把库里的 fn_request_refund / fn_approve_refund / fn_complete_refund
// 调起来 —— 能不能退、退多少、订单状态怎么改，全在库里。
func cmdRefund(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("refund 需要子命令：request | approve | complete | show")
	}
	switch args[0] {
	case "request":
		return cmdRefundRequest(args[1:])
	case "approve":
		return cmdRefundApprove(args[1:])
	case "complete":
		return cmdRefundComplete(args[1:])
	case "show":
		return cmdRefundShow(args[1:])
	default:
		return fmt.Errorf("refund 未知子命令：%s（可用：request | approve | complete | show）", args[0])
	}
}

func cmdRefundRequest(args []string) error {
	fs := flag.NewFlagSet("refund request", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	orderID := fs.Int64("order", 0, "订单 id")
	amount := fs.String("amount", "", "退款金额（十进制文本，必须等于订单实付）")
	key := fs.String("key", "", "幂等键（必填；重放一次就多退一次钱）")
	reason := fs.String("reason", "", "退款原因")
	by := fs.String("by", "", "发起人")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *orderID == 0 {
		return fmt.Errorf("refund request 需要 --order")
	}
	svc := refund.New(store.New(fulfillDB(*dbName)))
	res, err := svc.RequestRefund(refund.Request{
		OrderID:        *orderID,
		Amount:         *amount,
		Reason:         *reason,
		RequestedBy:    *by,
		IdempotencyKey: *key,
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
	if res.Requested {
		fmt.Printf("已发起退款：%s（id %d）· 订单 %s · 金额 %s · 订单状态 %s\n",
			res.RefundNo, res.RefundID, res.OrderNo, *amount, res.OrderStatus)
	} else {
		fmt.Printf("幂等命中：%s（id %d）· 订单 %s · 订单状态 %s（本次未新发起）\n",
			res.RefundNo, res.RefundID, res.OrderNo, res.OrderStatus)
	}
	return nil
}

func cmdRefundApprove(args []string) error {
	fs := flag.NewFlagSet("refund approve", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	refundID := fs.Int64("refund", 0, "退款单 id")
	by := fs.String("by", "", "放行人")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *refundID == 0 {
		return fmt.Errorf("refund approve 需要 --refund")
	}
	svc := refund.New(store.New(fulfillDB(*dbName)))
	res, err := svc.ApproveRefund(*refundID, *by)
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
	fmt.Printf("退款单 %s（id %d）→ %s · 订单状态 %s（钱还没回来）\n",
		res.RefundNo, res.RefundID, res.RefundStatus, res.OrderStatus)
	return nil
}

func cmdRefundComplete(args []string) error {
	fs := flag.NewFlagSet("refund complete", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	refundID := fs.Int64("refund", 0, "退款单 id")
	success := fs.Bool("success", false, "退款成功")
	fail := fs.Bool("fail", false, "退款失败")
	supplierRefundID := fs.String("supplier-refund-id", "", "源侧/渠道侧退款流水号")
	errCode := fs.String("error-code", "", "错误码")
	errMessage := fs.String("error-message", "", "错误信息")
	payload := fs.String("payload", "", "渠道回调原文 JSON 文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *refundID == 0 {
		return fmt.Errorf("refund complete 需要 --refund")
	}
	if *success == *fail {
		return fmt.Errorf("refund complete 需要明确给出 --success 或 --fail")
	}
	raw, err := readJSONFile(*payload)
	if err != nil {
		return err
	}
	svc := refund.New(store.New(fulfillDB(*dbName)))
	res, err := svc.CompleteRefund(refund.CompleteRequest{
		RefundID:         *refundID,
		Success:          *success,
		SupplierRefundID: *supplierRefundID,
		ErrorCode:        *errCode,
		ErrorMessage:     *errMessage,
		RawPayload:       raw,
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
	fmt.Printf("退款单 %s（id %d）→ %s · 订单 %s · 状态 %s · 支付 %s · 履约 %s\n",
		res.RefundNo, res.RefundID, res.RefundStatus, res.OrderNo,
		res.OrderStatus, res.OrderPaymentStatus, res.OrderFulfillmentStatus)
	return nil
}

func cmdRefundShow(args []string) error {
	fs := flag.NewFlagSet("refund show", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	refundID := fs.Int64("refund", 0, "退款单 id")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *refundID == 0 {
		return fmt.Errorf("refund show 需要 --refund")
	}
	svc := refund.New(store.New(fulfillDB(*dbName)))
	st, err := svc.Show(*refundID)
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
	fmt.Printf("退款单 %s（id %d）· 订单 %s · 金额 %s %s · 状态 %s\n",
		st.RefundNo, st.RefundID, st.OrderNo, st.Amount, st.Currency, st.Status)
	if st.PreviousOrderStatus != "" {
		fmt.Printf("  退款前订单状态 %s\n", st.PreviousOrderStatus)
	}
	if st.ErrorCode != "" || st.ErrorMessage != "" {
		fmt.Printf("  失败原因 %s %s\n", st.ErrorCode, st.ErrorMessage)
	}
	return nil
}

// cmdRedeem 是核销子命令。scan 扫一次票，show 看这张券和它的核销流水，
// expire 跑过期作业，overdue 看过期作业漏跑了没有。
//
// 这一组命令只是把库里的 fn_redeem_voucher / fn_expire_vouchers 调起来 ——
// 能不能进场、扣多少额度、券状态怎么改，全在库里。
func cmdRedeem(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("redeem 需要子命令：scan | show | expire | overdue")
	}
	switch args[0] {
	case "scan":
		return cmdRedeemScan(args[1:])
	case "show":
		return cmdRedeemShow(args[1:])
	case "expire":
		return cmdRedeemExpire(args[1:])
	case "overdue":
		return cmdRedeemOverdue(args[1:])
	default:
		return fmt.Errorf("redeem 未知子命令：%s（可用：scan | show | expire | overdue）", args[0])
	}
}

func cmdRedeemScan(args []string) error {
	fs := flag.NewFlagSet("redeem scan", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	code := fs.String("code", "", "票码（闸机扫的那个）")
	voucherID := fs.Int64("voucher", 0, "凭证 id（后台补录用）")
	gateID := fs.Int64("gate", 0, "闸机 id")
	gateOperatorID := fs.Int64("gate-operator", 0, "闸机操作员 id")
	deviceID := fs.String("device", "", "扫票设备编号")
	operatorID := fs.String("operator", "", "操作员标识")
	payload := fs.String("payload", "", "扫票原文 JSON 文件")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *code == "" && *voucherID == 0 {
		return fmt.Errorf("redeem scan 需要 --code 或 --voucher")
	}
	raw, err := readJSONFile(*payload)
	if err != nil {
		return err
	}
	svc := redemption.New(store.New(fulfillDB(*dbName)))
	res, err := svc.Redeem(redemption.Request{
		VoucherID:      *voucherID,
		Code:           *code,
		GateID:         *gateID,
		GateOperatorID: *gateOperatorID,
		DeviceID:       *deviceID,
		OperatorID:     *operatorID,
		RawPayload:     raw,
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
	switch res.Result {
	case "success":
		fmt.Printf("核销成功：凭证 %s（id %d）→ %s · 消耗额度 %d\n",
			res.VoucherNo, res.VoucherID, res.VoucherStatus, res.ConsumedQuantity)
	case "duplicate":
		fmt.Printf("重复扫票：凭证 %s（id %d）已核销 · 首次核销记录 %d（%s）\n",
			res.VoucherNo, res.VoucherID, res.OriginalRedemptionID, res.OriginalScannedAt)
	case "expired", "revoked", "failed":
		fmt.Printf("未通过：凭证 %s（id %d）→ %s · 原因 %s\n",
			res.VoucherNo, res.VoucherID, res.Result, res.Reason)
	default:
		fmt.Printf("核销结果 %s：凭证 %s（id %d）→ %s\n",
			res.Result, res.VoucherNo, res.VoucherID, res.VoucherStatus)
	}
	return nil
}

func cmdRedeemShow(args []string) error {
	fs := flag.NewFlagSet("redeem show", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	voucherID := fs.Int64("voucher", 0, "凭证 id")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *voucherID == 0 {
		return fmt.Errorf("redeem show 需要 --voucher")
	}
	svc := redemption.New(store.New(fulfillDB(*dbName)))
	st, err := svc.Show(*voucherID)
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
	fmt.Printf("凭证 %s（id %d）· 状态 %s · 有效期 %s ~ %s\n",
		st.VoucherNo, st.VoucherID, st.Status, st.ValidFrom, st.ValidTo)
	if st.UsedAt != "" {
		fmt.Printf("  核销于 %s · 销售渠道 %s\n", st.UsedAt, st.UsedChannel)
	}
	for _, a := range st.Attempts {
		line := fmt.Sprintf("  %s %s · 消耗 %d", a.ScannedAt, a.Result, a.ConsumedQuantity)
		if a.Reason != "" {
			line += " · 原因 " + a.Reason
		}
		if a.GateLocation != "" {
			line += " · " + a.GateLocation
		}
		fmt.Println(line)
	}
	return nil
}

// cmdRedeemExpire 跑凭证过期作业。
//
// 核销路径只落核销记录、不改券状态 —— 券什么时候过期由这个作业统一判。
// 跑多少次都一样（幂等）：到期且仍是 issued 的券才会被改掉。
func cmdRedeemExpire(args []string) error {
	fs := flag.NewFlagSet("redeem expire", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	limit := fs.Int64("limit", 0, "单次最多过期几张（0 表示用默认 500）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	svc := redemption.New(store.New(fulfillDB(*dbName)))
	n, err := svc.ExpireOverdue(*limit)
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
	fmt.Printf("过期凭证 %d 张\n", n)
	return nil
}

// cmdRedeemOverdue 看过期作业漏跑了没有。
//
// 到期却还是 issued 的券，说明作业没跑 —— 券的状态还停在「已发出」，
// 运营侧看到的是一张还能用的票。
func cmdRedeemOverdue(args []string) error {
	fs := flag.NewFlagSet("redeem overdue", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
	}
	svc := redemption.New(store.New(fulfillDB(*dbName)))
	st, err := svc.ShowOverdue()
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
	if st.OverdueCount == 0 {
		fmt.Println("没有到期的凭证 —— 过期作业是跟上的")
		return nil
	}
	fmt.Printf("到期但状态还是 issued 的凭证 %d 张 · 分布在 %d 张订单上\n",
		st.OverdueCount, st.AffectedOrders)
	if st.OldestValidTo != "" {
		fmt.Printf("  最早到期 %s · 最晚到期 %s\n", st.OldestValidTo, st.NewestValidTo)
	}
	fmt.Println("  跑 `tc-connect redeem expire` 处理")
	return nil
}

// ---------------------------------------------------------------- 库存与预占

// cmdStock 是库存子命令。show 看一个源场次上还剩几张票。
//
// 「还剩几张」是业务口径，在库里的 fn_available_qty。这里只报事实，
// 特别要说清「知道不知道」：源侧没有库存数据时我们不知道还剩几张，
// 这时候报出去的数字是没有意义的。
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
	supplierSessionID := fs.Int64("supplier-session", 0, "源侧场次 id")
	ticketTypeID := fs.Int64("ticket-type", 0, "票种 id（0 表示不按票种过滤）")
	sourceTicketTypeID := fs.Int64("source-ticket-type", 0, "源票种 id（套装的池子按这个查；0 表示不按源票种查）")
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
		// 套装：池子是以套计的源票种，按源票种查才问得到这个池子。
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
		fmt.Printf("源场次 %d：源侧没有库存数据 —— 不知道还剩几张（放行但不保护）\n",
			*supplierSessionID)
		return nil
	}
	fmt.Printf("源场次 %d：源侧可售 %d · 已承诺 %d · 还剩 %d（源侧状态 %s，快照 %s）\n",
		*supplierSessionID, av.AvailableQty, av.CommittedQty, av.RemainingQty,
		av.SourceStatus, av.SnapshotAt)
	return nil
}

// cmdHold 是预占子命令。create 占住、release 放掉、expire 放掉过期的、show 看现状。
//
// 预占号是幂等键：同一个号再提交一次不会多占票。
// 够不够由库里的 fn_reserve_qty 判（它先锁源场次再判），
// 这里不预查、不预判 —— 预查就是 TOCTOU。
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
	holdNo := fs.String("no", "", "预占号（幂等键，必填）")
	channelID := fs.Int64("channel", 0, "渠道 id")
	variantID := fs.Int64("variant", 0, "变体 id")
	qty := fs.Int64("qty", 0, "要占几张")
	visitDate := fs.String("date", "", "使用日期 YYYY-MM-DD")
	cartID := fs.Int64("cart", 0, "购物车 id")
	ttl := fs.Int64("ttl", 0, "预占存活秒数（0 表示用默认 900）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
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
		fmt.Printf("预占 %s（id %d）%s · %s · 源侧没有库存数据 —— 不知道还剩几张\n",
			res.HoldNo, res.HoldID, verb, "已占住")
		return nil
	}
	fmt.Printf("预占 %s（id %d）%s · 源侧可售 %d · 已承诺 %d · 还剩 %d（源侧状态 %s）\n",
		res.HoldNo, res.HoldID, verb, res.AvailableQty, res.CommittedQty,
		res.RemainingQty, res.SourceStatus)
	return nil
}

func cmdHoldRelease(args []string) error {
	fs := flag.NewFlagSet("hold release", flag.ExitOnError)
	dbName := fs.String("db", "", "目标库")
	holdNo := fs.String("no", "", "预占号")
	reason := fs.String("reason", "", "释放原因（cart_abandoned / order_failed / ...）")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
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
		return nil
	}
	fmt.Printf("预占 %s 未释放（id %d）· 状态 %s\n", res.HoldNo, res.HoldID, res.Status)
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
	holdNo := fs.String("no", "", "预占号")
	jsonOut := fs.String("json", "", "结构化结果导出路径")
	if err := fs.Parse(args); err != nil {
		return err
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
	if st.CartID != 0 {
		fmt.Printf("  购物车 %d · 到期 %s\n", st.CartID, st.ExpiresAt)
	}
	if st.ReleasedAt != "" {
		fmt.Printf("  释放于 %s", st.ReleasedAt)
		if st.ReleaseWhy != "" {
			fmt.Printf(" · 原因 %s", st.ReleaseWhy)
		}
		fmt.Println()
	}
	return nil
}

func init() {
	register("order", "下单与查单：金额与选源都走库里的唯一实现", usageOrder, cmdOrder, 80)
	register("fulfill", "履约：支付 / 预订 / 出券，状态往哪走由状态机决定", usageFulfill, cmdFulfill, 90)
	register("refund", "退款：发起 / 放行 / 完成，能不能退由库里的唯一实现说了算", usageRefund, cmdRefund, 100)
	register("redeem", "核销：扫一次票落一条记录，能不能进场由库里的唯一实现说了算", usageRedeem, cmdRedeem, 110)
	register("stock", "库存：源场次还剩几张票，由库里的唯一实现说了算", usageStock, cmdStock, 120)
	register("hold", "预占：购物车占住票，够不够由库里的唯一实现说了算", usageHold, cmdHold, 130)
}

const usageOrder = `  tc-connect order      place --db name --request req.json [--json out.json]
  tc-connect order      show  --db name --id 7 [--json out.json]
  tc-connect order      reassign --db name --order 7 --item 3 [--reason "源侧下架"] [--json out.json]
  tc-connect order      stale --db name [--json out.json]
`

const usageFulfill = `  tc-connect fulfill    pay      --db name --order 7 --method alipay --amount 1171.60
                                  --currency CNY --provider alipay --txn ALI-001 [--json out.json]
  tc-connect fulfill    book     --db name --order 7 [--json out.json]
  tc-connect fulfill    request  --db name --booking 12 [--request req.json] [--json out.json]
  tc-connect fulfill    attempt  --db name --booking 12 [--response resp.json]
                                  [--http-status 200] [--latency-ms 120] [--error-type retriable]
  tc-connect fulfill    complete --db name --booking 12 --status confirmed
                                  [--external-booking-id X] [--code C1 --code C2] [--no-voucher]
  tc-connect fulfill    issue    --db name --booking 12 [--code C1 --code C2] [--json out.json]
  tc-connect fulfill    retry    --db name --booking 12 [--next-retry-at RFC3339] [--json out.json]
  tc-connect fulfill    show     --db name --order 7 [--json out.json]
`

const usageRefund = `  tc-connect refund     request  --db name --order 3 --amount 368.00 --key RF-001
                                  [--reason "源侧预订失败"] [--by ops@x] [--json out.json]
  tc-connect refund     approve  --db name --refund 1 [--by boss@x] [--json out.json]
  tc-connect refund     complete --db name --refund 1 [--success|--fail]
                                  [--supplier-refund-id EXT-RF-001] [--error-code SOURCE_TIMEOUT]
                                  [--error-message "源侧超时"] [--payload resp.json] [--json out.json]
  tc-connect refund     show     --db name --refund 1 [--json out.json]
`

const usageRedeem = `  tc-connect redeem     scan     --db name (--code PFT90001 | --voucher 7)
                                  [--gate 1] [--gate-operator 1] [--device POS-HK-0117]
                                  [--operator OP-HK-0117] [--payload scan.json] [--json out.json]
  tc-connect redeem     show     --db name --voucher 7 [--json out.json]
  tc-connect redeem     expire   --db name [--limit 500] [--json out.json]
  tc-connect redeem     overdue  --db name [--json out.json]
`

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
