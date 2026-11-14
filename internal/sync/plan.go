package sync

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"

	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
)

// 机器写的映射留痕用的人名。
//
// 「有人判过」= 存在一行 match_type='manual' 的映射（人写的），
// 或者 created_by 不是这几个机器写的名字之一。
// 这几个名字是**机器写者**的署名 —— 人写的是 'ops@demo' 这类。
var machineWriters = []string{"system@matcher", "dryrun", "sync"}

// machineWriterLits 是 machineWriters 的**转义后字面量**列表，
// 供拼进 SQL 的 NOT IN (...) 用（硬约束 40：值进 SQL 先转义）。
//
// 为什么单独留一份：plan.go 的 humanJudged 与 apply.go 的判定依据更新
// 要问的是**同一个问题**（「这一行是不是人写的」）。两份口径分开放，
// 迟早有一份改了另一份没改 —— 一份说「是机器写的」另一份说「是人写的」，
// 同一个行两个答案。这里只留一个来源。
var machineWriterLits = quoteAll(machineWriters)

// quoteAll 把一组字符串转成 SQL 字面量列表（带引号、可直接拼进 IN / NOT IN）。
func quoteAll(vals []string) []string {
	out := make([]string, 0, len(vals))
	for _, v := range vals {
		out = append(out, store.Quote(v))
	}
	return out
}

// buildPlan 把归一化产物算成一份要落库的行。
//
// **算清楚再落**：每行都带着解析出来的外键 id，落库时不再解析一遍。
// 解析不出来的那行不在 Plan 里 —— 落库阶段就无从指错对象。
//
// 覆盖判定**不在这儿算**（硬约束 15、25）：`fn_variant_covered` 是唯一实现，
// 这里只把 coverage 交给库问一句「哪些规范变体被覆盖住了」。
//
// 状态（active / pending_review）是**读出来的**，不是猜的：
// 它取决于「这一对已经有人判过没有」与「覆盖精确不精确」，
// 两个都是事实，事实要从库里读。
func buildPlan(db *store.DB, supplierID int64, code string, catalog Catalog) (Plan, error) {
	plan := Plan{
		SupplierID: supplierID,
		Supplier:   code,
	}

	// 变更检测：一次读完库里这些源商品的旧报文哈希。
	//
	// **一次查询，不是每个商品一次** —— 目录里几千个商品时，
	// 逐个查就是几千次往返，慢到看不出是同步还是卡住。
	existing, err := existingHashes(db, supplierID, externalIDsOf(catalog))
	if err != nil {
		return Plan{}, fmt.Errorf("读源商品现状失败: %w", err)
	}

	for _, product := range catalog.Products {
		rows, err := planProduct(db, supplierID, product)
		if err != nil {
			return Plan{}, fmt.Errorf("算商品 %s 的落库计划失败: %w", product.ExternalID, err)
		}
		rows.Disposition = dispositionOf(existing, product.ExternalID, rows.ContentHash)
		plan.Products = append(plan.Products, rows)
	}

	plan.Stats = countStats(plan.Products)
	return plan, nil
}

// externalIDsOf 取一份目录里所有源商品的外部标识。
func externalIDsOf(catalog Catalog) []string {
	out := make([]string, 0, len(catalog.Products))
	for _, p := range catalog.Products {
		out = append(out, p.ExternalID)
	}
	return out
}

// dispositionOf 判这一对是新建、更新还是跳过。
//
// 判据只有一条：**报文哈希与库里那一行一样吗**。
//
// - 库里没这一对 → 新建。
// - 库里有，哈希不同 → 源侧改了 → 更新。
// - 库里有，哈希相同 → 没改 → 跳过。
//
// 哈希存的是**整份报文**的 sha256，所以它变了一定是源侧改了什么东西
// （哪怕改的是一个我们不看的字段 —— 那也算「源侧改了」，
// 重写一遍的代价是几毫秒，而漏改的代价是「我们目录里的东西是旧的」）。
func dispositionOf(existing map[string]string, externalID, hash string) Disposition {
	old, ok := existing[externalID]
	if !ok {
		return DispositionCreated
	}
	if old == hash {
		return DispositionSkipped
	}
	return DispositionUpdated
}

