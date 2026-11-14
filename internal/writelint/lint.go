// Package writelint 检查「写路径有没有洗掉别人写的事实」。
//
// 背景：2026-11-14 的一次审计里找到两个同类缺陷 ——
//
//  1. 同步作业的 product_mapping upsert 无条件 `match_evidence = EXCLUDED.match_evidence`，
//     把人工写的判定依据洗成了机器的（提交 fa0ca11 修）。
//  2. 同步作业写 supplier_product / supplier_variant 时不校验 external_id，
//     空的标识落进了库，靠事后的不变量 128 才发现（提交 026e554 修）。
//
// 这两个的共同形状是：**机器写的路径动了它不该动的字段**。
// 一个靠 review 抓住（那行 SQL 看着很普通），
// 一个靠事后门禁抓住（更不容易 —— 事后门禁只说「库坏了」，不说「谁干的」）。
//
// 所以这里把两条变成门禁：
//
//	规则 1（不许洗掉人的判断）：判断表上的 upsert 不许无条件覆盖人的列。
//	规则 2（写之前要校验）：写了源侧表的包，必须校验标识列不为空。
//
// **两条规则的「表 / 列」清单都在本文件里，各只有一份。**
// 加一列改一处，不在别处再抄一遍（硬约束 37 的同一条道理）。
//
// 判据宁可放过也不误伤：门禁噪音多了就没人看了（硬约束 40 的同一条道理）。
//
// 这个包只扫 Go 源码。迁移文件（.sql）里的写入不归它管 ——
// 迁移是一次性铺开 DDL，不是「机器反复写的路径」。
package writelint

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"regexp"
	"sort"
	"strings"
)

// Finding 是一条问题。
type Finding struct {
	// File 是相对路径。
	File string
	// Line 是行号（1 起）。
	Line int
	// Rule 是触发的规则名。
	Rule string
	// Detail 是人话说明。
	Detail string
}

// String 渲染成一行人话。
func (f Finding) String() string {
	return fmt.Sprintf("%s:%d: [%s] %s", f.File, f.Line, f.Rule, f.Detail)
}

// humanCols 是「有人的判断在里面」的表，以及**人写的列**。
//
// 为什么只有这两张表：全库扫「不许覆盖」会误报一大片 ——
// 读模型（c_variant_facts / c_variant_calendar / price_calendar）覆盖的
// 全是机器推导的事实，覆盖是对的（读模型可重建，硬约束 10）；
// 源侧表（supplier_product / supplier_variant）覆盖的也是机器自己的事实。
//
// 判断表不一样 —— 里面可能有**人**写的行：
//
//	product_mapping.match_evidence —— 判定依据（人工复核要看它）
//	product_mapping.match_type     —— 这一行是机器匹的还是人判的
//	product_mapping.created_by     —— 这一行是谁写的
//
// 这几列被机器无条件覆盖，就是「洗掉人的判断」。
var humanCols = map[string][]string{
	"product_mapping":         {"match_evidence", "match_type", "created_by"},
	"supplier_variant_mapping": {"match_type"},
}

// sourceTables 是「源侧表」→ 该表的标识字段（**Go 侧的名字**）。
//
// 这些字段不许是空的 —— 空标识意味着库里多了一条匿名商品，
// 事后靠不变量 128 才发现，但那时已经不知道是哪一次同步干的。
//
// 记的是 Go 侧的字段名（ExternalID），不是 SQL 列名（external_id）：
// 要校验的地方是**算出这个值的那段代码**，那里只有 Go 的名字。
// SQL 列名只用来定位「谁在写这张表」。
var sourceTables = map[string][]string{
	"supplier_product": {"ExternalID"},
	"supplier_variant": {"ExternalID"},
}

// isSourceIDField 判断一个 Go 标识符是不是源侧标识字段。
//
// 判据：**名字本身就是那个字段**（大小写不敏感）——
// ExternalID / externalId 都认。
//
// **不能用「含 ExternalID」判** —— externalIDs（一堆 id 的切片）
// 也含它，但那是别的东西：拿它当别名，门禁会把「没校验」误判成「校验了」，
// 那是门禁自己骗自己，比漏报更坏。
func isSourceIDField(name string) bool {
	return strings.EqualFold(name, "ExternalID")
}

