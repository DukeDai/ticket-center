// 核销：扫一次票，查这张券和它的核销流水，跑凭证过期作业。
//
// 这一组命令只是把库里的 fn_redeem_voucher / fn_expire_vouchers 调起来 ——
// 能不能进场、扣多少额度、券状态怎么改，全在库里。
package main

import (
	"flag"
	"fmt"

	"ticket-center/internal/redemption"
	"ticket-center/internal/store"
)

func init() {
	register("redeem", "核销：扫一次票落一条记录，能不能进场由库里的唯一实现说了算", usageRedeem, cmdRedeem, 110)
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

const usageRedeem = `  tc-connect redeem     scan     --db name (--code PFT90001 | --voucher 7)
                                  [--gate 1] [--gate-operator 1] [--device POS-HK-0117]
                                  [--operator OP-HK-0117] [--payload scan.json] [--json out.json]
  tc-connect redeem     show     --db name --voucher 7 [--json out.json]
  tc-connect redeem     expire   --db name [--limit 500] [--json out.json]
  tc-connect redeem     overdue  --db name [--json out.json]
`