// planProduct 算一个源商品要落的行。
func planProduct(db *store.DB, supplierID int64, product normalize.Product) (ProductRows, error) {
	rawJSON, err := rawToJSON(product.Raw)
	if err != nil {
		return ProductRows{}, err
	}

	rows := ProductRows{
		ExternalID:       product.ExternalID,
		Title:            product.Name,
		Raw:              product.Raw,
		SourceAttributes: sourceAttributes(product.Raw),
		ContentHash:      contentHash(rawJSON),
		// 源侧新来的商品，规范层还没有对应的 → pending_review（spec §5.27 第四条）。
		// 这一步只落事实，「它该对应我们哪个商品」是判断，不在这里做。
		Status: "pending_review",
	}

	// 源变体：先算变体行，再算它覆盖住了哪些规范变体。
	variantIdx := map[string]int{}
	for _, v := range product.Variants {
		vrows, err := planVariant(v)
		if err != nil {
			return ProductRows{}, err
		}
		variantIdx[v.ExternalID] = len(rows.Variants)
		rows.Variants = append(rows.Variants, vrows)
	}

	// 覆盖判定交给库：fn_variant_covered 是唯一实现。
	// 覆盖住的规范变体 id 与 is_exact 都是库判的，Go 侧不重算（硬约束 25）。
	for i, v := range product.Variants {
		covered, err := coveredVariants(db, v.Coverage)
		if err != nil {
			return ProductRows{}, fmt.Errorf("判变体 %s 的覆盖失败: %w", v.ExternalID, err)
		}
		rows.Variants[i].Covered = covered
	}

	// 商品映射：这个源商品对应哪些规范商品。
	//
	// 规范商品来自它覆盖住的规范变体 —— 源变体能履约哪个可售单元，
	// 那个可售单元就属于哪个规范商品。
	products := map[int64]bool{}
	for _, vr := range rows.Variants {
		for _, cv := range vr.Covered {
			products[cv.ProductID] = true
		}
	}

	// 商品映射的状态要看**库里已经有什么**（spec §5.27 的两条路）。
	//
	// ① 这一对**已经是 active** → 保持 active。
	// ② 这一对**已经有人判过**（库里存在一行人工写的映射）→ active；
	// ③ 覆盖是**精确**的且这一对此前没有任何映射行 → active（规则做的那一半）；
	// 其余 → pending_review（机器认出来了但人还没认）。
	//
	// **① 不能省**（这是最容易漏的一条）：
	// 规则判的那条路（③）要求「此前没有任何映射行」——
	// 而规则自己判过之后，这一行**就有了**。
	// 下一轮同步再判一次，「没有映射行」不成立 → 落回 pending_review →
	// 变体映射跟着落回 pending_review → 报价行不再写（只给 active 的映射写）→
	// **C 端的价格凭空消失**。
	//
	// 判过就是判过：不管是谁判的（人判的、还是上一轮规则判的），
	// 已经是 active 的映射就还是 active。
	// 同步作业只往「更严」的方向走，不往「更松」的方向走（spec §5.27）。
	judged, err := humanJudged(db, supplierID, product.ExternalID, sortedInt64s(products))
	if err != nil {
		return ProductRows{}, fmt.Errorf("读商品映射现状失败: %w", err)
	}
	existing, err := existingMappings(db, supplierID, product.ExternalID, sortedInt64s(products))
	if err != nil {
		return ProductRows{}, fmt.Errorf("读商品映射现状失败: %w", err)
	}

	for _, pid := range sortedInt64s(products) {
		status := "pending_review"
		switch {
		case existing[pid] == "active":
			// 已经是 active → 保持。
			// 谁判的不重要：人判的、还是上一轮规则判的，都算数。
			status = "active"
		case judged[pid]:
			// 人判过了 → 这一对可以直接 active。
			status = "active"
		case existing[pid] == "" && exactFor(rows.Variants, pid):
			// 规则判的：覆盖精确 + 此前没有这一行 → 规则可以自己判。
			status = "active"
		}
		rows.Mappings = append(rows.Mappings, ProductMappingRows{
			ProductID:  pid,
			Status:     status,
			IsPrimary:  false,
			MatchType:  "rule",
			Confidence: 0.95,
			Evidence:   map[string]any{"decoded_by": "sync"},
			CreatedBy:  "sync",
		})
	}

	// 源商品与源变体的状态跟着商品映射走。
	//
	// 为什么：**待审核的事实不许漏进可用路径**（不变量 132-133）。
	// 一个 pending_review 的源商品不许挂着 active 的商品映射 ——
	// 那就等于「还没人看，它已经在可售路径上了」。
	//
	// 所以只要有一对映射 active，这个源商品就是 active（人认了它，
	// 它进了我们的目录）；否则它是 pending_review（源侧报了它，
	// 但我们还没认它对应哪个规范商品）。
	//
	// 这与 spec §5.27「人先判…源商品与源变体也放成 active」是同一条口径。
	if anyActive(rows.Mappings) {
		rows.Status = "active"
		for i := range rows.Variants {
			rows.Variants[i].Status = "active"
		}
	}

	// 变体映射的状态看父级：父级商品映射 active 才 active（不变量 133）。
	for i, vr := range rows.Variants {
		for _, cv := range vr.Covered {
			status := "pending_review"
			if rows.mappingStatus(cv.ProductID) == "active" {
				status = "active"
			}
			rows.Variants[i].Mappings = append(rows.Variants[i].Mappings, MappingRows{
				ProductVariantID: cv.ProductVariantID,
				IsExact:          cv.IsExact,
				Status:           status,
			})
		}
		// 源变体的状态跟着它自己的变体映射走：有一个 active 的映射
		// 就说明这个源变体已经进了可售路径，它自己不该还停在 pending_review ——
		// 那会让读的人以为「这个源变体还没人认」，而它明明已经在卖。
		for _, m := range rows.Variants[i].Mappings {
			if m.Status == "active" {
				rows.Variants[i].Status = "active"
				break
			}
		}
	}

	// 源报价行：一条源报价行要写成 N 行（N = 它覆盖住且映射已生效的规范变体数）。
	// **只给 active 的映射写** —— pending_review 的映射不许漏进可用路径
	// （不变量 133、fn_route_candidates 的 svm.status='active'）。
	for _, v := range product.Variants {
		prices := product.Prices[v.ExternalID]
		if len(prices) == 0 {
			continue
		}
		idx := variantIdx[v.ExternalID]
		prows, err := planPrices(prices, rows.Variants[idx])
		if err != nil {
			return ProductRows{}, err
		}
		rows.Variants[idx].Prices = append(rows.Variants[idx].Prices, prows...)
	}

	return rows, nil
}