// insertRe 认出「往哪张表插」。
var insertRe = regexp.MustCompile(`(?is)INSERT\s+INTO\s+([a-z_][a-z0-9_]*)`)

// conflictRe 认出 ON CONFLICT ... DO UPDATE 那一段。
//
// **不能带 `.*$` 收尾** —— 那样一次只匹配得到一段（第一段就把后面全吃掉了）。
// 这里只认出 DO UPDATE SET 后面**第一项**赋值的边界，剩下的交给 setClauseRe。
var conflictRe = regexp.MustCompile(`(?is)ON\s+CONFLICT\b.*?\bDO\s+UPDATE\s+SET\s+`)

// setClauseRe 认出 DO UPDATE SET 里的每一项「列 = 表达式」。
//
// 表达式认三种形状：带条件的（CASE WHEN ... END）、
// 直接用新值的（EXCLUDED.x）、取新值没有就留旧的（COALESCE(...)）。
var setClauseRe = regexp.MustCompile(
	`(?is)([a-z_][a-z0-9_]*)\s*=\s*(CASE\s+WHEN\b.*?END|EXCLUDED\.[a-z_][a-z0-9_]*|COALESCE\s*\(.*?\))`)

// excludedRe 认出「直接用新值覆盖」。
var excludedRe = regexp.MustCompile(`(?is)^EXCLUDED\.[a-z_][a-z0-9_]*$`)

// caseRe 认出一个带条件的赋值（条件覆盖 = 合法的保护）。
var caseRe = regexp.MustCompile(`(?is)^CASE\s+WHEN\b`)

// coalesceRe 认出「取新值，没有就留旧的」。
var coalesceRe = regexp.MustCompile(`(?is)^COALESCE\s*\(`)

// Package 是要一起检查的一组文件（同目录）。
//
// **按包检查，不按文件检查** —— 规则 2 的校验与写入可能不在同一个文件里
// （现在的写法就是：校验在 plan.go，写入在 apply.go）。
type Package struct {
	// Files 是这个包里的文件（路径 + 源码）。
	Files []SourceFile
}

// SourceFile 是一个待检查的源文件。
type SourceFile struct {
	Path string
	Src  []byte
}

// parsedFile 是一个解析好的文件及其位置表。
type parsedFile struct {
	path string
	file *ast.File
	fset *token.FileSet
}

// Check 检查一个包。
func Check(pkg Package) ([]Finding, error) {
	fset := token.NewFileSet()
	parsed := make([]parsedFile, 0, len(pkg.Files))
	for _, sf := range pkg.Files {
		af, err := parser.ParseFile(fset, sf.Path, sf.Src, parser.ParseComments)
		if err != nil {
			return nil, fmt.Errorf("解析 %s 失败: %w", sf.Path, err)
		}
		parsed = append(parsed, parsedFile{path: sf.Path, file: af, fset: fset})
	}
	if len(parsed) == 0 {
		return nil, nil
	}

	var out []Finding
	out = append(out, checkJudgmentOverwrite(parsed)...)
	out = append(out, checkSourceIDValidation(parsed)...)
	return out, nil
}

// sqlFragment 是一段 SQL 及其位置。
type sqlFragment struct {
	file string
	text string
	line int
}

// collectSQL 收集包里所有的 SQL 片段。
//
// **按函数收集，把函数里的字符串字面量按源码顺序拼起来。**
//
// 为什么不是「一个字面量算一段」：SQL 是用 store.NewSQL(...).Text(...) 一段段
// 拼出来的 —— `INSERT INTO product_mapping ...` 和
// `ON CONFLICT ... DO UPDATE SET match_evidence = EXCLUDED.match_evidence`
// 是两次独立的 Text 调用，字面量各看各的都看不出问题。
// 拼起来才看得出「这一段 upsert 覆盖了哪几列」。
//
// 一个函数里的**所有**字符串字面量都拼进去（包括与 SQL 无关的）——
// 拼错的代价是「一段文本里既认出了 INSERT 又认出了 DO UPDATE」，
// 而那正好就是要判的那一段。
func collectSQL(parsed []parsedFile) []sqlFragment {
	var out []sqlFragment
	for _, pf := range parsed {
		for _, fn := range functionsOf(pf.file) {
			text, line, ok := joinLiterals(pf.fset, fn)
			if !ok {
				continue
			}
			upper := strings.ToUpper(text)
			if !strings.Contains(upper, "INSERT") {
				continue
			}
			out = append(out, sqlFragment{file: pf.path, text: text, line: line})
		}
	}
	return out
}

