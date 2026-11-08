package migrate_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ticket-center/internal/migrate"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 迁移引擎的行为约定：
//   - 迁移只跑一次（账本说了算）；
//   - 已发布的迁移文件不许改（改了报错）；
//   - 存量库可以被接管（基线），但接管后新迁移照常应用。

func writeMigration(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatalf("写迁移文件失败：%v", err)
	}
}

func ledgerRows(t *testing.T, db *store.DB) []map[string]string {
	t.Helper()
	rows, err := db.Rows("SELECT version, name, checksum FROM ops.schema_migration ORDER BY version;")
	if err != nil {
		t.Fatalf("读账本失败：%v", err)
	}
	return rows
}

func TestApplyRunsMigrationOnceAndRecordsIt(t *testing.T) {
	name := testdb.New(t, testdb.Options{NoSchema: true})
	db := store.New(name)
	dir := t.TempDir()
	writeMigration(t, dir, "001_probe.sql", "CREATE TABLE probe_a (id INT);\n")

	res, err := migrate.Apply(db, migrate.Options{Dir: dir})
	if err != nil {
		t.Fatalf("应用迁移失败：%v", err)
	}
	if len(res.Applied) != 1 || res.Applied[0] != "001_probe" {
		t.Fatalf("应应用 001_probe，实际：%v", res.Applied)
	}
	if has, err := db.TableExists("probe_a"); err != nil || !has {
		t.Fatalf("迁移建的表应该存在：%v %v", has, err)
	}
	rows := ledgerRows(t, db)
	if len(rows) != 1 || rows[0]["version"] != "001" {
		t.Fatalf("账本应有一条 001 记录，实际：%v", rows)
	}

	// 再跑一次：什么都不该发生。
	res, err = migrate.Apply(db, migrate.Options{Dir: dir})
	if err != nil {
		t.Fatalf("重复应用应成功（幂等）：%v", err)
	}
	if len(res.Applied) != 0 {
		t.Fatalf("第二次不应再应用：%v", res.Applied)
	}
	if len(res.Skipped) != 1 {
		t.Fatalf("第二次应记为跳过：%v", res.Skipped)
	}
	if len(ledgerRows(t, db)) != 1 {
		t.Fatal("账本不应重复记账")
	}
}

func TestChangedMigrationFileIsRejected(t *testing.T) {
	name := testdb.New(t, testdb.Options{NoSchema: true})
	db := store.New(name)
	dir := t.TempDir()
	path := filepath.Join(dir, "001_probe.sql")
	writeMigration(t, dir, "001_probe.sql", "CREATE TABLE probe_a (id INT);\n")
	if _, err := migrate.Apply(db, migrate.Options{Dir: dir}); err != nil {
		t.Fatalf("首次应用失败：%v", err)
	}

	// 已发布的迁移被改了一行 —— 引擎必须拒绝继续跑。
	writeMigration(t, dir, "001_probe.sql", "CREATE TABLE probe_a (id INT, extra TEXT);\n")
	_, err := migrate.Apply(db, migrate.Options{Dir: dir})
	if err == nil {
		t.Fatal("改动已应用的迁移文件后应报错")
	}
	if !strings.Contains(err.Error(), "被修改过") {
		t.Fatalf("报错要说清是内容漂移：%v", err)
	}
	if _, statErr := os.Stat(path); statErr != nil {
		t.Fatalf("文件应还在：%v", statErr)
	}
}

func TestBaselineTakesOverExistingStructure(t *testing.T) {
	name := testdb.New(t, testdb.Options{NoSchema: true})
	db := store.New(name)
	dir := t.TempDir()
	writeMigration(t, dir, "001_probe.sql", "CREATE TABLE probe_a (id INT);\n")
	writeMigration(t, dir, "002_more.sql", "ALTER TABLE probe_a ADD COLUMN extra TEXT;\n")

	// 存量库：结构是用别的方式建出来的，账本还是空的。
	testdb.Exec(t, name, "CREATE TABLE probe_a (id INT);")

	res, err := migrate.Apply(db, migrate.Options{Dir: dir, Baseline: "001"})
	if err != nil {
		t.Fatalf("基线接管失败：%v", err)
	}
	if len(res.Baselined) != 1 || res.Baselined[0] != "001_probe" {
		t.Fatalf("应把 001 记为基线：%v", res.Baselined)
	}
	if len(res.Applied) != 1 || res.Applied[0] != "002_more" {
		t.Fatalf("基线之后的新迁移照常应用：%v", res.Applied)
	}
	// 002 真的执行了（列存在），001 没有重跑（表结构原样）。
	cols := testdb.Exec(t, name, "SELECT column_name FROM information_schema.columns WHERE table_name='probe_a';")
	found := false
	for _, c := range cols {
		if len(c) > 0 && c[0] == "extra" {
			found = true
		}
	}
	if !found {
		t.Fatal("002 迁移应已执行")
	}
}

func TestBaselineRefusesWhenLedgerNotEmpty(t *testing.T) {
	name := testdb.New(t, testdb.Options{NoSchema: true})
	db := store.New(name)
	dir := t.TempDir()
	writeMigration(t, dir, "001_probe.sql", "CREATE TABLE probe_a (id INT);\n")
	if _, err := migrate.Apply(db, migrate.Options{Dir: dir}); err != nil {
		t.Fatalf("首次应用失败：%v", err)
	}
	if _, err := migrate.Apply(db, migrate.Options{Dir: dir, Baseline: "001"}); err == nil {
		t.Fatal("账本非空时不应允许基线")
	}
}

func TestLoadFilesRejectsUnknownNaming(t *testing.T) {
	dir := t.TempDir()
	writeMigration(t, dir, "probe.sql", "SELECT 1;\n")
	if _, err := migrate.LoadFiles(dir); err == nil {
		t.Fatal("不合约定的文件名应报错")
	}
}

func TestRealMigrationsApplyCleanly(t *testing.T) {
	name := testdb.New(t, testdb.Options{})
	db := store.New(name)
	rows := ledgerRows(t, db)
	if len(rows) == 0 {
		t.Fatal("账本应有基线记录")
	}
	for _, table := range []string{"product", "price_calendar", "sales_order"} {
		has, err := db.TableExists(table)
		if err != nil || !has {
			t.Fatalf("表 %s 应该存在：%v %v", table, has, err)
		}
	}
	if v, err := db.Scalar("SELECT to_regclass('ops.schema_migration') IS NOT NULL;"); err != nil || v != "t" {
		t.Fatalf("账本表应该存在：%v %v", v, err)
	}
}
