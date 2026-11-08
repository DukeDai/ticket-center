// 这是一个外部测试包（package store_test）：它要用 testdb 建一次性库，
// 而 testdb 现在会走迁移引擎（它依赖 store），同包测试会形成导入环。
package store_test

import (
	"strconv"
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// testDB 起一个一次性的库，载入 schema + seed，测完自动删掉。
//
// 以前这里连的是开发机上的 ticket_center，结果是「测试结果取决于开发机当时的数据状态」：
// 数据被手工改过，测试就红；数据被清空，测试就空跑。现在每次都是干净的一次性库。
func testDB(t *testing.T) *store.DB {
	t.Helper()
	name := testdb.New(t, testdb.Options{Seed: true})
	return store.New(name)
}

func TestRowsParsesQuotedJSON(t *testing.T) {
	db := testDB(t)
	rows, err := db.Rows("SELECT variant_key, ticket_type_code, axes::text FROM v_product_variant_matrix " +
		"WHERE status='active' AND axes::text <> '[]' LIMIT 3;")
	if err != nil {
		t.Fatalf("查询失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("没有取到变体行")
	}
	for _, r := range rows {
		if r["variant_key"] == "" {
			t.Fatalf("列名解析异常：%v", r)
		}
		if r["axes"] == "" {
			t.Fatalf("axes 列为空：%v", r)
		}
		if r["axes"][0] != '[' {
			t.Fatalf("axes 不是 JSON 数组：%q", r["axes"])
		}
	}
}

func TestSeedLeavesIdentitySequencesUsable(t *testing.T) {
	// 种子数据用显式 id 插入，identity 序列必须同步推进。
	// 序列落后时应用第一次 INSERT 就撞主键，而不变量一条都发现不了。
	db := testDB(t)

	// 每个带 identity 序列的表，都要能发出一个不冲突的 id。
	tables, err := db.Query(`
		SELECT DISTINCT c.relname
		FROM pg_class s
		JOIN pg_depend d
		  ON d.objid = s.oid
		 AND d.classid = 'pg_class'::regclass
		 AND d.deptype IN ('a', 'i')
		JOIN pg_class c ON c.oid = d.refobjid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public' AND c.relkind = 'r' AND s.relkind = 'S'
		ORDER BY 1;`)
	if err != nil {
		t.Fatalf("取序列表清单失败：%v", err)
	}
	if len(tables) == 0 {
		t.Fatal("没有找到任何 identity 序列")
	}

	for _, tr := range tables {
		tbl := tr[0]
		mxRaw, err := db.Scalar("SELECT COALESCE(max(id),0) FROM " + tbl)
		if err != nil {
			t.Fatalf("读 %s 的 max(id) 失败：%v", tbl, err)
		}
		mx, err := strconv.ParseInt(mxRaw, 10, 64)
		if err != nil {
			t.Fatalf("%s 的 max(id) 不是整数：%q", tbl, mxRaw)
		}
		// nextval 会真的消耗一个值。这里取的是「应用马上要用的那个 id」，
		// 必须严格大于 max(id)，否则 INSERT 一定撞主键。
		nextRaw, err := db.Scalar("SELECT nextval(pg_get_serial_sequence('" + tbl + "','id'))")
		if err != nil {
			t.Fatalf("%s 发号失败：%v", tbl, err)
		}
		next, err := strconv.ParseInt(nextRaw, 10, 64)
		if err != nil {
			t.Fatalf("%s 发出的 id 不是整数：%q", tbl, nextRaw)
		}
		if next <= mx {
			t.Errorf("%s：序列发出 %d，但表里已有 id 到 %d —— 应用第一次 INSERT 就会撞主键",
				tbl, next, mx)
		}
	}
}

func TestQuote(t *testing.T) {
	cases := []struct {
		in   any
		want string
	}{
		{nil, "NULL"},
		{true, "true"},
		{42, "42"},
		{"abc", "'abc'"},
		{"O'Brien", "'O''Brien'"},
	}
	for _, c := range cases {
		if got := store.Quote(c.in); got != c.want {
			t.Errorf("Quote(%v) = %s，期望 %s", c.in, got, c.want)
		}
	}
}
