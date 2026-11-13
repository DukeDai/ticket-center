// Package migrate 是数据库迁移引擎。
//
// 为什么需要它：项目纪律是「DDL 只增不改」—— 已发布的表结构只允许用
// ALTER TABLE ... ADD 演进，不许回头改建表语句。这条纪律靠人记着迟早破：
// 总有人直接改掉建表脚本，存量库和新库从此分叉，而且没人发现。
//
// 这里把纪律变成机制：
//
//   - 每个迁移文件的内容 sha256 记进账本 ops.schema_migration；
//   - 文件在应用之后被改过 → 引擎拒绝继续跑，并说清是哪一版；
//   - 每个迁移在自己的事务里执行，账本写入与建表同一事务，崩了不留半截；
//   - 整轮迁移在同一个 psql 会话里跑，会话级互斥锁挡住并发改结构。
//
// 于是「只增不改」不再是一句约定：改了就报错，改不了。
package migrate

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

const (
	// LedgerSchema 单独放账本：公共 schema 里只应该有业务表。
	LedgerSchema = "ops"
	// LedgerTable 是迁移账本。
	LedgerTable = LedgerSchema + ".schema_migration"
	// lockKey 是会话级互斥锁的键。同一时刻只允许一个进程改结构。
	lockKey = 8814021
)

// ledgerDDL 建账本。幂等：每次跑迁移都先确保它在。
const ledgerDDL = `CREATE SCHEMA IF NOT EXISTS ` + LedgerSchema + `;
CREATE TABLE IF NOT EXISTS ` + LedgerTable + ` (
    version     TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    checksum    TEXT NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    duration_ms INT NOT NULL DEFAULT 0
);`

// fileRe 是迁移文件名的约定：NNN_小写下划线.sql。
var fileRe = regexp.MustCompile(`^(\d+)_([a-z0-9_]+)\.sql$`)

// File 是一个迁移文件。
type File struct {
	Version  string // 版本号，如 "001"
	Name     string // 文件名里的语义名，如 "baseline"
	Path     string
	Checksum string // 文件内容的 sha256
}

// Label 是给人看的版本标识。
func (f File) Label() string { return f.Version + "_" + f.Name }

// Applied 是账本里的一条记录。
type Applied struct {
	Version   string
	Name      string
	Checksum  string
	AppliedAt string
}

// Status 描述一个迁移文件在目标库里的状态。
type Status struct {
	File      File
	Applied   bool
	Drift     bool // 已应用，但文件内容与账本记录的校验和不一致
	AppliedAt string
}

// Options 是 Apply 的选项。
type Options struct {
	// Dir 是迁移目录（默认 db/migrations）。
	Dir string
	// Baseline 非空时：把版本号 <= Baseline 的迁移标记为「已应用」但不执行，
	// 用于接管一个用旧脚本建出来的存量库。账本非空时不允许基线。
	Baseline string
	// DryRun 为 true 时只算计划，不碰数据库。
	DryRun bool
}

// Result 是一次迁移的结果。
type Result struct {
	Applied   []string // 本次真正执行的版本
	Skipped   []string // 已应用，跳过
	Baselined []string // 存量库接管时标记为已应用的版本
	Drifted   []string // 内容漂移的版本（一旦发现就是硬错误）
}

