// Package inventory 是库存预占链路的客户端接口。
//
// 库存的实现也只有一个：库里的那几个函数（db/migrations/009_inventory_hold.sql）。
// 这个包只负责把「要占几张」拼成参数、把结果读回来 —— 不在这里算还剩几张、
// 不在这里判断够不够、不在这里自己扣减。这里的口径和 internal/order /
// internal/fulfillment / internal/refund / internal/redemption 完全一致：
//
//   - 「还剩几张」是业务口径，在库里（fn_available_qty 是唯一实现）。
//     Go 侧再算一遍就会出现两份规则，票卖超了都不知道是哪份规则放行的；
//   - 「够不够」由库里的 fn_reserve_qty 判（它先锁源场次再判）。
//     Go 侧先查后判就是 TOCTOU —— 两个并发订单都会看到「还剩 1 张」；
//   - 「不知道还剩多少」是一个合法的状态，不是错误。没有源侧库存数据时
//     系统放行（硬拦等于把系统堵死），但把这个事实报回去，让调用方知道
//     这次卖的时候没有库存保护；
//   - 预占是事实，不许悄悄消失。释放、过期都落状态，不删记录。
//
// 所以 Go 侧只做四件事：拼参数、收结果、把库的报错原样带出去、把事实报上去。
package inventory

import (
	"fmt"
	"strconv"
	"strings"

	"ticket-center/internal/store"
)

// Service 是库存预占入口。
type Service struct {
	db *store.DB
}

// New 构造库存服务。
func New(db *store.DB) *Service { return &Service{db: db} }

// ---------------------------------------------------------------- 可售数

// Availability 是「这个源场次上还剩几张票」。
//
// Known 是这里最重要的一个字段：为 false 表示源侧没有库存数据，
// 我们**不知道**还剩几张。剩下的数字这时没有意义，别拿它做判断。
type Availability struct {
	// Known 表示源侧有没有库存数据（false = 不知道）。
	Known bool
	// AvailableQty 是源侧报的可售数（known=false 时为 0）。
	AvailableQty int64
	// CommittedQty 是我们已经从源侧可售里扣掉的量
	// （源侧还没算进去的已售 + 还占着没兑现的预占）。
	CommittedQty int64
	// RemainingQty 是还剩几张（known=false 时为 0）。
	RemainingQty int64
	// SoldQty 是我们在这个场次上已经兑现（sold）了多少张。
	SoldQty int64
	// HeldQty 是我们在这个场次上还占着（购物车预占）多少张。
	HeldQty int64
	// SourceStatus 是源侧的库存状态（如 in_stock / sold_out / on_hold）。
	SourceStatus string
	// SnapshotAt 是这份库存数据的快照时间。
	SnapshotAt string
}

