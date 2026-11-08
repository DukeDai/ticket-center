package coverage_test

import (
	"strings"
	"testing"

	"ticket-center/internal/coverage"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 覆盖判定这条规则的行为约定：
//   - 判定只住在库里的 fn_variant_covered / fn_variant_coverage_gaps，
//     Go 侧只负责把结果读出来（不重算）；
//   - 人群不匹配 → 覆盖不住，并说清缺哪一项；
//   - 轴取值不匹配 → 覆盖不住，并说清缺哪一项；
//   - excludes 里的取值即使在 axes 里也不算数。

func seeded(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

// byKey 从规范变体清单里挑一个。
func byKey(t *testing.T, list []coverage.Canonical, key string) coverage.Canonical {
	t.Helper()
	for _, c := range list {
		if c.Key == key {
			return c
		}
	}
	t.Fatalf("规范变体清单里没有 %s", key)
	return coverage.Canonical{}
}

func TestLoadCanonicalReadsVariantKeys(t *testing.T) {
	db := seeded(t)

	list, err := coverage.LoadCanonical(db)
	if err != nil {
		t.Fatalf("读规范变体失败：%v", err)
	}
	if len(list) == 0 {
		t.Fatal("规范变体清单不该是空的")
	}
	for _, c := range list {
		if c.VariantID == 0 {
			t.Fatalf("变体 %s 没有 id", c.Key)
		}
	}
	// 种子里的成人一日票
	byKey(t, list, "adult:1d:studio_only")
}

func TestJudgeCoversMatchingVariantOnly(t *testing.T) {
	db := seeded(t)

	list, err := coverage.LoadCanonical(db)
	if err != nil {
		t.Fatalf("读规范变体失败：%v", err)
	}

	cov := coverage.JSON(normalize.Coverage{Axes: map[string][]string{
		"audience":   {"adult"},
		"pass_type":  {"1d"},
		"park_scope": {"studio_only"},
	}})

	verdicts, err := coverage.Judge(db, cov, list)
	if err != nil {
		t.Fatalf("判定失败：%v", err)
	}
	if len(verdicts) == 0 {
		t.Fatal("判定结果不该是空的")
	}

	byVariant := map[string]coverage.Verdict{}
	for _, v := range verdicts {
		byVariant[v.Key] = v
	}

	adult := byVariant["adult:1d:studio_only"]
	if !adult.CanFulfil {
		t.Fatalf("人群与轴取值都对，覆盖得住却判成覆盖不住：%v", adult.Gaps)
	}

	child := byVariant["child:1d:studio_only"]
	if child.CanFulfil {
		t.Fatal("人群不匹配，覆盖得住是错的")
	}
	if !strings.Contains(strings.Join(child.Gaps, ","), "audience:child") {
		t.Fatalf("缺什么要说清，实际缺口是 %v", child.Gaps)
	}

	// 票种不匹配：只声明一日票，覆盖不了双日票
	twoDay := byVariant["adult:2d:studio_only"]
	if twoDay.CanFulfil {
		t.Fatal("票种不匹配，覆盖得住是错的")
	}
	if !strings.Contains(strings.Join(twoDay.Gaps, ","), "pass_type:2d") {
		t.Fatalf("缺什么要说清，实际缺口是 %v", twoDay.Gaps)
	}
}

func TestJudgeRespectsExcludes(t *testing.T) {
	db := seeded(t)

	list, err := coverage.LoadCanonical(db)
	if err != nil {
		t.Fatalf("读规范变体失败：%v", err)
	}

	cov := coverage.JSON(normalize.Coverage{
		Axes:     map[string][]string{"audience": {"adult", "child"}},
		Excludes: []string{"child"},
	})

	child := byKey(t, list, "child:1d:studio_only")
	v, err := coverage.JudgeOne(db, cov, child)
	if err != nil {
		t.Fatalf("判定失败：%v", err)
	}
	if v.CanFulfil {
		t.Fatal("excludes 里的取值不该被覆盖")
	}
	if !strings.Contains(strings.Join(v.Gaps, ","), "audience:child") {
		t.Fatalf("缺口要说清，实际是 %v", v.Gaps)
	}
}

func TestJudgeOneRejectsUnknownVariant(t *testing.T) {
	db := seeded(t)

	if _, err := coverage.JudgeOne(db, "{}", coverage.Canonical{VariantID: 999999, Key: "nope"}); err == nil {
		t.Fatal("不存在的变体应当报错，不该静默返回")
	}
}
