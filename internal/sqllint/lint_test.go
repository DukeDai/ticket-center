package sqllint

import (
	"strings"
	"testing"
)

// checkOne 跑一次门禁，返回条数。
//
// 源码按「一个包」传进去 —— 常量是包级的，
// 跨文件的常量解析要靠这一点才能验。
func checkOne(t *testing.T, files map[string]string) []Finding {
	t.Helper()
	var pkg Package
	for path, src := range files {
		pkg.Files = append(pkg.Files, SourceFile{Path: path, Src: []byte(src)})
	}
	findings, err := Check(pkg)
	if err != nil {
		t.Fatalf("检查失败: %v", err)
	}
	return findings
}

// TestFlagsRawInterpolation 钉住门禁的主判据：
// 没转义的值拼进 SQL 的引号位置，要被报出来。
func TestFlagsRawInterpolation(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
func q(db *DB, name string) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE name = '%s'", name))
}
`})
	if len(findings) != 1 {
		t.Fatalf("应当报出 1 处，却报了 %d 处：%v", len(findings), findings)
	}
	if !strings.Contains(findings[0].Expr, "name") {
		t.Fatalf("报出的参数不对：%s", findings[0].Expr)
	}
}

// TestAcceptsQuoted 钉住「转义过的不报」。
func TestAcceptsQuoted(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
func q(db *DB, name string) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE name = %s", store.Quote(name)))
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE name = %s", store.QuoteIdent(name)))
}
`})
	if len(findings) != 0 {
		t.Fatalf("转义过的值不该报，却报了 %d 处：%v", len(findings), findings)
	}
}

// TestAcceptsStringLiteral 钉住「编译期常量不报」。
func TestAcceptsStringLiteral(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
func q(db *DB) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE name = '%s'", "固定值"))
}
`})
	if len(findings) != 0 {
		t.Fatalf("字符串字面量不该报，却报了 %d 处：%v", len(findings), findings)
	}
}

// TestAcceptsPackageConst 钉住包级常量解析：
// 常量定义在 a.go、用在 b.go，也不该报。
//
// 这是跨文件的：只看 b.go 认不出那个名字是常量。
func TestAcceptsPackageConst(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
const channelType = "b2c_own"
`,
		"b.go": `package p
func q(db *DB) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE type = '%s'", channelType))
}
`})
	if len(findings) != 0 {
		t.Fatalf("包级常量不该报，却报了 %d 处：%v", len(findings), findings)
	}
}

// TestFlagsFragmentSQL 钉住「片段形态的 SQL」也要被认出来：
//
//	" AND date >= DATE '%s'"
//
// 这种片段里没有 SELECT、没有 WHERE，单看关键词会漏掉。
// 但它是拼进 SQL 的，值位置照样会被字符串内容打断。
func TestFlagsFragmentSQL(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
func q(db *DB, day string) {
	where := fmt.Sprintf(" AND date >= DATE '%s'", day)
	db.Rows("SELECT * FROM c WHERE " + where)
}
`})
	if len(findings) != 1 {
		t.Fatalf("片段形态的 SQL 应当报出 1 处，却报了 %d 处：%v", len(findings), findings)
	}
}

// TestIgnoresNonSQL 钉住误伤控制：
// 不是 SQL 的格式化不该报。
func TestIgnoresNonSQL(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
func q(name string) {
	msg := fmt.Sprintf("变体 %s 不存在", name)
	fmt.Sprintf("第 %d 页", 3)
}
`})
	if len(findings) != 0 {
		t.Fatalf("非 SQL 的格式化不该报，却报了 %d 处：%v", len(findings), findings)
	}
}

// TestIgnoresBareNumericSlot 钉住门禁只盯带引号的位置：
// 裸的数值位置（col = 42）不会被字符串内容打断，不是注入面。
func TestIgnoresBareNumericSlot(t *testing.T) {
	findings := checkOne(t, map[string]string{
		"a.go": `package p
func q(db *DB, id int) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE id = %d", id))
}
`})
	if len(findings) != 0 {
		t.Fatalf("裸数值位置不该报，却报了 %d 处：%v", len(findings), findings)
	}
}

// TestSkipsTestFiles 钉住「测试不受门禁约束」：
// 测试要的就是随手拼个怪字符串看看会不会炸。
func TestSkipsTestFiles(t *testing.T) {
	findings, err := Walk("testdata/lintwalk")
	if err != nil {
		t.Fatalf("扫描失败: %v", err)
	}
	if len(findings) != 0 {
		t.Fatalf("_test.go 不该被扫，却报了 %d 处：%v", len(findings), findings)
	}
}
