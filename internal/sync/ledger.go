package sync

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"ticket-center/internal/apperr"
	"ticket-center/internal/store"
)

// startLedger 开跑时落一行 running。
//
// **一个源一行台账，跑一次更新一行，不追加**（spec §5.27）。
// 表上**没有** (supplier_id, job_type) 的唯一约束 —— 这一条是写者自己的口径，
// 不是数据库兜着的：先按 (supplier_id, job_type) 找最老的那一行，
// 有就把它改成 running 并清掉上次的 finished_at / error（这次又开跑了），
// 没有就插一行新的。
//
// 为什么复用最老的那一行而不是插一行新的：台账是「这个源现在怎么样」的读法，
// 追加式会让读的人自己去挑哪一行是最新的 —— 而挑选规则不是数据里的事实。
func startLedger(db *store.DB, led Ledger) error {
	existing, err := ledgerRowID(db, led.SupplierID, led.JobType)
	if err != nil {
		return err
	}

	if existing > 0 {
		sql := store.NewSQL(
			"UPDATE sync_job_log SET status = 'running', started_at = now(), finished_at = NULL,",
			" stats = '{}'::jsonb, error = NULL, scope = ",
		).BindJSON(led.Scope)
		sql = sql.Text(" WHERE id = ").Bind(existing)
		out, err := sql.String()
		if err != nil {
			return fmt.Errorf("写台账 running 失败: %w", err)
		}
		if err := db.Exec(out); err != nil {
			return fmt.Errorf("写台账 running 失败: %w", err)
		}
		return nil
	}

	scopeJSON, err := jsonOrEmpty(led.Scope)
	if err != nil {
		return fmt.Errorf("序列化 scope 失败: %w", err)
	}
	sql := "INSERT INTO sync_job_log (supplier_id, job_type, scope, status, started_at) VALUES (" +
		strings.Join([]string{
			store.Quote(led.SupplierID),
			store.Quote(led.JobType),
			store.Quote(scopeJSON) + "::jsonb",
			store.Quote("running"),
			"now()",
		}, ",") + ");"
	if err := db.Exec(sql); err != nil {
		return fmt.Errorf("写台账 running 失败: %w", err)
	}
	return nil
}

// finishLedger 跑完落终态。
//
// 失败也要落 —— 作业失败不留痕，源健康视图上看着一切正常。
func finishLedger(db *store.DB, led Ledger) error {
	id, err := ledgerRowID(db, led.SupplierID, led.JobType)
	if err != nil {
		return err
	}
	if id == 0 {
		// 台账行不在（起跑那一步没写成）。补一行终态，
		// 否则这次失败在台账上根本不存在。
		return insertLedgerRow(db, led)
	}

	sql := store.NewSQL(
		"UPDATE sync_job_log SET status = ",
	).Bind(led.Status)
	sql = sql.Text(", finished_at = now()")
	sql = sql.Text(", stats = ").BindJSON(led.Stats)
	if len(led.Error) > 0 {
		sql = sql.Text(", error = ").BindJSON(led.Error)
	}
	sql = sql.Text(" WHERE id = ").Bind(id)
	out, err := sql.String()
	if err != nil {
		return fmt.Errorf("写台账终态失败: %w", err)
	}
	if err := db.Exec(out); err != nil {
		return fmt.Errorf("写台账终态失败: %w", err)
	}
	return nil
}

// insertLedgerRow 补一行终态台账（起跑那一步没写成时的兜底）。
func insertLedgerRow(db *store.DB, led Ledger) error {
	errSeg := "NULL"
	if len(led.Error) > 0 {
		errJSON, err := jsonOrEmpty(led.Error)
		if err != nil {
			return fmt.Errorf("序列化 error 失败: %w", err)
		}
		errSeg = store.Quote(errJSON) + "::jsonb"
	}
	scopeJSON, err := jsonOrEmpty(led.Scope)
	if err != nil {
		return fmt.Errorf("序列化 scope 失败: %w", err)
	}
	statsJSON, err := jsonOrEmpty(led.Stats)
	if err != nil {
		return fmt.Errorf("序列化 stats 失败: %w", err)
	}
	sql := "INSERT INTO sync_job_log (supplier_id, job_type, scope, status, started_at, finished_at, stats, error) VALUES (" +
		strings.Join([]string{
			store.Quote(led.SupplierID),
			store.Quote(led.JobType),
			store.Quote(scopeJSON) + "::jsonb",
			store.Quote(led.Status),
			"now()",
			"now()",
			store.Quote(statsJSON) + "::jsonb",
			errSeg,
		}, ",") + ");"
	if err := db.Exec(sql); err != nil {
		return fmt.Errorf("补台账终态失败: %w", err)
	}
	return nil
}

// ledgerRowID 找这个源这一类作业的台账行 id。没有就返回 0。
func ledgerRowID(db *store.DB, supplierID int64, jobType string) (int64, error) {
	sql := store.NewSQL(
		"SELECT id FROM sync_job_log WHERE supplier_id = ",
	).Bind(supplierID)
	sql = sql.And("job_type = ").Bind(jobType)
	sql = sql.Text(" ORDER BY id ASC LIMIT 1")
	out, err := sql.String()
	if err != nil {
		return 0, fmt.Errorf("读台账行失败: %w", err)
	}

	rows, err := db.Rows(out)
	if err != nil {
		return 0, fmt.Errorf("读台账行失败: %w", err)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return parseID(rows[0]["id"]), nil
}

// parseID 把行 id 读成 int64。
func parseID(s string) int64 {
	var id int64
	fmt.Sscanf(s, "%d", &id)
	return id
}

// errorClass 把任意错误归到四分类。
//
// 四分类是接入层对外的口径（硬约束 8）：retriable / fatal / auth / rate_limit。
// 归不到的当 fatal —— 归到 retriable 会让调度器一直重试一个不会自愈的失败。
//
// 判据顺序：*apperr.Error 自带分类 → 缺凭证是 auth → 端点未确认是 fatal → 其余 fatal。
func errorClass(err error) string {
	if err == nil {
		return string(apperr.ClassFatal)
	}

	var appErr *apperr.Error
	if errors.As(err, &appErr) {
		if appErr.Class.Valid() {
			return string(appErr.Class)
		}
		return string(apperr.ClassFatal)
	}

	if _, ok := apperr.AsMissing(err); ok {
		return string(apperr.ClassAuth)
	}
	if _, ok := apperr.AsUnconfirmed(err); ok {
		return string(apperr.ClassFatal)
	}
	return string(apperr.ClassFatal)
}

// jsonOrEmpty 把一个值序列化成 jsonb 文本。
//
// 序列化失败不糊过去：返回空对象 + 错误，
// 让调用方决定是跳过那行还是整批失败 —— 但不许静默写空。
func jsonOrEmpty(v any) (string, error) {
	if v == nil {
		return "{}", nil
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
