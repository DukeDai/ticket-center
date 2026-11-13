// Package sqllint 检查「值怎么进 SQL」。
//
// 背景：psql 是子进程，没有 $1 占位符，SQL 全是拼出来的。
// 唯一的防线是「记得调 store.Quote」，而「记得」是约定不是机制 ——
// 约定迟早会被漏掉一次，漏掉的那一次就是注入。
//
// 这个包把那条约定变成门禁：扫 AST，找出「把没转义的值拼进 SQL」的地方。
//
// 判据分三步，每一步都宁可放过也不误伤：
//
//  1. 这是不是一条 SQL？（格式串里有没有 SQL 关键字）
//  2. 有没有把值拼进一个「带引号的位置」？（'%s' / "%s" / `DATE '%s'`）
//  3. 那个值转义了吗？（包在 store.Quote / store.QuoteIdent 里，或本身就是常量）
//
// 三条都成立才报。漏报一个注入点比多报一处噪音更可接受 —— 噪音多了门禁就没人看了。
package sqllint

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Finding 是一条问题。
type Finding struct {
	// File 是相对路径。
	File string
	// Line 是行号（1 起）。
	Line int
	// ArgIndex 是出问题的那个格式化参数的位置（0 起，第一个值参数是 0）。
	ArgIndex int
	// Format 是格式串。
	Format string
	// Expr 是那个没转义的值的源码文本。
	Expr string
}

// String 渲染成一行人话。
func (f Finding) String() string {
	return fmt.Sprintf("%s:%d: SQL 字面量位置拼了没转义的值 %s（格式串 %q，第 %d 个参数）",
		f.File, f.Line, f.Expr, f.Format, f.ArgIndex+1)
}

// Result 是一次扫描的结果。
type Result struct {
	Findings []Finding
}

// OK 表示没查到问题。
func (r Result) OK() bool { return len(r.Findings) == 0 }

// sqlKeywords 是「这条格式串像不像 SQL」的判据。
//
// 只取那些几乎不可能出现在人话里的词：一个错误消息里出现 "from" / "where"
// 的概率不为零，但一个错误消息里出现 "SELECT " 或 " WHERE " 的概率极低。
//
// 末尾的空格是要的：「FROMER」这种词不是 SQL。
var sqlKeywords = []string{
	"SELECT ", "INSERT ", "UPDATE ", "DELETE ", " FROM ", " WHERE ",
	"JOIN ", "VALUES ", "CREATE ", "ALTER ", "DROP ",
}

// whereClauseRe 认出 WHERE 子句（可以带表别名）。
//
// 「c.channel_id = %d AND c.locale = '%s'」这种片段本身没有 SELECT，
// 但它显然是 SQL 的 WHERE 子句 —— 单看关键词会漏掉。
var whereClauseRe = regexp.MustCompile(`(?i)\bwhere\b\s+`)

// sqlFragmentRe 认出「被拼进 SQL 的片段」的三种形态：
//
//	WHERE 子句片段：  " AND date >= DATE '%s'"
//	类型字面量：      "DATE '%s'"、  "TIMESTAMP '%s'"
//	比较表达式：      "col = '%s'"、 "col >= '%s'"
//
// 为什么单看关键词不够：条件片段常常只有一个 AND 开头，
// 「AND date >= DATE '%s'」里没有 SELECT、没有 WHERE。
// 但它照样是拼进 SQL 的，而它的值位置照样会被字符串内容打断。
//
// 比较表达式这一条要小心误伤：人话里也有「x = '%s'」这种形状。
// 所以要求左边是一个标识符形态（可带表别名前缀），
// 而「错误信息里说 %s = '%s'」这种形态左边是空白 —— 认不出来。
var sqlFragmentRe = regexp.MustCompile(
	`(?i)(\bwhere\b\s+` +
		`|\b(and|or)\b\s+[a-z_][a-z0-9_.]*\s*(=|<>|!=|<=|>=|<|>)\s*` +
		`|\b(date|timestamp|timestamptz|time|interval)\s+'%` +
		`|\b[a-z_][a-z0-9_.]*\s*(=|<>|!=|<=|>=|<|>)\s*'%` +
		`|\b[a-z_][a-z0-9_.]*\s+(date|timestamp|timestamptz)\s+)`)

// looksLikeSQL 判断格式串是不是 SQL。
func looksLikeSQL(format string) bool {
	up := strings.ToUpper(format)
	for _, kw := range sqlKeywords {
		if strings.Contains(up, kw) {
			return true
		}
	}
	return sqlFragmentRe.MatchString(format)
}