// mappingStatus 查这个规范商品上的商品映射状态。
func (p ProductRows) mappingStatus(productID int64) string {
	for _, m := range p.Mappings {
		if m.ProductID == productID {
			return m.Status
		}
	}
	return "pending_review"
}

// humanJudged 问库：这些 (源商品, 规范商品) 对里，哪些已经有人判过。
//
// 「有人判过」= 存在一行 match_type='manual' 的映射，
// 或者 created_by 不是机器写的 —— 机器写的署名是那几个固定名字。
//
// 这不是「库里有没有这一行」，而是「这一行是不是人写的」：
// 一行机器写的映射不算判过（它自己就是待审核的那个）。
func humanJudged(db *store.DB, supplierID int64, externalID string, productIDs []int64) (map[int64]bool, error) {
	out := map[int64]bool{}
	if len(productIDs) == 0 {
		return out, nil
	}

	// 这条 SQL 里有 IN 列表与 NOT IN 列表 —— 不是「一个条件片段」，
	// 用 NewSQL 的 And/Where 拼起来反而别扭（And 会自带 AND 前缀）。
	// 值一律走 store.Quote（硬约束 40）。
	parts := make([]string, 0, len(productIDs))
	for _, pid := range productIDs {
		parts = append(parts, store.Quote(pid))
	}

	sql := "SELECT m.product_id FROM product_mapping m " +
		"JOIN supplier_product sp ON sp.id = m.supplier_product_id " +
		"WHERE sp.supplier_id = " + store.Quote(supplierID) +
		" AND sp.external_id = " + store.Quote(externalID) +
		" AND (m.match_type = 'manual' OR (m.created_by IS NOT NULL AND m.created_by NOT IN (" +
		strings.Join(machineWriterLits, ", ") + ")))" +
		" AND m.product_id IN (" + strings.Join(parts, ", ") + ");"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out[parseID(r["product_id"])] = true
	}
	return out, nil
}

