// Command tc-connect 是供应源接入层的命令行工具。
//
// 子命令：
//
//	sources    列出已注册的源与状态
//	layers     分层连通性测试（连通→认证→目录→详情→价格→映射→路由）
//	mock       协议级 mock 自检（本地 mock 跑通完整链路，21 项断言）
//	normalize  归一化（把源报文变成源变体 + 覆盖声明，供演练器/脚本消费）
//
// 用法：
//
//	tc-connect layers --supplier trip_com --env prod
//	tc-connect layers --offline
//	tc-connect mock
//	tc-connect normalize --source trip_com --fixture fixtures/trip_com_catalog.json
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"ticket-center/internal/config"
	"ticket-center/internal/layertest"
	"ticket-center/internal/normalize"
	"ticket-center/internal/registry"
	"ticket-center/internal/store"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "sources":
		err = cmdSources(args)
	case "layers":
		err = cmdLayers(args)
	case "mock":
		err = cmdMock(args)
	case "normalize":
		err = cmdNormalize(args)
	case "-h", "--help", "help":
		usage()
		return
	default:
		fmt.Fprintf(os.Stderr, "未知子命令：%s\n\n", cmd)
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "执行失败：%v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Print(`tc-connect — 供应源接入层 CLI

用法：
  tc-connect sources    [--config path]
  tc-connect layers     [--supplier code]... [--env sandbox|prod] [--db name]
                        [--canonical-db name] [--offline] [--json out.json]
  tc-connect mock       [--canonical-db name] [--json out.json]
  tc-connect normalize  --source key --fixture path [--json out.json]

常用环境变量（凭证只从环境变量读，其次 supplier.auth_config）：
  TRIPCOM_AID / TRIPCOM_SID / TRIPCOM_KEY
  GLOBALTIX_RESELLER_ID / GLOBALTIX_RESELLER_NAME / GLOBALTIX_USERNAME / GLOBALTIX_API_KEY
`)
}

// ---------------------------------------------------------------- 公共参数

type commonFlags struct {
	configPath   string
	rulesPath    string
	fixturesDir  string
	archiveDB    string
	mockDB       string
	canonicalDB  string
	jsonOut      string
	env          string
	suppliers    stringList
	offline      bool
	timeout      time.Duration
}

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func (c *commonFlags) register(fs *flag.FlagSet) {
	root := findRoot()
	fs.StringVar(&c.configPath, "config", filepath.Join(root, "configs", "api_config.json"), "传输层配置文件")
	fs.StringVar(&c.rulesPath, "rules", filepath.Join(root, "configs", "mapping_rules.json"), "映射规则配置文件")
	fs.StringVar(&c.fixturesDir, "fixtures", filepath.Join(root, "fixtures"), "样例报文目录")
	fs.StringVar(&c.archiveDB, "db", "ticket_center_integration", "报文归档库")
	fs.StringVar(&c.mockDB, "mock-db", "ticket_center_mock", "mock 模式归档库")
	fs.StringVar(&c.canonicalDB, "canonical-db", "ticket_center", "规范库（读变体与路由）")
	fs.StringVar(&c.jsonOut, "json", "", "结构化结果导出路径")
	fs.StringVar(&c.env, "env", "sandbox", "端点环境：sandbox | prod")
	fs.Var(&c.suppliers, "supplier", "只测某个源（可重复）")
	fs.BoolVar(&c.offline, "offline", false, "完全不外呼")
	fs.DurationVar(&c.timeout, "timeout", 20*time.Second, "单次请求超时")
}

func (c *commonFlags) load() (*config.File, *normalize.Rules, error) {
	cfg, err := config.Load(c.configPath)
	if err != nil {
		return nil, nil, err
	}
	rules, err := normalize.LoadRules(c.rulesPath)
	if err != nil {
		return nil, nil, err
	}
	return cfg, rules, nil
}

// findRoot 向上找 go.mod 所在目录（项目根）。
func findRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		return "."
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "."
}

// ---------------------------------------------------------------- 子命令

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

// ---------------------------------------------------------------- 输出与工具

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

func writeJSON(path string, v any) error {
	if !filepath.IsAbs(path) {
		path = filepath.Join(findRoot(), path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	blob, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(blob, '\n'), 0o644)
}

// prepareArchiveDB 建归档库 + 建表 + 写 supplier 行（不碰主库）。
func prepareArchiveDB(name string, codes []string) (*store.DB, error) {
	if name == "" {
		return nil, nil
	}
	host := os.Getenv("PGHOST")
	if host == "" {
		host = "127.0.0.1"
	}
	bin := os.Getenv("PSQL_BIN")
	if bin == "" {
		bin = "psql"
	}
	exists, err := store.DatabaseExists(bin, host, name)
	if err != nil {
		return nil, err
	}
	if !exists {
		if err := store.CreateDatabase(bin, host, name); err != nil {
			return nil, err
		}
	}
	db := store.New(name)
	has, err := db.TableExists("supplier")
	if err != nil {
		return nil, err
	}
	if !has {
		schema := filepath.Join(findRoot(), "db", "schema.sql")
		if err := db.ExecFile(schema); err != nil {
			return nil, err
		}
	}
	for _, code := range codes {
		if _, err := store.EnsureSupplier(db, code, code); err != nil {
			return nil, err
		}
	}
	return db, nil
}