// Available 查一个源场次上还剩几张票。
//
// 这是只读的：不预占、不扣减。要预占走 Hold。
func (s *Service) Available(supplierSessionID, ticketTypeID int64) (*Availability, error) {
	if s.db == nil {
		return nil, fmt.Errorf("查库存需要数据库连接")
	}
	if supplierSessionID == 0 {
		return nil, fmt.Errorf("查库存需要源场次 id")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT known, COALESCE(available_qty, 0) AS available_qty,
                COALESCE(committed_qty, 0) AS committed_qty,
                COALESCE(remaining_qty, 0) AS remaining_qty,
                COALESCE(sold_qty, 0) AS sold_qty,
                COALESCE(held_qty, 0) AS held_qty,
                COALESCE(source_status, '') AS source_status,
                COALESCE(snapshot_at::text, '') AS snapshot_at
           FROM fn_available_qty(%s, %s);`,
		store.Quote(supplierSessionID),
		quoteOrNullInt(ticketTypeID)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("查库存没有返回结果")
	}
	r := rows[0]
	return &Availability{
		Known:        r["known"] == "t" || r["known"] == "true",
		AvailableQty: parseInt(r["available_qty"]),
		CommittedQty: parseInt(r["committed_qty"]),
		RemainingQty: parseInt(r["remaining_qty"]),
		SoldQty:      parseInt(r["sold_qty"]),
		HeldQty:      parseInt(r["held_qty"]),
		SourceStatus: r["source_status"],
		SnapshotAt:   r["snapshot_at"],
	}, nil
}

// ---------------------------------------------------------------- 预占

// HoldRequest 是一次购物车预占。
type HoldRequest struct {
	// HoldNo 是预占号，也是幂等键。同一个号重复提交是同一笔预占，
	// 内容不同则报错（重放一次预占不等于多占一张票）。
	HoldNo string
	// ChannelID 是销售渠道。
	ChannelID int64
	// VariantID 是商品变体 id。
	VariantID int64
	// Quantity 要占几张。
	Quantity int64
	// VisitDate 是使用日期（YYYY-MM-DD）。
	VisitDate string
	// CartID 是购物车 id（0 表示不给）。
	CartID int64
	// TTLSeconds 是预占存活秒数（0 表示用库里默认的 900）。
	TTLSeconds int64
}

// HoldResult 是预占的结果。
type HoldResult struct {
	HoldID int64
	HoldNo string
	// Known 表示源侧有没有库存数据（false = 不知道还剩几张）。
	Known bool
	// AvailableQty 是源侧报的可售数。
	AvailableQty int64
	// CommittedQty 是我们已经承诺出去的量。
	CommittedQty int64
	// RemainingQty 是可售数减去已承诺量。
	RemainingQty int64
	// SourceStatus 是源侧的库存状态。
	SourceStatus string
	// SoldQty 是我们在这个场次上已经兑现了多少张。
	SoldQty int64
	// HeldQty 是我们在这个场次上还占着多少张。
	HeldQty int64
	// Created 表示这次是不是新建的（false = 命中幂等，返回上一次的结果）。
	Created bool
}

// Hold 占住库存（购物车预占）。
//
// 幂等靠预占号：同一个号再提交一次不会多占票，返回的是同一张预占。
// 同号异内容报错 —— 静默返回上一笔等于吞掉一次预占。
//
// 库存不足时库里的 fn_reserve_qty 会当场报错，错误原样带出来。
// 「不知道还剩多少」不算错：放行，但 Known=false，调用方要知道自己这次没有库存保护。
func (s *Service) Hold(req HoldRequest) (*HoldResult, error) {
	if s.db == nil {
		return nil, fmt.Errorf("预占库存需要数据库连接")
	}
	if strings.TrimSpace(req.HoldNo) == "" {
		return nil, fmt.Errorf("预占需要预占号（幂等键必填）")
	}
	if req.ChannelID == 0 {
		return nil, fmt.Errorf("预占需要渠道 id")
	}
	if req.VariantID == 0 {
		return nil, fmt.Errorf("预占需要变体 id")
	}
	if req.Quantity <= 0 {
		return nil, fmt.Errorf("预占数量不合法：%d", req.Quantity)
	}
	if strings.TrimSpace(req.VisitDate) == "" {
		return nil, fmt.Errorf("预占需要使用日期")
	}

	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT hold_id, hold_no, known,
                COALESCE(available_qty, 0) AS available_qty,
                COALESCE(committed_qty, 0) AS committed_qty,
                COALESCE(remaining_qty, 0) AS remaining_qty,
                COALESCE(sold_qty, 0) AS sold_qty,
                COALESCE(held_qty, 0) AS held_qty,
                COALESCE(source_status, '') AS source_status,
                created
           FROM fn_hold_inventory(
                   p_hold_no     => %s,
                   p_channel_id  => %s,
                   p_variant_id  => %s,
                   p_quantity    => %s,
                   p_visit_date  => %s::date,
                   p_cart_id     => %s,
                   p_ttl_seconds => %s);`,
		store.Quote(req.HoldNo),
		store.Quote(req.ChannelID),
		store.Quote(req.VariantID),
		store.Quote(req.Quantity),
		store.Quote(req.VisitDate),
		quoteOrNullInt(req.CartID),
		quoteOrNullInt(req.TTLSeconds)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("预占没有返回结果")
	}
	r := rows[0]
	return &HoldResult{
		HoldID:       parseInt(r["hold_id"]),
		HoldNo:       r["hold_no"],
		Known:        r["known"] == "t" || r["known"] == "true",
		AvailableQty: parseInt(r["available_qty"]),
		CommittedQty: parseInt(r["committed_qty"]),
		RemainingQty: parseInt(r["remaining_qty"]),
		SoldQty:      parseInt(r["sold_qty"]),
		HeldQty:      parseInt(r["held_qty"]),
		SourceStatus: r["source_status"],
		Created:      r["created"] == "t" || r["created"] == "true",
	}, nil
}

// ReleaseResult 是释放预占的结果。
type ReleaseResult struct {
	HoldID   int64
	HoldNo   string
	Status   string
	Released bool
}

