// 子命令注册表。
//
// 每个域的文件在 init 里注册自己的子命令：加一个子命令只动它自己的文件，
// main.go 不跟着改。注册顺序由 order 决定，跟文件名无关。
package main

import (
	"fmt"
	"sort"
)

// command 是一个子命令的注册项。
type command struct {
	name  string
	desc  string
	usage string
	run   func([]string) error
	order int
}

var commands []command

// register 注册一个子命令。
func register(name, desc, usage string, run func([]string) error, order int) {
	commands = append(commands, command{
		name:  name,
		desc:  desc,
		usage: usage,
		run:   run,
		order: order,
	})
}

// lookupCommand 按名字找子命令。
func lookupCommand(name string) *command {
	for i := range commands {
		if commands[i].name == name {
			return &commands[i]
		}
	}
	return nil
}

// sortedCommands 按注册顺序排好的子命令。
func sortedCommands() []command {
	out := append([]command(nil), commands...)
	sort.Slice(out, func(i, j int) bool { return out[i].order < out[j].order })
	return out
}

// usage 打帮助。每个子命令自带自己的用法行，主文件只负责拼起来。
func usage() {
	fmt.Print("tc-connect — 供应源接入层 CLI\n\n用法：\n")
	for _, c := range sortedCommands() {
		fmt.Print(c.usage)
	}
	fmt.Print(commonUsage)
}

// commonUsage 是所有子命令共用的说明。
const commonUsage = `
下单请求文件 req.json 的字段：
  {"channel_id":1,"customer_id":3,"idempotency_key":"demo-001",
   "items":[{"variant_id":9,"quantity":2,"visit_date":"<日期>"}],
   "holders":[{"variant_id":9,"sequence":1,"field_code":"holder_name","value":"张三"}],
   "contact":{"phone":"13800000000"},"buyer_note":""}

组合套餐的实名可带 item_index（1 起的明细行号）：同一个成分变体出现在多行明细里时，
光看 variant_id 分不出持票人属于哪一行。带 item_index 的实名必须全带。
   "holders":[{"variant_id":18,"item_index":1,"sequence":1,"field_code":"holder_name","value":"王大明"}],

常用环境变量（凭证只从环境变量读，其次 supplier.auth_config）：
  TRIPCOM_AID / TRIPCOM_SID / TRIPCOM_KEY
  GLOBALTIX_RESELLER_ID / GLOBALTIX_RESELLER_NAME / GLOBALTIX_USERNAME / GLOBALTIX_API_KEY
`
