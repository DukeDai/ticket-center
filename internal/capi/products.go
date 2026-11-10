package capi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"ticket-center/internal/variant"
)

// ProductCard 是一行列表页卡片。
//
// 价格与评分是 NUMERIC，**一律以字符串出**（Go 标准库没有十进制类型，
// 硬约束 5：禁止浮点）。jsonb 的两列是原样带出来的 JSON。
type ProductCard struct {
	ProductID         int64           `json:"product_id"`
	ChannelID         int64           `json:"channel_id"`
	ChannelCode       string          `json:"channel_code"`
	Locale            string          `json:"locale"`
	Title             string          `json:"title"`
	Subtitle          string          `json:"subtitle"`
	ThumbURL          string          `json:"thumb_url"`
	FromPrice         string          `json:"from_price"`
	ListPrice         string          `json:"list_price"`
	Currency          string          `json:"currency"`
	Rating            string          `json:"rating"`
	ReviewCount       int             `json:"review_count"`
	DurationMinutes   int             `json:"duration_minutes"`
	TagLabels         json.RawMessage `json:"tag_labels"`
	SellingPoints     json.RawMessage `json:"selling_points"`
	NextAvailableDate string          `json:"next_available_date"`
	AvailableDays     int             `json:"available_days"`
	CityName          string          `json:"city_name"`
	CategoryName      string          `json:"category_name"`
	MeetingPoint      string          `json:"meeting_point"`
	Latitude          string          `json:"latitude"`
	Longitude         string          `json:"longitude"`
	Status            string          `json:"status"`
	SortWeight        int             `json:"sort_weight"`
	SyncedAt          string          `json:"synced_at"`
}

// VariantRow 是一行变体：人群 / 轴取值 / 有效天数 / 退款口径 / 本渠道价格区间，
// 外加组合的构成摘要（异构融合方向 B 的差异）。
type VariantRow struct {
	ProductVariantID int64           `json:"product_variant_id"`
	ProductID        int64           `json:"product_id"`
	VariantCode      string          `json:"variant_code"`
	Title            string          `json:"title"`
	Audience         string          `json:"audience"`
	Axes             json.RawMessage `json:"axes"`
	ValidDays        int             `json:"valid_days"`
	Refundable       bool            `json:"refundable"`
	RefundFeePercent string          `json:"refund_fee_percent"`
	PriceMin         string          `json:"price_min"`
	PriceMax         string          `json:"price_max"`
	AvailableDays    int             `json:"available_days"`
	FirstDate        string          `json:"first_date"`
	LastDate         string          `json:"last_date"`
	IsCombo          bool            `json:"is_combo"`
	ComboAudience    string          `json:"combo_audience"`
	ComponentCount   int             `json:"component_count"`
	Composition      json.RawMessage `json:"composition"`
}

// CompositionRow 是一行组合成分。
//
// 字段全是语言无关的结构化事实：人群是编码不是文案，
// 份数与天数是数字 —— 「2 成人 + 1 儿童」这句话由前端按 locale 拼
// （硬约束 9：展示文案不进模型）。
type CompositionRow struct {
	ComponentVariantID int64  `json:"component_variant_id"`
	VariantCode        string `json:"variant_code"`
	Title              string `json:"title"`
	Sequence           int    `json:"sequence"`
	Quantity           string `json:"quantity"`
	AudienceCode       string `json:"audience_code"`
	ValidDays          int    `json:"valid_days"`
}

// CalendarCell 是一天。
//
// valid_to 是**库算好的有效期终点**（格子日期 + 有效天数），前端不许自己加一天 ——
// 应用侧加一天和库里加一天，早晚有一天对不上（不变量 77）。
type CalendarCell struct {
	Date        string `json:"date"`
	PriceMin    string `json:"price_min"`
	PriceMax    string `json:"price_max"`
	Status      string `json:"status"`
	SourceCount int    `json:"source_count"`
	ValidTo     string `json:"valid_to"`
	SyncedAt    string `json:"synced_at"`
}

type productListResponse struct {
	ChannelID int64         `json:"channel_id"`
	Locale    string        `json:"locale"`
	Total     int           `json:"total"`
	Items     []ProductCard `json:"items"`
}

type variantListResponse struct {
	ChannelID int64        `json:"channel_id"`
	ProductID int64        `json:"product_id"`
	Items     []VariantRow `json:"items"`
}

type compositionResponse struct {
	ChannelID int64            `json:"channel_id"`
	VariantID int64            `json:"product_variant_id"`
	Items     []CompositionRow `json:"items"`
}

type calendarResponse struct {
	ChannelID int64          `json:"channel_id"`
	VariantID int64          `json:"product_variant_id"`
	Items     []CalendarCell `json:"items"`
}

