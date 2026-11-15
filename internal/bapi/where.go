package bapi

import (
	"ticket-center/internal/store"
)

// where 是「拼 WHERE 条件」的累加器。
//
// 为什么不用 store.SQL.And 直接拼：And 永远前置 " AND "，
// 第一个条件就会拼出 "FROM v WHERE ... AND ..." 之外的东西 ——
// 准确说是 "FROM v AND channel_id = 1"，语法直接坏。
// 所以要有一层知道「第一个条件还没出」的包装。
//
// 它同时收紧了口径：条件只经由 Bind 进去（值在绑定的当场转义），
// 标识符走 QuoteIdent。写 SQL 的人在这里写不出一个未经转义的值。
type where struct {
	sql     *store.SQL
	started bool
	inGroup bool
}

func newWhere(sql *store.SQL) *where {
	return &where{sql: sql}
}

// Eq 加一个相等条件。
func (w *where) Eq(column string, v any) *where {
	return w.add(column + " = ", v)
}

// Ne 加一个不等条件。
func (w *where) Ne(column string, v any) *where {
	return w.add(column + " <> ", v)
}

// Ge 加一个大于等于条件。
func (w *where) Ge(column string, v any) *where {
	return w.add(column + " >= ", v)
}

// Gt 加一个大于条件。
func (w *where) Gt(column string, v any) *where {
	return w.add(column + " > ", v)
}

// Raw 加一个已经写好占位的条件片段。
//
// 片段里不许有值 —— 值一律走 Eq 这类方法。用于「column IS NULL」这种
// 没有值的位置。
func (w *where) Raw(cond string) *where {
	if !w.started {
		w.sql.Text(" WHERE ")
		w.started = true
	} else {
		w.sql.And("")
	}
	w.sql.Text(cond)
	return w
}

// Like 加一个模糊匹配条件（两侧加 %）。
//
// 值会被转义并转义 LIKE 的通配符（% 与 _），
// 否则搜「50%」会匹配到「50」开头的任何字符串。
//
// 用法是成对的：Like 一列，再 OrLike 另一列 —— 两列命中任一即可。
// 出来的 SQL 带括号：`WHERE (a ILIKE ... OR b ILIKE ...)`。
// 不带括号的话，`AND` 与 `OR` 的优先级会让 `a = 1 AND b ILIKE x OR c ILIKE y`
// 变成「(a=1 AND b ILIKE x) OR (c ILIKE y)」，筛选的语义就变了 ——
// 页面看起来「筛多了」，但说不清多出来的是什么。
func (w *where) Like(column, v string) *where {
	w.openGroup()
	w.sql.Text(column + " ILIKE ")
	w.sql.Bind("%" + escapeLike(v) + "%")
	w.sql.Text(" ESCAPE '\\'")
	return w
}

// OrLike 在 Like 打开的括号组里追加一个 OR 条件。
func (w *where) OrLike(column, v string) *where {
	w.sql.Or(column + " ILIKE ")
	w.sql.Bind("%" + escapeLike(v) + "%")
	w.sql.Text(" ESCAPE '\\'")
	return w
}

// CloseGroup 关闭 Like 打开的括号组。
func (w *where) CloseGroup() *where {
	w.sql.Text(")")
	w.inGroup = false
	return w
}

// openGroup 打开一个括号组（第一个 Like 时开，之后复用同一个组）。
func (w *where) openGroup() {
	if w.inGroup {
		return
	}
	if !w.started {
		w.sql.Text(" WHERE ")
		w.started = true
	} else {
		w.sql.And("")
	}
	w.sql.Text("(")
	w.inGroup = true
}

// add 是 Eq/Ne/Ge/Gt 共用的那一步。
func (w *where) add(prefix string, v any) *where {
	if !w.started {
		w.sql.Text(" WHERE ")
		w.started = true
	} else {
		w.sql.And("")
	}
	w.sql.Text(prefix)
	w.sql.Bind(v)
	return w
}