// quotedSlotRE 找出格式串里「带引号的值位置」。
//
// SQL 里值的位置有两种：裸的（col = 42）和带引号的（col = 'abc'）。
// 只有带引号的那种会被字符串内容打断 —— "'%s'" 里插进一个带单引号的
// 字符串就闭合了引号，后面的内容就变成 SQL 了。
//
// 所以门禁只盯带引号的位置。
//
// 手写这个而不是用 regexp：regexp 要同时处理 '\'' 与 "'%s'" 与
// `DATE '%s'`，而这里的实际形态就这几种。
func quotedSlots(format string) []slot {
	var slots []slot
	for i := 0; i < len(format); i++ {
		switch format[i] {
		case '\'':
			// 单引号位置：'...' 或 DATE '...'
			j := strings.IndexByte(format[i+1:], '\'')
			if j < 0 {
				continue
			}
			inner := format[i+1 : i+1+j]
			if k := strings.Index(inner, "%s"); k >= 0 {
				slots = append(slots, slot{verbIndex: countVerbsBefore(format, i+1+k), quoted: true})
			}
			i += j + 1
		case '"':
			j := strings.IndexByte(format[i+1:], '"')
			if j < 0 {
				continue
			}
			inner := format[i+1 : i+1+j]
			if k := strings.Index(inner, "%s"); k >= 0 {
				slots = append(slots, slot{verbIndex: countVerbsBefore(format, i+1+k), quoted: true})
			}
			i += j + 1
		}
	}
	return slots
}

// slot 是一个带引号的值位置。
type slot struct {
	// verbIndex 是这个位置对应的格式化动词序号（%s 的序号，0 起）。
	verbIndex int
	// quoted 恒为 true —— 现在只留带引号的位置。
	quoted bool
}

// countVerbsBefore 数 format 里在 offset 之前出现了几个 %s / %v / %d 之类的动词。
//
// 顺序按 fmt 的规则：第一个动词吃第一个参数。
func countVerbsBefore(format string, offset int) int {
	n := 0
	for i := 0; i < offset && i < len(format); i++ {
		if format[i] != '%' {
			continue
		}
		// 跳过 %% 与带标志/宽度/精度的部分。
		j := i + 1
		for j < len(format) && strings.ContainsRune("+-# 0123456789.", rune(format[j])) {
			j++
		}
		if j >= len(format) {
			break
		}
		switch format[j] {
		case '%':
			i = j
			continue
		case 's', 'v', 'd', 'q', 'x', 'X', 'f', 'e', 'g', 't', 'b', 'o', 'c', 'U':
			n++
		}
		i = j
	}
	return n
}

// safeCallers 是「转义过了」的判定：这些包名 + 函数名组合算已转义。
var safeCallers = map[string]bool{
	"store.Quote":      true,
	"store.QuoteIdent": true,
}

// isSafeExpr 判断一个表达式是不是「已经转义过的值」。
//
// 四种算安全：
//   - 包在 store.Quote / store.QuoteIdent 里
//   - 字符串字面量（编译期常量，改不了）
//   - 指向一个字符串常量的标识符（const publicChannelType = "b2c_own"）
//   - strconv.Quote 之类？不算 —— 那是 Go 的转义，不是 SQL 的。
func isSafeExpr(e ast.Expr, consts map[string]bool) bool {
	switch v := e.(type) {
	case *ast.BasicLit:
		return v.Kind == token.STRING
	case *ast.Ident:
		return consts[v.Name]
	case *ast.CallExpr:
		if sel, ok := v.Fun.(*ast.SelectorExpr); ok {
			if id, ok := sel.X.(*ast.Ident); ok {
				if safeCallers[id.Name+"."+sel.Sel.Name] {
					return true
				}
			}
		}
	}
	return false
}

// exprText 取表达式的源码文本（尽力而为）。
//
// 按字节 offset 从源码里切 —— 切出来的就是表达式的字面文本，
// 不用从 "file.go:12:34" 这种位置串里猜前缀长什么样。
//
// Position.Offset 已经是「相对本文件开头」的偏移，
// 不再减 file.Base()（减两次会错开一个字节）。
func exprText(fset *token.FileSet, src []byte, e ast.Expr) string {
	if e == nil {
		return ""
	}
	start := fset.Position(e.Pos())
	end := fset.Position(e.End())
	if start.Filename != end.Filename {
		return "…"
	}
	from, to := start.Offset, end.Offset
	if from < 0 || to > len(src) || from > to {
		return "…"
	}
	return string(src[from:to])
}

