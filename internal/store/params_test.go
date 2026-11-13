package store_test

import (
	"strings"
	"testing"

	"ticket-center/internal/store"
)

// TestBindEscapesAtBindTime 是这套机制的核心约定：
// 绑定完拿到的就是**已经转义好的 SQL 字面量**，不是原始值。
//
// 绑一个带单引号的字符串，结果里不能出现能闭合引号的裸单引号。
func TestBindEscapesAtBindTime(t *testing.T) {
	sql := store.NewSQL("SELECT * FROM t WHERE name = ").Bind("O'Brien").MustString()
	if !strings.Contains(sql, "'O''Brien'") {
		t.Fatalf("绑定后没有转义单引号：%s", sql)
	}
	// 转义后 SQL 里只有一对引号边界（O''Brien 是两个转义引号）。
	if strings.Count(sql, "'") != 4 {
		t.Fatalf("引号数量不对（应为 4：两个边界 + 两个转义）：%s", sql)
	}
}

// TestBindRejectsInjection 钉住最要紧的一条：
// 一个拼进引号位置的值不许闭合引号、注入第二条语句。
func TestBindRejectsInjection(t *testing.T) {
	evil := "x'; DROP TABLE t; --"
	sql := store.NewSQL("SELECT * FROM t WHERE name = ").Bind(evil).MustString()
	// 转义后的正确形态是 'x''; DROP TABLE t; --' ——
	// 引号被加倍了，所以「闭合引号」这件事没发生。
	if !strings.Contains(sql, "'x''; DROP TABLE t; --'") {
		t.Fatalf("注入内容没有被转义：%s", sql)
	}
	// 真正的判据：值前后各只有一个引号边界。
	if strings.Count(sql, "'") != 4 {
		t.Fatalf("引号数量不对（应为 4）：%s", sql)
	}
}

// TestBindNonScalarIsRejected 钉住「不知道就说不知道」：
// 绑定非标量当场报错，不悄悄变成一个看着像字符串的字面量。
func TestBindNonScalarIsRejected(t *testing.T) {
	s := store.NewSQL("SELECT * FROM t WHERE tags = ").Bind([]string{"a", "b"})
	sql, err := s.String()
	if err == nil {
		t.Fatalf("绑定 slice 应当报错，却拿到 SQL：%s", sql)
	}
	if !strings.Contains(err.Error(), "BindJSON") {
		t.Fatalf("报错没有指向 BindJSON：%v", err)
	}
	// 报错了也不给出半成品 SQL。
	if sql != "" {
		t.Fatalf("出错时应当返回空串，却拿到：%s", sql)
	}
}

// TestBindJSON 钉住报文与快照这类「结构不可控」的值走 JSON 通道。
func TestBindJSON(t *testing.T) {
	payload := map[string]any{"note": "it's fine", "n": 3}
	sql := store.NewSQL("UPDATE t SET payload = ").BindJSON(payload).MustString()
	if !strings.Contains(sql, "::jsonb") {
		t.Fatalf("BindJSON 没有加 ::jsonb：%s", sql)
	}
	if !strings.Contains(sql, "''") {
		t.Fatalf("JSON 里的单引号没有转义：%s", sql)
	}
}

// TestBindScalars 覆盖 Quote 认识的标量：它们进 SQL 时不带引号（数值）。
func TestBindScalars(t *testing.T) {
	cases := []struct {
		in   any
		want string
	}{
		{nil, "NULL"},
		{true, "true"},
		{false, "false"},
		{42, "42"},
		{int64(-7), "-7"},
		{3.5, "3.5"},
		{"hi", "'hi'"},
	}
	for _, c := range cases {
		got := store.NewSQL("v = ").Bind(c.in).MustString()
		if got != "v = "+c.want {
			t.Fatalf("绑定 %v 得到 %q，期望 %q", c.in, got, "v = "+c.want)
		}
	}
}

// TestAndAndWhere 钉住累加器的形状：And / Where 自己带关键字。
func TestAndAndWhere(t *testing.T) {
	sql := store.NewSQL("SELECT * FROM t").Where("a = 1").And("b = 2").Or("c = 3").MustString()
	want := "SELECT * FROM t WHERE a = 1 AND b = 2 OR c = 3"
	if sql != want {
		t.Fatalf("拼出来是 %q，期望 %q", sql, want)
	}
}

// TestMustStringPanics 钉住 MustString 的契约：错只可能是调用方笔误，当场炸。
func TestMustStringPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("MustString 在有错时应当 panic")
		}
	}()
	store.NewSQL("v = ").Bind([]int{1}).MustString()
}

// TestQuoteIdent 覆盖标识符转义：双引号加倍。
func TestQuoteIdent(t *testing.T) {
	got := store.QuoteIdent(`we"ird`)
	want := `"we""ird"`
	if got != want {
		t.Fatalf("QuoteIdent 得到 %q，期望 %q", got, want)
	}
}