// handleHealth 探活：顺带探一次数据库，免得库挂了还报「健康」。
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if _, err := s.db.Scalar("SELECT 1;"); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "数据库不可达："+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "database": s.db.Name})
}

// handleProducts 出列表页卡片。
//
// 口径：卡片行来自读模型 c_product_card（v_c_listing_feed 只是给它补上
// 城市 / 品类 / 集合点的名字），**下架的卡片不出现在列表里**
// （status='offline'），售罄的仍在（前端画灰）。
func (s *Server) handleProducts(w http.ResponseWriter, r *http.Request) {
	channel, err := channelID(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	loc, err := locale(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	limit, offset, err := paging(r)
	if err != nil {
		badRequest(w, err)
		return
	}

	where := fmt.Sprintf("c.channel_id = %d AND c.locale = '%s' AND c.status <> 'offline'", channel, loc)
	totalRaw, err := s.db.Scalar(fmt.Sprintf("SELECT count(*) FROM c_product_card c WHERE %s", where))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "读卡片总数失败："+err.Error())
		return
	}
	total := atoi(totalRaw)

	// 每一列都要有别名：psql 的 CSV 输出把表达式原样当列名，
	// 几个 COALESCE 会挤成同一个列名，取值就全乱了。
	sql := `SELECT c.product_id AS product_id,
	               c.channel_id AS channel_id,
	               f.channel_code AS channel_code,
	               c.locale AS locale,
	               c.title AS title,
	               COALESCE(c.subtitle, '') AS subtitle,
	               COALESCE(c.thumb_url, '') AS thumb_url,
	               COALESCE(c.from_price::text, '') AS from_price,
	               COALESCE(c.list_price::text, '') AS list_price,
	               c.currency AS currency,
	               COALESCE(c.rating::text, '') AS rating,
	               c.review_count AS review_count,
	               COALESCE(c.duration_minutes, 0) AS duration_minutes,
	               c.tag_labels::text AS tag_labels,
	               c.selling_points::text AS selling_points,
	               COALESCE(c.next_available_date::text, '') AS next_available_date,
	               c.available_days AS available_days,
	               COALESCE(f.city_name, '') AS city_name,
	               COALESCE(f.category_name, '') AS category_name,
	               COALESCE(f.meeting_point, '') AS meeting_point,
	               COALESCE(f.latitude::text, '') AS latitude,
	               COALESCE(f.longitude::text, '') AS longitude,
	               c.status AS status,
	               c.sort_weight AS sort_weight,
	               c.synced_at::text AS synced_at
	          FROM c_product_card c
	          JOIN v_c_listing_feed f
	            ON f.channel_id = c.channel_id AND f.product_id = c.product_id AND f.locale = c.locale
	         WHERE ` + where + `
	         ORDER BY c.sort_weight DESC, c.product_id
	         LIMIT ` + strconv.Itoa(limit) + ` OFFSET ` + strconv.Itoa(offset)

	rows, err := s.db.Rows(sql)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "读卡片失败："+err.Error())
		return
	}
	items := make([]ProductCard, 0, len(rows))
	for _, r := range rows {
		items = append(items, ProductCard{
			ProductID:         atoi64(r["product_id"]),
			ChannelID:         atoi64(r["channel_id"]),
			ChannelCode:       r["channel_code"],
			Locale:            r["locale"],
			Title:             r["title"],
			Subtitle:          r["subtitle"],
			ThumbURL:          r["thumb_url"],
			FromPrice:         r["from_price"],
			ListPrice:         r["list_price"],
			Currency:          r["currency"],
			Rating:            r["rating"],
			ReviewCount:       atoi(r["review_count"]),
			DurationMinutes:   atoi(r["duration_minutes"]),
			TagLabels:         rawJSON(r["tag_labels"]),
			SellingPoints:     rawJSON(r["selling_points"]),
			NextAvailableDate: r["next_available_date"],
			AvailableDays:     atoi(r["available_days"]),
			CityName:          r["city_name"],
			CategoryName:      r["category_name"],
			MeetingPoint:      r["meeting_point"],
			Latitude:          r["latitude"],
			Longitude:         r["longitude"],
			Status:            r["status"],
			SortWeight:        atoi(r["sort_weight"]),
			SyncedAt:          r["synced_at"],
		})
	}
	writeJSON(w, http.StatusOK, productListResponse{
		ChannelID: channel,
		Locale:    loc,
		Total:     total,
		Items:     items,
	})
}

