// Command tc-connect 是供应源接入层的命令行工具。
//
// 子命令分几组，各在一个文件里：
//
//	cmd_source.go   sources / layers / mock / normalize —— 跟源谈得怎么样
//	cmd_lib.go      price / migrate / refresh —— 库侧的口径
//	cmd_trade.go    order / fulfill / refund / redeem / stock / hold —— 交易侧
//	cmd_fusion.go   variant —— 异构差异的只读视图
//	compose.go      compose —— 组合配方的解算与写入
//
// 每个子命令只拼参数、只读结果：金额、状态、能不能进场，
// 全在库里的唯一实现里（见 AGENTS.md 的硬约束 14-22）。
//
// 用法：
//
//	tc-connect layers --supplier trip_com --env prod
//	tc-connect layers --offline
//	tc-connect mock
//	tc-connect normalize --source trip_com --fixture fixtures/trip_com_catalog.json
//	tc-connect price --variant 11 --date 2026-11-18
//	tc-connect price --reprice
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	name := os.Args[1]
	if name == "-h" || name == "--help" || name == "help" {
		usage()
		return
	}
	cmd := lookupCommand(name)
	if cmd == nil {
		fmt.Fprintf(os.Stderr, "未知子命令：%s\n\n", name)
		usage()
		os.Exit(2)
	}
	if err := cmd.run(os.Args[2:]); err != nil {
		fmt.Fprintf(os.Stderr, "执行失败：%v\n", err)
		os.Exit(1)
	}
}