// anyActive 判断有没有一条 active 的商品映射。
func anyActive(ms []ProductMappingRows) bool {
	for _, m := range ms {
		if m.Status == "active" {
			return true
		}
	}
	return false
}

// existingMappings 问库：这些 (源商品, 规范商品) 对里，哪些已经有映射行了，
// 各自是什么状态。
//
// **返回状态而不是布尔**：三件事要分清 ——
//
//   - 没有这一行（「键不存在」）= 这一对还没出现过 → 规则可以自己判；
//   - 这一行是 pending_review = 机器认出来了但人还没认 → 保持待审核；
//   - 这一行是 active = 判过了（人判的，或上一轮规则判的）→ 保持 active。
//
// 折成一个布尔就把这三件事糊成两件，而第三件正是
// 「规则自己把映射判成 active，下一轮又把它判回 pending_review」的根因。
//
// 「已经有行」与「有人判过」也是两件事：
// 一行机器写的映射**存在**，但**没人判过**（它自己就是待审核的那个）——
// 所以另有一处判「谁判过」（humanJudged）。
func existingMappings(db *store.DB, supplierID int64, externalID string, productIDs []int64) (map[int64]string, error) {
	out := map[int64]string{}
	if len(productIDs) == 0 {
		return out, nil
	}

	parts := make([]string, 0, len(productIDs))
	for _, pid := range productIDs {
		parts = append(parts, store.Quote(pid))
	}

	sql := "SELECT m.product_id, m.status FROM product_mapping m " +
		"JOIN supplier_product sp ON sp.id = m.supplier_product_id " +
		"WHERE sp.supplier_id = " + store.Quote(supplierID) +
		" AND sp.external_id = " + store.Quote(externalID) +
		" AND m.product_id IN (" + strings.Join(parts, ", ") + ");"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out[parseID(r["product_id"])] = r["status"]
	}
	return out, nil
}

// exactFor 判断这个规范商品上有没有一个**精确覆盖**它的源变体。
//
// 精确 = 覆盖声明恰好等于这个可售单元的要求（不多不少）。
// 判定在库里（fn_variant_coverage_is_exact），这里只读结果。
//
// **一个就够**：这个源商品只要有一个源变体精确地盖住了这个规范商品，
// 这一对就算「规则判得准」。要求每个变体都精确是过头的 ——
// 宽覆盖的那个变体照样能履约这个可售单元。
func exactFor(variants []VariantRows, productID int64) bool {
	for _, vr := range variants {
		for _, cv := range vr.Covered {
			if cv.ProductID == productID && cv.IsExact {
				return true
			}
		}
	}
	return false
}

// planVariant 算一个源变体要落的行。
func planVariant(v normalize.Variant) (VariantRows, error) {
	rows := VariantRows{
		ExternalVariantID: v.ExternalID,
		Title:             v.Title,
		Attrs:             v.Attrs,
		Raw:               v.Raw,
		PriceLocked:       v.PriceLocked,
		Numbers:           v.Numbers,
		Coverage:          v.Coverage,
		// 源变体还没有对应的规范变体 → pending_review（spec §5.27 第四条）。
		Status: "pending_review",
	}

	// 兑现窗口：源侧肯兑现几天。源侧没报 → nil = 没给约束 = 不拦
	// （硬约束 22、34 同一条口径）。绝不折成 0。
	if days, ok := v.Numbers["valid_days"]; ok {
		d := days
		rows.ValidDays = &d
	}

	return rows, nil
}

