// 履约：支付 → 预订 → 出券。
//
// 这一组命令只把库里的 fn_record_payment / fn_create_bookings / … 调起来：
// 状态往哪走、订单履约状态怎么算，全在库里。
package main

import (
	"flag"
	"fmt"
	"time"

	"ticket-center/internal/fulfillment"
	"ticket-center/internal/store"
)

func init() {
	register("fulfill", "履约：支付 / 预订 / 出券，状态往哪走由状态机决定", usageFulfill, cmdFulfill, 90)
}

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
