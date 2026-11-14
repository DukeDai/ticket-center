// Package sync 是同步落库的写者：抓 → 归一化 → 落库。
//
// 口径住在 spec/20-jobs.md §5.27，这里只实现它。
//
// 形状是「先算清楚再落」：抓回来的报文先归一化成 Catalog，
// 再解析成一份 Plan（每行都带着它解析出来的外键 id 与计数），
// 最后整份 Plan 在**一个事务**里落库。
//
// 为什么先算清楚再落：一次同步要落八张表，中间任何一步失败都会留下半套事实 ——
// 源商品在、变体不在，报价行指向一个不存在的变体。
// 先算清楚，失败就一行都不落；落了一半，下一次同步重跑会撞唯一键改成同一条，
// 幂等边界就是那八个唯一键（硬约束 3、spec §5.27 第一条）。
package sync

import (
	"context"
	"fmt"
	"time"

	"ticket-center/internal/config"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
)

// JobType 目录同步的作业类型（sync_job_log.job_type）。
const JobType = "catalog_sync"

// Stats 作业台账的计数。
//
// 键只用种子里的那五个 —— sync_job_log.stats 是 jsonb，
// 形状是我们自己定的，所以只写这五个，读的人不用猜还有没有第六个。
type Stats struct {
	Scanned int `json:"scanned"`
	Created int `json:"created"`
	Updated int `json:"updated"`
	Skipped int `json:"skipped"`
	Failed  int `json:"failed"`
}

// Catalog 一个源在一次同步里报出来的东西。
//
// 这是归一化之后、还没碰数据库的形状。
type Catalog struct {
	SupplierCode string
	Products     []normalize.Product
}

// ProductRows 一个源商品要落的行。
//
// ExternalID 是源侧的外部标识（幂等锚点的一半），
// ContentHash 是这份报文的摘要（变更检测靠它）。
type ProductRows struct {
	SupplierProductID int64
	ExternalID        string
	Title             string
	Raw               map[string]any
	SourceAttributes  map[string]any
	ContentHash       string
	Status            string
	// Disposition 这次同步对这一对的处置（新建 / 更新 / 跳过）。
	//
	// 它由**变更检测**得出：报文哈希比库里的旧哈希。
	//
	// **它是台账上的一个数，不是写路径的开关**：跳过的那些商品，
	// 它们的变体与报价行照样写。
	//
	// 为什么：商品级哈希算的是**商品详情报文**，
	// 报价行不在里面 —— 源侧只改价不改商品时，哈希不变，
	// 而那一条报价是**新事实**（C 端卡片的价格就靠它）。
	// 「跳过就不写」会让价格永远停在旧值 —— 读模型永远是旧的。
	//
	// 所以口径是：**写路径一律幂等（ON CONFLICT DO UPDATE 写同样的值），
	// 变更是用来报告的，不是用来决定写不写的**。
	Disposition Disposition
	Variants    []VariantRows
	// Mappings 这个源商品与各规范商品的映射行要落的状态。
	//
	// 状态是**算出来的**（spec §5.27 的两条路）：
	// 这一对已经有人判过 → active；覆盖精确且此前没有映射行 → active；
	// 其余 → pending_review。
	Mappings []ProductMappingRows
}

// ProductMappingRows 一条商品映射要落的行。
type ProductMappingRows struct {
	ProductID  int64
	Status     string
	IsPrimary  bool
	MatchType  string
	Confidence float64
	Evidence   map[string]any
	CreatedBy  string
}

// VariantRows 一个源变体要落的行。
//
// Numbers 是源侧的数值事实，按**事实名**索引（硬约束 4）：
// 事实名住在配置里，事实名到列的映射住在写者里。
// 键缺席 = 源侧没给约束（写 NULL），不是 0。
type VariantRows struct {
	SupplierVariantID int64
	ExternalVariantID string
	Title             string
	Attrs             map[string]any
	Raw               map[string]any
	PriceLocked       bool
	ValidDays         *int
	Status            string
	Coverage          normalize.Coverage
	Numbers           map[string]int
	// Covered 这个源变体覆盖住的规范变体（判定在库里，见 coveredVariants）。
	//
	// 一个源变体可以覆盖多个规范变体（方向 A：宽覆盖），
	// 所以这里是一个列表，不是一个 id。
	Covered []CoveredVariant
	// Mappings 这个源变体与各规范变体的映射行要落的状态。
	//
	// 状态是**算出来的**，不是猜的（spec §5.27）：
	// 父级的商品映射 active → 这里 active；否则 pending_review。
	// 「机器写的映射不许自己变成 active」（不变量 132-133）。
	Mappings []MappingRows
	// Prices 这个源变体上的报价行。
	//
	// 报价行挂在变体下（不是挂在商品下）：源报价行的幂等锚点
	// ux_spc_variant_scope 走的是 (supplier_variant_id, product_variant_id, date)，
	// 变体是它的一部分。
	Prices []PriceRows
}

