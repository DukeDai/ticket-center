// Command tc-lint 是「值怎么进 SQL」的门禁。
//
// 扫 Go 源码，找出「把没转义的值拼进 SQL 的引号位置」的地方。
// 有问题就非零退出。
//
// 用法：
//
//	tc-lint [目录...]     默认为当前目录
package main

import (
	"fmt"
	"os"

	"ticket-center/internal/sqllint"
)

func main() {
	roots := os.Args[1:]
	if len(roots) == 0 {
		roots = []string{"."}
	}
	var all []sqllint.Finding
	for _, root := range roots {
		findings, err := sqllint.Walk(root)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		all = append(all, findings...)
	}
	sqllint.Sort(all)
	for _, f := range all {
		fmt.Fprintln(os.Stderr, f.String())
	}
	if len(all) > 0 {
		fmt.Fprintf(os.Stderr, "\nSQL 门禁失败：%d 处把没转义的值拼进了 SQL。\n", len(all))
		fmt.Fprintln(os.Stderr, "值要进 SQL，走 store.Quote（字符串字面量）或 store.QuoteIdent（标识符）。")
		os.Exit(1)
	}
	fmt.Println("SQL 门禁通过：没有把没转义的值拼进 SQL。")
}
