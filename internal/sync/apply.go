package sync

import (
	"fmt"
	"strings"

	"ticket-center/internal/store"
)

// apply 把一份 Plan 落库。
//
// **一次同步是一个事务**（spec §5.27 第一条）：多表写入要么全成要么全不成，
// 否则一次崩掉会留下「源商品落了、报价没落」的半截状态。
// 用 store.ExecScript（一个 psql 会话里跑多语句）而不是逐条 Exec。
//
// **幂等边界 = 现有的唯一键 + ON CONFLICT DO UPDATE**：
// 重放一次同步不会多落一个商品 —— 每张目标表的唯一锚点已经在那儿了，
// 写入路径不新增任何列。
//
// **变更检测靠 content_hash**：报文没变 → 哈希没变 → 台账记 skipped；
// 变了 → 哈希变了 → 台账记 updated，DO UPDATE 盖上新的报文与 last_synced_at。
//
// **skipped 不等于不写**：商品级哈希只覆盖商品详情，
// 报价行不在里面 —— 只改价不改商品的源侧，哈希不变，
// 而那一条报价是新事实。写路径一律幂等（同样的值写回去，事实不变），
// 变更是用来**报告**的，不是用来决定写不写的。
//
// **盖的不是整列**：源侧撤下来的事实要**退役而不是删除**
// —— 卖过的历史订单还指着它，删了就查不出来了。
//
// **写的是一条语句的 CTE 链**：每个源商品一条。
// 为什么一条语句而不是逐条：逐条要把 id 读回来（一次往返），
// 而一条语句里 `WITH sp AS (... RETURNING id), sv AS (... RETURNING id)`
// 把整条链一次跑完 —— 少一次往返，少一个「id 读回来了但事务已经回滚」的机会。
func apply(db *store.DB, plan Plan) error {
	if len(plan.Products) == 0 {
		return nil
	}

	var b strings.Builder
	b.WriteString("BEGIN;\n")

	for _, product := range plan.Products {
		stmt, err := productStatement(plan, product)
		if err != nil {
			return err
		}
		b.WriteString(stmt)
		b.WriteString("\n")
	}

	b.WriteString("COMMIT;\n")

	if _, err := db.ExecScript(b.String()); err != nil {
		return fmt.Errorf("落库失败: %w", err)
	}
	return nil
}