// MappingRows 一条变体映射要落的行。
type MappingRows struct {
	ProductVariantID int64
	IsExact          bool
	Status           string
}

// CoveredVariant 库判出来的覆盖关系。
//
// IsExact 由 fn_variant_coverage_is_exact 给出：
// 覆盖得准不准是同一条规则，Go 侧不重算（硬约束 25）。
type CoveredVariant struct {
	ProductVariantID int64
	IsExact          bool
	// ProductID 这个规范变体所属的规范商品（商品映射要落它）。
	ProductID int64
}

// PriceRows 一条源报价行要落的行。
//
// ProductVariantID 是规范变体的外键：没有它，
// fn_source_quantity_limits 读不到这一行的份数区间（硬约束 34 的门禁就空转）。
type PriceRows struct {
	SupplierProductID  int64
	SupplierVariantID  int64
	ProductVariantID   int64
	ProductID          int64
	ResourceID         string
	Date               string
	Currency           string
	SupplierPrice      *float64
	NetPrice           *float64
	Stock              *int
	Status             string
	Raw                map[string]any
	SupplierTicketType int64
	MinQty             *int
	MaxQty             *int
}

// Plan 一次同步算出来的、要落库的行。
//
// 每行都带着解析出来的外键 id —— 落库时不再解析一遍。
// 解析不出来的那行不在 Plan 里（落库阶段就无从指错对象）。
type Plan struct {
	SupplierID int64
	Supplier   string
	Products   []ProductRows
	Stats      Stats
}

// Ledger 作业台账那一行。
type Ledger struct {
	SupplierID int64
	JobType    string
	Scope      map[string]any
	Status     string
	Stats      Stats
	Error      map[string]any
}

// Options 一次同步的输入。
type Options struct {
	// DB 是规范库（也是归档库 —— 归档表在同一个库里）。
	DB *store.DB
	// Config 是接入层配置：端点、ICODE、探针都在里面。
	Config *config.File
	// Rules 是归一化规则。
	Rules *normalize.Rules
	// Env 是源侧环境（sandbox / production），决定取哪一套 ICODE 与端点。
	Env string
	// EnvVars 是凭证来源（进程环境）。
	EnvVars map[string]string
	// Timeout 是单个源侧请求的超时。
	Timeout time.Duration
	// Start / End 是价格日历要拉的日期区间。空则用默认（今天 +7 天起 7 天）。
	Start string
	End   string
}

// Run 跑一次目录同步。
//
// 返回台账行与错误。台账行在出错时也有值 —— 作业失败也要留痕，
// 否则源健康视图上看着一切正常（spec §5.27：作业是它唯一的写者）。
func Run(ctx context.Context, code string, opts Options) (Ledger, error) {
	ledger := Ledger{
		SupplierID: 0,
		JobType:    JobType,
		Scope:      map[string]any{"supplier": code},
		Status:     "running",
	}

	// 源行必须挂在一个存在的 supplier 上。解析不到就当场报错，
	// 不许静默跳过 —— 静默跳过等于这次同步什么也没记，
	// 而源健康视图上还看着一切正常（硬约束 12、spec §5.27）。
	sup, err := store.LoadSupplier(opts.DB, code)
	if err != nil {
		ledger.Status = "failed"
		ledger.Error = errorPayload(err)
		return ledger, fmt.Errorf("解析源 %s 失败: %w", code, err)
	}
	if sup == nil {
		ledger.Status = "failed"
		err := fmt.Errorf("库里没有 code=%s 的源行", code)
		ledger.Error = errorPayload(err)
		return ledger, err
	}
	ledger.SupplierID = sup.ID

	// 台账先落一行 running：跑挂了就有一条「这次跑过但没跑完」的记录，
	// 而不是一个什么都没发生过的空白。
	if err := startLedger(opts.DB, ledger); err != nil {
		ledger.Status = "failed"
		ledger.Error = errorPayload(err)
		return ledger, err
	}

	catalog, err := fetch(ctx, code, opts)
	if err != nil {
		ledger.Status = "failed"
		ledger.Error = errorPayload(err)
		finishLedger(opts.DB, ledger)
		return ledger, err
	}

	plan, err := buildPlan(opts.DB, sup.ID, code, catalog)
	if err != nil {
		ledger.Status = "failed"
		ledger.Error = errorPayload(err)
		finishLedger(opts.DB, ledger)
		return ledger, err
	}

	if err := apply(opts.DB, plan); err != nil {
		ledger.Status = "failed"
		ledger.Error = errorPayload(err)
		finishLedger(opts.DB, ledger)
		return ledger, err
	}

	ledger.Status = "success"
	ledger.Stats = plan.Stats
	finishLedger(opts.DB, ledger)
	return ledger, nil
}

// errorPayload 把错误落成台账的 error 段。
func errorPayload(err error) map[string]any {
	return map[string]any{
		"message": err.Error(),
		"class":   errorClass(err),
	}
}