// Release 释放一张预占（购物车清空、用户改数量、下单失败回滚）。
//
// 幂等：已经释放过的再释放一次不报错，只是返回 released=false。
// 记录不删 —— 「曾经占过、后来放了」本身就是事实。
func (s *Service) Release(holdNo, reason string) (*ReleaseResult, error) {
	if s.db == nil {
		return nil, fmt.Errorf("释放预占需要数据库连接")
	}
	if strings.TrimSpace(holdNo) == "" {
		return nil, fmt.Errorf("释放预占需要预占号")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT hold_id, hold_no, status, released
           FROM fn_release_hold(%s, %s);`,
		store.Quote(holdNo),
		quoteOrNull(reason)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("释放预占没有返回结果")
	}
	r := rows[0]
	return &ReleaseResult{
		HoldID:   parseInt(r["hold_id"]),
		HoldNo:   r["hold_no"],
		Status:   r["status"],
		Released: r["released"] == "t" || r["released"] == "true",
	}, nil
}

// Expire 释放所有到期的购物车预占（作业入口）。
//
// 返回这次放掉了几张。不放掉就等于我们凭空少卖了一张票 ——
// 购物车里的票不占住，别的渠道就卖不掉。
func (s *Service) Expire(limit int64) (int64, error) {
	if s.db == nil {
		return 0, fmt.Errorf("过期预占需要数据库连接")
	}
	if limit <= 0 {
		limit = 500
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT expired_count FROM fn_expire_holds(%s);`, store.Quote(limit)))
	if err != nil {
		return 0, store.PLError(err)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return parseInt(rows[0]["expired_count"]), nil
}

// ---------------------------------------------------------------- 读侧

// HoldState 是一张预占的现状。
type HoldState struct {
	HoldID     int64
	HoldNo     string
	Status     string
	Quantity   int64
	Consumed   int64
	ChannelID  int64
	CartID     int64
	OrderID    int64
	VariantID  int64
	SessionID  int64
	TicketType int64
	SupplierID int64
	SupSession int64
	ExpiresAt  string
	ReleasedAt string
	ReleaseWhy string
	CreatedAt  string
}

// Show 读一张预占的现状。
//
// 这是只读的：不推进、不判断，只是把库里的现状读出来。
func (s *Service) Show(holdNo string) (*HoldState, error) {
	if s.db == nil {
		return nil, fmt.Errorf("读预占需要数据库连接")
	}
	if strings.TrimSpace(holdNo) == "" {
		return nil, fmt.Errorf("读预占需要预占号")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT id, hold_no, status, quantity, COALESCE(consumed_quantity, 0) AS consumed_quantity,
                channel_id, COALESCE(cart_id, 0) AS cart_id, COALESCE(order_id, 0) AS order_id,
                COALESCE(product_variant_id, 0) AS product_variant_id,
                COALESCE(product_session_id, 0) AS product_session_id,
                COALESCE(ticket_type_id, 0) AS ticket_type_id,
                COALESCE(supplier_id, 0) AS supplier_id,
                COALESCE(supplier_session_id, 0) AS supplier_session_id,
                COALESCE(expires_at::text, '') AS expires_at,
                COALESCE(released_at::text, '') AS released_at,
                COALESCE(release_reason, '') AS release_reason,
                created_at::text AS created_at
           FROM inventory_hold
          WHERE hold_no = %s;`, store.Quote(holdNo)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("预占 %s 不存在", holdNo)
	}
	r := rows[0]
	return &HoldState{
		HoldID:     parseInt(r["id"]),
		HoldNo:     r["hold_no"],
		Status:     r["status"],
		Quantity:   parseInt(r["quantity"]),
		Consumed:   parseInt(r["consumed_quantity"]),
		ChannelID:  parseInt(r["channel_id"]),
		CartID:     parseInt(r["cart_id"]),
		OrderID:    parseInt(r["order_id"]),
		VariantID:  parseInt(r["product_variant_id"]),
		SessionID:  parseInt(r["product_session_id"]),
		TicketType: parseInt(r["ticket_type_id"]),
		SupplierID: parseInt(r["supplier_id"]),
		SupSession: parseInt(r["supplier_session_id"]),
		ExpiresAt:  r["expires_at"],
		ReleasedAt: r["released_at"],
		ReleaseWhy: r["release_reason"],
		CreatedAt:  r["created_at"],
	}, nil
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

// quoteOrNull 空串 → NULL，否则给出 SQL 字面量。
func quoteOrNull(s string) string {
	if strings.TrimSpace(s) == "" {
		return "NULL"
	}
	return store.Quote(s)
}

// quoteOrNullInt 0 → NULL，否则给出 SQL 字面量。
func quoteOrNullInt(v int64) string {
	if v == 0 {
		return "NULL"
	}
	return store.Quote(v)
}
