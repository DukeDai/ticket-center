package pricing

import (
	"strconv"
	"strings"
	"testing"

	"ticket-center/internal/store"
	"ticket-center/internal/testdb"
)

// seeded 起一个带种子数据的一次性库。
//
// 种子里的日期是相对的（current_date + N），所以测试不能写死日期，
// 必须从库里把「哪一行、什么日期」查出来 —— 否则测试会在换日那天开始红。
func seeded(t *testing.T) (*Calculator, *store.DB) {
	t.Helper()
	name := testdb.New(t, testdb.Options{Seed: true})
	db := store.New(name)
	return New(db), db
}

func mustRows(t *testing.T, db *store.DB, sql string) []map[string]string {
	t.Helper()
	rows, err := db.Rows(sql)
	if err != nil {
		t.Fatalf("查询失败：%v", err)
	}
	if len(rows) == 0 {
		t.Fatal("没有取到数据")
	}
	return rows
}

// TestQuoteMatchesPriceCalendar 锁住「定价只有一份实现」这条合同：
// 库里每一行在售售价，都必须等于定价函数算出来的那个价。
func TestQuoteMatchesPriceCalendar(t *testing.T) {
	calc, db := seeded(t)
	rows := mustRows(t, db, `
		SELECT product_variant_id, date, channel_id, currency,
		       cost_price, sell_price, list_price, cost_source_product_id
		  FROM price_calendar
		 WHERE status = 'active' AND product_variant_id IS NOT NULL
		 ORDER BY id;`)

	for _, r := range rows {
		var variant int64
		mustInt(t, r["product_variant_id"], &variant)
		var channel int64
		mustInt(t, r["channel_id"], &channel)

		var priceChannel *int64
		if channel != 0 {
			priceChannel = &channel
		}
		q, err := calc.Quote(variant, r["date"], channel, priceChannel)
		if err != nil {
			t.Fatalf("变体 %s @ %s 定价失败：%v", r["product_variant_id"], r["date"], err)
		}
		if q == nil {
			t.Fatalf("变体 %s @ %s 在库里明明有售价 %s，定价却给不出结果",
				r["product_variant_id"], r["date"], r["sell_price"])
		}
		if q.SellPrice != r["sell_price"] {
			t.Errorf("变体 %s @ %s：定价给 %s，库里是 %s",
				r["product_variant_id"], r["date"], q.SellPrice, r["sell_price"])
		}
		if q.CostPrice != r["cost_price"] {
			t.Errorf("变体 %s @ %s：成本定价给 %s，库里是 %s",
				r["product_variant_id"], r["date"], q.CostPrice, r["cost_price"])
		}
		if q.ListPrice != r["list_price"] {
			t.Errorf("变体 %s @ %s：划线价定价给 %s，库里是 %s",
				r["product_variant_id"], r["date"], q.ListPrice, r["list_price"])
		}
		if q.Currency != strings.TrimSpace(r["currency"]) {
			t.Errorf("变体 %s @ %s：币种定价给 %s，库里是 %s",
				r["product_variant_id"], r["date"], q.Currency, r["currency"])
		}
	}
}

// TestLockedPriceIsSourceListPrice 锁价行：售价必须等于源方挂牌价，不加价。
func TestLockedPriceIsSourceListPrice(t *testing.T) {
	calc, db := seeded(t)
	rows := mustRows(t, db, `
		SELECT pc.product_variant_id, pc.date, pc.sell_price, pc.cost_source_product_id,
		       spc.supplier_price, spc.currency
		  FROM price_calendar pc
		  JOIN supplier_price_calendar spc
		    ON spc.supplier_product_id = pc.cost_source_product_id
		   AND spc.product_variant_id = pc.product_variant_id
		   AND spc.date = pc.date
		   AND spc.status = 'available'
		 WHERE pc.status = 'active' AND pc.price_locked
		 ORDER BY pc.id;`)
	if len(rows) == 0 {
		t.Fatal("种子数据里没有锁价行，这条测试就没意义了")
	}

	for _, r := range rows {
		var variant int64
		mustInt(t, r["product_variant_id"], &variant)
		q, err := calc.Quote(variant, r["date"], 0, nil)
		if err != nil {
			t.Fatalf("变体 %s 定价失败：%v", r["product_variant_id"], err)
		}
		if q == nil {
			t.Fatalf("变体 %s 锁价行没有定价结果", r["product_variant_id"])
		}
		if !q.PriceLocked {
			t.Errorf("变体 %s：库里标了锁价，定价结果没标", r["product_variant_id"])
		}
		if q.SellPrice != r["sell_price"] {
			t.Errorf("变体 %s：锁价售价 %s ≠ 库里 %s",
				r["product_variant_id"], q.SellPrice, r["sell_price"])
		}
		if q.ListPrice != q.SellPrice {
			t.Errorf("变体 %s：锁价行不该有划线价（划线价 %s，售价 %s）",
				r["product_variant_id"], q.ListPrice, q.SellPrice)
		}
	}
}