// planPrices 算一个源变体上的报价行要落成几行。
//
// **一条源报价行写 N 行**（N = 它覆盖住且映射已生效的规范变体数）——
// 带 product_variant_id 的源报价行是 fn_route_candidates 的输入（硬约束 15），
// 没有它这个门禁就空转。
//
// **只给 active 的映射写**（spec §5.27）：这一条同时满足三件事 ——
// 不变量 133（pending_review 的映射不许漏进可用路径）、
// `fn_route_candidates` 的 `svm.status = 'active'`、
// 以及硬约束 34 的份数门禁（`fn_source_quantity_limits` 走同一套候选集）。
//
// 给 pending_review 的映射写报价 = 没审核就上架：
// 那条报价行会进候选集，价格会算出来，货会卖出去 ——
// 而它的覆盖关系还没人核过。
//
// 一个规范变体都没覆盖住 → 不落。落了就是一行指向 NULL 规范变体的报价 ——
// 它进不了任何路由，只会让「这个源报了多少条报价」这个数虚高。
func planPrices(prices []normalize.PriceRow, vr VariantRows) ([]PriceRows, error) {
	active := activeCovered(vr)
	if len(active) == 0 {
		return nil, nil
	}

	out := make([]PriceRows, 0, len(prices)*len(active))
	for _, pr := range prices {
		for _, cv := range active {
			row := PriceRows{
				ProductVariantID: cv.ProductVariantID,
				ProductID:        cv.ProductID,
				ResourceID:       pr.ResourceID,
				Date:             pr.Date,
				Currency:         pr.Currency,
				SupplierPrice:    pr.SalePrice,
				NetPrice:         pr.NetPrice,
				Stock:            pr.Stock,
				Status:           "available",
				Raw:              map[string]any{},
			}

			// 份数区间跟着源变体走：源侧把份数区间报在**商品详情**的资源上，
			// 不报在价格日历的资源上 —— 它先落在源变体的数值事实里，
			// 再**抄**到那个变体的每一条源报价行上。抄，不重算（硬约束 34）。
			if min, ok := vr.Numbers["min_qty"]; ok {
				m := min
				row.MinQty = &m
			}
			if max, ok := vr.Numbers["max_qty"]; ok {
				m := max
				row.MaxQty = &m
			}

			out = append(out, row)
		}
	}
	return out, nil
}

// activeCovered 挑出**映射已生效**的那些覆盖关系。
//
// 判据是变体映射的状态 —— 父级商品映射 active 才 active（不变量 133）。
// 覆盖关系本身（Covered）是「这个源变体能履约哪些可售单元」，
// 变体映射的状态是「这个判断有没有被认下来」。
// 两件事，不许混。
func activeCovered(vr VariantRows) []CoveredVariant {
	out := make([]CoveredVariant, 0, len(vr.Covered))
	for _, m := range vr.Mappings {
		if m.Status != "active" {
			continue
		}
		for _, cv := range vr.Covered {
			if cv.ProductVariantID == m.ProductVariantID {
				out = append(out, cv)
				break
			}
		}
	}
	return out
}

// coveredVariants 问库：这个 coverage 覆盖住了哪些规范变体。
//
// 判定在库里（fn_variant_covered / fn_variant_coverage_is_exact），
// Go 侧不重算 —— 重算就是第二份实现（硬约束 15、25）。
//
// 组合变体跳过：组合的供给走配方，直接挂源映射会让定价函数用
// **一个**源 SKU 的成本给整张套餐定价（收三个人的钱，出一张票）。
// 库里还有守卫触发器 fn_guard_combo_mapping 兜底，这里先跳过是不让批量插入整条失败。
func coveredVariants(db *store.DB, cov normalize.Coverage) ([]CoveredVariant, error) {
	// 这条 SQL 里 coverage 出现三次（is_exact 一次、covered 一次），
	// 所以它不是一个「条件片段」而是整条查询 ——
	// 用 NewSQL 拼条件片段（And/Where）在这里表达不了函数调用的参数位置。
	// JSON 字面量走 store.Quote（硬约束 40：值进 SQL 要先转义）。
	covJSON, err := jsonOrEmpty(covToMap(cov))
	if err != nil {
		return nil, fmt.Errorf("序列化 coverage 失败: %w", err)
	}
	covLit := store.Quote(covJSON) + "::jsonb"

	sql := "SELECT pv.id, pv.product_id, fn_variant_coverage_is_exact(" + covLit + ", pv.id) AS is_exact " +
		"FROM product_variant pv " +
		"WHERE pv.status = 'active' " +
		"AND pv.variant_role <> 'combo' " +
		"AND fn_variant_covered(" + covLit + ", pv.id) " +
		"ORDER BY pv.id;"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}

	res := make([]CoveredVariant, 0, len(rows))
	for _, r := range rows {
		res = append(res, CoveredVariant{
			ProductVariantID: parseID(r["id"]),
			ProductID:        parseID(r["product_id"]),
			IsExact:          r["is_exact"] == "t" || r["is_exact"] == "true",
		})
	}
	return res, nil
}

