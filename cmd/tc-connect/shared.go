// 共享的旗标、路径与文件助手。
//
// 这些东西不属于任何一个域：它们被多个子命令共用，
// 放在这里就不会随着某个域的代码一起被搬走。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"ticket-center/internal/config"
	"ticket-center/internal/migrate"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
)

// ---------------------------------------------------------------- 公共参数

type commonFlags struct {
	configPath  string
	rulesPath   string
	fixturesDir string
	archiveDB   string
	mockDB      string
	canonicalDB string
	jsonOut     string
	env         string
	suppliers   stringList
	offline     bool
	timeout     time.Duration
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

// fulfillDB 解析目标库名。
func fulfillDB(name string) string {
	if name != "" {
		return name
	}
	if v := os.Getenv("PGDATABASE"); v != "" {
		return v
	}
	return "ticket_center"
}

// readJSONFile 读一个 JSON 文件（报文归档用）。
func readJSONFile(path string) (map[string]any, error) {
	if path == "" {
		return nil, nil
	}
	blob, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读文件失败：%w", err)
	}
	var m map[string]any
	if err := json.Unmarshal(blob, &m); err != nil {
		return nil, fmt.Errorf("文件不是合法的 JSON 对象：%w", err)
	}
	return m, nil
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
		if _, err := migrate.Apply(db, migrate.Options{Dir: filepath.Join(findRoot(), "db", "migrations")}); err != nil {
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
