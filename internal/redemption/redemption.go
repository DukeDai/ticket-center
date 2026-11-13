// Package redemption 是核销（扫票入场）链路的客户端接口。
//
// 核销的实现也只有一个：库里的那个函数（db/migrations/008_redemption.sql）。
// 这个包只负责把扫票拼成参数、把结果读回来 —— 不在这里判断券能不能用、
// 不在这里算该扣多少额度、不在这里改券状态。理由与 internal/order /
// internal/fulfillment / internal/refund 一样：
//
//   - 能不能进场的口径在库里（硬约束 21 的同类要求）。
//     Go 侧再判一遍，就会出现两份规则；
//   - 「这张票有没有人用过」是事实，要能查：每一次扫票都留一条记录，
//     重复扫票记 duplicate，不覆盖前一次 —— 压掉重复扫票，
//     票务欺诈的入口就看不见了；
//   - 额度是整数，券状态是字符串，两者都不该在 Go 侧被改写。
//
// 所以 Go 侧只做四件事：拼参数、收结果、把库的报错原样带出去、把事实报上去。
package redemption

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Service 是核销入口。
type Service struct {
	db *store.DB
}

// New 构造核销服务。
func New(db *store.DB) *Service { return &Service{db: db} }

// ---------------------------------------------------------------- 扫票

// Request 是一次扫票。
//
// VoucherID 与 Code 至少给一个：闸机扫的是票码，后台补录给的是券 id。
type Request struct {
	// VoucherID 是凭证 id（0 表示不给）。
	VoucherID int64
	// Code 是票码（空串表示不给）。票码不唯一时报错，不猜。
	Code string
	// GateID 是闸机 id（0 表示不给）。
	GateID int64
	// GateOperatorID 是闸机操作员 id（0 表示不给）。
	GateOperatorID int64
	// DeviceID 是扫票设备（闸机 POS 的编号）。
	DeviceID string
	// OperatorID 是操作员标识（自由文本，闸机给什么就存什么）。
	OperatorID string
	// RawPayload 是扫票原文（归档用，硬约束 8）。
	RawPayload map[string]any
}

// Result 是这次扫票的结果。
//
// Result 只有五档：success / duplicate / expired / revoked / failed。
// 前四档是这张券的处境，failed 是这次没过的原因（Reason 里写清楚）。
type Result struct {
	RedemptionID int64
	VoucherID    int64
	VoucherNo    string
	// Result 是核销结果（success / duplicate / expired / revoked / failed）。
	Result string
	// Reason 是没过或重复的原因（如 not_yet_valid / order_refunding）。
	Reason string
	// VoucherStatus 是核销后这张券的状态。
	VoucherStatus string
	// ConsumedQuantity 是这次消耗的入场额度（按人是 1，按团是整团人数）。
	ConsumedQuantity int64
	// RemainingQuantity 是核销后还剩多少额度（成功核销后是 0）。
	RemainingQuantity int64
	// OriginalRedemptionID 是重复扫票时，第一次成功核销的记录 id（0 表示不是重复）。
	// 网络重试丢了响应时，调用方靠它对账。
	OriginalRedemptionID int64
	// OriginalScannedAt 是第一次成功核销的时间。
	OriginalScannedAt string
}