// functionsOf 取文件里的所有函数声明。
func functionsOf(f *ast.File) []*ast.FuncDecl {
	var out []*ast.FuncDecl
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok {
			out = append(out, fd)
		}
	}
	return out
}

// joinLiterals 把一个函数体里的字符串字面量按源码顺序拼起来。
//
// 返回拼好的文本、第一个字面量的行号、以及有没有字面量。
func joinLiterals(fset *token.FileSet, fn *ast.FuncDecl) (string, int, bool) {
	type lit struct {
		pos  token.Pos
		text string
	}
	var lits []lit
	ast.Inspect(fn, func(n ast.Node) bool {
		bl, ok := n.(*ast.BasicLit)
		if !ok || bl.Kind != token.STRING {
			return true
		}
		lits = append(lits, lit{pos: bl.Pos(), text: bl.Value})
		return true
	})
	if len(lits) == 0 {
		return "", 0, false
	}
	// 按位置排序（ast.Inspect 的顺序基本就是源码顺序，但排一下更稳）。
	sort.Slice(lits, func(i, j int) bool { return lits[i].pos < lits[j].pos })
	var sb strings.Builder
	for _, l := range lits {
		sb.WriteString(l.text)
		sb.WriteString(" ")
	}
	return sb.String(), fset.Position(lits[0].pos).Line, true
}

// checkJudgmentOverwrite 查规则 1：判断表的 upsert 无条件覆盖了人的列。
func checkJudgmentOverwrite(parsed []parsedFile) []Finding {
	var out []Finding
	for _, s := range collectSQL(parsed) {
		// 一段文本里可能有好几段 upsert（一个函数拼好几张表）。
		// 每一段要配上**它自己的** INSERT INTO —— 取前面最近的那个，
		// 不是整段里的第一个（那可能是另一张表）。
		for _, upsert := range upsertsOf(s.text) {
			cols, ok := humanCols[upsert.table]
			if !ok {
				continue
			}
			for _, cm := range setClauseRe.FindAllStringSubmatch(upsert.set, -1) {
				col := strings.ToLower(cm[1])
				val := strings.TrimSpace(cm[2])
				if !contains(cols, col) {
					continue
				}
				// 无条件覆盖 = 直接用新值。有条件覆盖（CASE WHEN）或
				// 「新值没有就留旧的」（COALESCE）都是保护，合法。
				if excludedRe.MatchString(val) && !caseRe.MatchString(val) && !coalesceRe.MatchString(val) {
					out = append(out, Finding{
						File:   s.file,
						Line:   s.line,
						Rule:   "规则1 不许洗掉人的判断",
						Detail: fmt.Sprintf("%s.%s 被无条件覆盖成 EXCLUDED 的值 —— 人工写的判定依据不许被机器洗掉（要用 CASE WHEN 按行的归属判断）", upsert.table, col),
					})
				}
			}
		}
	}
	return out
}

// upsert 是一段 upsert：往哪张表写，以及 DO UPDATE SET 的内容。
type upsert struct {
	table string
	set   string
}

// upsertsOf 从一段文本里找出所有 upsert，各配上前面的 INSERT INTO。
func upsertsOf(text string) []upsert {
	var out []upsert
	// 先找所有 ON CONFLICT ... DO UPDATE SET 的位置。
	locs := conflictRe.FindAllStringSubmatchIndex(text, -1)
	for i, loc := range locs {
		start := loc[0]
		setStart := loc[1]
		// SET 的内容到**下一段 ON CONFLICT** 或者文本末尾为止。
		setEnd := len(text)
		if i+1 < len(locs) {
			setEnd = locs[i+1][0]
		}
		// 往前找最近的 INSERT INTO。
		prefix := text[:start]
		ins := insertRe.FindAllStringSubmatchIndex(prefix, -1)
		if len(ins) == 0 {
			continue
		}
		last := ins[len(ins)-1]
		table := strings.ToLower(prefix[last[2]:last[3]])
		out = append(out, upsert{table: table, set: text[setStart:setEnd]})
	}
	return out
}

