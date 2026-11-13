package sqllint

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SkipDirs 是扫描时跳过的目录。
//
// vendor 与第三方依赖不是我们的代码 —— 门禁管自己写的部分。
var SkipDirs = map[string]bool{
	"vendor":       true,
	"node_modules": true,
	".git":         true,
	"bin":          true,
}

// Walk 扫一棵目录树，返回全部问题。
//
// 只看 .go 文件，且跳过 _test.go —— 测试里的 SQL 拼法不受门禁约束
// （测试要的就是能随手拼个怪字符串看看会不会炸）。
//
// 按目录分组（一个目录 = 一个包），因为常量是包级的：
// const 在 a.go、值用在 b.go 时，只看 b.go 认不出那个常量是常量。
func Walk(root string) ([]Finding, error) {
	byDir := map[string][]SourceFile{}
	var dirs []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			if SkipDirs[info.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		dir := filepath.Dir(path)
		if _, ok := byDir[dir]; !ok {
			dirs = append(dirs, dir)
		}
		byDir[dir] = append(byDir[dir], SourceFile{Path: path, Src: src})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("扫描 %s 失败: %w", root, err)
	}
	sort.Strings(dirs)
	var out []Finding
	for _, dir := range dirs {
		findings, err := Check(Package{Files: byDir[dir]})
		if err != nil {
			return nil, err
		}
		out = append(out, findings...)
	}
	Sort(out)
	return out, nil
}
