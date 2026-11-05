// Package testdb 给测试提供一次性的、干净的 PostgreSQL 数据库。
//
// 为什么需要它：
//
//   - 以前 store / tripcom 的 DB 测试直接连本机的 ticket_center 库，
//     结果是「测试结果取决于开发机当时的数据状态」，不可复现；
//   - 数据库不可用时 t.Skip 让 `make test` 在没有数据库的机器上照样全绿，
//     门禁形同虚设。
//
// 现在每次测试都建一个带唯一后缀的临时库，载入 db/schema.sql（可选 db/seed.sql），
// 测完删掉。要让「数据库不可用」变成失败而不是跳过，设 TC_REQUIRE_DB=1
// （CI 必须设）。
package testdb

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Options 建库选项。
type Options struct {
	// Seed 为 true 时额外载入 db/seed.sql。
	Seed bool
	// Schema 为 true 时载入 db/schema.sql（默认 true）。
	NoSchema bool
}

// RepoRoot 从本包位置向上找 go.mod 所在目录。
func RepoRoot() string {
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

func psqlBin() string {
	if b := os.Getenv("PSQL_BIN"); b != "" {
		return b
	}
	return "psql"
}

func host() string {
	if h := os.Getenv("PGHOST"); h != "" {
		return h
	}
	return "127.0.0.1"
}

// Available 报告本地 PostgreSQL 是否可用。
func Available() error {
	cmd := exec.Command(psqlBin(), "-h", host(), "-d", "postgres", "-t", "-A", "-c", "SELECT 1;")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("本地 PostgreSQL 不可用：%s", strings.TrimSpace(string(out)))
	}
	return nil
}

// requireDB 决定数据库不可用时是跳过还是失败。
//
// 默认跳过（本地开发方便），CI 用 TC_REQUIRE_DB=1 让它失败，
// 否则「没有数据库」会变成一道假绿。
func requireDB(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		return
	}
	if os.Getenv("TC_REQUIRE_DB") == "1" {
		t.Fatalf("需要本地 PostgreSQL：%v", err)
	}
	t.Skipf("跳过：%v", err)
}

// New 建一个一次性数据库，返回库名。
//
// 库名形如 tc_test_<pid>_<n>，避免并发跑测试时互相踩。
// 测试结束时自动删除。
func New(t *testing.T, opts Options) string {
	t.Helper()
	requireDB(t, Available())

	name := fmt.Sprintf("tc_test_%d_%d", os.Getpid(), nextID())
	drop(name)
	run(t, "-d", "postgres", "-c", "CREATE DATABASE "+name+";")

	root := RepoRoot()
	if !opts.NoSchema {
		run(t, "-d", name, "-f", filepath.Join(root, "db", "schema.sql"))
	}
	if opts.Seed {
		run(t, "-d", name, "-f", filepath.Join(root, "db", "seed.sql"))
	}
	t.Cleanup(func() { drop(name) })
	return name
}

// Exec 在一次性库里跑一条 SQL，返回二维结果（无表头）。
func Exec(t *testing.T, db, sql string) [][]string {
	t.Helper()
	out := run(t, "-d", db, "-t", "-A", "-F", "\x1f", "-c", sql)
	rows := [][]string{}
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		rows = append(rows, strings.Split(line, "\x1f"))
	}
	return rows
}

func run(t *testing.T, args ...string) string {
	t.Helper()
	full := append([]string{"-h", host(), "-v", "ON_ERROR_STOP=1", "-q"}, args...)
	cmd := exec.Command(psqlBin(), full...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("psql %v 失败：%s", args, strings.TrimSpace(string(out)))
	}
	return string(out)
}

func drop(name string) {
	cmd := exec.Command(psqlBin(), "-h", host(), "-d", "postgres", "-q", "-c", "DROP DATABASE IF EXISTS "+name+";")
	_ = cmd.Run()
}

var idSeq int

func nextID() int {
	idSeq++
	return idSeq
}
