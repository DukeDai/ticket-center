// Package store 是数据库访问层。
//
// 只用 psql 子进程（零第三方依赖），与仓库既有的 scripts/mapping_dryrun.py 做法一致。
package store

import (
	"encoding/csv"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// DB 是一个 PostgreSQL 数据库句柄。
type DB struct {
	Bin  string
	Host string
	Name string
}

// New 构造数据库句柄。bin/host 为空时取环境变量或默认值。
func New(name string) *DB {
	bin := os.Getenv("PSQL_BIN")
	if bin == "" {
		bin = "psql"
	}
	host := os.Getenv("PGHOST")
	if host == "" {
		host = "127.0.0.1"
	}
	return &DB{Bin: bin, Host: host, Name: name}
}

// baseArgs 只放参数，**不要**再放二进制名（否则 psql 会把第一个参数当成用户名）。
func (d *DB) baseArgs() []string {
	return []string{"-h", d.Host, "-d", d.Name, "-v", "ON_ERROR_STOP=1", "-q"}
}

// Exec 执行一条语句。
func (d *DB) Exec(sql string) error {
	cmd := exec.Command(d.Bin, append(d.baseArgs(), "-c", sql)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("SQL 执行失败（%s）：%s", err, truncate(string(out), 4000))
	}
	return nil
}

// Query 返回二维字符串结果（无表头）。
func (d *DB) Query(sql string) ([][]string, error) {
	cmd := exec.Command(d.Bin, append(d.baseArgs(), "-t", "-A", "-F", "\x1f", "-c", sql)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("SQL 执行失败（%s）：%s", err, truncate(string(out), 4000))
	}
	var rows [][]string
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		rows = append(rows, strings.Split(line, "\x1f"))
	}
	return rows, nil
}

// Rows 返回带列名的结果集。
func (d *DB) Rows(sql string) ([]map[string]string, error) {
	cmd := exec.Command(d.Bin, append(d.baseArgs(), "--csv", "-c", sql)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("SQL 执行失败（%s）：%s", err, truncate(string(out), 4000))
	}
	r := csv.NewReader(strings.NewReader(string(out)))
	r.FieldsPerRecord = -1
	records, err := r.ReadAll()
	if err != nil {
		return nil, fmt.Errorf("解析 CSV 结果失败: %w", err)
	}
	if len(records) == 0 {
		return nil, nil
	}
	header := records[0]
	var rows []map[string]string
	for _, rec := range records[1:] {
		m := map[string]string{}
		for i, h := range header {
			if i < len(rec) {
				m[h] = rec[i]
			}
		}
		rows = append(rows, m)
	}
	return rows, nil
}

// Scalar 返回第一行第一列。
func (d *DB) Scalar(sql string) (string, error) {
	rows, err := d.Query(sql)
	if err != nil {
		return "", err
	}
	if len(rows) == 0 || len(rows[0]) == 0 {
		return "", nil
	}
	return rows[0][0], nil
}

// TableExists 判断表是否存在。
func (d *DB) TableExists(name string) (bool, error) {
	v, err := d.Scalar(fmt.Sprintf(
		"SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name=%s;",
		Quote(name)))
	if err != nil {
		return false, err
	}
	return v == "1", nil
}

// ExecScript 在单个 psql 会话里执行一段脚本，返回输出。
//
// 整段脚本共用一个会话，所以会话级的锁（advisory lock）和
// 显式事务在脚本里都有效。脚本从 stdin 喂给 psql。
func (d *DB) ExecScript(script string) (string, error) {
	cmd := exec.Command(d.Bin, append(d.baseArgs(), "-f", "-")...)
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("脚本执行失败: %s", truncate(string(out), 4000))
	}
	return string(out), nil
}

// ExecFile 执行一个 SQL 文件。
func (d *DB) ExecFile(path string) error {
	cmd := exec.Command(d.Bin, append(d.baseArgs(), "-f", path)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s 执行失败: %s", path, truncate(string(out), 4000))
	}
	return nil
}

// DatabaseExists 判断数据库是否存在。
func DatabaseExists(bin, host, name string) (bool, error) {
	cmd := exec.Command(bin, "-h", host, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-q", "-t", "-A", "-c",
		fmt.Sprintf("SELECT count(*) FROM pg_database WHERE datname=%s;", Quote(name)))
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false, fmt.Errorf("连接 postgres 失败: %s", truncate(string(out), 2000))
	}
	return strings.TrimSpace(string(out)) == "1", nil
}

// CreateDatabase 建库。
func CreateDatabase(bin, host, name string) error {
	cmd := exec.Command(bin, "-h", host, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-q", "-c",
		fmt.Sprintf("CREATE DATABASE %s;", QuoteIdent(name)))
	out, err := cmd.CombinedOutput()
	if err != nil && !strings.Contains(string(out), "already exists") {
		return fmt.Errorf("建库失败: %s", truncate(string(out), 2000))
	}
	return nil
}

// PLError 把 psql 的报错整理成一句人话。
//
// psql 的输出长这样：
//
//	psql:... ERROR:  变体 9 在 <日期> 没有可售价格（...）
//
// 这里把 ERROR 后面那句抠出来，其余噪音丢掉 —— 调用方要的是「卡在哪」。
func PLError(err error) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if i := strings.Index(msg, "ERROR:"); i >= 0 {
		rest := msg[i+len("ERROR:"):]
		if j := strings.Index(rest, "\n"); j >= 0 {
			rest = rest[:j]
		}
		rest = strings.TrimSpace(rest)
		if rest != "" {
			return fmt.Errorf("%s", rest)
		}
	}
	return err
}

// Quote 把值转成 SQL 字面量。
func Quote(v any) string {
	switch t := v.(type) {
	case nil:
		return "NULL"
	case bool:
		if t {
			return "true"
		}
		return "false"
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case string:
		return "'" + strings.ReplaceAll(t, "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(fmt.Sprintf("%v", v), "'", "''") + "'"
}

// QuoteIdent 把标识符转成 SQL 字面量（表名/库名）。
func QuoteIdent(v string) string {
	return `"` + strings.ReplaceAll(v, `"`, `""`) + `"`
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
