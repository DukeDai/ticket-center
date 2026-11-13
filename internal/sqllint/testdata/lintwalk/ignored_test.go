package lintwalk

import "fmt"

// 测试文件不受门禁约束：这里故意拼一个会注入的字符串。
func ignored(db *DB, name string) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE name = '%s'", name))
}