// checkSourceIDValidation 查规则 2：写了源侧表的包，必须校验标识列不为空。
//
// 判据：这个包里只要写了 supplier_product（有 INSERT INTO supplier_product），
// 那么包里必须有一处「这个标识是不是空的」的判断。
//
// 判断怎么算「有校验」：包里出现了对该列的**比较表达式**，
// 且比较的另一边是空 —— 空的形状认 `""` / `nil` / `len(...)`。
// 也就是说，光提到这一列不算，必须拿它跟空比过。
func checkSourceIDValidation(parsed []parsedFile) []Finding {
	var out []Finding

	// 这个包写了哪些源侧表？
	written := map[string]sqlFragment{}
	for _, s := range collectSQL(parsed) {
		for _, im := range insertRe.FindAllStringSubmatch(s.text, -1) {
			table := strings.ToLower(im[1])
			if _, ok := sourceTables[table]; !ok {
				continue
			}
			if _, seen := written[table]; !seen {
				written[table] = s
			}
		}
	}
	if len(written) == 0 {
		return nil
	}

	// 这个包里有没有对标识字段的空值校验？
	// 看的是**表达式**（ast），不是文本 —— 文本会误伤到注释里的一句
	// 「这里要判空」，或者别处的字符串常量。
	checked := map[string]bool{}
	for _, pf := range parsed {
		for table, fields := range sourceTables {
			if _, ok := written[table]; !ok {
				continue
			}
			for _, field := range fields {
				if hasEmptyComparison(pf.file, field) {
					checked[table] = true
				}
			}
		}
	}

	for table, s := range written {
		if checked[table] {
			continue
		}
		out = append(out, Finding{
			File:   s.file,
			Line:   s.line,
			Rule:   "规则2 写之前要校验标识",
			Detail: fmt.Sprintf("这个包写了 %s，但没看到对 %s 的空值校验 —— 空的标识落进库只能靠事后门禁发现，那时已经不知道是哪一次同步干的（写之前要挡住）", table, strings.Join(sourceTables[table], " / ")),
		})
	}
	return out
}

// hasEmptyComparison 判断这个文件里有没有「拿源侧标识跟空比」的比较表达式。
//
// 认这些形状：
//
//	strings.TrimSpace(product.ExternalID) == ""   直接比空串
//	product.ExternalID == nil                      比 nil
//	len(product.ExternalID) == 0                  取长度比零
//
// 以及它们的 != 变体（!= "" 同样是「检查它是不是空的」）。
//
// **中间隔了一个局部变量也算**：
//
//	id := product.ExternalID
//	if strings.TrimSpace(id) == "" { ... }
//
// 这种情况要先找出「哪些局部变量是从源侧标识赋来的」，
// 再看比较里有没有用到它们。
func hasEmptyComparison(f *ast.File, col string) bool {
	aliases := sourceIDAliases(f, col)
	found := false
	ast.Inspect(f, func(n ast.Node) bool {
		if found {
			return false
		}
		bin, ok := n.(*ast.BinaryExpr)
		if !ok {
			return true
		}
		if bin.Op != token.EQL && bin.Op != token.NEQ {
			return true
		}
		if !mentionsColumn(bin.X, col, aliases) && !mentionsColumn(bin.Y, col, aliases) {
			return true
		}
		// 另一边是不是空？
		// len(x) == 0 与 len(x) != 0：一边是 len 调用，另一边得是 0。
		if (isLenCall(bin.X) && isZero(bin.Y)) || (isLenCall(bin.Y) && isZero(bin.X)) {
			found = true
			return false
		}
		if isEmptyExpr(bin.X) || isEmptyExpr(bin.Y) {
			// 一边是 len 调用、另一边是零 —— 上面已经接住了；
			// 这里只认「空串 / nil / 零」。
			if isLenCall(bin.X) || isLenCall(bin.Y) {
				return true
			}
			found = true
			return false
		}
		return true
	})
	return found
}

