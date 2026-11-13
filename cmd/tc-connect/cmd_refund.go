// 退款：发起 → 放行 → 完成。
//
// 这一组命令只是把库里的 fn_request_refund / fn_approve_refund / fn_complete_refund
// 调起来 —— 能不能退、退多少、订单状态怎么改，全在库里。
package main

import (
	"flag"
	"fmt"

	"ticket-center/internal/refund"
	"ticket-center/internal/store"
)

func init() {
	register("refund", "退款：发起 / 放行 / 完成，能不能退由库里的唯一实现说了算", usageRefund, cmdRefund, 100)
}

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

const usageRefund = `  tc-connect refund     request  --db name --order 3 --amount 368.00 --key RF-001
                                  [--reason "源侧预订失败"] [--by ops@x] [--json out.json]
  tc-connect refund     approve  --db name --refund 1 [--by boss@x] [--json out.json]
  tc-connect refund     complete --db name --refund 1 [--success|--fail]
                                  [--supplier-refund-id EXT-RF-001] [--error-code SOURCE_TIMEOUT]
                                  [--error-message "源侧超时"] [--payload resp.json] [--json out.json]
  tc-connect refund     show     --db name --refund 1 [--json out.json]
`