// handleVariants 出某个商品在某个渠道下的变体行。
//
// 变体行带的是**差异事实**：人群 / 轴取值 / 有效天数 / 退款口径 / 价格区间，
// 以及组合的构成摘要。事实来自 v_c_variant_feed（读模型），
// 不在这里 join 主数据重算 —— 重算就是第二份实现。
func (s *Server) handleVariants(w http.ResponseWriter, r *http.Request) {
	channel, err := channelID(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	productID, err := pathID(r, "product_id")
	if err != nil {
		badRequest(w, err)
		return
	}

	feed, err := variant.FeedRows(s.db, channel, productID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "读变体行失败："+err.Error())
		return
	}
	items := make([]VariantRow, 0, len(feed))
	for _, f := range feed {
		items = append(items, VariantRow{
			ProductVariantID: f.ProductVariantID,
			ProductID:        f.ProductID,
			VariantCode:      f.VariantCode,
			Title:            f.Title,
			Audience:         f.Audience,
			Axes:             rawJSON(f.Axes),
			ValidDays:        f.ValidDays,
			Refundable:       f.Refundable,
			RefundFeePercent: f.RefundFeePercent,
			PriceMin:         f.PriceMin,
			PriceMax:         f.PriceMax,
			AvailableDays:    f.AvailableDays,
			FirstDate:        f.FirstDate,
			LastDate:         f.LastDate,
			IsCombo:          f.IsCombo,
			ComboAudience:    f.ComboAudience,
			ComponentCount:   f.ComponentCount,
			Composition:      rawJSON(f.Composition),
		})
	}
	writeJSON(w, http.StatusOK, variantListResponse{
		ChannelID: channel,
		ProductID: productID,
		Items:     items,
	})
}

// handleComposition 出套餐 / 套装的成分清单。
//
// 渠道是必答的：成分明细是按渠道建的，一个套餐上了两个渠道就有两份，
// 不按渠道过滤会把份数数成两遍（SPEC §5.14）。
func (s *Server) handleComposition(w http.ResponseWriter, r *http.Request) {
	channel, err := channelID(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	variantID, err := pathID(r, "variant_id")
	if err != nil {
		badRequest(w, err)
		return
	}

	rows, err := variant.CompositionRows(s.db, channel, variantID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "读成分清单失败："+err.Error())
		return
	}
	items := make([]CompositionRow, 0, len(rows))
	for _, c := range rows {
		items = append(items, CompositionRow{
			ComponentVariantID: c.ComponentVariantID,
			VariantCode:        c.VariantCode,
			Title:              c.Title,
			Sequence:           c.Sequence,
			Quantity:           c.Quantity,
			AudienceCode:       c.AudienceCode,
			ValidDays:          c.ValidDays,
		})
	}
	writeJSON(w, http.StatusOK, compositionResponse{
		ChannelID: channel,
		VariantID: variantID,
		Items:     items,
	})
}

// handleCalendar 出变体的日历格子。
//
// valid_to 由库算好（格子日期 + 有效天数），前端不自己加一天。
func (s *Server) handleCalendar(w http.ResponseWriter, r *http.Request) {
	channel, err := channelID(r)
	if err != nil {
		badRequest(w, err)
		return
	}
	variantID, err := pathID(r, "variant_id")
	if err != nil {
		badRequest(w, err)
		return
	}
	from, err := dateParam(r, "from")
	if err != nil {
		badRequest(w, err)
		return
	}
	to, err := dateParam(r, "to")
	if err != nil {
		badRequest(w, err)
		return
	}
	if from != "" && to != "" && from > to {
		badRequest(w, fmt.Errorf("from (%s) 不能晚于 to (%s)", from, to))
		return
	}

	where := fmt.Sprintf("channel_id = %d AND product_variant_id = %d", channel, variantID)
	if from != "" {
		where += fmt.Sprintf(" AND date >= DATE '%s'", from)
	}
	if to != "" {
		where += fmt.Sprintf(" AND date <= DATE '%s'", to)
	}
	sql := `SELECT date::text AS date,
	               COALESCE(price_min::text, '') AS price_min,
	               COALESCE(price_max::text, '') AS price_max,
	               status AS status,
	               source_count AS source_count,
	               COALESCE(valid_to::text, '') AS valid_to,
	               synced_at::text AS synced_at
	          FROM c_variant_calendar WHERE ` + where + ` ORDER BY date`

	rows, err := s.db.Rows(sql)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "读日历失败："+err.Error())
		return
	}
	items := make([]CalendarCell, 0, len(rows))
	for _, r := range rows {
		items = append(items, CalendarCell{
			Date:        r["date"],
			PriceMin:    r["price_min"],
			PriceMax:    r["price_max"],
			Status:      r["status"],
			SourceCount: atoi(r["source_count"]),
			ValidTo:     r["valid_to"],
			SyncedAt:    r["synced_at"],
		})
	}
	writeJSON(w, http.StatusOK, calendarResponse{
		ChannelID: channel,
		VariantID: variantID,
		Items:     items,
	})
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}

func atoi64(s string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n
}