// LoadFiles 读取迁移目录，按版本号升序返回。
//
// 文件名不合约定（不是 NNN_小写.sql）会直接报错 —— 迁移目录里的每个文件
// 都必须被引擎认领，否则它就是一份「谁也不知道该不该跑」的脚本。
func LoadFiles(dir string) ([]File, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("读迁移目录 %s 失败: %w", dir, err)
	}
	var files []File
	seen := map[string]string{}
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		m := fileRe.FindStringSubmatch(e.Name())
		if m == nil {
			return nil, fmt.Errorf("迁移文件名不合约定：%s（应为 NNN_小写下划线.sql）", e.Name())
		}
		path := filepath.Join(dir, e.Name())
		content, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("读迁移文件 %s 失败: %w", path, err)
		}
		// psql 会把行首的反斜杠当元命令。迁移文件必须是纯 SQL。
		for i, line := range strings.Split(string(content), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "\\") {
				return nil, fmt.Errorf("%s:%d 行以反斜杠开头，psql 会把它当元命令", path, i+1)
			}
		}
		sum := sha256.Sum256(content)
		f := File{
			Version:  m[1],
			Name:     m[2],
			Path:     path,
			Checksum: hex.EncodeToString(sum[:]),
		}
		if prev, dup := seen[f.Version]; dup {
			return nil, fmt.Errorf("迁移版本号重复：%s 与 %s", prev, f.Label())
		}
		seen[f.Version] = f.Label()
		files = append(files, f)
	}
	sort.Slice(files, func(i, j int) bool {
		a, _ := strconv.Atoi(files[i].Version)
		b, _ := strconv.Atoi(files[j].Version)
		if a != b {
			return a < b
		}
		return files[i].Name < files[j].Name
	})
	return files, nil
}

// ReadLedger 读账本。账本不存在时返回空账本。
func ReadLedger(db *store.DB) (map[string]Applied, error) {
	exists, err := db.Scalar(fmt.Sprintf("SELECT to_regclass('%s') IS NOT NULL;", LedgerTable))
	if err != nil {
		return nil, err
	}
	if exists != "t" {
		return map[string]Applied{}, nil
	}
	rows, err := db.Rows(fmt.Sprintf(
		"SELECT version, name, checksum, applied_at::text FROM %s ORDER BY version;", LedgerTable))
	if err != nil {
		return nil, err
	}
	ledger := make(map[string]Applied, len(rows))
	for _, r := range rows {
		ledger[r["version"]] = Applied{
			Version:   r["version"],
			Name:      r["name"],
			Checksum:  r["checksum"],
			AppliedAt: r["applied_at"],
		}
	}
	return ledger, nil
}

// List 列出每个迁移文件的状态。
func List(db *store.DB, dir string) ([]Status, error) {
	files, err := LoadFiles(dir)
	if err != nil {
		return nil, err
	}
	ledger, err := ReadLedger(db)
	if err != nil {
		return nil, err
	}
	out := make([]Status, 0, len(files))
	for _, f := range files {
		a, ok := ledger[f.Version]
		st := Status{File: f, Applied: ok}
		if ok {
			st.AppliedAt = a.AppliedAt
			st.Drift = a.Checksum != f.Checksum
		}
		out = append(out, st)
	}
	return out, nil
}

// Apply 执行待应用的迁移。
//
// 顺序固定为：读文件 → 读账本 → 校验内容漂移 → 整轮在一个 psql 会话里执行。
// 任何一个已经应用的迁移文件内容变了，直接失败，不执行任何东西 ——
// 漂移意味着账本和现实对不上，先查清再动。
func Apply(db *store.DB, opts Options) (Result, error) {
	var res Result
	dir := opts.Dir
	if dir == "" {
		dir = "db/migrations"
	}
	files, err := LoadFiles(dir)
	if err != nil {
		return res, err
	}
	if len(files) == 0 {
		return res, fmt.Errorf("迁移目录 %s 里没有迁移文件", dir)
	}
	ledger, err := ReadLedger(db)
	if err != nil {
		return res, err
	}

	// 内容漂移检查：已应用的文件被改过 = 有人回头改了已发布的结构。
	for _, f := range files {
		a, ok := ledger[f.Version]
		if !ok {
			continue
		}
		if a.Checksum != f.Checksum {
			res.Drifted = append(res.Drifted, f.Label())
		}
	}
	if len(res.Drifted) > 0 {
		return res, fmt.Errorf("迁移文件在应用后被修改过：%s。已发布的迁移不许改，请新增一个迁移文件",
			strings.Join(res.Drifted, ", "))
	}

	// 存量库接管：把基线版本标记为已应用。
	var baselined []File
	if opts.Baseline != "" {
		if len(ledger) > 0 {
			return res, fmt.Errorf("账本里已有 %d 条记录，不能再基线。基线只用于接管一个由旧脚本建出来的库", len(ledger))
		}
		for _, f := range files {
			if versionLess(f.Version, opts.Baseline) || f.Version == opts.Baseline {
				baselined = append(baselined, f)
			}
		}
		if len(baselined) == 0 {
			return res, fmt.Errorf("基线版本 %s 不在迁移目录里", opts.Baseline)
		}
		for _, f := range baselined {
			res.Baselined = append(res.Baselined, f.Label())
		}
	}

	var pending []File
	baselineSet := versionSet(baselined)
	for _, f := range files {
		if _, ok := ledger[f.Version]; ok {
			res.Skipped = append(res.Skipped, f.Label())
			continue
		}
		if baselineSet[f.Version] {
			// 基线只是记账，不执行。
			continue
		}
		pending = append(pending, f)
	}

	if opts.DryRun {
		return res, nil
	}
	if len(pending) == 0 && len(baselined) == 0 {
		return res, nil
	}

	script, err := buildScript(files, baselined)
	if err != nil {
		return res, err
	}
	if _, err := db.ExecScript(script); err != nil {
		return res, err
	}
	for _, f := range pending {
		res.Applied = append(res.Applied, f.Label())
	}
	return res, nil
}

