package readmodel_test

import (
	"strconv"
	"testing"

	"ticket-center/internal/readmodel"
	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// 组合（异构融合方向 B）在 C 端的行为约定：
//
//   - 组合源侧没有商品条目，售价行与日历格子必须由它自己的配方推出来；
//   - 组合给客户的窗口 = 成分窗口的并集（家庭套餐里两日成人 + 一日儿童 = 两天）；
//   - 构成必须带出来（几份成人、几份儿童、各管几天），且不许与主数据分叉；
//   - 口径写错时门禁必须当场报出来 —— 不是等客诉。
const (
	mixedComboKey  = "family:2adult2d:1child1d:studio_only" // 两日成人 2 份 + 一日儿童 1 份
	singleComboKey = "family:2adult:1child:studio_only"     // 一日成人 2 份 + 一日儿童 1 份
	jpComboKey     = "jp:family:2adult:1child"              // 源侧日元、我们卖人民币的一张
)

func comboDB(t *testing.T) *store.DB {
	t.Helper()
	return store.New(testdb.New(t, testdb.Options{Seed: true}))
}

func comboID(t *testing.T, db *store.DB, key string) int64 {
	t.Helper()
	s, err := db.Scalar("SELECT id FROM product_variant WHERE variant_key = '" + key + "';")
	if err != nil {
		t.Fatalf("查组合 id 失败：%v", err)
	}
	if s == "" {
		t.Fatalf("种子里没有组合 %s", key)
	}
	var id int64
	for _, c := range s {
		if c < '0' || c > '9' {
			t.Fatalf("组合 id 不是数字：%s", s)
		}
		id = id*10 + int64(c-'0')
	}
	return id
}

func TestComboSyncGivesComboAPriceRowAndACalendarCell(t *testing.T) {
	db := comboDB(t)
	id := comboID(t, db, mixedComboKey)

	// 组合必须有带售价的售价行 —— C 端画不出一个没有价格的套餐。
	s, err := db.Scalar(`SELECT count(*) FROM price_calendar
	                      WHERE product_variant_id = ` + strconv.FormatInt(id, 10) + `
	                        AND status = 'active' AND sell_price IS NOT NULL;`)
	if err != nil {
		t.Fatalf("查组合售价行失败：%v", err)
	}
	if s == "0" {
		t.Fatal("组合没有带售价的售价行（C 端画不出它）")
	}

	// 日历格子上必须有价格：挂着一个卖不了的套餐 = 白占一个位置。
	s, err = db.Scalar(`SELECT count(*) FROM c_variant_calendar
	                     WHERE product_variant_id = ` + strconv.FormatInt(id, 10) + `
	                       AND status = 'available' AND price_min IS NOT NULL;`)
	if err != nil {
		t.Fatalf("查组合日历格子失败：%v", err)
	}
	if s == "0" {
		t.Fatal("组合的日历格子没有价格")
	}
}

func TestComboWindowIsTheUnionOfItsComponentWindows(t *testing.T) {
	db := comboDB(t)
	mixed := comboID(t, db, mixedComboKey)
	single := comboID(t, db, singleComboKey)

	// 两日成人 + 一日儿童 → 客户拿到的是两天的票（不是一天，也不是三天）。
	days, err := db.Scalar(`SELECT (valid_to - date)::text FROM c_variant_calendar
	                         WHERE product_variant_id = ` + strconv.FormatInt(mixed, 10) + `
	                         ORDER BY date LIMIT 1;`)
	if err != nil {
		t.Fatalf("查组合窗口失败：%v", err)
	}
	if days != "2" {
		t.Fatalf("混合窗口的组合应给客户 2 天，实际 %s 天", days)
	}

	// 两个成分都是一日 → 组合一日。
	days, err = db.Scalar(`SELECT (valid_to - date)::text FROM c_variant_calendar
	                        WHERE product_variant_id = ` + strconv.FormatInt(single, 10) + `
	                        ORDER BY date LIMIT 1;`)
	if err != nil {
		t.Fatalf("查组合窗口失败：%v", err)
	}
	if days != "1" {
		t.Fatalf("同窗口的组合应给客户 1 天，实际 %s 天", days)
	}
}

func TestComboSyncIsIdempotent(t *testing.T) {
	db := comboDB(t)

	before, err := db.Scalar(`SELECT count(*) FROM price_calendar WHERE product_variant_id IN (
	                             SELECT id FROM product_variant WHERE variant_role = 'combo');`)
	if err != nil {
		t.Fatalf("数组合售价行失败：%v", err)
	}

	for i := 0; i < 2; i++ {
		if _, err := readmodel.SyncCombos(db); err != nil {
			t.Fatalf("组合同步失败：%v", err)
		}
	}

	after, err := db.Scalar(`SELECT count(*) FROM price_calendar WHERE product_variant_id IN (
	                            SELECT id FROM product_variant WHERE variant_role = 'combo');`)
	if err != nil {
		t.Fatalf("数组合售价行失败：%v", err)
	}
	if before != after {
		t.Fatalf("组合同步不是幂等的：同步前 %s 行，同步后 %s 行", before, after)
	}
}

func TestComboCompositionMustNotDriftFromMasterData(t *testing.T) {
	db := comboDB(t)
	id := comboID(t, db, mixedComboKey)

	// 读模型里的成分被改错了（份数从 2 变成 5）——
	// C 端会显示「5 份成人」，实际只发 2 份。这是必须当场抓住的分叉。
	if err := db.Exec(`UPDATE c_variant_composition SET quantity = 5
	                    WHERE product_variant_id = ` + strconv.FormatInt(id, 10) + ` AND audience_code = 'adult';`); err != nil {
		t.Fatalf("改坏读模型成分失败：%v", err)
	}

	actual, err := db.Scalar(`SELECT count(*) FROM v_invariant_checks_readmodel
	                          WHERE seq = 90 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if actual == "0" {
		t.Fatal("读模型的组合构成与主数据分叉了，90 必须报 FAIL，实际还是 0")
	}
}

// TestComboFxTraceMustBeCheckedAgainstTheData 证明 92 有牙齿。
//
// 组合的成本来自配方，不是来自某一个源商品，所以它的 cost_source_product_id 是空的 ——
// 不变量 45（普通可售单元的折算留痕）按这个字段 join 源价行，直接跳过组合。
// 组合的折算留痕以前没人复查：留个假日期都没人知道。
// 92 专门查这件事，所以它必须真的能报红。
func TestComboFxTraceMustBeCheckedAgainstTheData(t *testing.T) {
	db := comboDB(t)
	id := comboID(t, db, jpComboKey)

	// 基线：留痕自洽，92 必须绿。
	actual, err := db.Scalar(`SELECT count(*) FROM v_invariant_checks_readmodel
	                          WHERE seq = 92 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if actual != "0" {
		t.Fatalf("基线的折算留痕就是自洽的，92 不该报红，实际报红 %s 项", actual)
	}

	// 坏法一：把折算因子改成与快照对不上的数。
	// 现实后果：客户按这个因子付了钱，对账时按快照复算出来的数对不上。
	if err := db.Exec(`UPDATE price_calendar
	                      SET rule = jsonb_set(rule, '{combo,0,fx_rate}', to_jsonb(0.5))
	                    WHERE product_variant_id = ` + strconv.FormatInt(id, 10)); err != nil {
		t.Fatalf("改坏折算因子失败：%v", err)
	}
	actual, err = db.Scalar(`SELECT count(*) FROM v_invariant_checks_readmodel
	                          WHERE seq = 92 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if actual == "0" {
		t.Fatal("折算因子与快照对不上，92 必须报 FAIL，实际还是 0")
	}

	// 坏法二：跨币种却不留快照日期（声称没用过这份汇率）。
	if err := db.Exec(`UPDATE price_calendar
	                      SET rule = jsonb_set(rule, '{combo,0,fx_rate}',
	                                           to_jsonb((rule->'combo'->0->>'fx_rate')::numeric))
	                    WHERE product_variant_id = ` + strconv.FormatInt(id, 10)); err != nil {
		t.Fatalf("恢复折算因子失败：%v", err)
	}
	if err := db.Exec(`UPDATE price_calendar
	                      SET rule = jsonb_set(rule, '{combo,0,fx_as_of}', 'null'::jsonb)
	                    WHERE product_variant_id = ` + strconv.FormatInt(id, 10)); err != nil {
		t.Fatalf("抹掉折算快照日期失败：%v", err)
	}
	actual, err = db.Scalar(`SELECT count(*) FROM v_invariant_checks_readmodel
	                          WHERE seq = 92 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if actual == "0" {
		t.Fatal("跨币种成分没留折算快照日期，92 必须报 FAIL，实际还是 0")
	}
}

// TestComboValidityRuleMustBeCheckedAgainstTheData 证明 89 不是「自己证明自己」。
//
// 89 拿组合的有效期与成分的有效期比，两边独立读：组合那边走函数，
// 成分那边直接从轴选项读。函数被改坏（组合取最短而不是并集）时，
// 现实后果是家庭套餐里两日成人票的第二天进不去 —— 门禁必须报出来。
func TestComboValidityRuleMustBeCheckedAgainstTheData(t *testing.T) {
	db := comboDB(t)

	broken := `CREATE OR REPLACE FUNCTION fn_variant_validity_days(p_variant_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE AS $fn$
    SELECT CASE
             WHEN EXISTS (SELECT 1 FROM product_variant_relation r
                           WHERE r.parent_variant_id = p_variant_id
                             AND r.relation_type = 'included')
             THEN (SELECT MIN(fn_variant_validity_days(r.child_variant_id))
                     FROM product_variant_relation r
                    WHERE r.parent_variant_id = p_variant_id
                      AND r.relation_type = 'included')
             ELSE COALESCE((SELECT MAX(ao.valid_days)
                              FROM product_variant_option pvo
                              JOIN product_axis_option ao ON ao.id = pvo.axis_option_id
                             WHERE pvo.product_variant_id = p_variant_id), 1)
           END;
$fn$;`
	if err := db.Exec(broken); err != nil {
		t.Fatalf("改坏有效期口径失败：%v", err)
	}

	actual, err := db.Scalar(`SELECT count(*) FROM v_invariant_checks_readmodel
	                          WHERE seq = 89 AND actual > 0;`)
	if err != nil {
		t.Fatalf("查不变量失败：%v", err)
	}
	if actual == "0" {
		t.Fatal("组合的有效期规则被写错（取最短而不是并集），89 必须报 FAIL，实际还是 0")
	}
}
