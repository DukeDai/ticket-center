// Command tc-writelint 是「写路径有没有洗掉别人写的事实」的门禁。
//
// 扫 Go 源码，找出两类问题：
//
//	规则 1 判断表上的 upsert 无条件覆盖了人的判断列
//	规则 2 写了源侧表的包没有校验标识列不为空
//
// 有问题就非零退出。
//
// 用法：
//
//	tc-writelint [目录...]     默认为当前目录
package main

import (
	"fmt"
	"os"

	"ticket-center/internal/writelint"
)

func main() {
	roots := os.Args[1:]
	if len(roots) == 0 {
		roots = []string{"."}
	}
	var all []writelint.Finding
	for _, root := range roots {
		findings, err := writelint.Walk(root)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		all = append(all, findings...)
	}
	writelint.Sort(all)
	for _, f := range all {
		fmt.Fprintln(os.Stderr, f.String())
	}
	if len(all) > 0 {
		fmt.Fprintf(os.Stderr, "\n写路径门禁失败：%d 处机器写的路径动了它不该动的字段。\n", len(all))
		fmt.Fprintln(os.Stderr, "人工写的判定依据不许被机器洗掉；源侧标识不许是空的，写之前就要挡住。")
		os.Exit(1)
	}
	fmt.Println("写路径门禁通过：机器没有洗掉人的判断，也没有落下空的源标识。")
}