// versionLess 比较两个版本号（数字字符串）。
func versionLess(a, b string) bool {
	x, _ := strconv.Atoi(a)
	y, _ := strconv.Atoi(b)
	return x < y
}

// buildScript 生成整轮迁移要执行的脚本。
//
// 整轮放在同一个 psql 会话里：会话级 advisory lock 因此能挡住并发迁移，
// 事务边界也就落在每个迁移文件上，而不是整轮。
func buildScript(files []File, baselined []File) (string, error) {
	var b strings.Builder
	b.WriteString("\\set ON_ERROR_STOP on\n")
	b.WriteString(ledgerDDL)
	b.WriteString("\n")
	b.WriteString(fmt.Sprintf("SELECT pg_advisory_lock(%d);\n", lockKey))

	for _, f := range baselined {
		b.WriteString(fmt.Sprintf(
			"INSERT INTO %s(version, name, checksum) VALUES (%s, %s, %s) ON CONFLICT (version) DO NOTHING;\n",
			LedgerTable, store.Quote(f.Version), store.Quote(f.Name), store.Quote(f.Checksum)))
	}

	for _, f := range files {
		if _, done := versionSet(baselined)[f.Version]; done {
			continue
		}
		content, err := os.ReadFile(f.Path)
		if err != nil {
			return "", fmt.Errorf("读迁移文件 %s 失败: %w", f.Path, err)
		}
		body := string(content)
		b.WriteString("BEGIN;\n")
		b.WriteString(fmt.Sprintf("SELECT count(*) AS __applied FROM %s WHERE version = %s \\gset\n", LedgerTable, store.Quote(f.Version)))
		b.WriteString("\\if :__applied\n")
		b.WriteString(fmt.Sprintf("\\echo '· %s 已应用，跳过'\n", f.Label()))
		b.WriteString("\\else\n")
		b.WriteString("SELECT clock_timestamp() AS __t0 \\gset\n")
		b.WriteString(body)
		if !strings.HasSuffix(body, "\n") {
			b.WriteString("\n")
		}
		b.WriteString(fmt.Sprintf(
			"INSERT INTO %s(version, name, checksum, duration_ms) VALUES (%s, %s, %s, "+
				"round(EXTRACT(EPOCH FROM (clock_timestamp() - :'__t0'::timestamptz)) * 1000));\n",
			LedgerTable, store.Quote(f.Version), store.Quote(f.Name), store.Quote(f.Checksum)))
		b.WriteString("\\endif\n")
		b.WriteString("COMMIT;\n")
	}
	b.WriteString(fmt.Sprintf("SELECT pg_advisory_unlock(%d);\n", lockKey))
	return b.String(), nil
}

func versionSet(files []File) map[string]bool {
	set := make(map[string]bool, len(files))
	for _, f := range files {
		set[f.Version] = true
	}
	return set
}