// Redeem 核销一张券（扫一次票）。
//
// 幂等靠状态，不靠幂等键：一张券最多成功核销一次（库里唯一索引兜底）。
// 第二次扫同一张券返回 Result='duplicate' 并带回第一次的核销记录 ——
// 网络重试和恶意重复扫码在这里是同一件事，不该分成两条路。
//
// 失败不是异常：券过期、券作废、券还没出票、订单在退款 —— 这些都是
// 扫票的正常结果，要返回给闸机看，同时在库里留一条记录。
// 报错只有两种：票码不存在 / 不唯一，以及库里执行失败。
func (s *Service) Redeem(req Request) (*Result, error) {
	if s.db == nil {
		return nil, fmt.Errorf("核销需要数据库连接")
	}
	if req.VoucherID == 0 && strings.TrimSpace(req.Code) == "" {
		return nil, fmt.Errorf("核销需要凭证 id 或票码")
	}
	raw, err := jsonPayload(req.RawPayload)
	if err != nil {
		return nil, fmt.Errorf("核销原文序列化失败：%w", err)
	}

	sql := fmt.Sprintf(
		`SELECT redemption_id, voucher_id, voucher_no, result, reason, voucher_status,
                consumed_quantity, remaining_quantity,
                COALESCE(original_redemption_id, 0) AS original_redemption_id,
                COALESCE(original_scanned_at::text, '') AS original_scanned_at
           FROM fn_redeem_voucher(
                   p_voucher_id       => %s,
                   p_code             => %s,
                   p_gate_id          => %s,
                   p_gate_operator_id => %s,
                   p_device_id        => %s,
                   p_operator_id      => %s,
                   p_payload          => %s::jsonb);`,
		quoteOrNullInt(req.VoucherID),
		quoteOrNull(req.Code),
		quoteOrNullInt(req.GateID),
		quoteOrNullInt(req.GateOperatorID),
		quoteOrNull(req.DeviceID),
		quoteOrNull(req.OperatorID),
		store.Quote(raw))

	rows, err := s.db.Rows(sql)
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("核销没有返回结果")
	}
	r := rows[0]
	return &Result{
		RedemptionID:         parseInt(r["redemption_id"]),
		VoucherID:            parseInt(r["voucher_id"]),
		VoucherNo:            r["voucher_no"],
		Result:               r["result"],
		Reason:               r["reason"],
		VoucherStatus:        r["voucher_status"],
		ConsumedQuantity:     parseInt(r["consumed_quantity"]),
		RemainingQuantity:    parseInt(r["remaining_quantity"]),
		OriginalRedemptionID: parseInt(r["original_redemption_id"]),
		OriginalScannedAt:    r["original_scanned_at"],
	}, nil
}

// ---------------------------------------------------------------- 过期作业