// sourceIDAliases 找出「从源侧标识赋值来的」局部变量名。
//
// 认的形状：x := product.ExternalID、
// x := strings.TrimSpace(product.ExternalID)。
//
// **只认「值就是那一个标识」的赋值** —— 不能是「包含那个标识的东西」。
// `idx := variantIdx[v.ExternalID]` 里的 idx 是下标，不是标识；
// `out := f(product.ExternalID)` 里的 out 是别的结果。
// 把这两种当成别名，门禁就会把「没校验」误判成「校验了」——
// 那比漏报更坏：门禁自己骗自己。
func sourceIDAliases(f *ast.File, col string) map[string]bool {
	aliases := map[string]bool{}
	ast.Inspect(f, func(n ast.Node) bool {
		as, ok := n.(*ast.AssignStmt)
		if !ok || len(as.Lhs) != 1 || len(as.Rhs) != 1 {
			return true
		}
		id, ok := as.Lhs[0].(*ast.Ident)
		if !ok {
			return true
		}
		if isTheIdentifier(as.Rhs[0], col) {
			aliases[id.Name] = true
		}
		return true
	})
	return aliases
}

// isTheIdentifier 判断表达式是不是「就是那一个标识」。
//
// 认两种形状：
//
//	product.ExternalID              —— 直接取字段
//	strings.TrimSpace(product.ExternalID) —— 对它做一次包装
//
// 不认：包含它的下标、参数、复合字面量。
func isTheIdentifier(e ast.Expr, col string) bool {
	switch v := e.(type) {
	case *ast.SelectorExpr:
		return v.Sel != nil && (v.Sel.Name == col || isSourceIDField(v.Sel.Name))
	case *ast.Ident:
		return v.Name == col || isSourceIDField(v.Name)
	case *ast.CallExpr:
		// 只认「唯一的参数就是那一个标识」。
		if len(v.Args) != 1 {
			return false
		}
		return isTheIdentifier(v.Args[0], col)
	case *ast.UnaryExpr:
		return isTheIdentifier(v.X, col)
	}
	return false
}

// mentionsColumn 判断表达式里有没有提到源侧标识字段。
//
// 认两种形状：直接用这个字段名（一个 ident）、或者取它的字段
// （product.ExternalID —— 字段名在 selector 的 Sel 上）。
func mentionsColumn(e ast.Expr, col string, aliases map[string]bool) bool {
	found := false
	ast.Inspect(e, func(n ast.Node) bool {
		if found {
			return false
		}
		switch v := n.(type) {
		case *ast.Ident:
			// 标识符本身：这个包里的结构体字段名，或者一个局部变量。
			// 局部变量名要认 —— 校验常常写成
			// `id := product.ExternalID; if strings.TrimSpace(id) == ""`。
			if v.Name == col || isSourceIDField(v.Name) || aliases[v.Name] {
				found = true
				return false
			}
		case *ast.SelectorExpr:
			// x.ExternalID —— 字段名匹配就算。
			if v.Sel != nil && (v.Sel.Name == col || isSourceIDField(v.Sel.Name)) {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

// isEmptyExpr 判断表达式是不是「空」。
//
// 认：空字符串（"" / ''）、nil、数字零。
//
// **不认单独的 len(...)** —— len(x) 单独出现不是「空」的判断，
// 只有 len(x) == 0 才是（那一对由 isLenCall + isZero 单独接）。
func isEmptyExpr(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.BasicLit:
		if v.Kind == token.STRING {
			return v.Value == `""` || v.Value == `''`
		}
		if v.Kind == token.INT {
			return v.Value == "0"
		}
		return false
	case *ast.Ident:
		return v.Name == "nil"
	}
	return false
}

// isLenCall 判断表达式是不是 len(...) 调用。
func isLenCall(e ast.Expr) bool {
	call, ok := e.(*ast.CallExpr)
	if !ok {
		return false
	}
	id, ok := call.Fun.(*ast.Ident)
	return ok && id.Name == "len"
}

// isZero 判断表达式是不是数字零。
func isZero(e ast.Expr) bool {
	lit, ok := e.(*ast.BasicLit)
	return ok && lit.Kind == token.INT && lit.Value == "0"
}

// contains 判断切片里有没有这个值。
func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// Sort 把 findings 按文件、行号排好。
func Sort(fs []Finding) {
	sort.Slice(fs, func(i, j int) bool {
		if fs[i].File != fs[j].File {
			return fs[i].File < fs[j].File
		}
		if fs[i].Line != fs[j].Line {
			return fs[i].Line < fs[j].Line
		}
		return fs[i].Rule < fs[j].Rule
	})
}