// TestFxTraceSameCurrency 源币种与本行币种相同：没有折算，就没有快照。
// 留一个假的快照日期，等于声称「这次折算用过这份汇率」—— 对账时会去查一份不存在的折算。
func TestFxTraceSameCurrency(t *testing.T) {
	calc, db := seeded(t)
	rows := mustRows(t, db, `
		SELECT pc.product_variant_id, pc.date, pc.currency, pc.fx_rate, pc.fx_as_of
		  FROM price_calendar pc
		  JOIN supplier_price_calendar spc
		    ON spc.supplier_product_id = pc.cost_source_product_id
		   AND spc.product_variant_id = pc.product_variant_id
		   AND spc.date = pc.date
		   AND spc.status = 'available'
		 WHERE pc.status = 'active' AND spc.currency = pc.currency
		 ORDER BY pc.id;`)
	if len(rows) == 0 {
		t.Fatal("种子数据里没有同币种的售价行")
	}

	for _, r := range rows {
		var variant int64
		mustInt(t, r["product_variant_id"], &variant)
		q, err := calc.Quote(variant, r["date"], 0, nil)
		if err != nil {
			t.Fatalf("变体 %s 定价失败：%v", r["product_variant_id"], err)
		}
		if q.FxAsOf != "" {
			t.Errorf("变体 %s：同币种没有折算，却留了快照日期 %s",
				r["product_variant_id"], q.FxAsOf)
		}
		if !isOne(q.FxRate) {
			t.Errorf("变体 %s：同币种的折算因子应为 1，实际 %s", r["product_variant_id"], q.FxRate)
		}
	}
}

// TestFxTraceCrossCurrency 跨币种：必须留快照日期，且留痕的因子能复算出来。
func TestFxTraceCrossCurrency(t *testing.T) {
	calc, db := seeded(t)
	rows := mustRows(t, db, `
		SELECT pc.product_variant_id, pc.date, pc.currency, pc.fx_rate, pc.fx_as_of
		  FROM price_calendar pc
		  JOIN supplier_price_calendar spc
		    ON spc.supplier_product_id = pc.cost_source_product_id
		   AND spc.product_variant_id = pc.product_variant_id
		   AND spc.date = pc.date
		   AND spc.status = 'available'
		 WHERE pc.status = 'active' AND spc.currency <> pc.currency
		 ORDER BY pc.id;`)
	if len(rows) == 0 {
		t.Fatal("种子数据里没有跨币种的售价行")
	}

	for _, r := range rows {
		var variant int64
		mustInt(t, r["product_variant_id"], &variant)
		q, err := calc.Quote(variant, r["date"], 0, nil)
		if err != nil {
			t.Fatalf("变体 %s 定价失败：%v", r["product_variant_id"], err)
		}
		if q.FxAsOf == "" {
			t.Errorf("变体 %s：跨币种折算却没有快照日期", r["product_variant_id"])
		}
		if isOne(q.FxRate) {
			t.Errorf("变体 %s：跨币种的折算因子不该是 1", r["product_variant_id"])
		}
		// 留痕日期必须能独立复算出同一个因子。
		got, err := db.Scalar("SELECT round(fn_fx_pair_rate(spc.currency, pc.currency, pc.fx_as_of), 8) " +
			"FROM price_calendar pc " +
			"JOIN supplier_price_calendar spc ON spc.supplier_product_id = pc.cost_source_product_id " +
			"  AND spc.product_variant_id = pc.product_variant_id AND spc.date = pc.date " +
			"  AND spc.status = 'available' " +
			"WHERE pc.product_variant_id = " + r["product_variant_id"] +
			"  AND pc.date = " + store.Quote(r["date"]) + ";")
		if err != nil {
			t.Fatalf("复算折算因子失败：%v", err)
		}
		if got != q.FxRate {
			t.Errorf("变体 %s：按留痕日期 %s 复算出 %s，与留痕的 %s 不一致",
				r["product_variant_id"], q.FxAsOf, got, q.FxRate)
		}
	}
}

// TestPricedSourceIsRoutePick 定价采用的源必须就是路由选中的源。
// 两边分叉 = 按 A 源的价格卖、按 B 源出票。
func TestPricedSourceIsRoutePick(t *testing.T) {
	_, db := seeded(t)
	rows := mustRows(t, db, `
		SELECT pc.product_variant_id, pc.date, pc.channel_id, pc.cost_source_product_id
		  FROM price_calendar pc
		 WHERE pc.status = 'active' AND pc.product_variant_id IS NOT NULL
		 ORDER BY pc.id;`)

	for _, r := range rows {
		var variant int64
		mustInt(t, r["product_variant_id"], &variant)
		var channel int64
		mustInt(t, r["channel_id"], &channel)
		pick, err := db.Scalar(
			"SELECT rc.supplier_product_id FROM fn_route_candidates(" +
				strconv.FormatInt(variant, 10) + ", " + store.Quote(r["date"]) + ", " +
				"CASE WHEN " + strconv.FormatInt(channel, 10) + " = 0 THEN fn_default_context_channel() ELSE " +
				strconv.FormatInt(channel, 10) + " END, " +
				"fn_price_row_currency(" + strconv.FormatInt(channel, 10) + ")) rc " +
				"WHERE rc.route_rank = 1;")
		if err != nil {
			t.Fatalf("取路由首选源失败：%v", err)
		}
		if pick == "" {
			// 套装没有路由候选：它的供给就是声明的那个整套源 SKU。
			// 定价用的源必须就是它 —— 换个源就是「按 A 源的价格卖、按 B 源出票」。
			want, err := db.Scalar(
				"SELECT sv.supplier_product_id FROM supplier_variant_bundle svb " +
					"JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id " +
					"WHERE svb.product_variant_id = " + strconv.FormatInt(variant, 10) + " " +
					"AND svb.status = 'active';")
			if err != nil {
				t.Fatalf("取套装声明的整套源失败：%v", err)
			}
			if want != r["cost_source_product_id"] {
				t.Errorf("变体 %s @ %s：套装定价用了源 %s，套装声明的是 %s",
					r["product_variant_id"], r["date"], r["cost_source_product_id"], want)
			}
			continue
		}
		if pick != r["cost_source_product_id"] {
			t.Errorf("变体 %s @ %s：定价用了源 %s，路由选的是 %s",
				r["product_variant_id"], r["date"], r["cost_source_product_id"], pick)
		}
	}
}