// ExpireOverdue 把有效期已过的已出票券改成 expired（作业入口）。
//
// 口径在库里的 fn_expire_vouchers（db/migrations/028_voucher_expiry.sql），
// 这里只拼参数、只读结果 —— 不在这里判断「哪张券过期了」，
// 不在这里改券状态，不在这里发事件。
//
// 为什么要有这个作业：核销路径（008）刻意只落核销记录、不改券状态 ——
// 「过期只落核销记录，不改券状态 —— 券状态由过期作业统一改。
// 一件事一件事分开，才说得清是谁在什么时候把哪张票判成什么。」
// 那句话不是注释，是承诺。现在补上兑现它的那一半。
//
// 幂等：同一张券只会被改一次（第二次跑没有到期且仍是 issued 的券了）。
// 事件：状态一变，触发器 fn_emit_state_event 自动落一条 VoucherExpired ——
// 不在这儿手插事件。
func (s *Service) ExpireOverdue(limit int64) (int64, error) {
	if s.db == nil {
		return 0, fmt.Errorf("过期作业需要数据库连接")
	}
	if limit <= 0 {
		limit = 500
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT expired_count FROM fn_expire_vouchers(%s);`, store.Quote(limit)))
	if err != nil {
		return 0, store.PLError(err)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return parseInt(rows[0]["expired_count"]), nil
}

// Overdue 是过期作业漏跑时能看出来的现状。
type Overdue struct {
	// OverdueCount 是到期却还是 issued 的券数（作业跑完应该是 0）。
	OverdueCount int64
	// OldestValidTo / NewestValidTo 是这批券的有效期终点范围。
	OldestValidTo string
	NewestValidTo string
	// AffectedOrders 是这批券分散在多少张订单上。
	AffectedOrders int64
}

// ShowOverdue 读过期作业的现状（作业漏跑时看一眼就知道）。
//
// 只读，不推进。
func (s *Service) ShowOverdue() (*Overdue, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读过期现状需要数据库连接")
	}
	rows, err := s.db.Rows(
		`SELECT overdue_count,
                COALESCE(oldest_valid_to::text, '') AS oldest_valid_to,
                COALESCE(newest_valid_to::text, '') AS newest_valid_to,
                affected_orders
           FROM v_voucher_expiry_overdue;`)
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("过期现状视图没有返回结果")
	}
	r := rows[0]
	return &Overdue{
		OverdueCount:   parseInt(r["overdue_count"]),
		OldestValidTo:  r["oldest_valid_to"],
		NewestValidTo:  r["newest_valid_to"],
		AffectedOrders: parseInt(r["affected_orders"]),
	}, nil
}

// ---------------------------------------------------------------- 读侧

// Attempt 是一条核销记录（一次扫票）。
type Attempt struct {
	RedemptionID int64
	VoucherID    int64
	VoucherNo    string
	// Result 是这次扫票的结果。
	Result string
	// Reason 是没过或重复的原因。
	Reason string
	// ConsumedQuantity 是这次消耗的额度。
	ConsumedQuantity int64
	ScannedAt        string
	GateLocation     string
	DeviceID         string
	OperatorID       string
	GateID           int64
	GateOperatorID   int64
}

// VoucherState 是一张券的现状和它的核销流水。
type VoucherState struct {
	VoucherID int64
	VoucherNo string
	// Status 是券状态（pending / issued / used / void / expired / refunded）。
	Status string
	// ValidFrom / ValidTo 是券的有效期。
	ValidFrom string
	ValidTo   string
	// UsedAt 是核销时间。
	UsedAt string
	// UsedChannel 是这张券所属订单的销售渠道。
	UsedChannel string
	// Attempts 是核销流水，从新到旧。
	Attempts []Attempt
}

// Show 读一张券和它的核销流水。
//
// 这是只读的：不推进、不判断，只是把库里的现状读出来。
func (s *Service) Show(voucherID int64) (*VoucherState, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读凭证需要数据库连接")
	}
	if voucherID == 0 {
		return nil, fmt.Errorf("读凭证需要凭证 id")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT v.id, v.voucher_no, v.status,
                COALESCE(v.valid_from::text, '') AS valid_from,
                COALESCE(v.valid_to::text, '')   AS valid_to,
                COALESCE(v.used_at::text, '')    AS used_at,
                COALESCE(v.used_channel, '')     AS used_channel
           FROM voucher v
          WHERE v.id = %s;`, store.Quote(voucherID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("凭证 %d 不存在", voucherID)
	}
	r := rows[0]
	st := &VoucherState{
		VoucherID:   parseInt(r["id"]),
		VoucherNo:   r["voucher_no"],
		Status:      r["status"],
		ValidFrom:   r["valid_from"],
		ValidTo:     r["valid_to"],
		UsedAt:      r["used_at"],
		UsedChannel: r["used_channel"],
	}

	attempts, err := s.db.Rows(fmt.Sprintf(
		`SELECT r.id, r.voucher_id, v.voucher_no, r.result,
                COALESCE(r.reason, '') AS reason,
                COALESCE(r.consumed_quantity, 0) AS consumed_quantity,
                r.scanned_at::text AS scanned_at,
                COALESCE(r.gate_location, '') AS gate_location,
                COALESCE(r.device_id, '')      AS device_id,
                COALESCE(r.operator_id, '')    AS operator_id,
                COALESCE(r.gate_id, 0)         AS gate_id,
                COALESCE(r.gate_operator_id, 0) AS gate_operator_id
           FROM voucher_redemption r
           JOIN voucher v ON v.id = r.voucher_id
          WHERE r.voucher_id = %s
          ORDER BY r.scanned_at DESC, r.id DESC;`, store.Quote(voucherID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	for _, a := range attempts {
		st.Attempts = append(st.Attempts, Attempt{
			RedemptionID:     parseInt(a["id"]),
			VoucherID:        parseInt(a["voucher_id"]),
			VoucherNo:        a["voucher_no"],
			Result:           a["result"],
			Reason:           a["reason"],
			ConsumedQuantity: parseInt(a["consumed_quantity"]),
			ScannedAt:        a["scanned_at"],
			GateLocation:     a["gate_location"],
			DeviceID:         a["device_id"],
			OperatorID:       a["operator_id"],
			GateID:           parseInt(a["gate_id"]),
			GateOperatorID:   parseInt(a["gate_operator_id"]),
		})
	}
	return st, nil
}

// ---------------------------------------------------------------- 工具

// parseInt 解析整数；解析不了就返回 0。
func parseInt(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// jsonPayload 把 map 序列化成 JSON 文本；nil 给空对象。
func jsonPayload(m map[string]any) (string, error) {
	if m == nil {
		return "{}", nil
	}
	blob, err := json.Marshal(m)
	if err != nil {
		return "", err
	}
	return string(blob), nil
}

// quoteOrNull 空串 → NULL，否则给出 SQL 字面量。
//
// SQL 里空串和 NULL 不是一回事，别混。返回的是**已经转义好的字面量**，
// 不是原始值 —— 少一次 store.Quote 就是一次注入。
func quoteOrNull(s string) string {
	if strings.TrimSpace(s) == "" {
		return "NULL"
	}
	return store.Quote(s)
}

// quoteOrNullInt 0 → NULL，否则给出 SQL 字面量。
//
// id 是 0 还是 NULL，语义不一样：0 是「没有这张券」，NULL 是「没给这个参数」。
func quoteOrNullInt(v int64) string {
	if v == 0 {
		return "NULL"
	}
	return store.Quote(v)
}
