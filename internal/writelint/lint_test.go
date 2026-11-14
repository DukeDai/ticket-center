package writelint

import (
	"strings"
	"testing"
)

// check 对一段源码跑门禁，返回 findings。
func check(t *testing.T, files map[string]string) []Finding {
	t.Helper()
	pkg := Package{}
	for path, src := range files {
		pkg.Files = append(pkg.Files, SourceFile{Path: path, Src: []byte(src)})
	}
	out, err := Check(pkg)
	if err != nil {
		t.Fatalf("Check 失败: %v", err)
	}
	return out
}

// ── 规则 1：不许洗掉人的判断 ───────────────────────────────────────

// 无条件覆盖人的列 —— 报。
func TestUnconditionalOverwriteIsReported(t *testing.T) {
	src := `
package p

func write() {
	sql := "INSERT INTO product_mapping (supplier_product_id, product_id, match_evidence) " +
		"SELECT sp.id, p.id, ev " +
		"FROM sp ON CONFLICT (supplier_product_id, product_id) DO UPDATE SET " +
		"match_evidence = EXCLUDED.match_evidence, " +
		"status = EXCLUDED.status"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条，实际 %d 条: %v", len(findings), findings)
	}
	if !strings.Contains(findings[0].Detail, "match_evidence") {
		t.Errorf("详情里没点名被覆盖的列: %s", findings[0].Detail)
	}
}

// 带条件覆盖（CASE WHEN）—— 不报。这是修好之后的样子。
func TestConditionalOverwriteIsAllowed(t *testing.T) {
	src := `
package p

func write() {
	sql := "INSERT INTO product_mapping (supplier_product_id, product_id, match_evidence) " +
		"SELECT sp.id, p.id, ev " +
		"FROM sp ON CONFLICT (supplier_product_id, product_id) DO UPDATE SET " +
		"match_evidence = CASE WHEN product_mapping.match_type = 'manual' " +
		"THEN product_mapping.match_evidence ELSE EXCLUDED.match_evidence END, " +
		"status = CASE WHEN product_mapping.status = 'active' THEN 'active' ELSE EXCLUDED.status END"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 0 {
		t.Fatalf("条件覆盖不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// COALESCE（新值没有就留旧的）—— 不报。
func TestCoalesceOverwriteIsAllowed(t *testing.T) {
	src := `
package p

func write() {
	sql := "INSERT INTO product_mapping (supplier_product_id, product_id, match_evidence) " +
		"SELECT sp.id, p.id, ev FROM sp " +
		"ON CONFLICT (supplier_product_id, product_id) DO UPDATE SET " +
		"match_evidence = COALESCE(EXCLUDED.match_evidence, product_mapping.match_evidence)"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 0 {
		t.Fatalf("COALESCE 不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// 覆盖的不是人的列 —— 不报（读模型覆盖机器事实是对的）。
func TestMachineOwnedColumnOverwriteIsAllowed(t *testing.T) {
	src := `
package p

func write(p product) {
	sql := "INSERT INTO supplier_product (supplier_id, external_id, content_hash) " +
		"SELECT sp.id, ev, ch FROM sp " +
		"ON CONFLICT (supplier_id, external_id) DO UPDATE SET content_hash = EXCLUDED.content_hash"
	if strings.TrimSpace(p.ExternalID) == "" {
		return
	}
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 0 {
		t.Fatalf("覆盖机器自己的事实不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// 一段文本里有好几段 upsert —— 每段配自己的表。
// 错在这里：product_mapping 的那段配上了 supplier_product 的表名。
func TestEachUpsertPairsWithItsOwnTable(t *testing.T) {
	src := `
package p

func write() {
	a := "INSERT INTO product (id, name) SELECT a, b FROM t"
	b := "INSERT INTO product_mapping (supplier_product_id, product_id, match_evidence) " +
		"SELECT c, d, e FROM t " +
		"ON CONFLICT (supplier_product_id, product_id) DO UPDATE SET " +
		"match_evidence = EXCLUDED.match_evidence"
	_, _ = a, b
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条（只报 product_mapping 那一段），实际 %d 条: %v", len(findings), findings)
	}
	if !strings.Contains(findings[0].Detail, "product_mapping.match_evidence") {
		t.Errorf("报错了表或列: %s", findings[0].Detail)
	}
}

// ── 规则 2：写之前要校验标识 ───────────────────────────────────────

// 写了源侧表但没有校验 —— 报。
func TestMissingIDValidationIsReported(t *testing.T) {
	src := `
package p

func write() {
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条，实际 %d 条: %v", len(findings), findings)
	}
	if !strings.Contains(findings[0].Rule, "规则2") {
		t.Errorf("规则名不对: %s", findings[0].Rule)
	}
}

// 校验与写入**不在同一个文件** —— 不报（按包判，不是按文件判）。
// 现在的写法就是这样：校验在 plan.go，写入在 apply.go。
func TestValidationInAnotherFileCounts(t *testing.T) {
	write := `
package p

func write() {
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	validate := `
package p

import "strings"

func validate(p product) bool {
	return strings.TrimSpace(p.ExternalID) == ""
}
`
	findings := check(t, map[string]string{"apply.go": write, "plan.go": validate})
	if len(findings) != 0 {
		t.Fatalf("包里有校验就不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// 只提到这一列但没有跟空比过 —— 报（光提到不算校验）。
func TestMentioningColumnIsNotValidation(t *testing.T) {
	src := `
package p

func write() {
	id := product.ExternalID
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
	_ = id
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条，实际 %d 条: %v", len(findings), findings)
	}
}

// 拿 len(列) 比零 —— 算校验。
func TestLenComparisonCountsAsValidation(t *testing.T) {
	src := `
package p

func write(p product) {
	if len(p.ExternalID) == 0 {
		return
	}
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 0 {
		t.Fatalf("len 比较不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// 中间隔了一个局部变量 —— 也算校验（校验常常这么写）。
func TestAliasedIdentifierCountsAsValidation(t *testing.T) {
	src := `
package p

func write(p product) {
	id := p.ExternalID
	if strings.TrimSpace(id) == "" {
		return
	}
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 0 {
		t.Fatalf("局部变量中转不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// 别的表的写入不受规则 2 约束 —— 不报。
func TestOtherTablesAreNotAffected(t *testing.T) {
	src := `
package p

func write() {
	sql := "INSERT INTO product_mapping (supplier_product_id, product_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 0 {
		t.Fatalf("别的表不该报，实际 %d 条: %v", len(findings), findings)
	}
}

// ── 门禁不许自己骗自己 ─────────────────────────────────────────────
//
// 下面两条是**实测出来的坑**：门禁一度把「没校验」误判成「校验了」。
// 那比漏报更坏 —— 门禁绿着，bug 还在。

// 「一堆 id 的切片」不是标识本身。
// externalIDs 含 "ExternalID"，但拿 len(externalIDs)==0 当校验是错的。
func TestSliceOfIDsIsNotValidation(t *testing.T) {
	src := `
package p

func write(externalIDs []string) {
	if len(externalIDs) == 0 {
		return
	}
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条（len(externalIDs) 不是校验），实际 %d 条: %v", len(findings), findings)
	}
}

// 「拿标识当下标」不是校验 —— 那是别的东西。
func TestIdentifierAsIndexIsNotValidation(t *testing.T) {
	src := `
package p

func write(v variant) {
	idx := variantIdx[v.ExternalID]
	if len(idx) == 0 {
		return
	}
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条（下标不是校验），实际 %d 条: %v", len(findings), findings)
	}
}

// 拿标识跟**另一个标识**比 —— 不是空值校验。
func TestComparingTwoIDsIsNotValidation(t *testing.T) {
	src := `
package p

func write(p product, pid string) {
	if p.ExternalID == pid {
		return
	}
	sql := "INSERT INTO supplier_product (supplier_id, external_id) SELECT a, b FROM t"
	_ = sql
}
`
	findings := check(t, map[string]string{"a.go": src})
	if len(findings) != 1 {
		t.Fatalf("应该报 1 条（两个 id 比大小不是校验），实际 %d 条: %v", len(findings), findings)
	}
}

// ── 真实代码回归 ───────────────────────────────────────────────────

// 现在的同步写路径必须过门禁。
// 门禁自己跑得起来不算数 —— 它得在真代码上绿。
func TestRealSyncPackagePasses(t *testing.T) {
	findings, err := Walk("../../internal/sync")
	if err != nil {
		t.Fatalf("扫描失败: %v", err)
	}
	if len(findings) != 0 {
		t.Fatalf("internal/sync 应该有 0 条，实际 %d 条: %v", len(findings), findings)
	}
}

// 全仓库过门禁。
func TestWholeRepoPasses(t *testing.T) {
	findings, err := Walk("../..")
	if err != nil {
		t.Fatalf("扫描失败: %v", err)
	}
	if len(findings) != 0 {
		t.Fatalf("仓库应该有 0 条，实际 %d 条: %v", len(findings), findings)
	}
}