// TestRepriceRestoresPrices 被改坏的售价行，重算后必须回到定价函数的口径。
func TestRepriceRestoresPrices(t *testing.T) {
	calc, db := seeded(t)
	row := mustRows(t, db, `
		SELECT id, product_variant_id, date FROM price_calendar
		 WHERE status = 'active' AND product_variant_id IS NOT NULL
		 ORDER BY id LIMIT 1;`)[0]

	if err := db.Exec("UPDATE price_calendar SET sell_price = 1.00, cost_price = 1.00 WHERE id = " + row["id"] + ";"); err != nil {
		t.Fatalf("故意改坏售价行失败：%v", err)
	}
	if _, err := calc.Reprice(); err != nil {
		t.Fatalf("重算失败：%v", err)
	}

	got, err := db.Scalar("SELECT sell_price FROM price_calendar WHERE id = " + row["id"] + ";")
	if err != nil {
		t.Fatalf("读回售价失败：%v", err)
	}
	if got == "1.00" {
		t.Errorf("变体 %s @ %s：重算之后售价还是被改坏的 1.00", row["product_variant_id"], row["date"])
	}
	missing, err := calc.Unpriced()
	if err != nil {
		t.Fatalf("查未定价行失败：%v", err)
	}
	if len(missing) != 0 {
		t.Errorf("重算之后仍有 %d 行没有定价：%v", len(missing), missing)
	}
}

// TestRepriceClearsPricesWhenSourceGone 源没了，价格必须跟着没。
// 留着旧价 = 卖一个已经买不到的东西。
func TestRepriceClearsPricesWhenSourceGone(t *testing.T) {
	calc, db := seeded(t)
	listing := mustRows(t, db, `
		SELECT cl.id AS listing_id, cl.product_id, cls.supplier_product_id
		  FROM channel_listing cl
		  JOIN channel_listing_source cls ON cls.channel_listing_id = cl.id AND cls.enabled
		 WHERE (SELECT count(*) FROM channel_listing_source c2
		         WHERE c2.channel_listing_id = cl.id AND c2.enabled) = 1
		 ORDER BY cl.id LIMIT 1;`)[0]

	if err := db.Exec("UPDATE channel_listing_source SET enabled = false WHERE channel_listing_id = " +
		listing["listing_id"] + ";"); err != nil {
		t.Fatalf("停用源失败：%v", err)
	}
	if _, err := calc.Reprice(); err != nil {
		t.Fatalf("重算失败：%v", err)
	}

	stale, err := db.Scalar("SELECT count(*) FROM price_calendar " +
		"WHERE product_id = " + listing["product_id"] +
		"  AND status = 'active' AND sell_price IS NOT NULL;")
	if err != nil {
		t.Fatalf("统计残留售价失败：%v", err)
	}
	if stale != "0" {
		t.Errorf("源已停用，却还有 %s 行挂着售价", stale)
	}
}

// TestQuoteWithoutCandidate 没有任何候选源时返回「没有价格」，不是零价。
// 零价会被当成免费，这是最危险的一种错。
func TestQuoteWithoutCandidate(t *testing.T) {
	calc, _ := seeded(t)
	q, err := calc.Quote(999999, "2026-01-01", 0, nil)
	if err != nil {
		t.Fatalf("不存在的变体不该报错：%v", err)
	}
	if q != nil {
		t.Errorf("不存在的变体给出了报价：%+v", q)
	}
}

// isOne 判断一个十进制字符串是不是 1（1 与 1.00000000 都算）。
func isOne(s string) bool {
	f, err := strconv.ParseFloat(s, 64)
	return err == nil && f == 1
}

func mustInt(t *testing.T, s string, out *int64) {
	t.Helper()
	var n int64
	for _, c := range s {
		if c < '0' || c > '9' {
			t.Fatalf("不是整数：%q", s)
		}
		n = n*10 + int64(c-'0')
	}
	*out = n
}
