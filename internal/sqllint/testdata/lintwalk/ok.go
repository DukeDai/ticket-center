package lintwalk

import "fmt"

// 这个文件里的 SQL 拼法是合规的，扫描不该报。
func ok(db *DB, name string) {
	db.Rows(fmt.Sprintf("SELECT * FROM t WHERE name = %s", quote(name)))
}
