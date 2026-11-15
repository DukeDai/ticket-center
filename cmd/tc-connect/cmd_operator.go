// 运营台操作员的管理子命令。
//
// 为什么凭证管理在 CLI 里而不在网页上：网页上改凭证 = 谁能进网页谁能改凭证，
// 那就等于没有分级。而「建一个 admin」这件事本身是极少数人该做的事。
//
// 明文凭证只在创建时显示一次 —— 库里只存 sha256 哈希，
// 丢了就重新建一个，不找回（硬约束 12 的精神：不入库、不进仓库、不进日志）。
package main

import (
	"flag"
	"fmt"
	"strings"

	"ticket-center/internal/bapi"
	"ticket-center/internal/store"
)

func init() {
	register("operator", "运营台操作员：建号 / 停用 / 换凭证 / 列表",
		usageOperator, cmdOperator, 80)
}

const usageOperator = `  tc-connect operator list   [--db name]
  tc-connect operator create --code CODE --name NAME --role admin|operator|viewer [--db name]
  tc-connect operator disable --code CODE [--db name]
  tc-connect operator enable  --code CODE [--db name]
  tc-connect operator rotate  --code CODE [--db name]
`

func cmdOperator(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("operator 要一个子动作：list / create / disable / enable / rotate")
	}
	action := args[0]
	fs := flag.NewFlagSet("operator "+action, flag.ContinueOnError)
	dbName := fs.String("db", fulfillDB(""), "数据库名")
	code := fs.String("code", "", "操作员 code")
	name := fs.String("name", "", "操作员姓名")
	role := fs.String("role", bapi.RoleViewer, "角色：admin / operator / viewer")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	db := store.New(*dbName)
	svc := bapi.NewOperatorService(db)

	switch action {
	case "list":
		ops, err := svc.List()
		if err != nil {
			return err
		}
		if len(ops) == 0 {
			fmt.Println("还没有操作员。用 operator create 建一个。")
			return nil
		}
		fmt.Printf("%-16s %-20s %-10s %-10s\n", "CODE", "NAME", "ROLE", "STATUS")
		for _, op := range ops {
			fmt.Printf("%-16s %-20s %-10s %-10s\n", op.Code, op.Name, op.Role, op.Status)
		}
		return nil

	case "create":
		if strings.TrimSpace(*code) == "" || strings.TrimSpace(*name) == "" {
			return fmt.Errorf("create 需要 --code 与 --name")
		}
		secret, err := svc.Create(*code, *name, *role)
		if err != nil {
			return err
		}
		fmt.Printf("操作员 %s（%s）已建，角色 %s。\n", *code, *name, *role)
		fmt.Printf("凭证（只显示这一次，库里只存哈希，丢了就重新建）：\n\n    %s\n\n", secret)
		return nil

	case "disable", "enable":
		if strings.TrimSpace(*code) == "" {
			return fmt.Errorf("%s 需要 --code", action)
		}
		status := "active"
		if action == "disable" {
			status = "disabled"
		}
		// 停用要立刻生效：换会话盐，让已签发的会话当场作废。
		// 只改 status 不够 —— 已签发的会话会一直有效到过期（8 小时）。
		salt, err := bapi.NewSalt()
		if err != nil {
			return err
		}
		sql := fmt.Sprintf(
			`UPDATE b2b_operator SET status = %s, session_salt = %s WHERE code = %s;`,
			store.Quote(status), store.Quote(salt), store.Quote(*code))
		if err := db.Exec(sql); err != nil {
			return store.PLError(err)
		}
		fmt.Printf("操作员 %s 已%s。\n", *code, map[bool]string{true: "停用", false: "启用"}[action == "disable"])
		return nil

	case "rotate":
		if strings.TrimSpace(*code) == "" {
			return fmt.Errorf("rotate 需要 --code")
		}
		secret, err := bapi.NewSecret()
		if err != nil {
			return err
		}
		salt, err := bapi.NewSalt()
		if err != nil {
			return err
		}
		sql := fmt.Sprintf(
			`UPDATE b2b_operator SET key_hash = %s, session_salt = %s WHERE code = %s;`,
			store.Quote(bapi.HashSecret(secret)), store.Quote(salt), store.Quote(*code))
		if err := db.Exec(sql); err != nil {
			return store.PLError(err)
		}
		fmt.Printf("操作员 %s 的凭证已换。\n", *code)
		fmt.Printf("新凭证（只显示这一次）：\n\n    %s\n\n", secret)
		return nil

	default:
		return fmt.Errorf("operator 不认识这个动作：%s（可用：list / create / disable / enable / rotate）", action)
	}
}