// covToMap 把 coverage 变成可落库的 map。
//
// 空的 axes 落成空对象而不是 null —— 两条路径对「没有 axes」的行为
// 必须一致：`fn_variant_covered` 读 `p_coverage->'axes'->req.axis_code`，
// `fn_variant_coverage_is_exact` 读 `jsonb_each(p_coverage->'axes')`，
// 显式给 `{}` 不留这个疑问。
func covToMap(cov normalize.Coverage) map[string]any {
	axes := map[string]any{}
	for k, v := range cov.Axes {
		axes[k] = v
	}
	excludes := cov.Excludes
	if excludes == nil {
		excludes = []string{}
	}
	return map[string]any{
		"axes":     axes,
		"excludes": excludes,
	}
}

// sourceAttributes 取源侧未归一化的属性。
//
// 它是**源侧报了什么**的原始形状（硬约束 4：源的结构不许泄漏进核心域，
// 所以这里存的是事实，不是我们理解的结构）。
// 报文本身就是这份事实，所以取报文本身。
func sourceAttributes(raw map[string]any) map[string]any {
	if raw == nil {
		return map[string]any{}
	}
	return raw
}

// contentHash 算一份源报文的内容哈希。
//
// 变更检测靠它（spec §5.27 第一条）：报文没变 → 哈希没变 → 这一行不更新。
func contentHash(rawJSON []byte) string {
	sum := sha256.Sum256(rawJSON)
	return hex.EncodeToString(sum[:])
}

// Disposition 一个源商品这次同步的处置。
//
// 它是**变更检测的结果**：报文比库里的旧报文变了没有。
type Disposition string

const (
	// DispositionCreated 库里没有这一对 → 新建。
	DispositionCreated Disposition = "created"
	// DispositionUpdated 库里有，但报文变了 → 更新。
	DispositionUpdated Disposition = "updated"
	// DispositionSkipped 库里有，报文没变 → 跳过（不改）。
	DispositionSkipped Disposition = "skipped"
)

// countStats 数这份计划里的行数。
//
// **三个计数是商品粒度的**，不是行粒度：变更检测靠的是
// `supplier_product.content_hash`（全表只有源商品有这一列），
// 所以「这个源商品变了没有」是能判定的最小单位。
// 变体与报价行跟着源商品走 —— 源商品没变，它们也没有新的事实可写。
//
// scanned 数的是**扫过的源商品数**（不是所有行的总数）：
// 它回答的是「这次同步看了多少个源商品」，与 created/updated/skipped 同一个口径，
// 四个数自洽 —— 读的人不用猜「scanned 是行还是商品」。
func countStats(products []ProductRows) Stats {
	st := Stats{}
	for _, p := range products {
		st.Scanned++
		switch p.Disposition {
		case DispositionCreated:
			st.Created++
		case DispositionUpdated:
			st.Updated++
		case DispositionSkipped:
			st.Skipped++
		}
	}
	return st
}

// existingHashes 读库里这些源商品现在的报文哈希。
//
// 变更检测的另一半：**库里没有这一对 = 没见过 = 新建**，
// 不拿别的源商品的哈希顶上。
//
// 键是源侧的 external_id —— 那是幂等锚点的一半（另一半是 supplier_id）。
func existingHashes(db *store.DB, supplierID int64, externalIDs []string) (map[string]string, error) {
	out := map[string]string{}
	if len(externalIDs) == 0 {
		return out, nil
	}

	parts := make([]string, 0, len(externalIDs))
	for _, id := range externalIDs {
		parts = append(parts, store.Quote(id))
	}

	sql := "SELECT external_id, coalesce(content_hash, '') AS content_hash FROM supplier_product " +
		"WHERE supplier_id = " + store.Quote(supplierID) +
		" AND external_id IN (" + strings.Join(parts, ", ") + ");"

	rows, err := db.Rows(sql)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out[r["external_id"]] = r["content_hash"]
	}
	return out, nil
}

// sortedInt64s 返回一个去重排序过的 id 列表。
//
// 排序不是为了好看 —— 是为了让同一个输入产出**逐字节相同**的 SQL，
// 重放一次同步的落库结果与上一次完全一致（spec §5.27 第一条）。
func sortedInt64s(set map[int64]bool) []int64 {
	out := make([]int64, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
