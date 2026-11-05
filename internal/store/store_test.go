package store

import (
	"os"
	"testing"
)

// 测试需要一个本地 PostgreSQL；没有就跳过（CI 上不该因此红）。
func testDB(t *testing.T, name string) *DB {
	t.Helper()
	host := os.Getenv("PGHOST")
	if host == "" {
		host = "127.0.0.1"
	}
	db := New(name)
	if _, err := db.Scalar("SELECT 1;"); err != nil {
		t.Skipf("跳过：本地 PostgreSQL 不可用（%v）", err)
	}
	return db
}

func TestRowsParsesQuotedJSON(t *testing.T) {
	db := testDB(t, "ticket_center")
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
		if got := Quote(c.in); got != c.want {
			t.Errorf("Quote(%v) = %s，期望 %s", c.in, got, c.want)
		}
	}
}