// parserFile 解析一个 Go 文件。
func parserFile(fset *token.FileSet, filename string, src []byte) (*ast.File, error) {
	return parser.ParseFile(fset, filename, src, parser.ParseComments)
}

// Package 是要一起检查的一组文件（同目录）。
//
// 常量在包里可能是跨文件定义的（const 在 a.go，用在 b.go），
// 所以检查一个文件之前得先把这个包里所有字符串常量收齐。
type Package struct {
	// Files 是这个包里的文件（路径 + 源码）。
	Files []SourceFile
}

// SourceFile 是一个待检查的源文件。
type SourceFile struct {
	Path string
	Src  []byte
}

// Check 检查一个包。
func Check(pkg Package) ([]Finding, error) {
	fset := token.NewFileSet()
	parsed := make([]*ast.File, 0, len(pkg.Files))
	for _, sf := range pkg.Files {
		f, err := parserFile(fset, sf.Path, sf.Src)
		if err != nil {
			return nil, fmt.Errorf("解析 %s 失败: %w", sf.Path, err)
		}
		parsed = append(parsed, f)
	}
	consts := collectStringConsts(parsed)
	var out []Finding
	for i, f := range parsed {
		out = append(out, checkFile(fset, f, pkg.Files[i].Path, pkg.Files[i].Src, consts)...)
	}
	return out, nil
}

// collectStringConsts 收齐包里所有「字符串常量」的名字。
//
// 只收包级的 const 与 var（var 也算：包级 var 的初值是编译期写下的，
// 实务上同样是常量）。函数内的局部变量不算 —— 那是运行期的值。
//
// 判定「字符串」：初值是字符串字面量，或指向另一个已知常量。
func collectStringConsts(files []*ast.File) map[string]bool {
	names := map[string]bool{}
	// 先按文件收一遍，再按依赖多解几轮（a 指向 b，b 指向字面量）。
	for round := 0; round < 3; round++ {
		for _, f := range files {
			for _, decl := range f.Decls {
				gd, ok := decl.(*ast.GenDecl)
				if !ok || (gd.Tok != token.CONST && gd.Tok != token.VAR) {
					continue
				}
				for _, spec := range gd.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					for i, name := range vs.Names {
						if i >= len(vs.Values) {
							continue
						}
						if isStringValue(vs.Values[i], names) {
							names[name.Name] = true
						}
					}
				}
			}
		}
	}
	return names
}

// isStringValue 判断一个初值是不是「字符串常量」。
func isStringValue(e ast.Expr, known map[string]bool) bool {
	switch v := e.(type) {
	case *ast.BasicLit:
		return v.Kind == token.STRING
	case *ast.Ident:
		return known[v.Name]
	case *ast.BinaryExpr:
		// "a" + "b" 是常量。
		return isStringValue(v.X, known) && isStringValue(v.Y, known)
	}
	return false
}

// checkFile 检查一个文件里的 fmt.Sprintf 调用。
func checkFile(fset *token.FileSet, f *ast.File, filename string, src []byte, consts map[string]bool) []Finding {
	var out []Finding
	ast.Inspect(f, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		id, ok := sel.X.(*ast.Ident)
		if !ok || id.Name != "fmt" || sel.Sel.Name != "Sprintf" {
			return true
		}
		if len(call.Args) == 0 {
			return true
		}
		lit, ok := call.Args[0].(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return true
		}
		format, err := strconv.Unquote(lit.Value)
		if err != nil {
			return true
		}
		if !looksLikeSQL(format) {
			return true
		}
		slots := quotedSlots(format)
		if len(slots) == 0 {
			return true
		}
		for _, s := range slots {
			argIdx := s.verbIndex
			if argIdx >= len(call.Args)-1 {
				continue
			}
			arg := call.Args[argIdx+1]
			if isSafeExpr(arg, consts) {
				continue
			}
			out = append(out, Finding{
				File:     filepath.ToSlash(filename),
				Line:     fset.Position(call.Pos()).Line,
				ArgIndex: argIdx,
				Format:   format,
				Expr:     exprText(fset, src, arg),
			})
		}
		return true
	})
	return out
}

// Sort 按文件名与行号排序，输出才稳定。
func Sort(fs []Finding) {
	sort.Slice(fs, func(i, j int) bool {
		if fs[i].File != fs[j].File {
			return fs[i].File < fs[j].File
		}
		if fs[i].Line != fs[j].Line {
			return fs[i].Line < fs[j].Line
		}
		return fs[i].ArgIndex < fs[j].ArgIndex
	})
}
