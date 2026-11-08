// 接入层源侧的子命令：列出源、分层连通性测试、协议 mock、归一化。
//
// 这一组命令打的是「我们跟源谈得怎么样」，
// 不碰交易侧的任何事实 —— 交易侧的命令在 cmd_trade.go。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"ticket-center/internal/layertest"
	"ticket-center/internal/registry"
	"ticket-center/internal/store"
)

func cmdSources(args []string) error {
	fs := flag.NewFlagSet("sources", flag.ExitOnError)
	var c commonFlags
	c.register(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, _, err := c.load()
	if err != nil {
		return err
	}
	for _, s := range registry.List(cfg) {
		mark := "⏳"
		if s.Confirmed {
			mark = "✅"
		}
		fmt.Printf("%s %-18s %-24s %-28s %s\n", mark, s.Code, s.Protocol, s.Adapter, s.Note)
	}
	return nil
}

func cmdLayers(args []string) error {
	fs := flag.NewFlagSet("layers", flag.ExitOnError)
	var c commonFlags
	c.register(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, rules, err := c.load()
	if err != nil {
		return err
	}

	targets := c.suppliers
	if len(targets) == 0 {
		targets = cfg.Codes()
	}

	fmt.Printf("环境：%s   归档库：%s   规范库：%s\n", c.env, c.archiveDB, c.canonicalDB)
	fmt.Printf("目标源：%s\n\n", strings.Join(targets, ", "))

	checks := layertest.OfflineChecks(cfg, rules, c.fixturesDir)
	var runs []*layertest.SupplierRun

	if !c.offline {
		archiveDB, err := prepareArchiveDB(c.archiveDB, targets)
		if err != nil {
			fmt.Printf("归档库准备失败：%v\n", err)
		}
		var canonicalDB *store.DB
		if c.canonicalDB != "" {
			canonicalDB = store.New(c.canonicalDB)
		}
		for _, code := range targets {
			run := layertest.Run(context.Background(), code, layertest.Options{
				Config: cfg, Rules: rules, Env: c.env,
				ArchiveDB: archiveDB, CanonicalDB: canonicalDB, Timeout: c.timeout,
			})
			runs = append(runs, run)
		}
	}

	printReport(runs, checks)
	counts := summarize(runs, checks)
	fmt.Printf("合计：%d 通过 · %d 失败 · %d 跳过\n", counts[layertest.StatusPass], counts[layertest.StatusFail], counts[layertest.StatusSkip])

	if c.jsonOut != "" {
		if err := writeJSON(c.jsonOut, map[string]any{
			"env": c.env, "archive_db": c.archiveDB, "canonical_db": c.canonicalDB,
			"suppliers": runs, "offline_checks": checks, "counts": counts,
		}); err != nil {
			return err
		}
		fmt.Printf("报告已导出：%s\n", c.jsonOut)
	}
	if counts[layertest.StatusFail] > 0 {
		os.Exit(1)
	}
	return nil
}

func cmdMock(args []string) error {
	fs := flag.NewFlagSet("mock", flag.ExitOnError)
	var c commonFlags
	c.register(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, rules, err := c.load()
	if err != nil {
		return err
	}
	mockDB, err := prepareArchiveDB(c.mockDB, []string{"trip_com"})
	if err != nil {
		fmt.Printf("mock 归档库准备失败：%v\n", err)
		mockDB = nil
	}
	var canonicalDB *store.DB
	if c.canonicalDB != "" {
		canonicalDB = store.New(c.canonicalDB)
	}
	checks := layertest.MockProtocolChecks(context.Background(), cfg, rules, mockDB, canonicalDB, c.fixturesDir)
	offline := layertest.OfflineChecks(cfg, rules, c.fixturesDir)
	all := append(offline, checks...)

	fmt.Println(strings.Repeat("=", 88))
	fmt.Println("协议级自检：用本地 mock 跑通完整链路（取 token → 请求 → 分类 → 归档 → 归一化 → 路由）")
	fmt.Println(strings.Repeat("=", 88))
	for _, ck := range all {
		fmt.Printf("  %s %-16s %s\n", mark(ck.Status), ck.Name, ck.Detail)
	}
	counts := summarize(nil, all)
	fmt.Printf("\n合计：%d 通过 · %d 失败 · %d 跳过\n",
		counts[layertest.StatusPass], counts[layertest.StatusFail], counts[layertest.StatusSkip])
	if c.jsonOut != "" {
		if err := writeJSON(c.jsonOut, map[string]any{"checks": all, "counts": counts}); err != nil {
			return err
		}
		fmt.Printf("报告已导出：%s\n", c.jsonOut)
	}
	if counts[layertest.StatusFail] > 0 {
		os.Exit(1)
	}
	return nil
}

func cmdNormalize(args []string) error {
	fs := flag.NewFlagSet("normalize", flag.ExitOnError)
	var c commonFlags
	source := fs.String("source", "", "映射规则里的源 key")
	fixture := fs.String("fixture", "", "源报文 JSON 路径")
	c.register(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *source == "" || *fixture == "" {
		return fmt.Errorf("normalize 需要 --source 与 --fixture")
	}
	_, rules, err := c.load()
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(*fixture)
	if err != nil {
		return err
	}
	result, err := rules.Normalize(*source, raw)
	if err != nil {
		return err
	}
	blob, _ := json.MarshalIndent(result, "", "  ")
	if c.jsonOut != "" {
		if err := writeJSON(c.jsonOut, result); err != nil {
			return err
		}
		fmt.Printf("JSON 已导出：%s\n", c.jsonOut)
		return nil
	}
	fmt.Println(string(blob))
	return nil
}

func printReport(runs []*layertest.SupplierRun, checks []layertest.Check) {
	fmt.Println(strings.Repeat("=", 88))
	fmt.Println("分层连通性测试：连通 → 认证 → 目录 → 详情 → 价格 → 映射 → 路由")
	fmt.Println(strings.Repeat("=", 88))
	for _, run := range runs {
		fmt.Printf("\n【%s】\n", run.Supplier)
		if run.Fatal != "" {
			fmt.Printf("  ⚠ 致命：%s\n", run.Fatal)
		}
		for _, l := range run.Layers {
			fmt.Printf("  %s %-8s %s\n", mark(l.Status), l.Label, l.Detail)
		}
	}
	if len(checks) > 0 {
		fmt.Println("\n── 离线自检 ────────────────────────────────────────────")
		for _, ck := range checks {
			fmt.Printf("  %s %-16s %s\n", mark(ck.Status), ck.Name, ck.Detail)
		}
	}
	fmt.Println()
}

func mark(s layertest.Status) string {
	switch s {
	case layertest.StatusPass:
		return "✓"
	case layertest.StatusFail:
		return "✗"
	default:
		return "–"
	}
}

func summarize(runs []*layertest.SupplierRun, checks []layertest.Check) map[layertest.Status]int {
	counts := map[layertest.Status]int{
		layertest.StatusPass: 0, layertest.StatusFail: 0, layertest.StatusSkip: 0,
	}
	for _, run := range runs {
		for _, l := range run.Layers {
			counts[l.Status]++
		}
	}
	for _, ck := range checks {
		counts[ck.Status]++
	}
	return counts
}

func init() {
	register("sources", "列出已注册的源与状态", usageSources, cmdSources, 10)
	register("layers", "分层连通性测试（连通→认证→目录→详情→价格→映射→路由）", usageLayers, cmdLayers, 20)
	register("mock", "协议级 mock 自检（本地 mock 跑通完整链路）", usageMock, cmdMock, 30)
	register("normalize", "归一化：源报文变成源变体 + 覆盖声明", usageNormalize, cmdNormalize, 40)
}

const usageSources = `  tc-connect sources    [--config path]
`

const usageLayers = `  tc-connect layers     [--supplier code]... [--env sandbox|prod] [--db name]
                        [--canonical-db name] [--offline] [--json out.json]
`

const usageMock = `  tc-connect mock       [--canonical-db name] [--json out.json]
`

const usageNormalize = `  tc-connect normalize  --source key --fixture path [--json out.json]
`