// productStatement 生成一个源商品的落库语句。
//
// 链的顺序是有讲究的 —— 每一层读上一层 RETURNING 出来的 id：
//
//	sp   源商品     → sp.id
//	sv   源变体     → sv.id            （读 sp.id）
//	pm   商品映射   → 读 sp.id + 规范商品 id
//	svm  变体映射   → 读 sv.id + 规范变体 id
//	spc  源报价行   → 读 sv.id + sp.id + 规范变体 id
//
// **状态是绑定的值，不是 SQL 里算的**：active / pending_review
// 在 plan 阶段就读出来了（那里要读「已经有人判过没有」），
// 这里只把它写下去 —— 落库阶段不再问一次「这个该 active 吗」。
func productStatement(plan Plan, p ProductRows) (string, error) {
	var ctes []string

	// ── sp：源商品 ────────────────────────────────────────────────────────
	// 幂等锚点 (supplier_id, external_id)。
	spSQL := store.NewSQL(
		"INSERT INTO supplier_product (supplier_id, external_id, external_code, raw_title, ",
		"raw_payload, source_attributes, availability_mode, content_hash, status, last_synced_at) ",
		"VALUES (",
	)
	spSQL = spSQL.List(plan.SupplierID)
	spSQL = spSQL.List(p.ExternalID)
	spSQL = spSQL.List(p.ExternalID)
	spSQL = spSQL.List(p.Title)
	spSQL = spSQL.ListJSON(p.Raw)
	spSQL = spSQL.ListJSON(p.SourceAttributes)
	spSQL = spSQL.List("pull_sync")
	spSQL = spSQL.List(p.ContentHash)
	spSQL = spSQL.List(p.Status)
	spSQL = spSQL.List("now()")
	spSQL = spSQL.EndList()
	spSQL = spSQL.Text(")")
	spSQL = spSQL.Text(" ON CONFLICT (supplier_id, external_id) DO UPDATE SET ")
	spSQL = spSQL.Text("external_code = EXCLUDED.external_code, ")
	spSQL = spSQL.Text("raw_title = EXCLUDED.raw_title, ")
	spSQL = spSQL.Text("raw_payload = EXCLUDED.raw_payload, ")
	spSQL = spSQL.Text("source_attributes = EXCLUDED.source_attributes, ")
	spSQL = spSQL.Text("content_hash = EXCLUDED.content_hash, ")
	spSQL = spSQL.Text("last_synced_at = EXCLUDED.last_synced_at, ")
	// status 只往「更严」的方向走：已经是 active 的不许被降级成 pending_review。
	// 降级是审批流的动作（把人撤了的判断撤掉），不是同步作业的。
	spSQL = spSQL.Text("status = CASE WHEN supplier_product.status = 'active' THEN 'active' ELSE EXCLUDED.status END")
	spSQL = spSQL.Text(" RETURNING id")

	sp, err := spSQL.String()
	if err != nil {
		return "", err
	}
	ctes = append(ctes, "sp AS ("+sp+")")

	// ── sv：源变体 ────────────────────────────────────────────────────────
	// 幂等锚点 (supplier_product_id, external_variant_id)。
	variantRefs := make([]string, 0, len(p.Variants))
	for i, v := range p.Variants {
		name := fmt.Sprintf("sv%d", i)
		variantRefs = append(variantRefs, name)

		svSQL := store.NewSQL(
			"INSERT INTO supplier_variant (supplier_product_id, external_variant_id, title, ",
			"variant_attrs, raw_payload, status, is_price_locked, valid_days) ",
			"SELECT sp.id, ",
		)
		svSQL = svSQL.List(v.ExternalVariantID)
		svSQL = svSQL.List(v.Title)
		svSQL = svSQL.ListJSON(v.Attrs)
		svSQL = svSQL.ListJSON(v.Raw)
		svSQL = svSQL.List(v.Status)
		svSQL = svSQL.List(v.PriceLocked)
		if v.ValidDays != nil {
			svSQL = svSQL.List(*v.ValidDays)
		} else {
			svSQL = svSQL.List(nil)
		}
		svSQL = svSQL.EndList()
		svSQL = svSQL.Text(" FROM sp")
		svSQL = svSQL.Text(" ON CONFLICT (supplier_product_id, external_variant_id) DO UPDATE SET ")
		svSQL = svSQL.Text("title = EXCLUDED.title, ")
		svSQL = svSQL.Text("variant_attrs = EXCLUDED.variant_attrs, ")
		svSQL = svSQL.Text("raw_payload = EXCLUDED.raw_payload, ")
		svSQL = svSQL.Text("is_price_locked = EXCLUDED.is_price_locked, ")
		svSQL = svSQL.Text("valid_days = EXCLUDED.valid_days, ")
		svSQL = svSQL.Text("status = CASE WHEN supplier_variant.status = 'active' THEN 'active' ELSE EXCLUDED.status END")
		svSQL = svSQL.Text(" RETURNING id")

		stmt, err := svSQL.String()
		if err != nil {
			return "", err
		}
		ctes = append(ctes, name+" AS ("+stmt+")")
	}

	// ── pm：商品映射 ──────────────────────────────────────────────────────
	// 幂等锚点 (supplier_product_id, product_id)。
	//
	// **永远不许把一行已经 active 的人工映射降级成 pending_review** ——
	// 同步作业只往「更严」的方向走，往「更松」的方向走是审批流的动作。
	// 所以 DO UPDATE 里 status 只升不降。
	for _, m := range p.Mappings {
		pmSQL := store.NewSQL(
			"INSERT INTO product_mapping (supplier_product_id, supplier_id, product_id, ",
			"match_type, confidence, match_evidence, is_primary, status, created_by) ",
			"SELECT sp.id, ",
		)
		pmSQL = pmSQL.List(plan.SupplierID)
		pmSQL = pmSQL.List(m.ProductID)
		pmSQL = pmSQL.List(m.MatchType)
		pmSQL = pmSQL.List(m.Confidence)
		pmSQL = pmSQL.ListJSON(m.Evidence)
		pmSQL = pmSQL.List(m.IsPrimary)
		pmSQL = pmSQL.List(m.Status)
		pmSQL = pmSQL.List(m.CreatedBy)
		pmSQL = pmSQL.EndList()
		pmSQL = pmSQL.Text(" FROM sp")
		pmSQL = pmSQL.Text(" ON CONFLICT (supplier_product_id, product_id) DO UPDATE SET ")
		// 判定依据只在**机器写的行**上更新 —— 人工行的人工依据不许被洗掉。
		//
		// 为什么：match_evidence 是「判定依据 JSON」，用处就是让匹配可解释、可人工复核
		// （docs/schema-design.md §3.1）。人工写下 {"signals":[...],"decided_by":"ops@demo"}
		// 之后被换成 {"decoded_by":"sync"}，丢的是两样东西：
		// 人工为什么这么判的（依据没了），以及这一行是谁写的
		// （开始说「机器写的」，而机器写的行恰恰是待审核的那类）。
		//
		// 所以「谁写的」这一栏，机器只许写机器自己的那一份。
		// 人工行的判定依据原样留着。
		pmSQL = pmSQL.Text("match_evidence = CASE WHEN product_mapping.match_type = 'manual' " +
			"OR (product_mapping.created_by IS NOT NULL AND product_mapping.created_by NOT IN (" +
			strings.Join(machineWriterLits, ", ") + ")) " +
			"THEN product_mapping.match_evidence ELSE EXCLUDED.match_evidence END, ")
		pmSQL = pmSQL.Text("status = CASE WHEN product_mapping.status = 'active' THEN 'active' ELSE EXCLUDED.status END")

		stmt, err := pmSQL.String()
		if err != nil {
			return "", err
		}
		ctes = append(ctes, "pm_"+fmt.Sprint(m.ProductID)+" AS ("+stmt+")")
	}

	// ── svm：变体映射 ─────────────────────────────────────────────────────
	// 幂等锚点 (supplier_variant_id, product_variant_id)。
	for i, v := range p.Variants {
		for _, m := range v.Mappings {
			covMap := covToMap(v.Coverage)
			svmSQL := store.NewSQL(
				"INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, ",
				"coverage, is_exact, match_type, confidence, status) ",
				"SELECT "+variantRefs[i]+".id, ",
			)
			svmSQL = svmSQL.List(m.ProductVariantID)
			svmSQL = svmSQL.ListJSON(covMap)
			svmSQL = svmSQL.List(m.IsExact)
			svmSQL = svmSQL.List("rule")
			svmSQL = svmSQL.List(0.95)
			svmSQL = svmSQL.List(m.Status)
			svmSQL = svmSQL.EndList()
			svmSQL = svmSQL.Text(" FROM " + variantRefs[i])
			svmSQL = svmSQL.Text(" ON CONFLICT (supplier_variant_id, product_variant_id) DO UPDATE SET ")
			svmSQL = svmSQL.Text("coverage = EXCLUDED.coverage, ")
			svmSQL = svmSQL.Text("is_exact = EXCLUDED.is_exact, ")
			// 状态只升不降：已经是 active 的不许被降级（不变量 133）。
			svmSQL = svmSQL.Text("status = CASE WHEN supplier_variant_mapping.status = 'active' THEN 'active' ELSE EXCLUDED.status END")

			stmt, err := svmSQL.String()
			if err != nil {
				return "", err
			}
			ctes = append(ctes, fmt.Sprintf("svm_%d_%d AS (%s)", i, m.ProductVariantID, stmt))
		}
	}

	// ── spc：源报价行 ─────────────────────────────────────────────────────
	// 幂等锚点 ux_spc_variant_scope
	// （UNIQUE (supplier_variant_id, product_variant_id, date) WHERE supplier_variant_id IS NOT NULL）。
	//
	// **同步作业写的每一行都带 supplier_variant_id** —— 所以它走 variant_scope 那个索引，
	// 不走 ux_spc_scope_legacy（那个留给不带变体的老行）。
	for i, v := range p.Variants {
		for _, pr := range v.Prices {
			spcSQL := store.NewSQL(
				"INSERT INTO supplier_price_calendar (supplier_product_id, supplier_variant_id, ",
				"product_variant_id, product_id, date, currency, supplier_price, net_price, ",
				"min_qty, max_qty, status, raw_payload) ",
				"SELECT sp.id, "+variantRefs[i]+".id, ",
			)
			spcSQL = spcSQL.List(pr.ProductVariantID)
			spcSQL = spcSQL.List(pr.ProductID)
			spcSQL = spcSQL.List(pr.Date)
			spcSQL = spcSQL.List(pr.Currency)
			spcSQL = spcSQL.List(derefFloat(pr.SupplierPrice))
			spcSQL = spcSQL.List(derefFloat(pr.NetPrice))
			spcSQL = spcSQL.List(derefInt(pr.MinQty))
			spcSQL = spcSQL.List(derefInt(pr.MaxQty))
			spcSQL = spcSQL.List(pr.Status)
			spcSQL = spcSQL.ListJSON(pr.Raw)
			spcSQL = spcSQL.EndList()
			spcSQL = spcSQL.Text(" FROM sp CROSS JOIN " + variantRefs[i])
			spcSQL = spcSQL.Text(" ON CONFLICT (supplier_variant_id, product_variant_id, date) WHERE supplier_variant_id IS NOT NULL DO UPDATE SET ")
			spcSQL = spcSQL.Text("currency = EXCLUDED.currency, ")
			spcSQL = spcSQL.Text("supplier_price = EXCLUDED.supplier_price, ")
			spcSQL = spcSQL.Text("net_price = EXCLUDED.net_price, ")
			spcSQL = spcSQL.Text("min_qty = EXCLUDED.min_qty, ")
			spcSQL = spcSQL.Text("max_qty = EXCLUDED.max_qty, ")
			spcSQL = spcSQL.Text("status = EXCLUDED.status, ")
			spcSQL = spcSQL.Text("raw_payload = EXCLUDED.raw_payload,")
			spcSQL = spcSQL.Text("synced_at = now() ")

			stmt, err := spcSQL.String()
			if err != nil {
				return "", err
			}
			ctes = append(ctes, fmt.Sprintf("spc_%d_%d AS (%s)", i, pr.ProductVariantID, stmt))
		}
	}

	var b strings.Builder
	b.WriteString("WITH ")
	b.WriteString(strings.Join(ctes, ",\n"))
	b.WriteString("\nSELECT 1;")

	return b.String(), nil
}

// derefFloat 解引用一个可选的金额。
//
// **nil 落 NULL，不是 0**：源侧没报这个价 = 没有这个价。
// 折成 0 就是「这个商品免费」—— 报价行会变成 0 元，
// 定价函数拿它当成本算，赔本卖出去（硬约束 22、34 同一条口径）。
func derefFloat(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

// derefInt 解引用一个可选的整数。
//
// **nil 落 NULL，不是 0**：同上。份数区间尤其不许折成 0 ——
// 0 份的上限是「一份都不能买」，与「源侧没给上限」完全相反。
func derefInt(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}
