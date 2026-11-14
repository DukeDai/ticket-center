package store

import (
	"encoding/json"
	"fmt"
	"strings"
)

// 本文件是「值怎么进 SQL」的唯一机制。
//
// 为什么要有它：psql 是子进程，没有 $1 占位符，SQL 全是拼出来的。
// 以前唯一的防线是「记得调 store.Quote」，而「记得」是约定不是机制 ——
// 约定迟早会被漏掉一次，漏掉的那一次就是注入。
//
// 这里的做法：把「绑定一个值」做成一个类型，值在绑定的当场就被转义成
// SQL 字面量，之后拼 SQL 的人拿到的是**已经转义好的字面量**，不是原始值。
// 也就是说「忘了转义」这件事在类型上就不成立 —— 没有一个 API 能把
// 未经转义的字符串塞进 SQL。
//
// 两种用法：
//
//	sql := store.NewSQL("SELECT * FROM t WHERE a = ").Bind(a).And("b = ").Bind(b).String()
//	sql := store.NewSQL("SELECT * FROM t WHERE a = ").Bind(a).Where("b = ").Bind(b).String()
//
// Bind 接受任何值，内部走 Quote；Quote 覆盖不到的类型（struct、slice 等）
// 会被拒掉并返回错误，而不是悄悄变成一个奇怪的字面量。

// SQL 是拼 SQL 的累加器。
//
// 零值不可用，要用 NewSQL 起头。
type SQL struct {
	sb     strings.Builder
	errs   []error
	binds  int
	inList bool
}

// NewSQL 起一个 SQL 累加器。args 里如果是字符串，按原样拼进 SQL
// （写片段用）；其他类型会被当成绑定值处理。
func NewSQL(parts ...any) *SQL {
	s := &SQL{}
	for _, p := range parts {
		switch v := p.(type) {
		case string:
			s.sb.WriteString(v)
		case fmt.Stringer:
			s.sb.WriteString(v.String())
		default:
			// 片段位置出现非字符串：这是调用方的笔误，当场记下来。
			s.errs = append(s.errs, fmt.Errorf("SQL 片段位置出现非字符串值 %T（片段请用字符串）", p))
		}
	}
	return s
}

// Bind 绑定一个值，返回自己以便链式调用。
//
// 值走 Quote 转义。Quote 只认标量（nil / bool / 各种数值 / string），
// 其它类型（struct / slice / map / 指针等）**当场报错** ——
// 它们的 `fmt.Sprintf("%v")` 是个看着像字符串、语义完全不同的字面量
// （slice 会变成 `'[1 2 3]'`），拼进 SQL 就是一条错的值。
// 要绑定结构体请用 BindJSON。
func (s *SQL) Bind(v any) *SQL {
	s.binds++
	if !isScalar(v) {
		s.errs = append(s.errs, fmt.Errorf("绑定非标量值 %T：值要进 SQL 请用 BindJSON", v))
		s.sb.WriteString("NULL")
		return s
	}
	s.sb.WriteString(Quote(v))
	return s
}

// BindAll 绑定多个值，按顺序拼进去。
func (s *SQL) BindAll(vs ...any) *SQL {
	for _, v := range vs {
		s.Bind(v)
	}
	return s
}

// BindJSON 绑定一个 JSON 值（转义后加 ::jsonb）。
//
// 报文、快照、请求明细这类「结构不可控」的值走这里 ——
// 它们是本项目里最容易被塞进奇怪字符的东西。
func (s *SQL) BindJSON(v any) *SQL {
	s.binds++
	raw, err := json.Marshal(v)
	if err != nil {
		s.errs = append(s.errs, fmt.Errorf("绑定 JSON 值失败: %w", err))
		s.sb.WriteString("NULL")
		return s
	}
	s.sb.WriteString(Quote(string(raw)))
	s.sb.WriteString("::jsonb")
	return s
}

// And 拼一个 AND 条件片段。
func (s *SQL) And(cond string) *SQL {
	s.sb.WriteString(" AND ")
	s.sb.WriteString(cond)
	return s
}

// List 往一个逗号分隔的值列表末尾追加一项。
//
// 为什么要有它：VALUES (?, ?, ?)、SELECT a, b, c、IN (?, ?, ?) 这些位置
// 的分隔符是逗号，不是 AND —— And() 在这些位置会拼出 "AND"，
// 语法直接坏掉。
//
// 第一个 List 项前面不加分隔符（调用方自己写 "VALUES ("），
// 之后的每一项前面补一个逗号。
func (s *SQL) List(v any) *SQL {
	s.binds++
	if s.inList {
		s.sb.WriteString(", ")
	}
	s.inList = true
	if !isScalar(v) {
		s.errs = append(s.errs, fmt.Errorf("列表里出现非标量值 %T：值要进 SQL 请用 BindJSON", v))
		s.sb.WriteString("NULL")
		return s
	}
	s.sb.WriteString(Quote(v))
	return s
}

// ListJSON 往一个逗号分隔的值列表末尾追加一个 JSON 值。
func (s *SQL) ListJSON(v any) *SQL {
	s.binds++
	if s.inList {
		s.sb.WriteString(", ")
	}
	s.inList = true
	raw, err := json.Marshal(v)
	if err != nil {
		s.errs = append(s.errs, fmt.Errorf("绑定 JSON 值失败: %w", err))
		s.sb.WriteString("NULL")
		return s
	}
	s.sb.WriteString(Quote(string(raw)))
	s.sb.WriteString("::jsonb")
	return s
}

// EndList 结束当前这个值列表。
//
// 之后的片段不再补逗号 —— 一个 SQL 里可能有多段列表
// （VALUES 列表、SELECT 列表、IN 列表），它们各自独立。
func (s *SQL) EndList() *SQL {
	s.inList = false
	return s
}

// Text 追加一段字面文本（不带任何分隔符）。
//
// 与 And/Or 的区别：这两个自带 " AND " / " OR "。
// 收尾的括号、逗号、关键字这些位置要的是**原样拼接**。
func (s *SQL) Text(t string) *SQL {
	s.sb.WriteString(t)
	return s
}

// Or 拼一个 OR 条件片段。
func (s *SQL) Or(cond string) *SQL {
	s.sb.WriteString(" OR ")
	s.sb.WriteString(cond)
	return s
}

// Where 拼一个 WHERE 片段（不含关键字）。
func (s *SQL) Where(cond string) *SQL {
	s.sb.WriteString(" WHERE ")
	s.sb.WriteString(cond)
	return s
}

// String 返回拼好的 SQL；有错误时返回空串与第一个错误。
func (s *SQL) String() (string, error) {
	if len(s.errs) > 0 {
		return "", s.errs[0]
	}
	return s.sb.String(), nil
}

// MustString 返回拼好的 SQL，有错误就 panic。
//
// 只给「错误只可能是调用方笔误、而且当场就该炸」的场合用
// （比如启动期构造固定 SQL）。运行期的路径请用 String()。
func (s *SQL) MustString() string {
	sql, err := s.String()
	if err != nil {
		panic(err)
	}
	return sql
}

// isScalar 判断一个值是不是 Quote 认识的标量。
func isScalar(v any) bool {
	switch v.(type) {
	case nil, bool, int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64,
		float32, float64, string:
		return true
	}
	return false
}
